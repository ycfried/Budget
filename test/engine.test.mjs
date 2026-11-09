// Household Budget engine + restoration tests — run with:
//   node --test test/engine.test.mjs
// All amounts are integer cents. $1 = 100.
// Spec: Household Budget — Revised iOS Spec (v2) FINAL, A2/A3/A4.
// The old refund-credit fixtures were DELETED (not kept passing):
// under FINAL there is no refund-credit model, so those tests are
// failing spec tests, not passing ones. The deferred refund question
// is MOOT and has no test here. Restoration cases below are the
// FINAL A4 acceptance cases, verbatim in amounts.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  computeWeek,
  weekStartOf,
  addDays,
  surplusReleaseDate,
  releaseDateFromCloseDate,
  applyShortfallToRelease,
  reduceFundForLateCharge,
  isWeekLocked,
  isExcludedFromMath,
  isPendingRefund,
  pendingRefundExcludedCents,
  chargeContribution,
} from '../engine.mjs';
import {
  simulateWeeks,
  computeRestorationTotal,
  computeIncrementalRestoration,
  postedRefundTotalCents,
} from '../restoration.mjs';

const B = 37500; // $375 base allowance

// --- A3 worked examples (kept, all still pass under FINAL) ---------------

test('spend $400 week 1 -> debt $25, week 2 available $350', () => {
  const w1 = computeWeek({ B, C: 40000 });
  assert.equal(w1.outgoingDebt, 2500);
  assert.equal(w1.earnedSurplus, 0);
  const w2 = computeWeek({ B, D: w1.outgoingDebt, C: 0 });
  assert.equal(w2.baseAvailable, 35000);
  assert.equal(w2.available, 35000);
});

test('spend $800 week 1 -> week 1 debt $425, week 2 carried debt $50, base available $0, week 3 debt $50 absorbed, surplus $325', () => {
  const w1 = computeWeek({ B, C: 80000 });
  assert.equal(w1.outgoingDebt, 42500);
  const w2 = computeWeek({ B, D: w1.outgoingDebt, C: 0 });
  assert.equal(w2.carriedDebt, 5000);
  assert.equal(w2.baseAvailable, 0);
  assert.equal(w2.outgoingDebt, 5000);
  const w3 = computeWeek({ B, D: w2.outgoingDebt, C: 0 });
  assert.equal(w3.baseAvailable, 32500);
  assert.equal(w3.earnedSurplus, 32500);
  assert.equal(w3.outgoingDebt, 0);
});

test('spend $300 -> surplus $75', () => {
  const w = computeWeek({ B, C: 30000 });
  assert.equal(w.earnedSurplus, 7500);
  assert.equal(w.outgoingDebt, 0);
});

test('$100 temp increment + spend $300 -> surplus $75 only (unused temp earns nothing)', () => {
  const w = computeWeek({ B, T: 10000, C: 30000 });
  assert.equal(w.earnedSurplus, 7500);
  assert.equal(w.coveredTemp, 0);
  // Dashboard available follows the FINAL formula base_available + T - C,
  // which includes unused T even though surplus does not.
  assert.equal(w.available, 17500);
});

test('$100 temp + spend $450 -> no debt, surplus $0, $25 increment unused', () => {
  const w = computeWeek({ B, T: 10000, C: 45000 });
  assert.equal(w.coveredBase, 37500);
  assert.equal(w.coveredTemp, 7500);
  assert.equal(w.outgoingDebt, 0);
  assert.equal(w.earnedSurplus, 0);
  assert.equal(w.available, 2500);
});

test('incoming debt $50 + $100 temp + spend $450 -> new debt $25', () => {
  const w = computeWeek({ B, T: 10000, D: 5000, C: 45000 });
  assert.equal(w.baseAvailable, 32500);
  assert.equal(w.coveredBase, 32500);
  assert.equal(w.coveredTemp, 10000);
  assert.equal(w.newDebt, 2500);
  assert.equal(w.outgoingDebt, 2500);
});

test('legacy credit fields sent by a stale caller are ignored, never computed', () => {
  const plain = computeWeek({ B, T: 10000, D: 5000, C: 45000 });
  const stale = computeWeek({ B, T: 10000, D: 5000, C: 45000, R_in: 99999, X: 99999 });
  assert.deepEqual(stale, plain);
  assert.equal('outgoingCredit' in stale, false);
  assert.equal('coveredCredit' in stale, false);
});

