-- plaid-sync-lock.sql — build 44, item 3 (Plaid webhook overlap lock).
--
-- DASHBOARD-APPLY FILE — NOT yet applied live. Apply via the Supabase
-- dashboard SQL Editor (project "Budget", ref tnkhvdkmwmwiogiienee)
-- BEFORE, or together with, deploying the build-44 plaid-sync /
-- plaid-webhook Edge Functions. Until it lands, plaid-sync FAILS OPEN
-- on the lock claim (logs, then syncs normally) — the lock is absent,
-- not broken — so a function deploy ahead of the dashboard apply
-- never blocks sync. Verify after applying:
--   select * from pg_indexes where indexname = 'plaid_sync_locks_pkey';
--   select proname from pg_proc where proname in
--     ('try_claim_sync_lock', 'release_sync_lock');
--   select grantee, privilege_type from information_schema.routine_privileges
--     where routine_name in ('try_claim_sync_lock', 'release_sync_lock');
-- Expected: service_role has EXECUTE on both RPCs; authenticated has
-- EXECUTE on neither.
--
-- WHY: a webhook-triggered sync, the hourly pg_cron backstop, and a
-- manual admin sync can all run at once for one household. The
-- upserts are idempotent, but two runs share one sync cursor and can
-- interleave page sequences, so one run can persist a cursor the
-- other has not finished reading. The lock serialises syncs per
-- household: the loser returns 200 { sync_skipped: 'already_running' }
-- and does nothing — the winner does the work. A lock is held at most
-- one TTL (~10 min); a crashed run's lock expires on its own, so no
-- stuck-sync cleanup is ever needed. Only the owner that claimed a
-- lock can release it (locked_by match), so a concurrent run can
-- never release another run's lock.
--
-- This file does NOT change supabase/server-sync-cron.sql — the hourly
-- cron stays exactly as the backstop; it calls plaid-sync, which
-- claims the lock internally.

create table if not exists public.plaid_sync_locks (
  household_id uuid primary key references public.households(id) on delete cascade,
  locked_until timestamptz not null,
  locked_by text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.plaid_sync_locks enable row level security;
-- No member policies: only the service role (which bypasses RLS)
-- ever touches this table, through the RPCs below. Members have no
-- direct access to it.
revoke all on table public.plaid_sync_locks from public, authenticated, anon;
grant select, insert, update, delete on table public.plaid_sync_locks to service_role;

-- try_claim_sync_lock: one atomic statement — insert a fresh lock,
-- or, if a row already exists, take it over ONLY when it has expired.
-- Returns true when this caller now holds the lock, false when
-- another run holds a live lock. The column is NOT NULL, so the
-- expired test is just locked_until < now() (no NULL branch needed).
create or replace function public.try_claim_sync_lock(
  p_household_id uuid, p_owner text, p_ttl_seconds integer default 600)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claimed uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'service role only'; end if;
  if p_household_id is null then raise exception 'household_id required'; end if;
  insert into public.plaid_sync_locks (household_id, locked_until, locked_by)
  values (p_household_id,
          now() + make_interval(secs => greatest(p_ttl_seconds, 1)),
          coalesce(p_owner, ''))
  on conflict (household_id) do update
    set locked_until = excluded.locked_until,
        locked_by = excluded.locked_by,
        updated_at = now()
    where plaid_sync_locks.locked_until < now()
  returning household_id into v_claimed;
  return v_claimed is not null;
end;
$$;

-- release_sync_lock: delete the lock, but only when the caller is
-- the owner that claimed it. A wrong-owner release is a silent no-op.
create or replace function public.release_sync_lock(p_household_id uuid, p_owner text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then raise exception 'service role only'; end if;
  delete from public.plaid_sync_locks
    where household_id = p_household_id
      and locked_by = coalesce(p_owner, '');
end;
$$;

revoke execute on function public.try_claim_sync_lock(uuid, text, integer) from public;
revoke execute on function public.try_claim_sync_lock(uuid, text, integer) from authenticated;
revoke execute on function public.try_claim_sync_lock(uuid, text, integer) from anon;
grant execute on function public.try_claim_sync_lock(uuid, text, integer) to service_role;
revoke execute on function public.release_sync_lock(uuid, text) from public;
revoke execute on function public.release_sync_lock(uuid, text) from authenticated;
revoke execute on function public.release_sync_lock(uuid, text) from anon;
grant execute on function public.release_sync_lock(uuid, text) to service_role;
