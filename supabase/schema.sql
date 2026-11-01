-- Household Budget — Supabase schema (PREPARED, NOT APPLIED).
-- Owner decision Nov 1, 2026: Free plan to start.
-- Apply this in the Supabase SQL editor only after the owner creates the
-- project. Nothing here creates a project, a user, or a secret.
--
-- Design rules (from the spec, unchanged):
--   * Every data row carries household_id. No query ever omits it.
--   * Amounts are integer cents. The server (Edge Functions) is
--     authoritative for financial calculations; engine.mjs is the
--     single formula, shared with the client for display only.
--   * Plaid access tokens are NEVER stored in this database. They live
--     only in Edge Function secrets / the Plaid Item vault flow. This
--     schema stores only the Plaid item id and the sync cursor.
--   * The audit log is append-only: no UPDATE/DELETE policy grants it.
--   * FIN-REFUND-001 is still OPEN: do not build automatic fund release
--     on an unreviewed refund-credit/surplus interpretation.

create extension if not exists pgcrypto;

create table if not exists households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Household',
  base_allowance_cents integer not null default 37500,
  created_at timestamptz not null default now()
);

create table if not exists household_members (
  household_id uuid not null references households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'member')),
  display_name text,
  created_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

create table if not exists transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  date date not null,
  merchant text not null,
  amount_cents integer not null,
  card_suffix char(4) not null default '0000',
  source text not null check (source in ('csv', 'amex_alert', 'plaid', 'manual')),
  state text not null check (state in ('provisional', 'verified', 'excluded', 'reversed')),
  kind text not null check (kind in ('charge', 'refund', 'fund_charge')),
  fund_allocation_cents integer not null default 0,
  excluded boolean not null default false,
  exclude_reason text not null default '',
  late boolean not null default false,
  external_id text,
  dedupe_hash text not null,
  created_at timestamptz not null default now(),
  unique (household_id, dedupe_hash)
);

create table if not exists fund_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  transaction_id uuid references transactions(id) on delete set null,
  requested_by uuid not null references auth.users(id),
  amount_cents integer not null check (amount_cents > 0),
  note text not null default '',
  status text not null check (status in ('pending', 'approved', 'declined', 'split')),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists savings_ledger (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  kind text not null check (kind in ('transfer_in', 'withdrawal', 'interest', 'adjustment')),
  amount_cents integer not null,
  attested_by uuid not null references auth.users(id),
  note text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  actor uuid references auth.users(id),
  actor_name text not null,
  action text not null,
  detail text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists plaid_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  plaid_item_id text not null,
  institution_name text,
  sync_cursor text,
  last_sync_at timestamptz,
  created_at timestamptz not null default now(),
  unique (household_id, plaid_item_id)
);

-- Row Level Security: a user sees only rows of households they belong to.
alter table households enable row level security;
alter table household_members enable row level security;
alter table transactions enable row level security;
alter table fund_requests enable row level security;
alter table savings_ledger enable row level security;
alter table audit_log enable row level security;
alter table plaid_items enable row level security;

create policy "members read own household"
  on households for select
  using (exists (select 1 from household_members m
                 where m.household_id = households.id and m.user_id = auth.uid()));
create policy "members read own membership"
  on household_members for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));
create policy "members read own transactions"
  on transactions for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));
create policy "members read own fund requests"
  on fund_requests for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));
create policy "members read own savings"
  on savings_ledger for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));
create policy "members read own audit"
  on audit_log for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));
create policy "members read own plaid items"
  on plaid_items for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));

-- NOTE: writes go through Edge Functions using the service role with
-- explicit household + role checks (admin-only for allocations, settings,
-- and savings attestation; members may create fund requests and manual
-- provisional transactions). Do NOT add permissive insert/update policies
-- for these tables; the Edge Function layer is the enforcement point.
-- Audit log has no update/delete policy by design (append-only).
