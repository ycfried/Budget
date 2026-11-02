-- Household Budget — plaid_items grants fix (Nov 1, 2026, evening).
-- WHY: the reconnect with the fixed exchange finally surfaced the real
-- error: "permission denied for table plaid_items". The original
-- fix-grants.sql granted only SELECT on plaid_items, and the
-- plaid-token-column migration added an INSERT POLICY but no INSERT
-- grant — and a policy without a grant is still a locked door (the
-- same lesson as the household_members join failure earlier today).
-- Upsert also needs UPDATE for the on-conflict path (a reconnect with
-- the same item id), so this grants INSERT + UPDATE and adds the
-- matching update policy, both restricted to the caller's own
-- household. SELECT was already granted. No DELETE, ever.

grant insert, update on plaid_items to authenticated;

create policy "members update own plaid items"
  on plaid_items for update
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()))
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));
