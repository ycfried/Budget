-- =====================================================================
-- OnBudget — invite-only: close household creation (Nov 17, 2026).
-- Launch package for App Store publication (free + invite-only).
--
-- WHY: the app is published as INVITE-ONLY. Until now any signed-in
-- user could call create_household() and get a whole household of
-- their own with no invitation at all — the "Create Household (I Am
-- the Owner)" button on the post-sign-up screen. That is the last
-- way into the app without an invite code. Joining an existing
-- household is already invite-only (join_household_by_code accepts
-- only the 6-character code; the legacy-UUID path was removed Nov 2,
-- 2026, and the join is rate-limited at 5 failed attempts/hour).
-- After this file, the ONLY way into any household is a valid invite
-- code shared by a household owner.
--
-- WHAT THIS FILE DOES:
--   1. Revokes EXECUTE on create_household(text) from `authenticated`.
--      That is the only live overload (signup-display-name.sql dropped
--      the no-arg overload Nov 8, 2026). A defensive revoke for the
--      no-arg overload is included, guarded so the script does not
--      fail if that overload does not exist.
--   2. Nothing else changes: join_household_by_code, the rate limit,
--      the RLS policies, and every other RPC are untouched.
--
-- WHAT BREAKS (intended):
--   * The native app's "Create Household" button is REMOVED in the
--     same launch branch (invite-only-launch) — the post-sign-up
--     screen becomes join-only. The button must never be shown
--     again while this revoke stands, or it will always fail.
--   * The frozen web app's (live.js) "Create Household" button will
--     fail with an error after this is applied. The owner already
--     belongs to a household and never sees that screen; a stranger
--     on the web gets a failure instead of a household, which is the
--     intended invite-only behaviour. If the web app is ever
--     unfrozen, remove its create button too.
--   * The simulator UI test testPlaidSandboxConnect is skipped in
--     the same branch (it created its own admin household to prove
--     the Plaid Link sheet opens). Plaid Link opening was proven in
--     earlier simulator runs and the live Amex connection is proven
--     in production; re-prove manually on TestFlight with the test
--     admin account if the Link flow ever changes.
--
-- HOW TO CREATE A HOUSEHOLD AFTER THIS (owner only):
--   Household creation is fully closed to app users. If the owner
--   ever needs a new household (e.g. for a family member starting
--   their own), run the one-off SQL below in the Supabase dashboard
--   SQL editor (it runs as the database owner, so RLS does not
--   block it). Replace the name and the owner's user id.
--     insert into households (name, base_allowance_cents, invite_code)
--       values ('Family', 37500, generate_invite_code())
--       returning id;  -- note the id, then:
--     insert into household_members (household_id, user_id, role)
--       values ('<id>', '<owner-user-uuid>', 'admin');
--     insert into audit_log (household_id, actor, actor_name, action, detail)
--       values ('<id>', '<owner-user-uuid>', 'admin', 'Household created',
--               'Created by owner via dashboard; creator is admin.');
--   To RE-OPEN creation for app users (reversing this file):
--     grant execute on function public.create_household(text) to authenticated;
--   (and restore the "Create Household" button in the app first, or
--   the reopened RPC has no UI.)
--
-- HOW TO APPLY: paste this whole file into the Supabase dashboard
-- SQL editor and run it. It is idempotent — running it twice is safe.
-- VERIFY after applying (read-only):
--   select has_function_privilege('authenticated',
--     'public.create_household(text)', 'execute');  -- expect: false
--   select proname, pg_get_function_identity_arguments(oid)
--     from pg_proc where proname = 'create_household';
--     -- expect: exactly one row, create_household(text)
-- =====================================================================

-- The live overload: create_household(p_name text).
revoke execute on function public.create_household(text) from authenticated;

-- Defensive: the no-arg overload was dropped Nov 8, 2026, but revoke
-- it too if it exists anywhere, so no create path survives.
do $$
begin
  if exists (
    select 1 from pg_proc
     where proname = 'create_household'
       and pg_get_function_identity_arguments(oid) = ''
  ) then
    revoke execute on function public.create_household() from authenticated;
  end if;
end;
$$;
