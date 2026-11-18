-- Household Budget — S3 migration: card-payment + cashback kinds (P0-10b).
-- Apply BEFORE deploying the rewritten plaid-sync / ingest-amex-alert
-- functions, which write kind='payment' and kind='cashback'.
--
-- Spec basis: FINAL A7 — "Amex cash-back statement credits are not
-- refunds. They are excluded from the budget by default." Owner
-- screenshot (Nov 1, P0-10b): Plaid surfaces Amex card payments as
-- negative amounts (merchant "MOBILE PAYMENT - THANK YOU", ~$2,273
-- across six rows) that were wrongly counted in a -$2,370.24
-- purchases total. Card payments are NOT refunds.
--
-- NEVER RUN §1 AGAIN (R4, Nov 9, 2026 — same treatment as
-- supabase/create-household-name.sql, which is marked SUPERSEDED,
-- NEVER APPLY, and as r13-charity.sql §1). §1 drops the live
-- transactions kind constraint and re-adds a 5-kind list (missing
-- 'transfer', 'charity', and 'income'): running it today would fail
-- outright if any transfer/charity/income rows exist, or silently
-- narrow the live 8-kind constraint. The live 8-kind constraint is
-- owned by supabase/refund-classification-income-kind.sql (applied
-- live Nov 9, 2026, step 3). §1 ran once, long ago, when the live
-- list was these 5 kinds; it must never re-run.
--
-- SECTION 1 (required): extend the transactions kind check constraint
-- to include 'payment' and 'cashback'. The original schema.sql check
-- constraint is anonymous, so its generated name is looked up from
-- pg_constraint rather than guessed; if no such constraint is found
-- this is a no-op followed by a fresh ADD (guarded by the DO block
-- below so re-running is safe only if the constraint name differs —
-- re-check before re-applying).

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
  check (kind in ('charge', 'refund', 'fund_charge', 'payment', 'cashback'));

-- SECTION 2 (OPTIONAL — READ FIRST): Plaid linkage columns.
-- S2's restoration-snapshots.sql was INTENDED to add
-- plaid_pending_transaction_id / plaid_transaction_id (per the S3
-- brief). That file does not exist in this copy, so S2 may still add
-- them. Apply this section ONLY if S2's file has not already added
-- these columns. The `if not exists` guards make applying twice
-- harmless, but do NOT apply this section if S2 defined the columns
-- with different types/constraints — reconcile first, then apply once.
-- original_purchase_id is the refund-linkage column: plaid-sync leaves
-- it NULL (Plaid's sync payload carries no refund-to-purchase link;
-- see S3_INTERFACE_NOTES.md). A real matcher owns populating it later.
alter table transactions
  add column if not exists plaid_pending_transaction_id text,
  add column if not exists plaid_transaction_id text,
  add column if not exists original_purchase_id uuid;
