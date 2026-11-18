-- P2-B3 — revoke EXECUTE on dead-but-granted RPCs (Nov 8, 2026, R3).
-- APPLIED LIVE Nov 9, 2026, step 10 (R4 §2; R4-BE-2, Nov 9, 2026 —
-- the "NOT APPLIED" header this file carried before is stale).
-- Verified: applied after its STEP 0 privilege probe. Do NOT
-- re-apply blindly: re-apply only if a live probe shows a grant
-- has drifted from this file, and reconcile first.
--
-- PROBLEM (first audit P2-B3): four RPCs are granted EXECUTE to
-- authenticated although nothing calls them. A granted-but-dead RPC
-- is live attack surface for no benefit: any signed-in member could
-- invoke it directly. Revoking the grant removes the call path
-- without deleting the functions — they stay in the repo and can
-- be re-granted if a caller ever returns.
--
-- EVIDENCE OF DEADNESS (repo-wide grep, Nov 8, 2026 — live.js,
-- supabase/functions/, test/, integrations/; only each function's
-- own definition + grant + doc mentions remain):
--   * add_temp_increase(uuid, date, integer, text) — live.js
--     never calls it (test/send-live-bundle.test.mjs asserts the
--     call is absent); the Temporary Increase box now writes via
--     set_weekly_allowance_override instead (live.js:4162 comment:
--     "never add_temp_increase"). No Edge Function calls it.
--   * attest_savings(uuid, integer, text) — no call site anywhere.
--     The savings page only READS savings_ledger (live.js:1215);
--     no write path calls this RPC.
--   * record_savings_entry(uuid, text, integer, text) — no call
--     site anywhere, same as attest_savings.
--   * approve_fund_request(uuid) — no call site anywhere. The
--     approval UI calls approve_and_allocate directly (live.js);
--     this legacy delegating wrapper is unreferenced.
--   * NOT revoked here: rotate_household_ingest_secret has no live
--     call site either, but it is the DOCUMENTED manual rotation
--     path (INGEST_CONTRACT.md, ingest-secrets.sql) — revoking it
--     would remove the only way to rotate the ingest secret.
--     That is an owner decision, not a cleanup. Likewise
--     _caller_display_name is a helper called by the household
--     RPCs, not a dead function.
--
-- CAVEAT: an old cached copy of the app shell on a phone could
-- still call add_temp_increase / approve_fund_request the way the
-- pre-Nov-4 UI did. After this revoke, such a call fails with a
-- permission error instead of writing. That is acceptable — pins
-- move forward and a reload fetches the current shell — but if a
-- user reports a sudden "permission denied" on an old cached page,
-- this revoke is the first thing to check.
--
-- STEP 0 — VERIFY LIVE FIRST (read-only; expect all four to exist
-- with EXECUTE granted to authenticated, and no other grantee
-- holding a live caller):
--   select p.proname, r.grantee from pg_proc p
--     join information_schema.routine_privileges r
--       on r.routine_name = p.proname
--    where p.proname in ('add_temp_increase', 'attest_savings',
--     'record_savings_entry', 'approve_fund_request')
--      and r.privilege_type = 'EXECUTE';
--
-- STEP 1 — Apply this file in the SQL editor, in order. Revoking a
-- grant that is already gone is a no-op; re-running is safe.

revoke execute on function public.add_temp_increase(uuid, date, integer, text) from authenticated;
revoke execute on function public.add_temp_increase(uuid, date, integer, text) from anon;
revoke execute on function public.add_temp_increase(uuid, date, integer, text) from public;

revoke execute on function public.attest_savings(uuid, integer, text) from authenticated;
revoke execute on function public.attest_savings(uuid, integer, text) from anon;
revoke execute on function public.attest_savings(uuid, integer, text) from public;

revoke execute on function public.record_savings_entry(uuid, text, integer, text) from authenticated;
revoke execute on function public.record_savings_entry(uuid, text, integer, text) from anon;
revoke execute on function public.record_savings_entry(uuid, text, integer, text) from public;

revoke execute on function public.approve_fund_request(uuid) from authenticated;
revoke execute on function public.approve_fund_request(uuid) from anon;
revoke execute on function public.approve_fund_request(uuid) from public;

-- VERIFICATION (run after applying, read-only — expect 0 rows):
--   select p.proname, r.grantee from pg_proc p
--     join information_schema.routine_privileges r
--       on r.routine_name = p.proname
--    where p.proname in ('add_temp_increase', 'attest_savings',
--     'record_savings_entry', 'approve_fund_request')
--      and r.grantee in ('authenticated', 'anon', 'public')
--      and r.privilege_type = 'EXECUTE';
