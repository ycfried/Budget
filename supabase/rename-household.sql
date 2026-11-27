-- rename-household.sql — Rename the household (owner, Nov 27, 2026).
--
-- The owner asked for a rename option on the Household & Members
-- screen: the screen showed "Household: Household" as plain text
-- with no edit affordance. No RPC existed to change the name —
-- `create_household(p_name)` only names a household at creation —
-- so this adds the one missing update.
--
-- Storage: `households.name`, the same column the name read
-- (`PostgrestClient.householdName`) already returns, so the new
-- name shows everywhere the current name shows (Members screen,
-- shell top bar, export) once the client re-reads it.
--
-- Writes go through this RPC, never a direct UPDATE — the same
-- rule as the fund rename (`set_fund_name`, fund-names.sql).
-- OWNER-ONLY: the caller must be the household's creator
-- (`households.owner_id = auth.uid()`), the same owner check the
-- Members screen already uses client-side for the invite code
-- (only the owner can share the invite code). Admins who are not
-- the owner cannot rename, and members cannot either.
--
-- NAME RULES: trimmed; a blank name is refused (unlike creation,
-- which falls back to 'Household' — a rename to blank would
-- silently un-name the household); capped at 80 characters, the
-- same cap as creation (`create_household`, HouseholdViews caps
-- the field at 80 too). Returns the stored name. A no-op (the
-- name is already that) succeeds silently so the client can call
-- it idempotently.
--
-- Apply via the Supabase dashboard SQL editor (project "Budget").
-- The native app degrades gracefully if this is not applied yet:
-- the rename attempt fails with a plain-language error. Apply
-- BEFORE the TestFlight build carrying the rename UI goes out,
-- as with the build-37 fund-names migration.

create or replace function public.rename_household(
  p_household_id uuid, p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_owner_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_household_id is null then
    raise exception 'household is required';
  end if;
  v_name := btrim(coalesce(p_name, ''));
  if v_name = '' then
    raise exception 'name must not be empty';
  end if;
  if char_length(v_name) > 80 then
    raise exception 'name must be 80 characters or fewer';
  end if;
  -- Owner-only: the caller must be the household's creator.
  -- A household with no recorded owner (backfill gap) cannot be
  -- renamed by anyone until its owner_id is set — the same
  -- fail-closed rule as the owner-only demote in
  -- household-roles-owner.sql.
  select h.owner_id into v_owner_id
    from public.households h where h.id = p_household_id;
  if v_owner_id is null then
    raise exception 'household not found';
  end if;
  if v_owner_id <> auth.uid() then
    raise exception 'owner only';
  end if;
  -- Idempotent no-op: already that name — succeed without an
  -- audit row, so the client can call it safely when nothing
  -- changed.
  if exists (select 1 from public.households
              where id = p_household_id and name = v_name) then
    return v_name;
  end if;
  update public.households
     set name = v_name
   where id = p_household_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Household renamed',
          'Household renamed to "' || v_name || '".');
  return v_name;
end;
$$;

revoke execute on function public.rename_household(uuid, text) from public;
grant execute on function public.rename_household(uuid, text) to authenticated;
