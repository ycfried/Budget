-- Household Budget — sign-up display name (owner, Nov 6, 2026).
-- "When someone signs up they must chose a name" — the follow-up to
-- the member-names caveat in PR #51: display_name was populated
-- nowhere, and the members list could only show the signed-in member
-- (household_members read policy: user_id = auth.uid()).
--
-- WHAT THIS FILE DOES (branch only, NOT applied live):
-- 1. create_household(p_name) and join_household_by_code(code) now
--    store the caller's auth-metadata name (full_name, then name) in
--    household_members.display_name when the member row is created.
--    Sign-up itself already requires a name (two-step authName panel,
--    live since Nov 4): the name step blocks on a blank name with an
--    inline soft-red error and only then calls auth.signUp with
--    options.data.full_name — so every new account from here on has a
--    metadata name for these RPCs to copy. A caller with no metadata
--    name gets display_name NULL (the list falls back to the email
--    prefix); no row is ever written with a blank or placeholder name.
--    join_household_by_code is the LIVE N13 rate-limited version
--    (verified from pg_get_functiondef, Nov 6, 2026), NOT the older
--    pre-N13 §5 version: 24-hour sweep of invite_join_attempts,
--    three trailing-1-hour buckets, unknown/malformed code logs the
--    attempt and returns NULL, already-in-a-household is checked
--    after the code resolves. The first apply of this file was
--    STOPPED at Step 0 because it was written against §5 and would
--    have silently removed the rate limiting; this reconciled
--    version keeps it. Threshold is 5 failed attempts per bucket
--    (owner, Nov 6, 2026 — was 10).
-- 2. list_household_members() — new SECURITY DEFINER RPC, member-only:
--    returns every member of the CALLER's own household (user_id,
--    display_name, role, created_at, email_prefix) and nothing else.
--    No full email is returned, only the part before '@', used as the
--    list fallback for a member with no stored name. The RLS policy on
--    household_members is NOT widened (fix-membership-policy.sql is
--    untouched): the RPC is the only path that sees other members.
--
-- WHAT THIS FILE DOES NOT DO (dropped at the owner's direction,
-- Nov 6, 2:55 PM): no admin path to set another member's display
-- name, and no backfill for existing members. The owner handles his
-- wife by deleting her account and re-adding her once the name
-- requirement is live, so she chooses a name on re-sign-up.
-- Existing members without a name keep the email-prefix fallback.
--
-- STEP 0 — VERIFY LIVE FIRST (read-only; run these and compare before
-- applying anything). Expected: create_household has the (text)
-- signature from create-household-name.sql (p_name, default
-- 'Household'), no display_name yet; join_household_by_code has the
-- (text) signature and IS the N13 rate-limited version — its body
-- references invite_join_attempts with thresholds >= 10 (the live
-- limit until this file is applied; this file lowers it to 5),
-- returns NULL on an unknown code, and has no display_name yet;
-- list_household_members does not exist yet. If live differs
-- (e.g. only the no-arg create_household exists, or the join has
-- no invite_join_attempts reference), STOP and reconcile — do not
-- apply blind.
--   select proname, pg_get_function_identity_arguments(oid) from pg_proc
--     where proname in ('create_household', 'join_household_by_code', 'list_household_members');
--   select pg_get_functiondef(oid) from pg_proc where proname = 'create_household';
--   select pg_get_functiondef(oid) from pg_proc where proname = 'join_household_by_code';
--
-- STEP 1 — Apply this file in the SQL editor, in order. The DROPs
-- leave exactly one create_household (the text signature); the
-- no-arg overload, if it still exists live, is removed with it.
-- The audit rows are unchanged in wording except that the actor
-- name now comes from the stored display name where one exists.

-- ---------------------------------------------------------------------
-- Helper: the caller's auth-metadata name, trimmed, capped, or NULL.
-- Reads auth.users, which a SECURITY DEFINER function may do; the
-- value is only ever written to the caller's OWN member row.
-- ---------------------------------------------------------------------
create or replace function public._caller_display_name()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select left(nullif(trim(coalesce(
    raw_user_meta_data->>'full_name',
    raw_user_meta_data->>'name', '')), ''), 80)
  from auth.users where id = auth.uid();
$$;
revoke execute on function public._caller_display_name() from public;
grant execute on function public._caller_display_name() to authenticated;

-- ---------------------------------------------------------------------
-- 1a. create_household(p_name) — identical to
-- supabase/create-household-name.sql except the admin member insert
-- also stores display_name from the caller's metadata.
-- ---------------------------------------------------------------------
drop function if exists public.create_household();
drop function if exists public.create_household(text);

