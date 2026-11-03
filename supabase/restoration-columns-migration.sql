-- Refund-table column migration — PREPARED ONLY, DO NOT APPLY
-- without the owner's explicit approval ("fix everything", Nov 3).
--
-- WHY: the live restoration_entries and held_refunds tables are an
-- older shape than supabase/restoration-snapshots.sql defines. That
-- file's CREATE TABLE IF NOT EXISTS is a no-op against the
-- pre-existing live tables, so the newer columns never landed. The
-- live app's refund panels select debt_reduction_cents,
-- fund_credit_cents (restoration_entries) and resolution_note
-- (held_refunds) and get Postgres 42703, so both panels show
-- "Could not load … Try again." The week-close restoration writes
-- insert the same columns: on failure they stop restoration for
-- that run and return 500 ("restoration failed partway") while
-- closes/releases above them stay persisted — loud, not silent,
-- but restorations cannot land until these columns exist.
--
-- SAFETY: additive only. Every ADD COLUMN is IF NOT EXISTS, so
-- re-running is a no-op. No column is dropped, renamed, or
-- retyped; no row is updated or deleted. The column block commits
-- on its own, so a later constraint problem cannot roll it back.
-- The unique constraints are added afterwards in guarded blocks:
-- a duplicate_object means the constraint is already there; a
-- unique_violation would mean duplicate non-null refund links
-- already exist (not expected — these inserts have been failing)
-- and must be investigated, not forced.

begin;
alter table restoration_entries
  add column if not exists week_start date,
  add column if not exists purchase_transaction_id uuid,
  add column if not exists refund_transaction_id uuid,
  add column if not exists restored_surplus_cents integer not null default 0,
  add column if not exists debt_reduction_cents integer not null default 0,
  add column if not exists fund_credit_cents integer not null default 0,
  add column if not exists created_at timestamptz not null default now();
alter table held_refunds
  add column if not exists refund_transaction_id uuid,
  add column if not exists purchase_transaction_id uuid,
  add column if not exists held_cents integer check (held_cents > 0),
  add column if not exists status text not null default 'pending' check (status in ('pending', 'resolved')),
  add column if not exists resolution_note text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists resolved_at timestamptz;
commit;

-- Unique-per-refund guards (week-close relies on them for safe
-- re-runs). Each block swallows only "already exists".
do $$
begin
  alter table restoration_entries
    add constraint restoration_entries_refund_transaction_id_key
    unique (refund_transaction_id);
exception when duplicate_object then null;
end $$;
do $$
begin
  alter table held_refunds
    add constraint held_refunds_refund_transaction_id_key
    unique (refund_transaction_id);
exception when duplicate_object then null;
end $$;
create index if not exists restoration_entries_household_purchase_idx
  on restoration_entries (household_id, purchase_transaction_id);
create index if not exists held_refunds_household_status_idx
  on held_refunds (household_id, status);

-- Verification (read-only): both tables must list the new columns.
select table_name, column_name
  from information_schema.columns
 where table_name in ('restoration_entries', 'held_refunds')
   and column_name in ('purchase_transaction_id', 'refund_transaction_id',
     'debt_reduction_cents', 'fund_credit_cents', 'resolution_note')
 order by table_name, column_name;
