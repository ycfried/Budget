-- remove-household-member.sql — admin removes another member (Nov 8, 2026).
-- Owner-found bug, Nov 8, ~7:42 PM: the admin could NOT remove other
-- household members from the app — the Members page had no remove
-- control at all, so a stale test account with data access could not
-- be removed. This is launch-blocking: an admin must be able to
-- remove a member.
--
-- PREPARED ONLY — apply live only with the owner's explicit approval.
-- Whole file, once, in the Supabase SQL editor.
--
-- What remove_household_member(p_user_id uuid) does:
--   * Admin-only, caller's own household only (same pattern as the
--     other admin RPCs: auth.uid() check, household_members
--     role = 'admin' check, revoke from public, grant to
--     authenticated).
--   * Refuses: removing yourself ("you cannot remove yourself"),
--     removing the last admin ("cannot remove the last admin"),
--     removing someone who is not a member of your household.
--   * Deletes ONLY the household_members row. It does NOT delete
--     the removed user's auth account and does NOT delete their data
--     rows (transactions, fund rows, audit rows stay, still
--     attributed to them) — only the membership ends, so they lose
--     access to the household.
--   * Writes one audit_log row ("Member removed").
-- The client shows the Remove button only on other members' rows,
-- only for admins (live.js memberRowHtml + removeMemberFlow); the
-- RPC re-checks everything server-side, so a forged call fails
-- the same way.

create or replace function public.remove_household_member(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household_id uuid;
  v_caller_role text;
  v_target_role text;
  v_admin_count integer;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_user_id is null then
    raise exception 'member is required';
  end if;
  -- Caller must be an admin of their household.
  select hm.household_id, hm.role into v_household_id, v_caller_role
    from household_members hm where hm.user_id = auth.uid();
  if v_household_id is null or v_caller_role <> 'admin' then
    raise exception 'admin only';
  end if;
  -- An admin cannot remove themselves (their own row never shows a
  -- Remove button; the server refuses anyway).
  if p_user_id = auth.uid() then
    raise exception 'you cannot remove yourself';
  end if;
  -- Target must be a member of the caller's household.
  select hm.role into v_target_role
    from household_members hm
   where hm.household_id = v_household_id and hm.user_id = p_user_id;
  if not found then
    raise exception 'that person is not a member of your household';
  end if;
  -- Never remove the last admin.
  if v_target_role = 'admin' then
    select count(*) into v_admin_count
      from household_members
     where household_id = v_household_id and role = 'admin';
    if v_admin_count <= 1 then
      raise exception 'cannot remove the last admin';
    end if;
  end if;
  -- Name for the audit row: stored display_name, else email prefix.
  select coalesce(nullif(btrim(hm.display_name), ''),
                  split_part(u.email, '@', 1))
    into v_name
    from household_members hm
    join auth.users u on u.id = hm.user_id
   where hm.household_id = v_household_id and hm.user_id = p_user_id;
  -- Only the membership ends. The auth account and all data rows
  -- (transactions, fund rows, audit rows) are untouched.
  delete from household_members
   where household_id = v_household_id and user_id = p_user_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_household_id, auth.uid(), 'admin', 'Member removed',
            'Removed ' || coalesce(v_name, 'a member')
            || ' from the household. They can no longer see the household.');
end;
$$;
revoke execute on function public.remove_household_member(uuid) from public;
grant execute on function public.remove_household_member(uuid) to authenticated;

-- VERIFICATION (run after applying, read-only):
--   select proname, pg_get_function_identity_arguments(oid) from pg_proc
--     where proname = 'remove_household_member';
--   -- expected: remove_household_member(uuid)
--   select pg_get_functiondef(oid) from pg_proc
--     where proname = 'remove_household_member';
--   -- expected: 'admin only', 'you cannot remove yourself',
--   -- 'cannot remove the last admin', 'not a member of your household',
--   -- 'Member removed' audit insert, delete from household_members only.
-- Live behaviour proof (synthetic household only, never the real one):
-- create a synthetic household with an admin + a member, call the RPC
-- as the admin for the member, and check: the member row is gone, the
-- audit row exists, the member's auth user still exists, and their
-- data rows are untouched. Then the refusal cases: self-removal,
-- last-admin removal, non-member, non-admin caller — each must raise.
