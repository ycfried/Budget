-- Household Budget — S3 migration: plaid_accounts + disconnect state
-- (audit P1-17) and plaid_items institution/status columns.
-- Apply before deploying rewritten plaid-sync and plaid-disconnect.
--
-- plaid_accounts: one row per Plaid account on a connected item, kept
-- after disconnect so the app can show "Previously connected".
-- Never stores tokens. mask is the card's last 4 (display only).

create table if not exists plaid_accounts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  plaid_item_id text not null,
  plaid_account_id text not null,
  name text,
  mask text,
  type text,
  subtype text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, plaid_account_id)
);

alter table plaid_items
  add column if not exists institution_id text,
  add column if not exists status text not null default 'active'
    check (status in ('active', 'disconnected')),
  add column if not exists disconnected_at timestamptz;

-- Backfill: existing rows predate the status column's default only if
-- the column was added without it; the default above covers new rows.
-- Any row already disconnected by another path keeps its status; this
-- statement only normalises nulls (defensive, no-op in practice).
update plaid_items set status = 'active' where status is null;

alter table plaid_accounts enable row level security;

create policy "members read own plaid accounts"
  on plaid_accounts for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));

-- plaid-sync / plaid-disconnect run with the caller's JWT, so the
-- account upsert needs member insert/update grants + policies scoped
-- to the caller's own household. No DELETE grant or policy, ever.
grant select, insert, update on plaid_accounts to authenticated;

create policy "members insert own plaid accounts"
  on plaid_accounts for insert
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));

create policy "members update own plaid accounts"
  on plaid_accounts for update
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()))
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));

-- NOTE (dependency on S1's vault file): no client may ever receive
-- token ciphertext. plaid_items.access_token_encrypted must keep NO
-- select policy for authenticated users (as in plaid-token-column.sql),
-- and any plaid_items_public view S1 creates must exclude that column
-- (and sync_cursor is sync state, not client display data — S1 to
-- confirm the view's column list). This migration adds no view and no
-- token exposure; it only adds the display/state columns above.
