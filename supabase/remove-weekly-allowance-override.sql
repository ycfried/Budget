-- Household Budget — remove weekly allowance override — NOT YET
-- APPLIED LIVE (Nov 12, 2026). The native Temporary Allowance UI
-- calls this RPC from its "Remove Override" button; until this file
-- is applied live the RPC does not exist and the button fails with a
-- plain-language error (nothing is changed). Apply with the usual
-- live-apply care, then verify in the test household: set a
-- temporary allowance, remove it, and confirm the base allowance
-- applies again for those weeks.
--
-- WHY: a weekly allowance override (supabase/weekly-allowance-
-- override.sql) had no removal path — once set, the only way back
-- to the base allowance was waiting the weeks out or setting a new
-- override equal to the base. This adds the removal: one RPC that
-- deletes the override row for a household/week.
--
-- SEMANTICS (read before approving):
-- - Deletes the override row for (household_id, week_start) only.
--   Weeks without an override keep using the household base (plus
--   temp increases, as before). Deleting an override for a week
--   that already has a week_closes snapshot changes nothing for
--   that week: compute-week still prefers the stored snapshot's B/T
--   over any later override, exactly as the set path documents.
-- - Deleting an override does NOT restore any temp_increases row:
--   setting the override deleted that week's temp increases, and
--   they are gone. The week falls back to the base allowance.
-- - Deleting a week with no override row is a silent no-op (the
--   client removes up to 4 weeks at once and must not fail on a
--   week that was never overridden). The audit row is written only
--   when a row was actually deleted.
-- - Admin-only, Sunday week_start only, SECURITY DEFINER — the
--   same guards as set_weekly_allowance_override.
--
-- WHAT CHANGES: one new RPC, no changes to any existing table,
-- column, or function.

create or replace function public.remove_weekly_allowance_override(p_household_id uuid, p_week_start date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  -- Week_start must be a Sunday (same rule as the set path:
  -- compute-week and week-close look overrides up by exact Sunday).
  if p_week_start is null or extract(dow from p_week_start) <> 0 then
    raise exception 'week_start must be a Sunday';
  end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  delete from weekly_allowance_overrides
    where household_id = p_household_id and week_start = p_week_start;
  get diagnostics v_deleted = row_count;
  if v_deleted > 0 then
    insert into audit_log (household_id, actor, actor_name, action, detail)
      values (p_household_id, auth.uid(), 'admin', 'Weekly allowance override removed',
              'Weekly allowance override removed for week ' || p_week_start::text || '. The base allowance applies again.');
  end if;
end;
$$;
revoke execute on function public.remove_weekly_allowance_override(uuid, date) from public;
grant execute on function public.remove_weekly_allowance_override(uuid, date) to authenticated;
