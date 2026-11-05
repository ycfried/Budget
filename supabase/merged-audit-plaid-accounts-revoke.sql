-- merged-audit-plaid-accounts-revoke.sql — Merged audit A16
-- PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS BRANCH.
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run after the owner has seen this exact file.
--
-- WHY: live grants (probe Nov 4, 2026, 10:12–10:18 PM) give
-- authenticated members SELECT+INSERT+UPDATE on plaid_accounts,
-- with member INSERT and UPDATE policies. A member can therefore
-- write connection display rows directly, outside any server flow.
-- The server sync path does not need member grants: plaid-sync
-- upserts plaid_accounts through its service-role client, and
-- plaid-disconnect does not write plaid_accounts rows.
--
-- WHAT THIS DOES: revokes member INSERT/UPDATE on plaid_accounts
-- and drops the two member write policies. Member SELECT stays
-- (the app still shows connected accounts), and no DELETE grant or
-- policy is ever created.
--
-- RETEST AFTER APPLY (synthetic household): run a bank sync and a
-- disconnect/reconnect; both must still work, because they run
-- server-side, not through member grants.
revoke insert, update on plaid_accounts from authenticated;
drop policy if exists "members insert own plaid accounts" on plaid_accounts;
drop policy if exists "members update own plaid accounts" on plaid_accounts;

-- Verification (read-only):
--   select grantee, privilege_type from information_schema.role_table_grants
--     where table_name = 'plaid_accounts' and grantee = 'authenticated';
-- Expected: SELECT only (no INSERT, no UPDATE, no DELETE).
