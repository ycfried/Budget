-- Gmail grant clock (Nov 8, 2026, P1-R2).
--
-- Testing-mode Google refresh tokens expire ~7 days after the grant,
-- and the app had no pre-expiry warning: the client could only read
-- created_at, which the oauth callback upsert never updates, so it
-- stays at the FIRST connection date forever. This migration adds
-- connected_at, set on every (re)connect, and exposes it through the
-- public view so the app can warn before the token dies.
--
-- STEP 0 — verify live first (read-only):
--   select column_name from information_schema.columns
--     where table_name = 'email_connections' and column_name = 'connected_at';
--   Expected: no row (column does not exist yet). If it exists, STOP.
-- STEP 1 — apply this file in the SQL editor, in order.
-- The view definition here must stay in sync with
-- supabase/gmail-oauth.sql (same column list); this file wins on
-- apply order because it runs after.

alter table public.email_connections
  add column if not exists connected_at timestamptz not null default now();

-- Backfill: the column is brand new, so every existing row's grant
-- time is its creation time. (No row can yet hold a real post-migration
-- grant time: the callback upsert sets connected_at only from here on.)
update public.email_connections
  set connected_at = created_at;

create or replace view public.email_connections_public as
  select
    id,
    household_id,
    provider,
    email_address,
    status,
    last_poll_at,
    last_error,
    created_at,
    connected_at
  from public.email_connections
  where household_id in (select household_id from public.household_members
                         where user_id = auth.uid());

grant select on public.email_connections_public to authenticated;
revoke all on public.email_connections_public from public;
