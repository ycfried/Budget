-- merged-audit-kind-constraint.sql — Merged audit A1
-- PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS BRANCH.
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run after the owner has seen this exact file.
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
