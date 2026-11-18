-- Household Budget — transactions upsert fix (Nov 1, 2026, evening).
--
-- DO NOT RE-APPLY THIS FILE (P1-B9, Nov 8, 2026). The UPDATE grant
-- + "members update own transactions" policy below let ANY household
-- member rewrite ANY transaction row directly (kind, amount, state),
-- bypassing the admin-only mutation RPCs. No live path needs it:
-- the client only INSERTs transactions (CSV import, manual add) and
-- every Edge Function writes through the service-role client, which
-- bypasses RLS. If the live probe finds the grant, revoke it with
-- supabase/revoke-member-transaction-update.sql (owner approval)
-- and retest CSV import + manual add + plaid-sync afterwards.
-- WHY: the first real Plaid sync reported "0 added, 0 updated, 121
-- skipped across 1 connected item" — Plaid returned 121 transactions
-- but every single upsert failed. The pattern matches the plaid_items
-- failure earlier tonight: PostgREST upsert (onConflict) needs an
-- UPDATE policy as well as an INSERT policy, and transactions had
-- no update policy at all, so every upsert was refused by RLS even
-- though the rows were new. This adds the missing update policy
-- (household members only, household unchanged) and the UPDATE grant.
-- No DELETE. Upsert still cannot move a row between households: the
-- with-check requires the same household membership.

grant update on transactions to authenticated;

create policy "members update own transactions"
  on transactions for update
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()))
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));
