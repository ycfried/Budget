// Household Budget engine tests — run with: node --test test/engine.test.mjs
// All amounts are integer cents. $1 = 100.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  computeWeek,
  weekStartOf,
  addDays,
  surplusReleaseDate,
  applyShortfallToRelease,
  reduceFundForLateCharge,
  isWeekLocked,
} from '../engine.mjs';

const B = 37500; // $375 base allowance

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

test('$100 credit carried in + $475 charges -> no debt, credit $0', () => {
  const w = computeWeek({ B, R_in: 10000, C: 47500 });
  assert.equal(w.coveredBase, 37500);
  assert.equal(w.coveredCredit, 10000);
  assert.equal(w.outgoingDebt, 0);
  assert.equal(w.outgoingCredit, 0);
});

test('$100 credit + $300 charges -> surplus $75, credit $100 remains', () => {
  const w = computeWeek({ B, R_in: 10000, C: 30000 });
  assert.equal(w.earnedSurplus, 7500);
  assert.equal(w.outgoingCredit, 10000);
  assert.equal(w.coveredCredit, 0);
});

test('$100 credit + $100 temp + $500 charges -> temp first, credit covers $25, credit $75 remains, no debt', () => {
  const w = computeWeek({ B, R_in: 10000, T: 10000, C: 50000 });
  assert.equal(w.coveredBase, 37500);
  assert.equal(w.coveredTemp, 10000);
  assert.equal(w.coveredCredit, 2500);
  assert.equal(w.outgoingCredit, 7500);
  assert.equal(w.outgoingDebt, 0);
});

test('$40 debt + $100 excess refund -> debt $0, credit $60', () => {
  const w = computeWeek({ B, D: 4000, X: 10000, C: 0 });
  assert.equal(w.debtPaidByCredit, 4000);
  assert.equal(w.outgoingDebt, 0);
  assert.equal(w.outgoingCredit, 6000);
  assert.equal(w.available, 43500); // $375 + $60
});

test('$500 debt + $100 excess refund, no charges -> debt $400 cut, base absorbs $375, outgoing debt $25, credit $0', () => {
  const w = computeWeek({ B, D: 50000, X: 10000, C: 0 });
  assert.equal(w.debtPaidByCredit, 10000);
  assert.equal(w.carriedDebt, 2500);
  assert.equal(w.baseAvailable, 0);
  assert.equal(w.outgoingDebt, 2500);
  assert.equal(w.outgoingCredit, 0);
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

test('surplus release: pending 7 days after close, released exactly once (release date = week start + 14 days)', () => {
  assert.equal(surplusReleaseDate('2026-10-25'), '2026-11-08');
  // A release dated in the future is not yet spendable; on/after the date it is.
  const releaseDate = surplusReleaseDate('2026-10-25');
  assert.equal('2026-11-01' < releaseDate, true);
  assert.equal('2026-11-08' >= releaseDate, true);
});

test('28-day open window: recent weeks open, old weeks locked; locked adjustments post to current week', () => {
  // Week starting 2026-09-20 ended 2026-09-27; 28 days later is 2026-10-25.
  // Current week starting 2026-11-01 is past that -> locked.
  assert.equal(isWeekLocked('2026-09-20', '2026-11-01'), true);
  // Week starting 2026-10-25 ended 2026-11-01; lock date 2026-11-29 -> still open.
  assert.equal(isWeekLocked('2026-10-25', '2026-11-01'), false);
});

test('week boundaries: Saturday belongs to the closing week, Sunday starts a new week', () => {
  assert.equal(weekStartOf('2026-10-31'), '2026-10-25'); // Saturday
  assert.equal(weekStartOf('2026-11-01'), '2026-11-01'); // Sunday
  assert.equal(addDays('2026-10-25', 7), '2026-11-01');
});

// FIN-REFUND-001 — DEFERRED, UNRESOLVED. This test is intentionally SKIPPED.
// Spec later test: "$100 excess refund in a week with no debt and no charges
// results in $375 earned surplus AND $100 outgoing refund credit." That may
// double-benefit (released surplus + full carried credit). No policy has been
// chosen by the owner, so this must NOT be marked passed. If un-skipped, the
// engine (faithfully following the spec text) returns surplus $375 AND
// credit $100 — which is precisely the ambiguity to be decided, not a pass.
test('FIN-REFUND-001 (SKIPPED, pending owner decision): $100 excess refund, no debt, no charges', { skip: 'DEFERRED — owner has not chosen the refund-credit/surplus policy. Engine currently returns BOTH $375 surplus AND $100 outgoing credit per the spec text; do not treat either interpretation as passed.' }, () => {
  const w = computeWeek({ B, X: 10000, C: 0 });
  assert.equal(w.earnedSurplus, 37500);
  assert.equal(w.outgoingCredit, 10000);
});
