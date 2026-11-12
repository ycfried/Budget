-- household-roles-owner.sql — Owner / Admin / Member roles (Nov 11, 2026).
--
-- OWNER DECISION (voice note, Nov 11, ~7:47 PM; invite-code rule
-- decided ~7:49 PM): one owner = the household creator. ONLY the owner
-- can remove members. Owner or admin can promote a member to admin
-- (co-admin: full access except removing members). ONLY the owner sees
-- the invite code. Labels: Owner / Admin / Member, each with a short
-- plain note of what it can do (native UI).
--
-- DESIGN (chosen to keep the blast radius small — see below): the owner
-- is recorded as `households.owner_id` (the creator's auth user id),
-- NOT as a third `household_members.role` value. The creator keeps
-- role = 'admin' in household_members, so every existing admin-only
-- RPC check (`role = 'admin'`) keeps passing for the owner with NO
-- changes — no sweep across ~25 SQL files, no risk of silently
-- locking the owner out of an admin capability. Owner-only rules are
-- additive checks in exactly two RPCs (remove + set-role) plus the
-- native UI gate on the invite code.
--
-- What this file does (apply ONCE, whole file, in the Supabase SQL
-- editor; NOT YET APPLIED LIVE as of Nov 11, ~9:00 PM):
--   §1  households.owner_id column + backfill for existing households
--       (creator from the audit_log 'Household created' row; fallback
--       = the earliest admin by household_members.created_at).
--   §2  create_household sets owner_id = auth.uid() for new households
--       (creator still gets role = 'admin').
--   §3  remove_household_member becomes OWNER-ONLY. The "never remove
--       the last admin" guard is DROPPED — reconciliation: under the
--       new model only the owner removes members at all, and the owner
--       is always admin-capable, so removing the last other admin can
--       never strand the household without an admin. Self-removal and
--       not-a-member refusals are kept.
--   §4  New RPC set_household_member_role(p_user_id, p_role):
--       promote member -> admin (owner or admin may do it), demote
--       admin -> member (OWNER ONLY — an admin demoting another admin
--       is a footgun). Refuses: the owner's role (the owner is
--       permanent), changing your own role, p_role outside
--       ('admin', 'member'). Audit-logged. Idempotent no-op if the
--       member already has that role.
--
-- What this file does NOT do (deliberate, report in the parent review):
--   * The invite-code column is NOT locked down server-side. The
--     native app only FETCHES it for the owner (UI gate), so admins
--     and members never see it in the app — but a member with a raw
--     PostgREST query could still read households.invite_code, as
--     today. A true column lock needs an RLS policy on households
--     (owner-only SELECT on invite_code) or an owner-only
--     get_household_invite_code() RPC; that is a follow-up, not in
--     this file, because it changes the read path for the web app too.
--   * The web app is NOT updated. Its Remove button still shows to
--     admins; a non-owner admin tapping it now gets the RPC's
--     'owner only' refusal (shown generically). The web UI freeze at
--     v69 is respected — the native app carries the new model.
--
-- VERIFICATION (read-only, after applying):
--   select id, name, owner_id from households;
--   -- every household must have a non-NULL owner_id. If any is NULL
--   -- (no audit row AND no admin — should not happen), set it by hand
--   -- to that household's creator before relying on remove/promote.
--   select pg_get_functiondef(oid) from pg_proc
--     where proname in ('remove_household_member',
--                       'set_household_member_role', 'create_household');
-- Live behaviour proof (synthetic household only, never the real one):
--   owner removes a member -> row gone + audit row; admin caller ->
--   'owner only'; owner removes self -> refused; promote member ->
--   admin as admin caller works; demote as admin caller -> refused;
--   demote as owner works; change the owner's role -> refused.

-- ---------------------------------------------------------------------
-- §1  households.owner_id + backfill
-- ---------------------------------------------------------------------
alter table public.households
  add column if not exists owner_id uuid references auth.users(id);

-- Backfill, first pass: the creator is the actor of the audit row
-- that create_household writes ('Household created').
update public.households h
   set owner_id = sub.actor
  from (
    select distinct on (household_id) household_id, actor
      from public.audit_log
     where action = 'Household created'
     order by household_id, created_at
  ) sub
 where h.id = sub.household_id
   and h.owner_id is null;

-- Backfill, fallback: households with no audit row (none expected —
-- every household was created through create_household) take their
-- earliest admin as owner. In the real household that is the creator
-- (the only admin; the test member joined later as a member).
update public.households h
   set owner_id = sub.user_id
  from (
    select distinct on (household_id) household_id, user_id
      from public.household_members
     where role = 'admin'
     order by household_id, created_at
  ) sub
 where h.id = sub.household_id
   and h.owner_id is null;