test('$75 released / $60 fund spend / $50 late reduction -> fund $0, shortfall $35', () => {
  const afterSpend = 7500 - 6000; // $15 left in the fund
  const res = reduceFundForLateCharge(afterSpend, 5000);
  assert.equal(res.fundAvailable, 0);
  assert.equal(res.shortfall, 3500);
  // Next release is netted against the shortfall before it becomes spendable.
  const next = applyShortfallToRelease(5000, res.shortfall);
  assert.equal(next.releasedToFund, 1500);
  assert.equal(next.remainingShortfall, 0);
});

test('surplus release: pending 7 days after close, released exactly once (release date = week start + 14 days on time)', () => {
  assert.equal(surplusReleaseDate('2026-10-25'), '2026-11-08');
  const releaseDate = surplusReleaseDate('2026-10-25');
  assert.equal('2026-11-01' < releaseDate, true);
  assert.equal('2026-11-08' >= releaseDate, true);
});

test('P1-6: pending window anchors to the ACTUAL close date (close + 7 days), not the week end', () => {
  // A week starting 2026-09-20 closed late on 2026-11-01 releases 2026-11-08,
  // not on the on-time date (week start + 14 = 2026-10-04, long past).
  assert.equal(releaseDateFromCloseDate('2026-11-01'), '2026-11-08');
  assert.equal(releaseDateFromCloseDate('2026-10-25'), '2026-11-01');
});

test('28-day open window: recent weeks open, old weeks locked; locked adjustments post to current week', () => {
  assert.equal(isWeekLocked('2026-09-20', '2026-11-01'), true);
  assert.equal(isWeekLocked('2026-10-25', '2026-11-01'), false);
});

test('week boundaries: Saturday belongs to the closing week, Sunday starts a new week', () => {
  assert.equal(weekStartOf('2026-10-31'), '2026-10-25'); // Saturday
  assert.equal(weekStartOf('2026-11-01'), '2026-11-01'); // Sunday
  assert.equal(addDays('2026-10-25', 7), '2026-11-01');
});

// --- Transaction counting rules (P0-12, A7) -------------------------------

test('counting rules: provisional refunds excluded, provisional charges count, payment/cashback/reversed/excluded never count', () => {
  const charge = { amount_cents: 4000, kind: 'charge', state: 'verified', excluded: false, fund_allocation_cents: 0 };
  const provCharge = { ...charge, state: 'provisional' };
  const provRefund = { amount_cents: -15000, kind: 'refund', state: 'provisional', excluded: false };
  const postedRefund = { ...provRefund, state: 'verified' };
  const payment = { amount_cents: -50000, kind: 'payment', state: 'verified', excluded: false };
  const cashback = { amount_cents: -2500, kind: 'cashback', state: 'verified', excluded: false };
  const reversed = { ...charge, state: 'reversed' };
  const excluded = { ...charge, excluded: true };
  assert.equal(isExcludedFromMath(provRefund), true);
  assert.equal(isExcludedFromMath(provCharge), false);
  assert.equal(isExcludedFromMath(postedRefund), false);
  assert.equal(isExcludedFromMath(payment), true);
  assert.equal(isExcludedFromMath(cashback), true);
  assert.equal(isExcludedFromMath(reversed), true);
  assert.equal(isExcludedFromMath(excluded), true);
  assert.equal(isPendingRefund(provRefund), true);
  assert.equal(isPendingRefund(postedRefund), false);
  assert.equal(pendingRefundExcludedCents([provRefund, postedRefund, charge]), 15000);
  assert.equal(chargeContribution(charge), 4000);
  assert.equal(chargeContribution({ ...charge, fund_allocation_cents: 1000 }), 3000);
  assert.equal(chargeContribution(provRefund), 0);
  assert.equal(chargeContribution(payment), 0);
});

// --- Restoration helpers --------------------------------------------------

function weeksFromCharges(chargesByWeekStart, extra = {}) {
  // chargesByWeekStart: { 'YYYY-MM-DD': charges_cents } in week order.
  return Object.entries(chargesByWeekStart).map(([week_start, charges_cents]) => ({
    week_start, B, T: extra[week_start]?.T ?? 0, charges_cents,
  }));
}

