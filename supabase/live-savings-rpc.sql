-- Household Budget — live savings attestation RPC.
-- WHY: the live slice had no savings page at all. The spec's savings
-- rule is strict: four separate numbers (fund available, earned not
-- yet transferred, actual balance, interest/outside movements tracked
-- separately and NOT spendable), transfers manual only, never
-- app-initiated, never counted as spending or income.
-- This RPC records a manual attestation (what the owner observed in
-- the real savings account) — it does not move money, does not change
-- the fund, and does not create a transaction. Admin only, audit-logged.
-- The savings_ledger table already exists in schema.sql with kind /
-- amount_cents / attested_by / note. An attestation is NOT a movement,
-- so it is stored as amount_cents = 0 with the observed balance in a
-- new actual_balance_cents column (added below) — a zero movement
-- cannot be mistaken for money in or out. This RPC is the only live
-- write path to savings_ledger for now, and it inserts only.
-- Granted to authenticated only, never to public.

alter table savings_ledger
  add column if not exists actual_balance_cents integer;

create or replace function public.attest_savings(p_household_id uuid, p_actual_balance_cents integer, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_actual_balance_cents is null or p_actual_balance_cents < 0 then raise exception 'balance must be non-negative'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into savings_ledger (household_id, kind, amount_cents, attested_by, note, actual_balance_cents)
    values (p_household_id, 'adjustment', 0, auth.uid(), coalesce(p_note, ''), p_actual_balance_cents);
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Savings balance attested', 'Actual savings balance attested: ' || p_actual_balance_cents::text || ' cents.');
end;
$$;
revoke execute on function public.attest_savings(uuid, integer, text) from public;
grant execute on function public.attest_savings(uuid, integer, text) to authenticated;
