// Manual debt adjustment tests (Add / Set Carried Debt, build 41)
// — run with:
//   node --test supabase/tests/debt-adjustments.test.mjs
// debtAdjustmentsAfterClose from supabase/functions/_shared/engine.mjs
// (synced verbatim to compute-week/engine.mjs and
// week-close/engine.mjs). It mirrors the SQL in
// supabase/add-set-debt.sql (debt_balance_cents) exactly: the same
// after-the-close window as debtPaymentsAfterClose, but every
// adjustment counts (no source filter) and the amount is a SIGNED
// delta (+ = added, − = a Set below the current balance). The SQL
// itself cannot run without a live database; the live behaviour is
// verified by the deploy steps (test household only).

import test from 'node:test';
import assert from 'node:assert/strict';
import { debtAdjustmentsAfterClose } from '../functions/_shared/engine.mjs';

// Weeks: close at 2026-11-01, requested week 2026-11-15.
const CLOSE = '2026-11-01';
const WEEK = '2026-11-15';
const rows = [
  { week_start: '2026-11-01', amount_cents: 99999 }, // on the close week: excluded
  { week_start: '2026-11-08', amount_cents: 50000 }, // add $500
  { week_start: '2026-11-15', amount_cents: -20000 }, // set down $200, in the requested week: included
  { week_start: '2026-11-22', amount_cents: 77777 }, // after the requested week: excluded
];

test('only adjustments after the close and up to the requested week count', () => {
  assert.equal(debtAdjustmentsAfterClose(rows, CLOSE, WEEK), 30000);
});

test('a row dated exactly on the close week is excluded; one on the requested week is included', () => {
  assert.equal(
    debtAdjustmentsAfterClose([{ week_start: CLOSE, amount_cents: 100 }], CLOSE, WEEK),
    0,
  );
  assert.equal(
    debtAdjustmentsAfterClose([{ week_start: WEEK, amount_cents: 100 }], CLOSE, WEEK),
    100,
  );
});

test('signed deltas compose: a Set below the balance is a negative adjustment', () => {
  assert.equal(
    debtAdjustmentsAfterClose([
      { week_start: '2026-11-08', amount_cents: 100000 },
      { week_start: '2026-11-08', amount_cents: -40000 },
    ], CLOSE, WEEK),
    60000,
  );
});

test('no close yet: every adjustment up to the requested week counts', () => {
  assert.equal(
    debtAdjustmentsAfterClose(rows, null, WEEK),
    99999 + 50000 - 20000,
  );
});

test('no requested week: every adjustment after the close counts', () => {
  assert.equal(
    debtAdjustmentsAfterClose(rows, CLOSE, null),
    50000 - 20000 + 77777,
  );
});

test('empty or missing rows sum to zero', () => {
  assert.equal(debtAdjustmentsAfterClose([], CLOSE, WEEK), 0);
  assert.equal(debtAdjustmentsAfterClose(null, CLOSE, WEEK), 0);
  assert.equal(debtAdjustmentsAfterClose(undefined, null, null), 0);
});

test('D formula mirrors the SQL: outgoing − cuts − payments + adjustments, floored at 0', () => {
  // Close outgoing $1,000; one $500 add and one $200 set-down after
  // the close; no cuts, no payments.
  const outgoing = 100000;
  const adjustments = debtAdjustmentsAfterClose(rows, CLOSE, WEEK);
  assert.equal(Math.max(0, outgoing - 0 - 0 + adjustments), 130000);
  // A set-down larger than the balance floors at zero, like the SQL's greatest(0, ...).
  const overSet = debtAdjustmentsAfterClose(
    [{ week_start: '2026-11-08', amount_cents: -150000 }], CLOSE, WEEK,
  );
  assert.equal(Math.max(0, outgoing + overSet), 0);
});
