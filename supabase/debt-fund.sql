-- Carried Debt fund (build 29, Nov 15, 2026 — owner-approved).
--
-- The problem: carried debt deducted dollar-for-dollar from the next
-- week's allowance, so the real household started every week at $0
-- (base $400.00 - carried debt $3,485.46 = allowance $0.00). The
-- owner called that unusable, and Home showed $0 with no reason why.
--
-- The model, in one paragraph:
-- - A household-level repayment RULE (debt_settings): each week a
--   portion of the BASE allowance pays the debt down — a percent of
--   the base (default 25%), a fixed dollar amount, or off. The rule
--   applies to the base only; temporary increases never feed it.
-- - The weekly payment P is computed by compute-week / week-close
--   from the rule (engine.mjs debtRulePayment) and capped at the
--   debt and at the base: P = min(D, rule, B). The engine's
--   baseAvailable is then B - P (not B - D), so the week keeps the
--   rest of the base. P defaults to D when no rule row exists AND
--   the table is missing — the pre-migration behaviour — so the
--   functions below and the edge functions keep working if they
--   deploy before this SQL is applied.
-- - DEBT PAYMENTS (debt_payments) reduce the balance: 'extra_fund'
--   (Pay from Extra Fund, via allocate_fund — same balance check
--   and typed-override rule as Spend from Fund), 'clear' (erase the
--   balance by hand), and 'surplus' (week-close: unspent allowance
--   pays the debt down FIRST, then the remainder becomes surplus
--   for the fund). Only 'extra_fund'/'clear' rows are subtracted
--   from the incoming debt D: a 'surplus' row is already inside the
--   close that recorded it (the close stores outgoing net of the
--   surplus payment), so subtracting it again would count the same
--   payment twice. The engine's debtPaymentsAfterClose enforces
--   this; the SQL helper below matches it.
-- - The current balance D is derived, never stored twice: latest
--   close's outgoing_debt_cents, minus restoration cuts and
--   extra_fund/clear payments posted after that close
--   (debt_balance_cents, same window as compute-week).
-- - A closed week keeps its stored debt_payment_cents
--   (week_closes.debt_payment_cents, written by week-close): a
--   later rule change never rewrites a closed week, same as the
--   B/T snapshot rule. NULL means a pre-migration close — the
--   reader falls back to the rule in effect now.
--
-- Rollout: apply this file, then redeploy the compute-week and
-- week-close edge functions (both declared in
-- supabase/config.toml). The native app reads debt_payment_cents
-- when the deployed function returns it and falls back to the old
-- display otherwise, so the app works against the old server too.
-- KNOWN CONSEQUENCE: the frozen web app (v69) renders its Weekly
-- sheet from carried_debt_cents as the deduction; with the new
-- server math the sheet's "Carried Debt" line no longer reconciles
-- with the Allowance line (the native sheet is fixed in this
-- build to show the Debt Payment instead). The web hero improves
-- (it shows the new allowance); only the web sheet's Carried Debt
-- line goes stale until the web is unfrozen for the same one-line
-- fix. See BUILD29_DEBT_FUND_REPORT.md.

-- 1. Repayment rule, one row per household (same pattern as
-- charity_settings in r13-charity.sql). Writes go through the RPC
-- only (admin-only, SECURITY DEFINER); members read their household.
create table if not exists public.debt_settings (
  household_id uuid primary key references public.households(id) on delete cascade,
  mode text not null default 'percent' check (mode in ('percent', 'fixed', 'off')),
  percent_bp integer not null default 2500 check (percent_bp between 0 and 10000),
  fixed_cents integer not null default 0 check (fixed_cents >= 0),
  updated_at timestamptz not null default now()
);
alter table public.debt_settings enable row level security;
drop policy if exists "members read own debt settings" on public.debt_settings;
create policy "members read own debt settings"
  on public.debt_settings for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.debt_settings to authenticated;

-- Default rule for every existing household: 25% of the base
-- allowance per week. Households created after this migration get
-- the same default from the readers (no row = 25% percent rule).
insert into public.debt_settings (household_id, mode, percent_bp, fixed_cents)
select id, 'percent', 2500, 0 from public.households
on conflict (household_id) do nothing;

