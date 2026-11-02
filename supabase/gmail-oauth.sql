-- gmail-oauth.sql — per-user Gmail (OAuth) email connections, UNVERIFIED mode.
--
-- Design (mirrors the Plaid vault pattern in 03-plaid-vault.sql):
--   * email_connections holds ONLY the AES-GCM ciphertext of the Google
--     refresh token. The plaintext token is never written anywhere, and
--     the ciphertext is never readable by a client: RLS is enabled and
--     there is NO policy granting authenticated/anon any access to this
--     table. Only the service-role key (Edge Functions) reads it, and
--     gmail-poll decrypts it in memory only, with GMAIL_TOKEN_KEY.
--   * Clients read connection STATUS through the email_connections_public
--     view, which lists every column EXCEPT refresh_token_encrypted
--     (explicit column list, never SELECT *, so a future sensitive
--     column is not silently exposed). The view filters by membership
--     (household_members + auth.uid()), same as plaid_items_public.
--   * processed_email_ids is the SERVER-SIDE record of handled Gmail
--     messages. It replaces Gmail labels entirely: the OAuth functions
--     never request gmail.modify and never label anything. A message
--     already in this table is never re-fetched for ingest.
--   * gmail_oauth_states holds single-use OAuth state nonces. A nonce is
--     deleted when the callback runs, so a captured state URL cannot be
--     replayed; rows older than 10 minutes are rejected even if found.
--   * This file is re-runnable (create if not exists / create or replace
--     / drop policy if exists) and touches nothing else.
--   * The owner's personal Apps Script ingest path is NOT touched by
--     this file and keeps working alongside the new per-household path.

create table if not exists public.email_connections (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  provider text not null default 'gmail' check (provider = 'gmail'),
  email_address text not null,
  refresh_token_encrypted text not null,
  status text not null default 'active' check (status in ('active', 'error')),
  last_poll_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  unique (household_id, provider, email_address)
);

create table if not exists public.processed_email_ids (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.email_connections (id) on delete cascade,
  message_id text not null,
  disposition text not null default 'stored'
    check (disposition in ('stored', 'duplicate', 'quarantined', 'unparseable')),
  processed_at timestamptz not null default now(),
  unique (connection_id, message_id)
);

create table if not exists public.gmail_oauth_states (
  nonce text primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.email_connections enable row level security;
alter table public.processed_email_ids enable row level security;
alter table public.gmail_oauth_states enable row level security;

-- Deliberately NO policies on the three tables above: no authenticated
-- or anon role can read or write them. Only the service-role key
-- (which bypasses RLS) used by the Edge Functions may touch them.
-- In particular, refresh_token_encrypted is never client-readable.

-- Public view: status only, ciphertext excluded by construction.
create or replace view public.email_connections_public as
  select
    id,
    household_id,
    provider,
    email_address,
    status,
    last_poll_at,
    last_error,
    created_at
  from public.email_connections
  where household_id in (select household_id from public.household_members
                         where user_id = auth.uid());

grant select on public.email_connections_public to authenticated;
revoke all on public.email_connections_public from public;