-- ---------------------------------------------------------------------
-- §2  create_household — creator becomes owner_id (role stays admin)
-- ---------------------------------------------------------------------
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
  insert into households (name, base_allowance_cents, invite_code, owner_id)
    values (v_name, 37500, generate_invite_code(), auth.uid())
    returning id into new_id;
  insert into household_members (household_id, user_id, role)
    values (new_id, auth.uid(), 'admin');
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (new_id, auth.uid(), 'admin', 'Household created',
            'Created via create_household RPC; creator is admin and owner.');
  return new_id;
end;
$$;

revoke execute on function public.create_household(text) from public;
grant execute on function public.create_household(text) to authenticated;

-- ---------------------------------------------------------------------
-- §3  remove_household_member — OWNER-ONLY (was admin-only)
-- ---------------------------------------------------------------------
-- Reconciles the PR #57 "never remove the last admin" guard: under the
-- new model only the owner removes members, and the owner is always
-- admin-capable, so no removal can leave the household admin-less.
-- The guard is dropped; self-removal and not-a-member stay refused.
create or replace function public.remove_household_member(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household_id uuid;
  v_owner_id uuid;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_user_id is null then
    raise exception 'member is required';
  end if;
  -- Caller must be a member of a household, and must be its owner.
  select hm.household_id into v_household_id
    from household_members hm where hm.user_id = auth.uid();
  if v_household_id is null then
    raise exception 'not in a household';
  end if;
  select h.owner_id into v_owner_id
    from households h where h.id = v_household_id;
  if v_owner_id is null or v_owner_id <> auth.uid() then
    raise exception 'owner only';
  end if;
  -- The owner cannot remove themselves.
  if p_user_id = auth.uid() then
    raise exception 'you cannot remove yourself';
  end if;
  -- Target must be a member of the owner's household.
  if not exists (
    select 1 from household_members hm
     where hm.household_id = v_household_id and hm.user_id = p_user_id
  ) then
    raise exception 'that person is not a member of your household';
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

-- ---------------------------------------------------------------------
-- §4  set_household_member_role — promote / demote
-- ---------------------------------------------------------------------
-- p_role must be 'admin' or 'member'. The owner role is never assigned
-- or removed through this RPC: the owner is the household creator and
-- is permanent. Promote (member -> admin) may be done by the owner or
-- an admin; demote (admin -> member) is OWNER-ONLY. Nobody may change
-- their own role. A no-op (target already has p_role) succeeds
-- silently so the client can call it idempotently.
create or replace function public.set_household_member_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household_id uuid;
  v_caller_role text;
  v_owner_id uuid;
  v_target_role text;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_user_id is null then
    raise exception 'member is required';
  end if;
  if p_role is null or p_role not in ('admin', 'member') then
    raise exception 'role must be admin or member';
  end if;
  -- Caller must be an admin of their household (the owner keeps
  -- role = 'admin', so this covers owner and admin alike).
  select hm.household_id, hm.role into v_household_id, v_caller_role
    from household_members hm where hm.user_id = auth.uid();
  if v_household_id is null or v_caller_role <> 'admin' then
    raise exception 'admin only';
  end if;
  -- Nobody changes their own role.
  if p_user_id = auth.uid() then
    raise exception 'you cannot change your own role';
  end if;
  -- Target must be a member of the caller's household.
  select hm.role into v_target_role
    from household_members hm
   where hm.household_id = v_household_id and hm.user_id = p_user_id;
  if not found then
    raise exception 'that person is not a member of your household';
  end if;
  -- The owner's role is permanent.
  select h.owner_id into v_owner_id
    from households h where h.id = v_household_id;
  if v_owner_id is not null and p_user_id = v_owner_id then
    raise exception 'you cannot change the owner''s role';
  end if;
  -- Demoting an admin to member is owner-only.
  if v_target_role = 'admin' and p_role = 'member' then
    if v_owner_id is null or v_owner_id <> auth.uid() then
      raise exception 'owner only';
    end if;
  end if;
  -- Idempotent no-op.
  if v_target_role = p_role then
    return;
  end if;
  select coalesce(nullif(btrim(hm.display_name), ''),
                  split_part(u.email, '@', 1))
    into v_name
    from household_members hm
    join auth.users u on u.id = hm.user_id
   where hm.household_id = v_household_id and hm.user_id = p_user_id;
  update household_members
     set role = p_role
   where household_id = v_household_id and user_id = p_user_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_household_id, auth.uid(), 'admin',
            case when p_role = 'admin' then 'Member promoted'
                 else 'Member demoted' end,
            coalesce(v_name, 'A member')
            || case when p_role = 'admin'
                    then ' was made an admin (co-admin).'
                    else ' was changed to a regular member.' end);
end;
$$;
revoke execute on function public.set_household_member_role(uuid, text) from public;
grant execute on function public.set_household_member_role(uuid, text) to authenticated;