test('FINAL A4: $475 purchase wk1 + $150 refund wk8, wk2 empty -> $150 surplus, $0 debt cut', () => {
  // Horizon = purchase week through the last COMPLETED week (wk7 here;
  // wk8 is the in-progress current week and is never simulated).
  const weeks = weeksFromCharges({
    '2026-10-04': 47500, '2026-10-11': 0, '2026-10-18': 0, '2026-10-25': 0,
    '2026-11-01': 0, '2026-11-08': 0, '2026-11-15': 0,
  });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: 15000,
  });
  assert.equal(total.restoredSurplusCents, 15000);
  assert.equal(total.debtReductionCents, 0);
  assert.equal(total.heldCents, 0);
});

test('FINAL A4 variant: same purchase, debt still outstanding -> $50 surplus + $100 debt cut', () => {
  // Weeks 2-7 each spend the full $375, so the $100 debt is never
  // absorbed and is still outstanding at the end of the last
  // completed week (wk7). The in-progress wk8 is excluded from the
  // horizon: including an empty wk8 would absorb the debt in the
  // baseline run and change this case to $150 surplus / $0 debt cut.
  const weeks = weeksFromCharges({
    '2026-10-04': 47500, '2026-10-11': 37500, '2026-10-18': 37500, '2026-10-25': 37500,
    '2026-11-01': 37500, '2026-11-08': 37500, '2026-11-15': 37500,
  });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: 15000,
  });
  assert.equal(total.restoredSurplusCents, 5000);
  assert.equal(total.debtReductionCents, 10000);
});

test('FINAL A4: $300 purchase, full $300 refund -> $300 restored', () => {
  const weeks = weeksFromCharges({ '2026-10-04': 30000, '2026-10-11': 0 });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 30000,
    totalRefundedCents: 30000,
  });
  assert.equal(total.restoredSurplusCents, 30000);
  assert.equal(total.debtReductionCents, 0);
});

test('FINAL A4: $475 purchase with $100 temp, $100 refund -> $0 (temp-covered portion restores nothing)', () => {
  const weeks = [
    { week_start: '2026-10-04', B, T: 10000, charges_cents: 47500 },
    { week_start: '2026-10-11', B, T: 0, charges_cents: 0 },
  ];
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: 10000,
  });
  assert.equal(total.restoredSurplusCents, 0);
  assert.equal(total.debtReductionCents, 0);
});

test('FINAL A4: $475 purchase with $100 temp, $150 refund -> $50 (only the amount above temp restores)', () => {
  const weeks = [
    { week_start: '2026-10-04', B, T: 10000, charges_cents: 47500 },
    { week_start: '2026-10-11', B, T: 0, charges_cents: 0 },
  ];
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: 15000,
  });
  assert.equal(total.restoredSurplusCents, 5000);
  assert.equal(total.debtReductionCents, 0);
});

test('FINAL A4: $60 fund purchase, $60 refund -> fund +$60, surplus unchanged', () => {
  // A fully fund-paid purchase contributes $0 to normal charges.
  const weeks = weeksFromCharges({ '2026-10-04': 0, '2026-10-11': 0 });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 6000,
    fundAllocationCents: 6000, totalRefundedCents: 6000,
  });
  assert.equal(total.fundCreditCents, 6000);
  assert.equal(total.restoredSurplusCents, 0);
  assert.equal(total.debtReductionCents, 0);
});

test('FINAL A4 + shortfall: $35 shortfall + $50 restoration -> $35 offsets shortfall, $15 spendable', () => {
  // $425 wk1 purchase (debt $50), wk2 empty; $50 refund restores $50.
  const weeks = weeksFromCharges({ '2026-10-04': 42500, '2026-10-11': 0 });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 42500,
    totalRefundedCents: 5000,
  });
  assert.equal(total.restoredSurplusCents, 5000);
  const applied = applyShortfallToRelease(total.restoredSurplusCents, 3500);
  assert.equal(applied.releasedToFund, 1500);
  assert.equal(applied.remainingShortfall, 0);
});

test('FINAL A4: $500 refund vs $475 purchase -> $475 restores, $25 held, held restores nothing', () => {
  const weeks = weeksFromCharges({ '2026-10-04': 47500, '2026-10-11': 0 });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: 50000,
  });
  assert.equal(total.heldCents, 2500);
  assert.equal(total.refundableCents, 47500);
  assert.equal(total.restoredSurplusCents, 47500);
  assert.equal(total.debtReductionCents, 0);
});

