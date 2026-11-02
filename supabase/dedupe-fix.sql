-- Household Budget — S3 migration: canonical dedupe + coexistence (P1-4).
-- Apply BEFORE deploying the rewritten plaid-sync / ingest functions
-- that rely on external_id / plaid_pending_transaction_id lookups.
--
-- What changes and why (audit P1-4, FINAL tests 18/19/20):
--   * DROP the UNIQUE(household_id, dedupe_hash) constraint. It made
--     two real identical purchases (same merchant, amount, date, card)
--     impossible: the second insert failed and data was lost.
--   * ADD partial unique indexes on (household_id, external_id) and
--     (household_id, plaid_pending_transaction_id), each WHERE the
--     column IS NOT NULL. Plaid transaction ids and pending ids are
--     the true identities; nulls (manual / legacy rows) must not
--     collide with each other, hence partial indexes, not a plain
--     unique constraint.
--   * KEEP dedupe_hash as a plain (non-unique) column + index: it is
--     for MATCHING ONLY (plaid-sync step 3, Gmail-row matching), never
--     a uniqueness constraint.
--   * Manual rows (S4/live.js, not this workstream) must set
--     dedupe_hash = canonical hash + '-' + random suffix, so two
--     identical real purchases can coexist even before they acquire
--     an external id. Identical-purchase coexistence is by
--     external_id / row identity, NOT by hash.
--
-- Dropping the old unique constraint: schema.sql created it anonymously
-- as part of the table definition, so its generated name is normally
-- transactions_household_id_dedupe_hash_key. Both the named drop and a
-- pg_constraint lookup fallback are included; the lookup runs only if
-- the named constraint is absent.

alter table transactions
  drop constraint if exists transactions_household_id_dedupe_hash_key;

do $$
declare
  c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'transactions'::regclass
     and contype = 'u'
     and pg_get_constraintdef(oid) like '%dedupe_hash%';
  if c is not null then
    execute 'alter table transactions drop constraint ' || quote_ident(c);
  end if;
end $$;

-- The linkage columns are added by payment-kind.sql §2 (optional
-- section) if S2 has not added them; these indexes require them.
-- If this file runs first, add the columns here (idempotent):
alter table transactions
  add column if not exists plaid_pending_transaction_id text,
  add column if not exists plaid_transaction_id text;

create unique index if not exists transactions_household_external_id_uidx
  on transactions (household_id, external_id)
  where external_id is not null;

create unique index if not exists transactions_household_pending_id_uidx
  on transactions (household_id, plaid_pending_transaction_id)
  where plaid_pending_transaction_id is not null;

-- Non-unique matching index (hash lookups in plaid-sync / ingest).
create index if not exists transactions_household_dedupe_hash_idx
  on transactions (household_id, dedupe_hash);