-- 2. Debt payments ledger. One row per payment; 'surplus' rows are
-- written by week-close (one per week at most — the partial unique
-- index makes the close's upsert idempotent across re-runs).
-- Writes go through the RPCs / week-close only; members read.
create table if not exists public.debt_payments (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  amount_cents integer not null check (amount_cents > 0),
  source text not null check (source in ('extra_fund', 'surplus', 'clear')),
  week_start date not null,
  note text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.debt_payments enable row level security;
drop policy if exists "members read own debt payments" on public.debt_payments;
create policy "members read own debt payments"
  on public.debt_payments for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.debt_payments to authenticated;
create unique index if not exists debt_payments_surplus_week_uidx
  on public.debt_payments (household_id, week_start) where source = 'surplus';

-- 3. A closed week keeps the debt payment that was in effect when
-- it closed (NULL = pre-migration close; readers fall back to the
-- rule in effect now). Same snapshot principle as B/T.
alter table public.week_closes add column if not exists debt_payment_cents integer;

-- 4. Current debt balance D, derived exactly as compute-week
-- derives it: the latest close's outgoing debt, minus restoration
-- cuts and extra_fund/clear payments posted after that close's
-- week and up to the current week. 'surplus' payments are NOT
-- subtracted here — they are already inside the close that
-- recorded them (see the header note).
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
begin
  select week_start, outgoing_debt_cents into v_close_week, v_outgoing
    from public.week_closes
    where household_id = p_household_id and week_start < v_cur_week
    order by week_start desc limit 1;
  if not found then return 0; end if;
  select coalesce(sum(debt_reduction_cents), 0) into v_cuts
    from public.restoration_entries
    where household_id = p_household_id
      and week_start > v_close_week and week_start <= v_cur_week;
  select coalesce(sum(amount_cents), 0) into v_payments
    from public.debt_payments
    where household_id = p_household_id
      and source in ('extra_fund', 'clear')
      and week_start > v_close_week and week_start <= v_cur_week;
  return greatest(0, v_outgoing - v_cuts - v_payments);
end;
$$;

-- 5. Set the repayment rule (admin only). Future-only: it applies
-- to the current open week and future weeks; closed weeks keep
-- their stored debt_payment_cents. Server-audited, same as
-- set_charity_default_rate.
create or replace function public.set_debt_repayment_rule(
  p_household_id uuid, p_mode text, p_percent_bp integer, p_fixed_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bp integer;
  v_fixed integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_mode is null or p_mode not in ('percent', 'fixed', 'off') then
    raise exception 'mode must be percent, fixed, or off';
  end if;
  if p_mode = 'percent' then
    if p_percent_bp is null or p_percent_bp < 0 or p_percent_bp > 10000 then
      raise exception 'percent must be between 0 and 10000 basis points';
    end if;
    v_bp := p_percent_bp; v_fixed := 0;
  elsif p_mode = 'fixed' then
    if p_fixed_cents is null or p_fixed_cents < 0 then
      raise exception 'fixed amount must be zero or more cents';
    end if;
    v_bp := 0; v_fixed := p_fixed_cents;
  else
    v_bp := 0; v_fixed := 0;
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into public.debt_settings (household_id, mode, percent_bp, fixed_cents, updated_at)
  values (p_household_id, p_mode, v_bp, v_fixed, now())
  on conflict (household_id)
  do update set mode = excluded.mode, percent_bp = excluded.percent_bp,
                fixed_cents = excluded.fixed_cents, updated_at = now();
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Debt repayment rule changed',
          'Debt repayment rule set to ' ||
          case p_mode
            when 'percent' then v_bp::text || ' basis points of the base allowance'
            when 'fixed' then v_fixed::text || ' cents per week'
            else 'off'
          end || ' (applies to the current open week and future weeks; closed weeks keep their stored payment).');
end;
$$;
revoke execute on function public.set_debt_repayment_rule(uuid, text, integer, integer) from public;
grant execute on function public.set_debt_repayment_rule(uuid, text, integer, integer) to authenticated;

-- 6. Pay debt from the Extra Fund (admin only). The fund side goes
-- through allocate_fund — same balance check and typed-override
-- rule as Spend from Fund, so the shortfall/approval rules still
-- apply and are never bypassed silently. The payment is refused
-- when it exceeds the remaining debt (never silently partial).
-- Returns the remaining debt in cents.
create or replace function public.pay_debt_from_fund(
  p_household_id uuid, p_amount_cents integer, p_note text, p_override_reason text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now date := (now() at time zone 'America/New_York')::date;
  v_cur_week date := v_now - extract(dow from v_now)::int;
  v_debt integer;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Same per-household lock as allocate_fund (04-admin-rpcs.sql §2).
  perform 1 from households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_debt := public.debt_balance_cents(p_household_id);
  if v_debt <= 0 then raise exception 'there is no debt to pay'; end if;
  if p_amount_cents > v_debt then
    raise exception 'amount exceeds remaining debt: % cents', v_debt;
  end if;
  v_note := 'Debt payment' || case when p_note is null or btrim(p_note) = '' then '' else ': ' || p_note end;
  -- allocate_fund takes the same household lock (re-entrant in this
  -- transaction), checks the fund balance (refusing
  -- 'insufficient fund' unless an override reason is given), writes
  -- the fund_ledger use row, and audits the fund spending.
  perform public.allocate_fund(p_household_id, p_amount_cents, v_note, p_override_reason);
  insert into public.debt_payments (household_id, amount_cents, source, week_start, note, created_by)
  values (p_household_id, p_amount_cents, 'extra_fund', v_cur_week, coalesce(p_note, ''), auth.uid());
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Debt payment from Extra Fund',
          'Paid ' || p_amount_cents::text || ' cents toward the carried debt from the Extra Fund.');
  return v_debt - p_amount_cents;
end;
$$;
revoke execute on function public.pay_debt_from_fund(uuid, integer, text, text) from public;
grant execute on function public.pay_debt_from_fund(uuid, integer, text, text) to authenticated;

-- 7. Clear (erase) the debt balance by hand (admin only). No money
-- moves — the balance is written off. The payment row is the
-- record; the audit entry is the trail. Returns the cleared amount.
create or replace function public.clear_debt(
  p_household_id uuid, p_note text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now date := (now() at time zone 'America/New_York')::date;
  v_cur_week date := v_now - extract(dow from v_now)::int;
  v_debt integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  perform 1 from households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_debt := public.debt_balance_cents(p_household_id);
  if v_debt <= 0 then raise exception 'there is no debt to clear'; end if;
  insert into public.debt_payments (household_id, amount_cents, source, week_start, note, created_by)
  values (p_household_id, v_debt, 'clear', v_cur_week, coalesce(p_note, ''), auth.uid());
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Carried debt cleared',
          'Cleared ' || v_debt::text || ' cents of carried debt by hand.');
  return v_debt;
end;
$$;
revoke execute on function public.clear_debt(uuid, text) from public;
grant execute on function public.clear_debt(uuid, text) to authenticated;
