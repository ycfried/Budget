-- Pending Savings Top-Ups — NOT APPLIED LIVE (build 41, Nov 17, 2026).
-- APPLY VIA THE SUPABASE DASHBOARD SQL EDITOR BEFORE THE BUILD-41
-- TESTFLIGHT BUILD GOES OUT. The build-41 client calls
-- add_fund_money with a fifth argument (p_confirmed) and the new
-- confirm_fund_topup RPC; until this file is applied those calls
-- fail (unknown function) and Add Money cannot save at all.
-- Apply order: after fund-icons.sql (also owed in build 41), any
-- order between the two is fine — they touch different tables.
--
-- What it adds: a top-up may be saved BEFORE the money is in
-- checking. It is stored as PENDING and counts for nothing until
-- an admin confirms it ("I have already put this money in
-- checking"), at which point the normal shortfall-first split runs
-- against the THEN-current shortfall. The fund summary needs no
-- change: Available is the fund_ledger sum, and a pending top-up
-- writes no ledger row (and touches no shortfall) until confirmed
-- — so Home's Savings card shows confirmed money only, and the
-- Funds detail sums pending top-ups from the fund_topups rows.
--
--   * fund_topups.status — 'pending' / 'confirmed' (existing rows
--     are all confirmed: the old form required the toggle), plus
--     confirmed_at / confirmed_by.
--   * add_fund_money gains p_confirmed (default true = today's
--     behaviour). p_confirmed = false records the row as pending
--     with no split, no ledger row, no shortfall change. The
--     idempotent replay returns the stored row, including its
--     status — a replay never confirms a pending row.
--   * confirm_fund_topup(p_topup_id) — admin-only. Locks the row
--     and the household shortfall, computes the split against the
--     current shortfall, writes the ledger row / shortfall update /
--     audit row, and marks the row confirmed. Re-confirming returns
--     the stored split (idempotent).
begin;
alter table public.fund_topups
  add column if not exists status text not null default 'confirmed'
    check (status in ('pending', 'confirmed')),
  add column if not exists confirmed_at timestamptz,
  add column if not exists confirmed_by uuid references auth.users(id);

-- One function, not two overloads: drop the 4-arg form so a call
-- without p_confirmed still resolves (default true = confirmed).
drop function if exists public.add_fund_money(uuid, integer, text, text);

create or replace function public.add_fund_money(
  p_household_id uuid, p_amount_cents integer, p_note text, p_client_key text,
  p_confirmed boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shortfall integer;
  v_covered integer;
  v_added integer;
  v_after integer;
  v_key text;
  v_existing fund_topups%rowtype;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Serialize concurrent top-ups against the same household row so
  -- two simultaneous saves cannot both cover the same shortfall.
  select fund_shortfall_cents into v_shortfall
    from public.households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_shortfall := coalesce(v_shortfall, 0);
  v_key := nullif(btrim(coalesce(p_client_key, '')), '');
  if v_key is not null then
    select * into v_existing from public.fund_topups
     where household_id = p_household_id and client_key = v_key;
    if found then
      -- Idempotent replay: return the stored row, move no money —
      -- and never confirm a pending row by replaying it.
      return jsonb_build_object(
        'amount_cents', v_existing.amount_cents,
        'shortfall_covered_cents', v_existing.shortfall_covered_cents,
        'fund_added_cents', v_existing.fund_added_cents,
        'shortfall_after_cents', v_existing.shortfall_after_cents,
        'status', v_existing.status,
        'replayed', true);
    end if;
  else
    -- No key supplied (no client should do this): still record the
    -- top-up once, under a fresh key, so the row stays unique.
    v_key := gen_random_uuid()::text;
  end if;
  v_note := left(btrim(coalesce(p_note, '')), 120);
  if coalesce(p_confirmed, true) is false then
    -- Pending: record the row only. No split (it runs at confirm
    -- time, against the then-current shortfall), no ledger row, no
    -- shortfall change — the money counts for nothing until then.
    insert into public.fund_topups
      (household_id, client_key, amount_cents, shortfall_covered_cents,
       fund_added_cents, shortfall_after_cents, note, created_by, status)
    values (p_household_id, v_key, p_amount_cents, 0, 0, v_shortfall,
            v_note, auth.uid(), 'pending');
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Extra Fund top-up recorded as pending',
            'Manual top-up ' || p_amount_cents::text || ' cents saved as pending — not in checking yet.'
            || case when v_note <> '' then ' Note: ' || v_note else '' end);
    return jsonb_build_object(
      'amount_cents', p_amount_cents,
      'shortfall_covered_cents', 0,
      'fund_added_cents', 0,
      'shortfall_after_cents', v_shortfall,
      'status', 'pending',
      'replayed', false);
  end if;
  v_covered := least(v_shortfall, p_amount_cents);
  v_added := p_amount_cents - v_covered;
  v_after := v_shortfall - v_covered;
  insert into public.fund_topups
    (household_id, client_key, amount_cents, shortfall_covered_cents,
     fund_added_cents, shortfall_after_cents, note, created_by, status,
     confirmed_at, confirmed_by)
  values (p_household_id, v_key, p_amount_cents, v_covered,
          v_added, v_after, v_note, auth.uid(), 'confirmed',
          now(), auth.uid());
  if v_added > 0 then
    insert into public.fund_ledger (household_id, kind, amount_cents, note, created_by)
    values (p_household_id, 'adjustment', v_added,
            'Manual top-up: ' || p_amount_cents::text || ' cents total; '
            || v_covered::text || ' cents covered shortfall; '
            || v_added::text || ' cents added to fund.'
            || case when v_note <> '' then ' Note: ' || v_note else '' end,
            auth.uid());
  end if;
  if v_covered > 0 then
    update public.households set fund_shortfall_cents = v_after where id = p_household_id;
  end if;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Extra Fund top-up recorded',
          'Manual top-up ' || p_amount_cents::text || ' cents: '
          || v_covered::text || ' cents covered shortfall, '
          || v_added::text || ' cents added to fund, '
          || v_after::text || ' cents owed back after.'
          || case when v_note <> '' then ' Note: ' || v_note else '' end);
  return jsonb_build_object(
    'amount_cents', p_amount_cents,
    'shortfall_covered_cents', v_covered,
    'fund_added_cents', v_added,
    'shortfall_after_cents', v_after,
    'status', 'confirmed',
    'replayed', false);
