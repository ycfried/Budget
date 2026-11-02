-- Household Budget — transactions upsert fix (Nov 1, 2026, evening).
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
