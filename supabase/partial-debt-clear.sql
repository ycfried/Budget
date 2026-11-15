-- Partial debt clear (build 30, task K). Applied via the Supabase
-- SQL editor. Re-running is safe (DROP + CREATE of the one RPC).
--
-- CHOICE: extend clear_debt with optional parameters instead of a
-- new RPC. Why: there is exactly one "clear debt" action in the
-- product, one audit trail and one call site (FundsViewModel /
-- RPCs.clearDebt). A second RPC would split the audit history and
-- force the client to choose between two names for one action.
-- Backwards compatibility: p_amount_cents and p_percent_bp both
-- default to NULL, and NULL/NULL means "clear all", exactly as
-- today — the existing native call clear_debt(p_household_id,
-- p_note) keeps working unchanged, and PostgREST applies the
-- defaults for the omitted arguments.
--
-- WHAT IT DOES: clear a specific dollar amount, or a percentage of
-- the CURRENT debt balance at call time, or all of it.
--   clear_debt(hh, note)                        -> clear all (today)
--   clear_debt(hh, note, p_amount_cents => N)   -> write off N cents
--   clear_debt(hh, note, p_percent_bp => N)     -> write off N basis
--                                                  points of the balance
-- A partial clear WRITES OFF that part of the debt: it inserts a
-- 'clear' debt_payments row and the same audit entry as a full
-- clear. It is NOT a payment from the Extra Fund — that is the
-- separate pay_debt_from_fund RPC, which still covers paying a
-- specific amount from the fund. No money moves here.
--
-- BALANCE MATH: no change was needed to the balance derivation.
-- debt_balance_cents (debt-fund.sql §4) already subtracts 'clear'
-- payments posted after the latest close, so a partial 'clear' row
-- reduces the balance by exactly the cleared amount, and
-- greatest(0, ...) floors it at zero. The weekly payment math in
-- compute-week / week-close reads the same derived balance, so a
-- partial clear flows into the next week's debt payment (capped at
-- the new, smaller balance) with no Edge Function change.
-- The JS mirror of this math is computePartialClear in
-- supabase/functions/_shared/engine.mjs (synced to compute-week /
-- week-close); the SQL below and that function throw the same
-- refusals.
--
-- REFUSALS (fail closed, never silently partial):
--   * no debt at all -> 'there is no debt to clear' (as today);
--   * both amount and percentage given -> specify one, not both;
--   * amount <= 0, or percentage outside 1..10000 bp;
--   * amount larger than the balance -> refused with the balance in
--     the message (same wording as pay_debt_from_fund);
--   * a percentage that floors to zero at the current balance
--     (e.g. 1 bp of a $0.50 balance) -> refused, nothing written.
-- Percentage uses FLOOR, same as the debt-rule percent math
-- (engine.mjs debtRulePayment): 25% of $3,194.44 is $798.61, never
-- $798.62 — the household never writes off a cent it did not ask for.
--
-- AUTH: admin-only, same pattern as the existing debt RPCs
-- (set_debt_repayment_rule / pay_debt_from_fund / clear_debt):
-- SECURITY DEFINER, auth.uid() required, admin membership check,
-- per-household lock for the whole call.
--
-- DEPENDS ON: debt-fund.sql (debt_balance_cents, debt_payments,
-- audit_log). The real household's debt is $3,194.44 — NEVER touch
-- it; live verification is test-household only (see
-- BUILD30_SERVER_DEPLOY.md).

-- The old 2-argument signature is replaced, not overloaded:
-- keeping both would leave two clear_debt functions and split the
-- audit history. The new signature keeps the old argument names
-- and order, so existing callers are unaffected.
drop function if exists public.clear_debt(uuid, text);

create or replace function public.clear_debt(
  p_household_id uuid, p_note text,
  p_amount_cents integer default null,
  p_percent_bp integer default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now date := (now() at time zone 'America/New_York')::date;
  v_cur_week date := v_now - extract(dow from v_now)::int;
  v_debt integer;
  v_clear integer;
  v_mode text;
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
  if p_amount_cents is not null and p_percent_bp is not null then
    raise exception 'specify an amount or a percentage, not both';
  end if;
  if p_amount_cents is not null then
    if p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
    if p_amount_cents > v_debt then
      raise exception 'amount exceeds remaining debt: % cents', v_debt;
    end if;
    v_clear := p_amount_cents;
    v_mode := 'partial clear of ' || p_amount_cents::text || ' cents';
  elsif p_percent_bp is not null then
    if p_percent_bp < 1 or p_percent_bp > 10000 then
      raise exception 'percent must be between 1 and 10000 basis points';
    end if;
    -- Integer division truncates toward zero = floor for positive
    -- values, same as engine.mjs debtRulePayment / computePartialClear.
    v_clear := (v_debt * p_percent_bp) / 10000;
    if v_clear <= 0 then
      raise exception 'percentage clears nothing at this balance';
    end if;
    v_mode := 'partial clear of ' || p_percent_bp::text || ' basis points ('
      || v_clear::text || ' cents of ' || v_debt::text || ' cents)';
  else
    v_clear := v_debt;
    v_mode := 'full clear';
  end if;
  insert into public.debt_payments (household_id, amount_cents, source, week_start, note, created_by)
  values (p_household_id, v_clear, 'clear', v_cur_week, coalesce(p_note, ''), auth.uid());
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Carried debt cleared',
          'Cleared ' || v_clear::text || ' cents of carried debt by hand (' || v_mode
          || '; ' || v_debt::text || ' cents owed before, '
          || (v_debt - v_clear)::text || ' cents remain).');
  return v_clear;
end;
$$;
revoke execute on function public.clear_debt(uuid, text, integer, integer) from public;
grant execute on function public.clear_debt(uuid, text, integer, integer) to authenticated;