create or replace function public.create_household(p_name text default 'Household')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
  v_name text;
  v_display_name text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from household_members where user_id = auth.uid()) then
    raise exception 'already in a household';
  end if;
  v_name := left(coalesce(nullif(trim(p_name), ''), 'Household'), 80);
  v_display_name := public._caller_display_name();
  insert into households (name, base_allowance_cents, invite_code)
    values (v_name, 37500, generate_invite_code())
    returning id into new_id;
  insert into household_members (household_id, user_id, role, display_name)
    values (new_id, auth.uid(), 'admin', v_display_name);
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (new_id, auth.uid(), 'admin', 'Household created',
            'Created via create_household RPC; creator is admin.');
  return new_id;
end;
$$;
revoke execute on function public.create_household(text) from public;
grant execute on function public.create_household(text) to authenticated;

-- ---------------------------------------------------------------------
-- 1b. join_household_by_code(code) — the LIVE N13 rate-limited
-- version, verbatim from pg_get_functiondef (Nov 6, 2026), with
-- exactly two changes: (a) all three bucket thresholds lowered
-- from >= 10 to >= 5 (owner, Nov 6, 2026); (b) the member insert
-- also stores display_name from the caller's metadata, via the
-- _caller_display_name() helper, same as §1a. Everything else is
-- byte-for-byte the live body: 24-hour sweep, NULL return on an
-- unknown/malformed code with the attempt logged, already-in-a-
-- household checked only after the code resolves, audit row.
-- ---------------------------------------------------------------------
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
  v_display_name text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  v_input := upper(btrim(coalesce(code, '')));
  delete from invite_join_attempts where created_at < now() - interval '24 hours';
  if (select count(*) from invite_join_attempts
    where user_id = auth.uid() and created_at >= v_window_start) >= 5 then
    raise exception 'too many failed join attempts, try again later';
  end if;
  if v_input <> '' and (select count(*) from invite_join_attempts
    where attempted_code = v_input and created_at >= v_window_start) >= 5 then
    raise exception 'too many failed join attempts, try again later';
  end if;
  if v_input ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' then
    select id into v_household_id from households where invite_code = v_input;
  end if;
  if v_household_id is null then
    insert into invite_join_attempts (user_id, attempted_code, household_id)
      values (auth.uid(), v_input, null);
    return null;
  end if;
  if (select count(*) from invite_join_attempts
    where household_id = v_household_id and created_at >= v_window_start) >= 5 then
    raise exception 'too many failed join attempts, try again later';
  end if;
  if exists (select 1 from household_members where user_id = auth.uid()) then
    insert into invite_join_attempts (user_id, attempted_code, household_id)
      values (auth.uid(), v_input, v_household_id);
    raise exception 'already in a household';
  end if;
  v_display_name := public._caller_display_name();
  insert into household_members (household_id, user_id, role, display_name)
    values (v_household_id, auth.uid(), 'member', v_display_name);
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_household_id, auth.uid(), 'member', 'Household joined',
            'Joined via invite code.');
  return v_household_id;
end;
$$;
revoke execute on function public.join_household_by_code(text) from public;
grant execute on function public.join_household_by_code(text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. list_household_members() — every member of the CALLER's own
--    household only. Returns no full email: email_prefix (the part
--    before '@') is the list fallback for a member with no name.
--    A caller in no household gets zero rows, never an error.
--    RLS on household_members is NOT changed by this file.
-- ---------------------------------------------------------------------
create or replace function public.list_household_members()
returns table (
  user_id uuid,
  display_name text,
  role text,
  created_at timestamptz,
  email_prefix text
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_household_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select hm.household_id into v_household_id
    from household_members hm where hm.user_id = auth.uid();
  if v_household_id is null then
    return;
  end if;
  return query
    select hm.user_id, hm.display_name, hm.role, hm.created_at,
           split_part(u.email, '@', 1)
      from household_members hm
      join auth.users u on u.id = hm.user_id
     where hm.household_id = v_household_id
     order by hm.created_at;
end;
$$;
revoke execute on function public.list_household_members() from public;
grant execute on function public.list_household_members() to authenticated;

-- VERIFICATION (run after applying, read-only):
--   select proname, pg_get_function_identity_arguments(oid) from pg_proc
--     where proname in ('create_household', 'join_household_by_code', 'list_household_members');
--   -- expected: create_household(text), join_household_by_code(text),
--   -- list_household_members() — and no no-arg create_household.
--   select pg_get_functiondef(oid) from pg_proc where proname = 'list_household_members';
--   -- expected: SECURITY DEFINER, scoped by user_id = auth.uid(), no
--   -- email column in the returns table.
--   select pg_get_functiondef(oid) from pg_proc where proname = 'join_household_by_code';
--   -- expected: still references invite_join_attempts, thresholds now
--   -- >= 5 in all three buckets, unknown code still returns NULL,
--   -- and the member insert stores display_name.
--   select * from household_members limit 0; -- unchanged shape; display_name stays nullable.
