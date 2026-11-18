-- Household Budget — create_household(p_name) — SUPERSEDED, NEVER
-- APPLY (P2-B19, Nov 8, 2026). The "NOT YET APPLIED" note this
-- header carried before is stale as a live-state claim: a
-- create_household(text) IS live — the version in
-- supabase/signup-display-name.sql, applied live Nov 8, 2026,
-- which is this file's body PLUS storing the caller's display name
-- on the admin member row. Applying THIS file would DROP that
-- version and silently remove display-name handling from every
-- new household. Keep this file only as the pre-display-name
-- record; any future create_household change starts from
-- signup-display-name.sql.
--
-- WHAT CHANGES vs the live function (supabase/01-invite-codes.sql §4):
-- exactly one thing: the household name comes from the new p_name
-- parameter instead of the hardcoded 'Household'. Everything else is
-- identical: same authenticated-only guard, same already-in-a-
-- household refusal, same admin membership insert, same audit row,
-- same invite_code assignment via generate_invite_code(), same
-- grants, same return (the new household id).
--
-- WHY THE DROPs: create or replace with a new signature would leave
-- the old no-arg function in place as an overload. Dropping both
-- known signatures first leaves exactly one create_household, so a
-- client call with no argument resolves to this function and its
-- DEFAULT applies. (If neither signature exists, the drops are
-- no-ops.)
--
-- NAME RULES: p_name is trimmed; a NULL, empty, or blank name falls
-- back to 'Household'; the stored name is capped at 80 characters
-- (the client input is maxlength="80" as well).

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
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from household_members where user_id = auth.uid()) then
    raise exception 'already in a household';
  end if;
  v_name := left(coalesce(nullif(trim(p_name), ''), 'Household'), 80);
  insert into households (name, base_allowance_cents, invite_code)
    values (v_name, 37500, generate_invite_code())
    returning id into new_id;
  insert into household_members (household_id, user_id, role)
    values (new_id, auth.uid(), 'admin');
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (new_id, auth.uid(), 'admin', 'Household created',
            'Created via create_household RPC; creator is admin.');
  return new_id;
end;
$$;

-- NOTE: the grants name the new (text) signature, not the old
-- zero-arg one — the old signature no longer exists after the DROPs.
revoke execute on function public.create_household(text) from public;
grant execute on function public.create_household(text) to authenticated;