test('FINAL A4: partial refunds $100 then $200 total exactly a single $300 refund, never more', () => {
  const weeks = weeksFromCharges({ '2026-10-04': 30000, '2026-10-11': 0 });
  const args = (n) => ({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 30000, totalRefundedCents: n,
  });
  const single = computeRestorationTotal(args(30000));
  const first = computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(0)),
    newTotal: computeRestorationTotal(args(10000)), newRefundCents: 10000,
  });
  const second = computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(10000)),
    newTotal: computeRestorationTotal(args(30000)), newRefundCents: 20000,
  });
  assert.equal(first.restoredSurplusCents, 10000);
  assert.equal(first.restoredSurplusCents <= 10000, true);
  assert.equal(second.restoredSurplusCents, 20000);
  assert.equal(second.restoredSurplusCents <= 20000, true);
  assert.equal(first.restoredSurplusCents + second.restoredSurplusCents, single.restoredSurplusCents);
});

test('FINAL A4: partial-refund order independence ($200 then $100 == $100 then $200)', () => {
  const weeks = weeksFromCharges({ '2026-10-04': 30000, '2026-10-11': 0 });
  const args = (n) => ({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 30000, totalRefundedCents: n,
  });
  const orderA = computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(0)),
    newTotal: computeRestorationTotal(args(10000)), newRefundCents: 10000,
  }).restoredSurplusCents + computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(10000)),
    newTotal: computeRestorationTotal(args(30000)), newRefundCents: 20000,
  }).restoredSurplusCents;
  const orderB = computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(0)),
    newTotal: computeRestorationTotal(args(20000)), newRefundCents: 20000,
  }).restoredSurplusCents + computeIncrementalRestoration({
    priorTotal: computeRestorationTotal(args(20000)),
    newTotal: computeRestorationTotal(args(30000)), newRefundCents: 10000,
  }).restoredSurplusCents;
  assert.equal(orderA, 30000);
  assert.equal(orderB, 30000);
  assert.equal(orderA, orderB);
});

test('FINAL A4: pending refund restores nothing; posted-only totals', () => {
  const pendingOnly = [{ amount_cents: -15000, kind: 'refund', state: 'provisional', excluded: false }];
  const posted = [{ amount_cents: -15000, kind: 'refund', state: 'verified', excluded: false }];
  assert.equal(postedRefundTotalCents(pendingOnly), 0);
  assert.equal(postedRefundTotalCents(posted), 15000);
  // A pending refund contributes a $0 cumulative total, i.e. no restoration.
  const weeks = weeksFromCharges({ '2026-10-04': 47500, '2026-10-11': 0 });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: postedRefundTotalCents(pendingOnly),
  });
  assert.equal(total.restoredSurplusCents, 0);
  assert.equal(total.debtReductionCents, 0);
});

test('FINAL A4: pending refund later removed leaves no trace (same as never existed)', () => {
  const weeks = weeksFromCharges({ '2026-10-04': 47500, '2026-10-11': 0 });
  const neverExisted = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: postedRefundTotalCents([]),
  });
  const pendingThenRemoved = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: postedRefundTotalCents([
      { amount_cents: -15000, kind: 'refund', state: 'provisional', excluded: false },
    ]),
  });
  assert.deepEqual(pendingThenRemoved, neverExisted);
});

test('FINAL A4: replay idempotency + read-only simulation (inputs and stored state identical after re-run)', () => {
  const weeks = weeksFromCharges({
    '2026-10-04': 47500, '2026-10-11': 37500, '2026-10-18': 0,
  });
  const before = structuredClone(weeks);
  const args = {
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500,
    totalRefundedCents: 15000,
  };
  const first = computeRestorationTotal(args);
  const second = computeRestorationTotal(args);
  assert.deepEqual(second, first);
  assert.deepEqual(weeks, before); // inputs not mutated
  const simA = simulateWeeks(weeks, 0);
  const simB = simulateWeeks(weeks, 0);
  assert.deepEqual(simB, simA);
  assert.deepEqual(weeks, before); // simulation is read-only
});

test('FINAL A4: split fund purchase uses fund-first ordering (owner-confirmed Nov 5, 2026 — N1 Option A; P2-M3)', () => {
  // $100 purchase: $60 fund + $40 normal. Normal charges in wk1 = $40.
  // $80 refund -> $60 fund credit + $20 normal restoration.
  const weeks = weeksFromCharges({ '2026-10-04': 4000, '2026-10-11': 0 });
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 10000,
    fundAllocationCents: 6000, totalRefundedCents: 8000,
  });
  assert.equal(total.fundCreditCents, 6000);
  assert.equal(total.restoredSurplusCents, 2000);
  assert.equal(total.fundCreditCents + total.restoredSurplusCents, 8000);
});
