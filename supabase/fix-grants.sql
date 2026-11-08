-- Household Budget — table grants for the authenticated role.
-- WHY (Nov 1, 2026, evening — real failure, third one today):
-- The spouse's join failed with exactly: "permission denied for table
-- household_members". That is NOT a row-level-security error (an RLS
-- rejection says "new row violates row-level security policy").
-- "Permission denied for table" means the table-level GRANT is missing:
-- RLS policies decide WHICH rows a user may touch, but the GRANT
-- decides whether the user's role may touch the table AT ALL.
-- Tables created through the SQL editor do not automatically get
-- grants to the authenticated role, and schema.sql never issued any
-- — so even with correct RLS policies, every client read/write was
-- refused at the table door. This also explains the owner's stuck
-- household screen: the membership SELECT was refused the same way.
-- (Household creation worked anyway because create_household() is a
-- SECURITY DEFINER function that runs as the database owner.)
-- Grants below are the minimal set for the live slice, and nothing
-- more: SELECT where the app reads, INSERT where the app writes.
-- No UPDATE and no DELETE are granted to authenticated users —
-- allocations, settings, and savings writes stay behind Edge
-- Functions, and the audit log stays append-only.

grant select on households to authenticated;
grant select, insert on household_members to authenticated;
grant select, insert on transactions to authenticated;
grant select, insert on fund_requests to authenticated;
grant select on savings_ledger to authenticated;
grant select, insert on audit_log to authenticated;
-- DO NOT RE-GRANT member SELECT on plaid_items (P1-B9, Nov 8, 2026):
-- it was revoked by 03-plaid-vault.sql (the vault's ciphertext column
-- must never be client-readable). The line below is commented out
-- deliberately — applying this file must not restore the grant.
-- grant select on plaid_items to authenticated;
