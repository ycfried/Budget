-- Household Budget — insert policies (run AFTER schema.sql).
-- schema.sql deliberately shipped select-only policies. Without insert
-- policies, the live app cannot create anything (RLS blocks every write).
-- These policies are the minimal safe set for a 2-user private household:
--   * Household creation is NOT granted to the client at all: a client
--     that could insert its own admin membership could also make itself
--     admin of someone else's household. Creation goes through the
--     bootstrap-household Edge Function (service role), which verifies
--     the caller has no membership yet, then creates the household and
--     the creator's admin membership server-side.
--   * Any signed-in user may join a household as MEMBER by inserting a
--     membership row for themselves only (user_id = auth.uid()).
--     The household ID acts as the join secret — share it only with the
--     spouse — and the owner should disable new Auth sign-ups once both
--     accounts exist, so a stranger cannot even get an account to try.
--   * Members may insert transactions for their own household only.
--   * Members may insert fund requests for themselves only.
--   * Members may insert audit rows for their own household only.
-- Admin-only writes (allocations, settings, savings attestation) are NOT
-- granted here — those go through Edge Functions with explicit role
-- checks in a later slice, and are never faked from the client.

create policy "users join as member for themselves"
  on household_members for insert
  with check (user_id = auth.uid() and role = 'member');

create policy "members insert own transactions"
  on transactions for insert
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));

create policy "members insert own fund requests"
  on fund_requests for insert
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid())
              and requested_by = auth.uid());

create policy "members insert own audit rows"
  on audit_log for insert
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));
