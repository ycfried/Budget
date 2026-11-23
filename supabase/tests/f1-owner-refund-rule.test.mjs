// F-1 shared fixture (build 64, owner rule Nov 23, 2026) — run with:
//   node --test supabase/tests/f1-owner-refund-rule.test.mjs
// Pure helpers from supabase/functions/_shared/engine.mjs, imported
// directly. This is the SHARED FIXTURE the audit's F-1 fix asks for:
// Home (compute-week) and the Transactions list (Swift
// WeekTransactionsNetting) must compute the SAME total for this
// fixture. The Swift side mirrors these numbers; if either side
// changes the rule, this file is the place the divergence shows.
//
// OWNER RULE (Nov 23, 2026 — supersedes the audit's fund-first
// logic and the old P0-12 provisional-refund exclusion):
//   * A refund restores to the CLASSIFICATION of the charge it
//     links to: spending charge -> reduces the week's spending in
//     full; fund charge -> goes back to the fund, nets 0.
//   * NO SPLITS: Cover with Savings is always the WHOLE charge,
//     never part of it — so a split purchase cannot happen and
//     "fund-first" (linkedRefundNormalPortionCents) is MOOT.
//   * A PENDING (provisional) refund counts RIGHT AWAY, like a
//     pending charge, and auto-reverses if it disappears (Plaid
//     removed[] -> exclude_transaction, F-14).
//   * A refund larger than its purchase is capped at the purchase's
//     spending portion; the excess is HELD, never netted.
//   * An unlinked refund nets in full, capped at the week's charges
//     (applyUnlinkedRefundCap).
//
// Fixture (all cents; week of 2026-11-15):
//   P1  $100.00 spending charge (verified) + $50.00 refund (verified)
//   P2  $100.00 fund charge (fund_charge, fully fund-covered)
//       + $50.00 refund (verified)
//   P3  $80.00 spending charge (verified) + $30.00 refund (PROVISIONAL)
//   P4  $40.00 spending charge (verified), no refund
//   U1  $25.00 unlinked refund (verified, no purchase)
// Charges gross: 10000 + 10000(fund, nets 0 via allocation) + 8000
//   + 4000 = 22000 spending portion. Refund netting: P1 5000 +
//   P2 0 + P3 3000 (pending counts) + U1 2500 = 10500.
// Week C = 22000 - 10500 = 11500 ($115.00).

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyUnlinkedRefundCap,
  chargeContribution,
  isExcludedFromMath,
  linkedRefundNormalPortionCents,
  linkedRefundSpendingPortionCents,
  pendingRefundExcludedCents,
} from '../functions/_shared/engine.mjs';

const spending = (amountCents, over = {}) => ({
  kind: 'charge', state: 'verified', excluded: false,
  amount_cents: amountCents, fund_allocation_cents: 0, ...over,
});
const fundCharge = (amountCents, over = {}) => ({
  kind: 'fund_charge', state: 'verified', excluded: false,
  amount_cents: amountCents, fund_allocation_cents: amountCents, ...over,
});
const refund = (amountCents, state, over = {}) => ({
  kind: 'refund', state, excluded: false,
  amount_cents: -Math.abs(amountCents), ...over,
});

// The fixture, as rows the engine sees.
const P1 = spending(10000);
const P1_REFUND = refund(5000, 'verified');
const P2 = fundCharge(10000);
const P2_REFUND = refund(5000, 'verified');
const P3 = spending(8000);
const P3_REFUND = refund(3000, 'provisional');
const P4 = spending(4000);
const U1 = refund(2500, 'verified');

test('F-1: a pending refund counts in week math (no longer excluded)', () => {
  assert.equal(isExcludedFromMath(P3_REFUND), false);
  assert.equal(isExcludedFromMath(P1_REFUND), false);
  assert.equal(isExcludedFromMath(spending(10000, { state: 'provisional' })), false);
  // Excluded / reversed refunds still count nothing.
  assert.equal(isExcludedFromMath(refund(5000, 'verified', { excluded: true })), true);
  assert.equal(isExcludedFromMath(refund(5000, 'verified', { state: 'reversed' })), true);
});

test('F-1: linked refund nets by purchase classification', () => {
  // Spending purchase: the refund nets in full.
  assert.equal(linkedRefundSpendingPortionCents(P1.kind, P1.amount_cents, P1.fund_allocation_cents, 5000), 5000);
  // Fund purchase: the refund goes back to the fund, nets 0.
  assert.equal(linkedRefundSpendingPortionCents(P2.kind, P2.amount_cents, P2.fund_allocation_cents, 5000), 0);
  // Pending refund on a spending purchase nets the same as posted.
  assert.equal(linkedRefundSpendingPortionCents(P3.kind, P3.amount_cents, P3.fund_allocation_cents, 3000), 3000);
  // Cap: a refund larger than its purchase nets only the purchase.
  assert.equal(linkedRefundSpendingPortionCents(P1.kind, P1.amount_cents, P1.fund_allocation_cents, 12000), 10000);
  // Partial refunds are order-independent (cumulative total).
  assert.equal(linkedRefundSpendingPortionCents(P1.kind, P1.amount_cents, P1.fund_allocation_cents, 3000), 3000);
  assert.equal(linkedRefundSpendingPortionCents(P1.kind, P1.amount_cents, P1.fund_allocation_cents, 6000), 6000);
});

test('F-1: whole-fixture week C is $115.00 (Home == Transactions list)', () => {
  const charges = [P1, P2, P3, P4].reduce((s, t) => s + chargeContribution(t), 0);
  assert.equal(charges, 22000, 'fund charge contributes 0 (fully allocated)');
  const linked =
    linkedRefundSpendingPortionCents(P1.kind, P1.amount_cents, P1.fund_allocation_cents, 5000) +
    linkedRefundSpendingPortionCents(P2.kind, P2.amount_cents, P2.fund_allocation_cents, 5000) +
    linkedRefundSpendingPortionCents(P3.kind, P3.amount_cents, P3.fund_allocation_cents, 3000);
  assert.equal(linked, 8000, 'P1 5000 + P2 0 + P3 3000 (pending counts)');
  const unlinked = applyUnlinkedRefundCap(2500, charges - linked, false);
  assert.equal(unlinked.nettedCents, 2500);
  assert.equal(unlinked.excessCents, 0);
  const C = Math.max(0, charges - linked - unlinked.nettedCents);
  assert.equal(C, 11500, 'week C must be $115.00 on both Home and the list');
});

test('F-1: pending-refund reporting helper still sums the pending cents', () => {
  // Legacy name, updated meaning (engine.mjs): the sum of pending
  // refunds that ARE counted in C, for display — not an excluded total.
  assert.equal(pendingRefundExcludedCents([P1_REFUND, P3_REFUND, U1]), 3000);
});

test('F-1: fund-first helper agrees with the owner rule on every reachable input', () => {
  // No splits can exist, so the old helper and the new one must agree
  // wherever the new one is defined. (The old helper stays only for
  // its pinned tests in test/math-fixes-n1-n2.test.mjs.)
  const cases = [
    ['charge', 10000, 0, 5000],
    ['charge', 10000, 0, 12000],
    ['fund_charge', 10000, 10000, 5000],
    ['charge', 8000, 0, 3000],
  ];
  for (const [kind, amount, fund, refunded] of cases) {
    assert.equal(
      linkedRefundSpendingPortionCents(kind, amount, fund, refunded),
      linkedRefundNormalPortionCents(amount, fund, refunded),
      `${kind} $${amount / 100} fund $${fund / 100} refund $${refunded / 100}`,
    );
  }
});
