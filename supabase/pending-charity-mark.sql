-- Pending charity marking (owner report, Nov 8, 2026).
--
-- PROBLEM: mark_transaction_charity (r13-charity.sql) refused every
-- pending (provisional) row with "only a posted transaction can be
-- marked as a charity gift", so real gifts that the bank had not
-- confirmed yet — Keren Hatzedaka $2.00, Cong Hanoe Vhanetzach $1.00,
-- Toiremorg $1.00 — could not be marked at all. The admin had already
-- confirmed they are gifts; waiting days for the bank to post them
-- first is pure friction.
--
-- FIX: a pending charge may be marked. The row keeps its state
-- (provisional), so nothing counts until the bank confirms it:
--   * Given counts only kind='charity' rows with state='verified'
--     (live.js charity aggregates), so a pending gift contributes $0
--     to Given and starts counting the moment it posts — no second tap.
--   * The mark survives the bank-confirm merge: plaid-sync's
--     re-delivery update never overwrites kind (merged-audit A14), so
--     when the bank row arrives it refreshes the same row's state to
--     verified and the charity kind stays.
--   * If the pending charge never posts (drops off / reverses), the
--     row is reversed or excluded by sync exactly like any pending
--     row, and a reversed/excluded charity row counts in nothing.
-- Everything else is unchanged: charge only, not excluded, no fund
-- allocation, date on/after 2026-11-01, unlocked week (35-day rule),
-- admin-only, audit row. The error for any other state (reversed)
-- now says "only a pending or posted transaction can be marked".
--
-- STEP 0 — none. This file replaces only mark_transaction_charity;
-- it touches no constraint, no table, no other RPC.
-- STEP 1 — Apply this file in the SQL editor, in order. No other file.
-- VERIFICATION (read-only, after applying):
--   select pg_get_functiondef(oid) from pg_proc where proname = 'mark_transaction_charity';
--   -- expected: the state guard reads "state not in ('provisional', 'verified')"
--   -- and the update still sets only kind = 'charity' (state untouched).
--
-- No secrets, tokens, or keys appear in this file.
create or replace function public.mark_transaction_charity(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from public.transactions where id = p_transaction_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_row.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_row.kind <> 'charge' then raise exception 'only a charge can be marked as a charity gift'; end if;
  -- Pending gifts may be marked (owner, Nov 8, 2026): the row keeps
  -- its state, so Given — which counts verified charity rows only —
  -- stays $0 until the bank confirms it. A reversed row still refuses.
  if v_row.state not in ('provisional', 'verified') then raise exception 'only a pending or posted transaction can be marked as a charity gift'; end if;
  if v_row.excluded then raise exception 'an excluded transaction cannot be marked as a charity gift'; end if;
  if coalesce(v_row.fund_allocation_cents, 0) <> 0 then raise exception 'a transaction partly paid from the fund cannot be marked as a charity gift'; end if;
  if v_row.date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  -- Engine lock rule, in NY Sunday weeks: locked once the current
  -- Sunday week is more than 35 days after the transaction's Sunday
  -- week (week end + 28 days). Locked weeks are never rewritten.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then raise exception 'week is locked: a locked-week gift cannot be marked here'; end if;
  update public.transactions set kind = 'charity' where id = p_transaction_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_row.household_id, auth.uid(), 'admin', 'Transaction marked as charity gift',
          v_row.merchant || ' ' || v_row.amount_cents::text || ' cents on ' || v_row.date::text
          || ' marked as a charity gift (now outside weekly spending).');
end;
$$;
revoke execute on function public.mark_transaction_charity(uuid) from public;
grant execute on function public.mark_transaction_charity(uuid) to authenticated;
