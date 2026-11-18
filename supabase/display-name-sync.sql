-- display-name-sync.sql — Display-name propagation (build 43, item 9, owner Nov 17, 2026).
--
-- ROOT CAUSE: `household_members.display_name` is a snapshot copied
-- from auth metadata only when the member row is created
-- (`create_household` / `join_household_by_code`,
-- `supabase/signup-display-name.sql`). Nothing ever updates it
-- afterwards, and Profile → Save Name writes auth metadata
-- (`full_name`) only. `list_household_members()` returns that stale
-- snapshot, and the client can only fall back to auth metadata for
-- its OWN row (RLS hides other members' metadata), so another
-- member's rename falls through to the email prefix — the wife's
-- updated name still showed as "chayasf1" on the owner's device.
--
-- FIX (two parts):
-- 1. `sync_my_display_name(p_display_name)` — the client calls it
--    (best-effort, never fails the save) right after Profile →
--    Save Name writes the metadata. It updates the caller's member
--    rows in every household to the new name, audited.
-- 2. Backfill below — one-time: copies the current metadata name
--    into every stale member row (this fixes the wife's row on
--    apply; no app update needed for the backfill itself).
--
-- Apply via the Supabase dashboard SQL editor (project "Budget").
-- The native app degrades gracefully if this is not applied yet:
-- the sync call throws (function does not exist) and is swallowed,
-- and the Members list keeps showing the stale snapshot until the
-- SQL lands. Apply BEFORE the build-43 TestFlight build goes out.

-- Sync the caller's display name into their member rows (all
-- households). Empty names raise; names are capped at 80 chars.
-- Only rows whose stored name actually differs are touched (and
-- audited).
create or replace function public.sync_my_display_name(p_display_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_household uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_name := btrim(coalesce(p_display_name, ''));
  if v_name = '' then raise exception 'name must not be empty'; end if;
  if char_length(v_name) > 80 then raise exception 'name must be 80 characters or fewer'; end if;
  for v_household in
    update public.household_members
       set display_name = v_name
     where user_id = auth.uid()
       and display_name is distinct from v_name
     returning household_id
  loop
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (v_household, auth.uid(), v_name, 'Display name updated',
            'Display name updated to "' || v_name || '".');
  end loop;
end;
$$;

revoke execute on function public.sync_my_display_name(text) from public;
grant execute on function public.sync_my_display_name(text) to authenticated;

-- One-time backfill: copy the current auth-metadata name into
-- every member row whose stored snapshot is stale or missing.
-- Rows with no metadata name are left alone.
update public.household_members hm
   set display_name = btrim(au.raw_user_meta_data->>'full_name')
  from auth.users au
 where hm.user_id = au.id
   and au.raw_user_meta_data->>'full_name' is not null
   and btrim(au.raw_user_meta_data->>'full_name') <> ''
   and hm.display_name is distinct from btrim(au.raw_user_meta_data->>'full_name');
