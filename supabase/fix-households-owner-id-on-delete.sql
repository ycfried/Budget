-- Fix: households.owner_id blocks account deletion (Nov 24, 2026).
--
-- The delete-account Edge Function deletes the caller's auth user
-- FIRST (design decision, Nov 5 — so a failure leaves the account
-- intact). But households.owner_id referenced auth.users(id) with
-- NO on-delete action, so the auth delete was refused whenever the
-- caller owned a household:
--   "update or delete on table users violates foreign key constraint
--    households_owner_id_fkey on table households".
-- The Nov 8 FK migration (delete-account-fk-migration.sql) re-pointed
-- the user-referencing HISTORY columns to ON DELETE SET NULL but
-- missed households.owner_id. This file fixes that one FK.
--
-- APPLIED LIVE Nov 24, 2026 (verified: households_owner_id_fkey is
-- now ON DELETE SET NULL; the Auth Admin delete of a household
-- owner then returned 200 and the household's owner_id became NULL).
-- The Edge Function then deletes the emptied household itself, so
-- the NULL owner_id is only ever transient.
--
-- NOTE: other user-referencing columns still have NO on-delete action
-- and could block an auth delete if the caller created such rows:
-- fund_topups.confirmed_by, debt_payments.created_by,
-- merchant_rules.created_by, charity_cash_gifts.created_by,
-- debt_adjustments.created_by, weekly_budget_topups.created_by.
-- If account deletion ever fails for a user with those rows, apply
-- the same ON DELETE SET NULL treatment to the blocking FK.
ALTER TABLE households DROP CONSTRAINT households_owner_id_fkey;
ALTER TABLE households ADD CONSTRAINT households_owner_id_fkey
  FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE SET NULL;
