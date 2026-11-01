-- Household Budget — create_household() RPC (run AFTER schema.sql).
-- WHY THIS EXISTS (Nov 1, 2026, evening — real failure, not theory):
-- The bootstrap-household Edge Function failed twice at 5:39 PM EST with
-- HTTP 500 on the households insert. The logs prove the user's JWT was
-- valid and auth passed, but the service-role insert failed. The
-- function's service-role client reads Deno.env SUPABASE_SERVICE_ROLE_KEY,
-- which this project's dashboard marks as a DEPRECATED legacy key
-- ("Use SUPABASE_SECRET_KEYS issued through JWT Signing Keys instead").
-- Rather than chase a legacy key that Supabase is retiring, household
-- creation moves to the pattern Supabase itself recommends for this
-- exact case: a SECURITY DEFINER Postgres function. It runs with the
-- database owner's rights (so it bypasses RLS by design), but it is
-- safe because:
--   * It only ever acts for auth.uid() — the caller, never anyone else.
--   * It refuses if the caller already belongs to any household.
--   * It creates exactly one household and exactly one membership row
--     (caller = admin), plus one audit row, and returns only the new id.
--   * It is granted to `authenticated` only — anonymous callers cannot
--     execute it, and even if they could, auth.uid() would be NULL and
--     the membership insert would fail on the NOT NULL constraint.
-- The bootstrap-household Edge Function is left deployed but unused;
-- live.js calls this RPC instead. No secret key is involved anywhere
-- in this path — the live app already proves the publishable key works
-- (sign-in and the membership read succeeded before this failure).

create or replace function public.create_household()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from household_members where user_id = auth.uid()) then
    raise exception 'already in a household';
  end if;
  insert into households (name, base_allowance_cents)
    values ('Household', 37500)
    returning id into new_id;
  insert into household_members (household_id, user_id, role)
    values (new_id, auth.uid(), 'admin');
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (new_id, auth.uid(), 'admin', 'Household created',
            'Created via create_household RPC; creator is admin.');
  return new_id;
end;
$$;

revoke execute on function public.create_household() from public;
grant execute on function public.create_household() to authenticated;
