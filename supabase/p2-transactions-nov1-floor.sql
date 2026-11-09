-- P2-C8 — DB CHECK: transactions start Nov 1, 2026 (Nov 8, 2026, R3).
-- APPLIED LIVE Nov 9, 2026, step 9 (R4 §2; R4-BE-2, Nov 9, 2026 —
-- the "NOT APPLIED" header this file carried before is stale).
-- Verified: STEP 0 pre-check count(*) where date < '2026-11-01' = 0.
-- Do NOT re-apply blindly: re-apply only if a live probe shows the
-- CHECK has drifted from this file, and reconcile first.
--
-- PROBLEM: the Nov 1 floor lived only in the client and the Edge
-- Functions (manual form blocks pre-Nov dates, CSV import skips
-- pre-Nov rows, plaid-sync deletes pre-Nov Plaid rows, compute-week
-- and week-close filter to date >= '2026-11-01', the list loads
-- with .gte('date', '2026-11-01')). A pre-Nov row written by any
-- other path would sit in the list and "Total shown" while being
-- excluded from math. This CHECK makes the floor structural.
--
-- WHY A CHECK IS SAFE HERE (repo evidence, checked Nov 8, 2026):
--   * No legitimate pre-Nov transaction can exist under the repo's
--     own rules: app data starts Nov 1, 2026; every ingestion path
--     enforces the floor (see above); charity income/gifts also
--     block pre-Nov dates. The test fixtures that mention October
--     dates (test/engine.test.mjs) are pure-JS engine tests — they
--     never insert a database row, so the CHECK cannot affect them.
--   * The backfill files (transfer-backfill.sql,
--     payment-backfill.sql) are 100% commented investigation
--     queries — they execute nothing, so the CHECK cannot break
--     them. Any FUTURE owner-approved backfill that genuinely
--     needs a pre-Nov row must drop this CHECK first, as a
--     separate owner decision — that is the point of the guard.
--
-- STEP 0 — VERIFY LIVE FIRST (read-only; expect 0 — if it is not 0,
-- STOP and reconcile before applying):
--   select count(*) from transactions where date < '2026-11-01';
--   -- NOTE: R3 §7 records an unreconciled count gap (45 rows in
--   -- the Nov 8 list vs 54 in the Nov 7 DB probe) and notes the Nov
--   -- 1 list floor may be hiding pre-Nov rows in the DB. If this
--   -- count is > 0, those rows are exactly the gap: the owner must
--   -- decide whether to delete them (they are invisible in the app
--   -- and excluded from math) before this CHECK can be added.
--   -- A second consequence of the same check: Postgres validates a
--   -- CHECK on UPDATE as well as INSERT, so while any pre-Nov row
--   -- exists, even a kind-only UPDATE to that row would fail.
--   -- The pre-check above is therefore mandatory, not advisory.
--
-- STEP 1 — Apply this file in the SQL editor. Idempotent
-- (IF NOT EXISTS guard); re-running is a no-op.

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'transactions_date_nov1_floor'
  ) then
    alter table transactions
      add constraint transactions_date_nov1_floor
      check (date >= date '2026-11-01');
  end if;
end;
$$;

-- VERIFICATION (run after applying, read-only):
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--    where conname = 'transactions_date_nov1_floor';
--     -- expect 1 row: check (date >= '2026-11-01'::date)
