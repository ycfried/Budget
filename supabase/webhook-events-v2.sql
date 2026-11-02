-- Household Budget — webhook events, part 2 (Nov 1, 2026).
-- Lets plaid-sync mark a household's webhook events processed after a
-- successful sync, so the live app's auto-sync does not re-run on every
-- refresh. Members may update only their own household's items' events
-- (via plaid_items); no other update, and no delete, is granted.
grant update on webhook_events to authenticated;

create policy "members update own webhook events"
  on webhook_events for update
  using (plaid_item_id in (select plaid_item_id from plaid_items
                           where household_id in (select household_id from household_members
                                                  where user_id = auth.uid())))
  with check (plaid_item_id in (select plaid_item_id from plaid_items
                                where household_id in (select household_id from household_members
                                                       where user_id = auth.uid())));
