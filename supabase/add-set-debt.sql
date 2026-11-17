-- Add / Set Carried Debt — NOT APPLIED LIVE (build 41, Nov 17, 2026).
-- APPLY VIA THE SUPABASE DASHBOARD SQL EDITOR BEFORE THE BUILD-41
-- TESTFLIGHT BUILD GOES OUT. The build-41 client calls the new
-- add_debt / set_debt RPCs and reads debt_adjustments; until this
-- file is applied those calls fail and the Edit Debt sheet cannot
-- save.
--
-- APPLY ORDER: any order relative to fund-icons.sql and
-- pending-topups.sql (also owed in build 41) — they touch different
-- tables. BUT this file alone does NOT make Add/Set work
-- end-to-end: the balance the app SHOWS comes from compute-week,
-- and the balance the next week-close STORES comes from the
-- week-close walk — both derive debt in TypeScript and must learn
-- about adjustments too (see "TS COMPANIONS" below). Until those
-- Edge Functions are redeployed, an added/set debt will show in
-- the RPC return but NOT in the Home/Funds/widget balance, and the
-- next week-close will drop it. The full feature needs SQL + TS +
-- redeploy; the client is built and the SQL is complete here.
--
-- WHY A TABLE, NOT A COLUMN: carried debt is DERIVED, not stored
-- (debt_balance_cents: latest close's outgoing debt − restoration
-- cuts − extra_fund/clear payments). A household-level column
-- would be invisible to the close walk, and mutating the latest
-- close's outgoing_debt_cents does not survive either — a week
-- locks only 28 days after it ends (engine.mjs isWeekLocked), so
-- the walk recomputes the latest close and would overwrite the
-- mutation. Adjustments therefore live in their own table, dated
-- to the week they were made, and every derivation adds them:
--
--   * debt_balance_cents (this file): + adjustments with
--     week_start after the latest close's week (same window as the
--     payments); with no close yet, + all adjustments.
--   * compute-week (TS companion): D = latest close outgoing −
--     cuts − payments + adjustments after that close (or, with no
--     close, the sum of all adjustments up to the current week).
--   * week-close walk (TS companion): Dws adds the adjustments
--     dated in week ws itself — each adjustment enters the chain
--     exactly once, at its week, then flows into the stored close
--     like any other debt. The restoration initialDebt (the
--     "priorClose" window) adds adjustments after the prior close
--     up to the purchase week, same as debt_balance_cents.
--
-- What this file adds:
--   * debt_adjustments — one row per manual change, with the
--     signed delta (amount_cents, + = added, − = reduced by a Set
--     below the current balance), the resulting balance
--     (balance_after_cents), kind ('add' / 'set'), week_start (the
--     current week, America/New_York Sunday), and note. The
--     Activity feed reads this table, so every change is listed.
--   * add_debt(p_household_id, p_amount_cents, p_note) — admin
--     only. Adds to the current derived balance, records the
--     adjustment, audits 'Carried debt increased', returns the new
--     balance.
--   * set_debt(p_household_id, p_amount_cents, p_note) — admin
--     only. Sets the balance to the given total: the adjustment is
--     the delta (target − current, signed, never 0 — the client
--     pre-validates and the RPC raises on a zero delta), audits
--     'Carried debt set', returns the new balance.
--
-- TS COMPANIONS (owed — separate work, Edge Functions deploy from
-- main via the GitHub integration, same as the build-30 server
-- deploy: cherry-pick to main, which redeploys week-close and
-- compute-week):
--   1. supabase/functions/_shared/engine.mjs — add
--      debtAdjustmentsAfterClose(rows, closeWeekStart, weekStart):
--      sum of amount_cents where week_start > closeWeekStart and
--      week_start <= weekStart (mirror debtPaymentsAfterClose).
--   2. supabase/functions/compute-week/index.ts — fetch
--      debt_adjustments (mirror the debt_payments fetch); D gains
--      + debtAdjustmentsAfterClose(...) when a close exists, else
--      the sum of all adjustments with week_start <= weekStart.
--   3. supabase/functions/week-close/index.ts — in the walk, Dws
--      gains + the adjustments dated in week ws (a by-week map,
--      mirror debtPaymentsByWeek); the restoration initialDebt
--      gains + debtAdjustmentsAfterClose(...) in the prior-close
--      window. No other walk line changes: the stored outgoing
--      then carries the adjustment forward like any other debt.
begin;
create table if not exists public.debt_adjustments (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  amount_cents integer not null check (amount_cents <> 0),
  balance_after_cents integer not null check (balance_after_cents >= 0),
  kind text not null check (kind in ('add', 'set')),
  week_start date not null,
  note text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.debt_adjustments enable row level security;
drop policy if exists "members read own debt adjustments" on public.debt_adjustments;
create policy "members read own debt adjustments"
  on public.debt_adjustments for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.debt_adjustments to authenticated;

-- The derived balance gains the manual adjustments (same window as
-- the payments: after the latest close). With no close yet, every
-- adjustment counts — a household with no closed week can still
-- carry manually added debt.
create or replace function public.debt_balance_cents(p_household_id uuid)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_now date := (now() at time zone 'America/New_York')::date;
  v_cur_week date := v_now - extract(dow from v_now)::int;
  v_close_week date;
  v_outgoing integer;
  v_cuts integer := 0;
  v_payments integer := 0;
  v_adjustments integer := 0;
begin
  select week_start, outgoing_debt_cents into v_close_week, v_outgoing
    from public.week_closes
    where household_id = p_household_id and week_start < v_cur_week
    order by week_start desc limit 1;
  if not found then
    select coalesce(sum(amount_cents), 0) into v_adjustments
      from public.debt_adjustments
      where household_id = p_household_id;
    return greatest(0, v_adjustments);
  end if;
  select coalesce(sum(debt_reduction_cents), 0) into v_cuts
    from public.restoration_entries
    where household_id = p_household_id
      and week_start > v_close_week and week_start <= v_cur_week;
  select coalesce(sum(amount_cents), 0) into v_payments
    from public.debt_payments
    where household_id = p_household_id
      and source in ('extra_fund', 'clear')
      and week_start > v_close_week and week_start <= v_cur_week;
  select coalesce(sum(amount_cents), 0) into v_adjustments
    from public.debt_adjustments
    where household_id = p_household_id
      and week_start > v_close_week and week_start <= v_cur_week;
  return greatest(0, v_outgoing - v_cuts - v_payments + v_adjustments);
end;
$$;

create or replace function public.add_debt(
  p_household_id uuid, p_amount_cents integer, p_note text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now date := (now() at time zone 'America/New_York')::date;
  v_cur_week date := v_now - extract(dow from v_now)::int;
  v_base integer;
  v_new integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  perform 1 from public.households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_base := public.debt_balance_cents(p_household_id);
  v_new := v_base + p_amount_cents;
  insert into public.debt_adjustments
    (household_id, amount_cents, balance_after_cents, kind, week_start, note, created_by)
  values (p_household_id, p_amount_cents, v_new, 'add', v_cur_week,
          left(btrim(coalesce(p_note, '')), 120), auth.uid());
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Carried debt increased',
          'Carried debt increased by ' || p_amount_cents::text || ' cents, from '
          || v_base::text || ' to ' || v_new::text || ' cents.'
          || case when btrim(coalesce(p_note, '')) <> '' then ' Note: ' || btrim(p_note) else '' end);
  return v_new;
end;
$$;
revoke execute on function public.add_debt(uuid, integer, text) from public;
grant execute on function public.add_debt(uuid, integer, text) to authenticated;

create or replace function public.set_debt(
  p_household_id uuid, p_amount_cents integer, p_note text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now date := (now() at time zone 'America/New_York')::date;
  v_cur_week date := v_now - extract(dow from v_now)::int;
  v_base integer;
  v_delta integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents < 0 then raise exception 'amount must not be negative'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  perform 1 from public.households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_base := public.debt_balance_cents(p_household_id);
  v_delta := p_amount_cents - v_base;
  if v_delta = 0 then raise exception 'debt is already that amount'; end if;
  insert into public.debt_adjustments
    (household_id, amount_cents, balance_after_cents, kind, week_start, note, created_by)
  values (p_household_id, v_delta, p_amount_cents, 'set', v_cur_week,
          left(btrim(coalesce(p_note, '')), 120), auth.uid());
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Carried debt set',
          'Carried debt set to ' || p_amount_cents::text || ' cents, from '
          || v_base::text || ' cents.'
          || case when btrim(coalesce(p_note, '')) <> '' then ' Note: ' || btrim(p_note) else '' end);
  return p_amount_cents;
end;
$$;
revoke execute on function public.set_debt(uuid, integer, text) from public;
grant execute on function public.set_debt(uuid, integer, text) to authenticated;
commit;
