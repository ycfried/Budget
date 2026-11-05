-- feedback-allowance-set.sql — Feedback bundle item 6
-- PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS BRANCH.
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run after the owner has seen this exact file.
--
-- WHY: households are created with base_allowance_cents default
-- 37500 ($375) in schema.sql, so the client cannot tell "the admin
-- never set an allowance" apart from "the admin set it to $375"
-- from that column alone. A new sign-up therefore showed $375 as
-- if it had been chosen. The owner rule (Nov 4, 2026) is: a new
-- sign-up must NOT show a weekly allowance figure before one is
-- set — it must show a "Set Your Weekly Allowance" button instead.
--
-- WHAT THIS DOES:
-- 1. Adds a nullable households.allowance_set_at column.
-- 2. Backfills EXISTING households (including the real household)
--    with allowance_set_at = created_at, so they keep showing their
--    current figure — this migration must NOT blank the real
--    household's allowance. Only households created AFTER this
--    migration get allowance_set_at = NULL until an admin sets
--    an allowance.
-- 3. Adds a trigger: whenever base_allowance_cents changes on a
--    household row, allowance_set_at is stamped to now(). This
--    covers every allowance-setting path (set_base_allowance RPC,
--    Settings save, any future path) without replacing any RPC.
--
-- CLIENT BEHAVIOUR (already in this branch, live.js): refresh()
-- reads allowance_set_at when the column exists. If it is null,
-- the hero big figure and the Weekly allowance stat are hidden
-- and the "Set Your Weekly Allowance" button shows (admin only);
-- members see no figure and no button. If the column does not
-- exist yet (this file not applied), the client falls back to
-- the old behaviour and shows the figure — applying this file is
-- what turns the new behaviour on for new households.
--
-- SAFE TO APPLY: adding a nullable column and a trigger changes
-- no existing figures and no rows except the backfill stamp.
-- The trigger fires only on base_allowance_cents changes.
alter table households
  add column if not exists allowance_set_at timestamptz;

update households
  set allowance_set_at = created_at
  where allowance_set_at is null;

create or replace function public.stamp_allowance_set_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW.base_allowance_cents is distinct from OLD.base_allowance_cents then
    NEW.allowance_set_at := now();
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_stamp_allowance_set_at on households;
create trigger trg_stamp_allowance_set_at
  before update on households
  for each row execute function public.stamp_allowance_set_at();

-- Verification (read-only):
--   select column_name from information_schema.columns
--     where table_name = 'households' and column_name = 'allowance_set_at';
--   select id, base_allowance_cents, allowance_set_at from households;
-- Expected: the column exists; existing households have a stamp;
-- a household created after this apply has allowance_set_at NULL
-- until its admin sets an allowance, at which point the trigger
-- stamps it. Retest on a SYNTHETIC household only: new sign-up
-- shows "Set Your Weekly Allowance" (no $375 figure), then after
-- the admin sets an allowance the hero shows the figure.
