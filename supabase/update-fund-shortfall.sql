-- Household Budget — update_fund_shortfall, CANONICAL version (P0-3, Nov 8, 2026).
--
-- This is the ONLY file that may be applied live for update_fund_shortfall.
-- It is the alias-qualified version from SQL_RESTORE_SHORTFALL_INVESTIGATION.md
-- §7 Item 3 (Nov 5, 2026 investigation), committed here so the repo finally
-- holds the version live is supposed to run.
--
-- WHY THIS VERSION (and not the p_ rename):
-- * Parameter name stays `household_id`, exactly as week-close calls it
--   (supabase/functions/week-close/index.ts:382, named argument
--   { household_id, shortfall_cents }). No caller change, no Edge Function
--   redeploy. The p_ rename file (supabase/DO-NOT-APPLY-...-fix.sql) would
--   break both week-close call sites with a missing-parameter error, mid-run,
--   after closes/releases were already persisted.
-- * Ambiguity is removed by qualifying the COLUMN with a table alias
--   (`hm.household_id = household_id`), not by renaming the parameter.
--   After aliasing, the only unqualified `household_id` references are the
--   parameter; `id = household_id` has no competing column.
-- * Restores the audit_log row and the FOR UPDATE row lock that the live
--   version dropped (a lost shortfall can never again vanish silently;
--   concurrent closes cannot race the shortfall). Those are behaviour
--   changes to name to the owner, not invisible no-ops.
--
-- LIVE STATE — VERIFIED Nov 8, 2026, 2:19 PM (read-only probe): live
-- update_fund_shortfall is this alias version — signature
-- (household_id uuid, shortfall_cents integer), body references
-- household_id throughout, p_household_id appears nowhere. P0-3 is
-- therefore verify-only: no SQL fix is needed live. This file is the
-- canonical repo copy of what live runs; re-applying it is a safe
-- no-op, needed only if live ever drifts from it. If a future probe
-- shows a different live body, stop and reconcile before applying.
-- STEP 0 (only if re-applying): select pg_get_functiondef(oid) from
-- pg_proc where proname = 'update_fund_shortfall'; expect the alias
-- version below (hm.household_id = household_id, audit_log insert,
-- FOR UPDATE). STEP 1: apply this file in the SQL editor, in order.
-- NEVER apply supabase/DO-NOT-APPLY-deep-audit-update-fund-shortfall-fix.sql.
-- NEVER re-apply supabase/04-admin-rpcs.sql in full (its §1 Approve
-- function is outdated and would break Approve).
create or replace function public.update_fund_shortfall(household_id uuid, shortfall_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if shortfall_cents is null or shortfall_cents < 0 then raise exception 'shortfall must be non-negative'; end if;
  if not exists (select 1 from household_members hm
                 where hm.household_id = household_id and hm.user_id = auth.uid() and hm.role = 'admin') then
    raise exception 'admin only';
  end if;
  select fund_shortfall_cents into v_old from households where id = household_id for update;
  if not found then raise exception 'household not found'; end if;
  update households set fund_shortfall_cents = shortfall_cents where id = household_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (household_id, auth.uid(), 'admin', 'Fund shortfall updated',
            'Fund shortfall changed from ' || v_old::text || ' cents to ' || shortfall_cents::text || ' cents.');
end;
$$;
revoke execute on function public.update_fund_shortfall(uuid, integer) from public;
grant execute on function public.update_fund_shortfall(uuid, integer) to authenticated;
