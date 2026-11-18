// Math fixes N1 + N2 (Nov 5, 2026, owner-approved, Option A each).
// Run with: node --test test/math-fixes-n1-n2.test.mjs
// All amounts are integer cents. $1 = 100.
// Sources: MATH_DECISIONS_N1_N2.md (worked examples re-run through the
// actual engine, not hand-computed) and DEEP_AUDIT_2026-11-05.md (N1, N2).
//
// N1 Option A — fund-first, counted once: a linked refund nets only
// its NORMAL portion against the week's charges; the fund portion is
// credited by refund restoration, never by the walk. A $50 refund on
// a $100 purchase ($60 fund / $40 normal) must give exactly $50 of
// total benefit, not $90.
// N2 Option A — adopt compute-week's definition of incoming debt:
// subtract only debt cuts posted after the prior close's week and up
// to the purchase week. The second $100 refund in the brief's example
// must post $0 surplus + $100 debt cut, not $75 surplus + $25 cut.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  computeWeek,
  linkedRefundNormalPortionCents,
  restorationDebtCutsAfterClose,
} from '../engine.mjs';
import {
  computeRestorationTotal,
  computeIncrementalRestoration,
} from '../restoration.mjs';

const B = 37500; // $375 base allowance

// --- N1: the shared split helper ----------------------------------------

test('N1: $50 refund on $100 split purchase ($60 fund / $40 normal) nets $0 in the walk', () => {
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 5000), 0);
});

test('N1: $70 refund on the same split purchase nets $10 (fund repaid first)', () => {
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 7000), 1000);
});

test('N1: fully-normal purchase nets the full refund; fully-fund nets $0', () => {
  assert.equal(linkedRefundNormalPortionCents(10000, 0, 5000), 5000);
  assert.equal(linkedRefundNormalPortionCents(10000, 10000, 5000), 0);
});

test('N1: refund beyond the purchase is capped at the normal portion (excess is held, never netted)', () => {
  // $120 refund on $100 purchase ($60 fund): fund 60 + normal 40 = $100
  // refundable; the $20 excess is held by restoration, not netted here.
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 12000), 4000);
  assert.equal(linkedRefundNormalPortionCents(10000, 0, 12000), 10000);
});

test('N1: partial refunds $30 + $30 are order-independent (cumulative split)', () => {
  // Cumulative $30 -> fund 30, normal 0. Cumulative $60 -> fund 60,
  // normal 0. A single $60 refund gives the same split.
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 3000), 0);
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 6000), 0);
  // And with a larger second refund the increment is the same either way.
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 9000), 3000);
});

// --- N1: end to end — total benefit exactly equals the refund -----------

test('N1: split purchase $100 ($60 fund / $40 normal) refunded $50 while open: benefit exactly $50', () => {
  // Walk: charges as booked are the $40 normal portion; the walk nets
  // the normal portion of the refund ($0), so charges stay $40 and
  // surplus stays $335. Restoration credits the fund $50.
  const walkCharges = 4000 - linkedRefundNormalPortionCents(10000, 6000, 5000);
  assert.equal(walkCharges, 4000);
  assert.equal(computeWeek({ B, C: walkCharges }).earnedSurplus, 33500);
  const total = computeRestorationTotal({
    weeks: [
      { week_start: '2026-11-01', B, T: 0, charges_cents: 4000 },
      { week_start: '2026-11-08', B, T: 0, charges_cents: 0 },
    ],
    purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    fundAllocationCents: 6000, totalRefundedCents: 5000,
  });
  assert.equal(total.fundCreditCents, 5000);
  assert.equal(total.restoredSurplusCents, 0);
  assert.equal(total.debtReductionCents, 0);
  assert.equal(total.heldCents, 0);
  // Total benefit = walk surplus gain ($0) + fund credit ($50) = $50.
  assert.equal(0 + total.fundCreditCents, 5000);
});

test('N1: split purchase refunded $30 then $30: fund +$60, surplus unchanged, never double-counted', () => {
  const weeks = [{ week_start: '2026-11-01', B, T: 0, charges_cents: 4000 }];
  const args = (n) => ({
    weeks, purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    fundAllocationCents: 6000, totalRefundedCents: n,
  });
  const first = computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(0)),
    newTotal: computeRestorationTotal(args(3000)), newRefundCents: 3000,
  });
  const second = computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(3000)),
    newTotal: computeRestorationTotal(args(6000)), newRefundCents: 3000,
  });
  assert.equal(first.fundCreditCents, 3000);
  assert.equal(first.restoredSurplusCents, 0);
  assert.equal(second.fundCreditCents, 3000);
  assert.equal(second.restoredSurplusCents, 0);
  assert.equal(first.fundCreditCents + second.fundCreditCents, 6000);
});

test('N1: $120 refund on the split purchase: $100 restores, $20 held, held restores nothing', () => {
  const total = computeRestorationTotal({
    weeks: [{ week_start: '2026-11-01', B, T: 0, charges_cents: 4000 }],
    purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    fundAllocationCents: 6000, totalRefundedCents: 12000,
  });
  assert.equal(total.heldCents, 2000);
  assert.equal(total.refundableCents, 10000);
  assert.equal(total.fundCreditCents, 6000);
  assert.equal(total.restoredSurplusCents, 4000);
  // Walk nets the normal portion ($40) and restoration posts fund
  // $60 + surplus $40: total benefit $100 = the refundable part.
  assert.equal(linkedRefundNormalPortionCents(10000, 6000, 12000), 4000);
});

