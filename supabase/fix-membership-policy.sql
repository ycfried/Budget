-- Household Budget — fix the household_members read policy.
-- WHY (Nov 1, 2026, evening — real failure, second one today):
-- After the owner created a household (RPC succeeded, ID returned),
-- the live app stayed stuck on the household screen on reload instead
-- of moving to the dashboard. The app decides that by reading the
-- user's own membership row. That read returned nothing, even though
-- the row exists.
-- Root cause: the original policy was self-referential —
--   household_id IN (SELECT household_id FROM household_members
--                    WHERE user_id = auth.uid())
-- A policy that has to read the same table it protects to decide
-- whether the read is allowed does not resolve the way it looks like
-- it should, and the membership read (and everything that depends on
-- it, including the other tables' policies that check membership the
-- same way) comes back empty.
-- Fix: a membership row is readable exactly when it is the caller's
-- own row. That is direct, non-recursive, and exactly as restrictive:
-- a user still sees only their own membership, never anyone else's.
-- The other tables keep their membership-check policies — those check
-- a DIFFERENT table (household_members) from the one they protect, so
-- they resolve correctly once this policy is fixed.

drop policy if exists "members read own membership" on household_members;

create policy "members read own membership"
  on household_members for select
  using (user_id = auth.uid());
