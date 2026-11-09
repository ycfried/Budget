-- merged-audit-kind-constraint.sql — Merged audit A1
-- SUPERSEDED — DO NOT APPLY (P1-B5, Nov 8, 2026). This file's
-- 7-kind list (no 'income') would REGRESS live, which already runs
-- the 8-kind list including 'income' (applied Nov 5, 2026 — the
-- $7,000 MOBILE CHECK DEPOSIT row holds kind='income' and the
-- apply would fail on it, or drop it from the allowed list).
-- THE CANONICAL KIND CONSTRAINT IS
-- supabase/refund-classification-income-kind.sql (8 kinds:
-- charge, refund, fund_charge, payment, cashback, charity,
-- transfer, income). No other file's kind list may be applied.
-- This file stays as the Nov 4 record of the transfer fix only.
--
-- WHY: live Transfer reclassification fails with "invalid kind"
-- (Fresh audit finding 1, reproduced twice live). The repo SQL
-- files each drop and re-add an absolute kind list, and the two
-- lists are mutually exclusive: transfer-kind.sql allows transfer
-- but not charity; r13-charity.sql allows charity but not transfer.
-- Whichever was applied last breaks the other.
--
-- LIVE PROBE (Nov 4, 2026, 10:12–10:18 PM, read-only, nothing
-- changed live): the live constraint is named
-- transactions_kind_check and allows exactly six kinds:
--   charge, refund, fund_charge, payment, cashback, charity.
-- Transfer is MISSING live — that is the confirmed cause of the
-- Transfer reclassification failure. The merged list below is
-- those six PLUS transfer (seven total), not a different list.
--
-- SAFE TO APPLY: dropping and re-adding a CHECK constraint changes
-- no rows. It only fails if a row already holds a kind outside the
-- new list; the live probe shows all live kinds are within the six,
-- so the seven-kind list cannot fail on live data.
alter table transactions drop constraint if exists transactions_kind_check;
alter table transactions
  add constraint transactions_kind_check
  check (kind in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer'));

-- Verification (run after apply, read-only):
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--     where conrelid = 'transactions'::regclass and conname = 'transactions_kind_check';
-- Expected: check (kind in ('charge','refund','fund_charge','payment',
--   'cashback','charity','transfer')).
-- Then retest on a SYNTHETIC household only: reclassify one row to
-- each of the seven kinds (via the UI Other action) and confirm
-- each saves and week math treats transfer/payment/cashback as $0.
