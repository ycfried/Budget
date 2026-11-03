-- Stage 1 A1: restore intended read access for the refund-review lists.
--
-- WHY: live reads of restoration_entries and held_refunds fail with
-- 403 / Postgres 42501 (permission denied, SELECT-grant hint), even
-- though supabase/restoration-snapshots.sql defines exactly these
-- grants + policies — evidently that section never landed live.
--
-- WHAT THIS DOES (read access only, no writes):
--   * enables RLS on both tables (already intended by the repo file),
--   * recreates the repo's member-of-household SELECT policies
--     (same names, same definitions as restoration-snapshots.sql),
--   * grants SELECT on both tables to authenticated.
--
-- WHAT IT DOES NOT DO: no INSERT/UPDATE/DELETE grants or policies
-- (writes stay with the admin-only SECURITY DEFINER RPC
-- resolve_held_refund); no change to week_closes or any other table.
--
-- week_snapshots is deliberately NOT touched here: no repo file
-- defines it and the app never reads it — inspect live first before
-- granting anything on it.
--
-- Apply via the Supabase SQL editor. Idempotent: re-running replaces
-- the two policies with identical definitions.

begin;

alter table restoration_entries enable row level security;
alter table held_refunds enable row level security;

drop policy if exists "members read own restoration entries" on restoration_entries;
create policy "members read own restoration entries"
  on restoration_entries for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));

drop policy if exists "members read own held refunds" on held_refunds;
create policy "members read own held refunds"
  on held_refunds for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));

grant select on restoration_entries to authenticated;
grant select on held_refunds to authenticated;

commit;