end;
$$;
revoke execute on function public.add_fund_money(uuid, integer, text, text, boolean) from public;
grant execute on function public.add_fund_money(uuid, integer, text, text, boolean) to authenticated;

create or replace function public.confirm_fund_topup(p_topup_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row fund_topups%rowtype;
  v_shortfall integer;
  v_covered integer;
  v_added integer;
  v_after integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from public.fund_topups where id = p_topup_id for update;
  if not found then raise exception 'top-up not found'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_row.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_row.status = 'confirmed' then
    -- Idempotent re-confirm: return the stored split, move nothing.
    return jsonb_build_object(
      'amount_cents', v_row.amount_cents,
      'shortfall_covered_cents', v_row.shortfall_covered_cents,
      'fund_added_cents', v_row.fund_added_cents,
      'shortfall_after_cents', v_row.shortfall_after_cents,
      'status', 'confirmed',
      'replayed', true);
  end if;
  select fund_shortfall_cents into v_shortfall
    from public.households where id = v_row.household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_shortfall := coalesce(v_shortfall, 0);
  -- The split runs NOW, against the current shortfall — it may
  -- differ from the preview shown when the pending top-up was saved.
  v_covered := least(v_shortfall, v_row.amount_cents);
  v_added := v_row.amount_cents - v_covered;
  v_after := v_shortfall - v_covered;
  update public.fund_topups
     set status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid(),
         shortfall_covered_cents = v_covered, fund_added_cents = v_added,
         shortfall_after_cents = v_after
   where id = p_topup_id;
  if v_added > 0 then
    insert into public.fund_ledger (household_id, kind, amount_cents, note, created_by)
    values (v_row.household_id, 'adjustment', v_added,
            'Manual top-up confirmed: ' || v_row.amount_cents::text || ' cents total; '
            || v_covered::text || ' cents covered shortfall; '
            || v_added::text || ' cents added to fund.'
            || case when v_row.note <> '' then ' Note: ' || v_row.note else '' end,
            auth.uid());
  end if;
  if v_covered > 0 then
    update public.households set fund_shortfall_cents = v_after where id = v_row.household_id;
  end if;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_row.household_id, auth.uid(), 'admin', 'Extra Fund top-up confirmed',
          'Manual top-up ' || v_row.amount_cents::text || ' cents confirmed in checking: '
          || v_covered::text || ' cents covered shortfall, '
          || v_added::text || ' cents added to fund, '
          || v_after::text || ' cents owed back after.'
          || case when v_row.note <> '' then ' Note: ' || v_row.note else '' end);
  return jsonb_build_object(
    'amount_cents', v_row.amount_cents,
    'shortfall_covered_cents', v_covered,
    'fund_added_cents', v_added,
    'shortfall_after_cents', v_after,
    'status', 'confirmed',
    'replayed', false);
end;
$$;
revoke execute on function public.confirm_fund_topup(uuid) from public;
grant execute on function public.confirm_fund_topup(uuid) to authenticated;
commit;