test('N1: fully-fund and fully-normal purchases unchanged by the fix', () => {
  // Fully fund: walk nets $0, restoration credits the fund $50.
  assert.equal(linkedRefundNormalPortionCents(10000, 10000, 5000), 0);
  const fundOnly = computeRestorationTotal({
    weeks: [{ week_start: '2026-11-01', B, T: 0, charges_cents: 0 }],
    purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    fundAllocationCents: 10000, totalRefundedCents: 5000,
  });
  assert.equal(fundOnly.fundCreditCents, 5000);
  assert.equal(fundOnly.restoredSurplusCents, 0);
  // Fully normal: walk nets $50, restoration credits the fund $0.
  assert.equal(linkedRefundNormalPortionCents(10000, 0, 5000), 5000);
  const normalOnly = computeRestorationTotal({
    weeks: [{ week_start: '2026-11-01', B, T: 0, charges_cents: 10000 }],
    purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    totalRefundedCents: 5000,
  });
  assert.equal(normalOnly.fundCreditCents, 0);
  assert.equal(normalOnly.restoredSurplusCents, 5000);
});

// --- N2: the shared debt-cut window --------------------------------------

test('N2: cuts after the prior close and up to the purchase week count; others do not', () => {
  const entries = [
    { week_start: '2026-10-25', debt_reduction_cents: 5000 }, // before the close: already inside it
    { week_start: '2026-11-08', debt_reduction_cents: 10000 }, // in the purchase week: counts
    { week_start: '2026-12-06', debt_reduction_cents: 7000 }, // after the purchase week: later weeks only
  ];
  // Prior close week 2026-11-01, purchase week 2026-11-08.
  assert.equal(restorationDebtCutsAfterClose(entries, '2026-11-01', '2026-11-08'), 10000);
  // No prior close: caller floors debt at 0 anyway; the helper returns 0
  // for the pre-close entries only when a close bounds the window.
  assert.equal(restorationDebtCutsAfterClose(entries, null, '2026-11-08'), 15000);
});

test('N2: brief example — first refund cut (Dec 6) does not reduce debt entering W2 (Nov 8)', () => {
  const entries = [
    { week_start: '2026-12-06', debt_reduction_cents: 10000 }, // X's $100 cut, posted Dec 6
  ];
  // Prior close is W1 (2026-11-01, outgoing debt $100); purchase week W2 (2026-11-08).
  assert.equal(restorationDebtCutsAfterClose(entries, '2026-11-01', '2026-11-08'), 0);
  // The old window (every cut before today) would have returned $100.
  const oldWindow = entries
    .filter((r) => r.week_start < '2026-12-20')
    .reduce((s, r) => s + r.debt_reduction_cents, 0);
  assert.equal(oldWindow, 10000);
});

// --- N2: end to end — second refund posts $0 surplus + $100 debt cut ----

test('N2: two refunds on two purchases in consecutive weeks — second refund is $0 surplus + $100 debt cut', () => {
  // Brief worked example: W2 $475 (purchase Y), W3–W5 $375, W6 $300.
  // Debt entering W2 is $100 (W1 close), not $0: X's Dec 6 cut is after W2.
  const weeks = [
    { week_start: '2026-11-08', B, T: 0, charges_cents: 47500 },
    { week_start: '2026-11-15', B, T: 0, charges_cents: 37500 },
    { week_start: '2026-11-22', B, T: 0, charges_cents: 37500 },
    { week_start: '2026-11-29', B, T: 0, charges_cents: 37500 },
    { week_start: '2026-12-13', B, T: 0, charges_cents: 30000 },
  ];
  const initialDebt = Math.max(0, 10000
    - restorationDebtCutsAfterClose(
      [{ week_start: '2026-12-06', debt_reduction_cents: 10000 }],
      '2026-11-01', '2026-11-08',
    ));
  assert.equal(initialDebt, 10000);
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-11-08', purchaseAmountCents: 47500,
    totalRefundedCents: 10000, initialDebtCents: initialDebt,
  });
  assert.equal(total.restoredSurplusCents, 0);
  assert.equal(total.debtReductionCents, 10000);
  assert.equal(total.fundCreditCents, 0);
  // The old starting debt ($0) would have posted the phantom split.
  const wrong = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-11-08', purchaseAmountCents: 47500,
    totalRefundedCents: 10000, initialDebtCents: 0,
  });
  assert.equal(wrong.restoredSurplusCents, 7500);
  assert.equal(wrong.debtReductionCents, 2500);
});

test('N2: a cut posted in the purchase week itself is subtracted (the <= purchaseWeek bound)', () => {
  const entries = [{ week_start: '2026-11-08', debt_reduction_cents: 5000 }];
  assert.equal(restorationDebtCutsAfterClose(entries, '2026-11-01', '2026-11-08'), 5000);
});

// --- Shared-logic guard: the helpers must exist in every engine copy ----

test('N1+N2: both helpers exist, identical, in every engine.mjs copy (root, compute-week, week-close, _shared)', () => {
  const paths = [
    '../engine.mjs',
    '../supabase/functions/compute-week/engine.mjs',
    '../supabase/functions/week-close/engine.mjs',
    '../supabase/functions/_shared/engine.mjs',
  ];
  const blocks = paths.map((p) => {
    const text = readFileSync(new URL(p, import.meta.url), 'utf8');
    assert.ok(text.includes('export function linkedRefundNormalPortionCents'), `${p} must export the N1 helper`);
    assert.ok(text.includes('export function restorationDebtCutsAfterClose'), `${p} must export the N2 helper`);
    const start = text.indexOf('// N1 + N2 shared helpers');
    const end = text.indexOf('export function restorationDebtCutsAfterClose');
    const fnEnd = text.indexOf('\n}\n', end) + '\n}\n'.length;
    return text.slice(start, fnEnd);
  });
  for (const block of blocks.slice(1)) assert.equal(block, blocks[0]);
});
