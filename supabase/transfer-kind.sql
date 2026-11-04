-- Household Budget — delta3 migration: internal-transfer kind (PREPARED ONLY).
-- DO NOT APPLY without owner approval: it changes the transactions kind
-- check constraint, and it must land together with the transfer-backfill
-- impact review (supabase/transfer-backfill.sql) and the redeployed
-- ingest functions that write kind='transfer'.
--
-- Why: a bank transfer between the household's own accounts (observed
-- merchant "INTERNAL TRANSFER DEBIT: SAVINGS -5939", $2,000) currently
-- classifies as an ordinary charge and counts toward weekly spending,
-- and a transfer in nets as a refund. The delta3 code classifies
-- INTERNAL TRANSFER rows as kind='transfer' (checked FIRST in
-- classifyKind, in every canonical.ts copy) and excludes that kind from
-- week math in engine.mjs — but the database CHECK constraint still
-- rejects the new kind, so the constraint must be extended first.
--
-- Pattern: same drop/re-add as supabase/payment-kind.sql. The original
-- schema.sql check constraint is anonymous, so its generated name is
-- looked up from pg_constraint rather than guessed; the lookup filters
-- conrelid = 'transactions' so the savings_ledger kind check (which
-- also mentions transfer_in/withdrawal/interest/adjustment) is never
-- touched. Re-running is safe: if the constraint already includes
-- 'transfer', the DO block drops it and the ADD restores the same list.
--
-- NOTE: if payment-kind.sql was never applied, the live constraint may
-- still be the original ('charge','refund','fund_charge'). This file
-- adds the full extended list either way, because the ADD below is
-- absolute, not incremental.

do $$
declare
  c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'transactions'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%fund_charge%';
  if c is not null then
    execute 'alter table transactions drop constraint ' || quote_ident(c);
  end if;
end $$;

alter table transactions
  add constraint transactions_kind_check
  check (kind in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'transfer'));

-- Verification (read-only, run after applying):
--   select conname, pg_get_constraintdef(oid)
--     from pg_constraint
--    where conrelid = 'transactions'::regclass and contype = 'c';
-- Expected: one transactions_kind_check row whose definition contains
-- 'transfer' alongside the five existing kinds.
