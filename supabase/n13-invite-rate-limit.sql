-- =====================================================================
-- N13 migration — invite join rate limiting (APPLIED LIVE, Nov 2026;
-- the live function was verified from pg_get_functiondef Nov 6, 2026)
-- Owner ruling preserved: invite codes stay REUSABLE and NON-EXPIRING.
-- This file changes NOTHING about code validity: a correct code
-- still joins, any number of times, forever. It only throttles
-- FAILED attempts so a code cannot be brute-forced unthrottled.
-- Threshold is 5 failed attempts per bucket (owner, Nov 6, 2026 —
-- was 10).
--
-- NOTE: this file is now APPLIED LIVE (verified Nov 6, 2026) and the
-- companion live.js join-handler fix (NULL = failed join) is live
-- too. Do NOT re-apply this file blind: it would overwrite the
-- display_name handling added by supabase/signup-display-name.sql
-- (§1b, which is the same N13 body with the display_name insert
-- and the threshold of 5). That file is the live-apply source from
-- here on; this file stays as the N13 reference with the same
-- threshold of 5.
--
-- WHY THE INVALID-CODE PATH RETURNS NULL INSTEAD OF RAISING:
-- A Postgres exception aborts the whole RPC transaction, so an
-- attempt row inserted before a RAISE would roll back with it and
-- no failure could ever be counted. The invalid-code path therefore
-- logs the attempt and returns NULL (which commits), while the
-- client treats NULL exactly like the old exception: the join
-- handler already shows the same generic 'Join failed' message for
-- error OR missing data after the companion fix. The other failure
-- modes keep raising exactly as before: 'not authenticated',
-- 'already in a household', and the new rate-limit error below.
-- The invalid-code message itself is unchanged for the user: the
-- handler never surfaces the exception text (it shows one generic
-- message), so no information leaks about whether a code exists.
--
-- Buckets (all counted over the trailing 1 hour, all raising the
-- same generic error so no bucket leaks code existence):
--   1. Per caller:    >5 failed attempts by this user_id.
--   2. Per code value: >5 failed attempts against the same
--      normalized code value, from any callers. A household's code
--      IS a single value, so this is the household-facing bucket:
--      it throttles guessing pressure against any one household's
--      code, including distributed attempts.
--   3. Per household: after a code resolves to a household, >5
--      failed attempts attributed to that household (e.g. callers
--      already in another household attempting this code).
-- Unknown codes cannot be attributed to a household — that is why
-- buckets 1 and 2 exist alongside bucket 3.
--
-- Table retention: rows older than 24 hours are deleted on each
-- call (cheap indexed range delete). The table is a rate-limit
-- ledger, not an audit trail; audit_log still records joins.
--
-- No secrets, tokens, or keys appear in this file. Attempted codes
-- are stored by design (like failed-login logging) and must never
-- be published; the table has RLS enabled with NO member policies
-- and all grants revoked, so only SECURITY DEFINER functions
-- (running as the owner) can read or write it.
-- =====================================================================

create table if not exists invite_join_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  attempted_code text not null,
  household_id uuid references households(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists invite_join_attempts_user_time_idx
  on invite_join_attempts (user_id, created_at desc);
create index if not exists invite_join_attempts_code_time_idx
  on invite_join_attempts (attempted_code, created_at desc);
create index if not exists invite_join_attempts_household_time_idx
  on invite_join_attempts (household_id, created_at desc)
  where household_id is not null;
create index if not exists invite_join_attempts_created_idx
  on invite_join_attempts (created_at);

alter table invite_join_attempts enable row level security;
revoke all on table invite_join_attempts from public, authenticated, anon;

-- join_household_by_code(code text) returns uuid
--   * Success path UNCHANGED: a valid code still joins (member
--     role, audit row, returns the household uuid), reusable and
--     non-expiring.
--   * Invalid/unknown/malformed code: logs the attempt and returns
--     NULL (see header note — raising would roll the log back).
--   * Rate limit exceeded: raises 'too many failed join attempts,
--     try again later' (generic; reveals nothing about the code).
--   * Caller already in a household: resolves the code first so a
--     valid code's household can be attributed, then raises
--     'already in a household' as before.
create or replace function public.join_household_by_code(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_input text;
  v_household_id uuid;
  v_window_start timestamptz := now() - interval '1 hour';
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  v_input := upper(btrim(coalesce(code, '')));

  -- Cheap retention sweep (indexed range delete; see header).
  delete from invite_join_attempts where created_at < now() - interval '24 hours';

  -- Bucket 1: per caller.
  if (select count(*) from invite_join_attempts
       where user_id = auth.uid() and created_at >= v_window_start) >= 5 then
    raise exception 'too many failed join attempts, try again later';
  end if;
  -- Bucket 2: per attempted code value (household-facing).
  if v_input <> '' and (select count(*) from invite_join_attempts
       where attempted_code = v_input and created_at >= v_window_start) >= 5 then
    raise exception 'too many failed join attempts, try again later';
  end if;

  -- Invite code only: 6 characters from the unambiguous alphabet.
  if v_input ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' then
    select id into v_household_id from households where invite_code = v_input;
  end if;

  if v_household_id is null then
    -- Unknown/malformed code: log and return NULL (commits).
    insert into invite_join_attempts (user_id, attempted_code, household_id)
      values (auth.uid(), v_input, null);
    return null;
  end if;

  -- Bucket 3: per resolved household.
  if (select count(*) from invite_join_attempts
       where household_id = v_household_id and created_at >= v_window_start) >= 5 then
    raise exception 'too many failed join attempts, try again later';
  end if;

  if exists (select 1 from household_members where user_id = auth.uid()) then
    -- Attributable failure: log against the resolved household.
    insert into invite_join_attempts (user_id, attempted_code, household_id)
      values (auth.uid(), v_input, v_household_id);
    raise exception 'already in a household';
  end if;

  insert into household_members (household_id, user_id, role)
    values (v_household_id, auth.uid(), 'member');
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_household_id, auth.uid(), 'member', 'Household joined',
            'Joined via invite code.');
  return v_household_id;
end;
$$;
revoke execute on function public.join_household_by_code(text) from public;
grant execute on function public.join_household_by_code(text) to authenticated;

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy, do NOT run
-- blindly against production data; use a throwaway household and a
-- throwaway user):
--   -- Table exists, RLS on, no member access:
--   select count(*) from invite_join_attempts;  -- as authenticated:
--     -- expect: permission denied / no rows (RLS, no policy)
--   -- Invalid code returns NULL and logs (as a fresh user):
--   select join_household_by_code('ZZZZZZ');  -- expect: null
--   -- (as owner/deployer) one attempt row for that code:
--   select count(*) from invite_join_attempts
--    where attempted_code = 'ZZZZZZ';  -- expect: 1
--   -- 5 more invalid attempts, then the 6th raises:
--   select join_household_by_code('ZZZZZZ');  -- x5, each null
--   select join_household_by_code('ZZZZZZ');
--     -- expect exception 'too many failed join attempts'
--   -- A valid code still joins after the limit window (or for a
--   -- different caller with no failures): reusable, non-expiring.
-- =====================================================================
