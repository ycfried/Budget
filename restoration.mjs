// Household Budget — refund restoration (pure, no I/O, no dependencies).
// Spec: FINAL A4, "Refund restoration". Imported by week-close; the
// engine (engine.mjs) stays a single-week function and knows nothing
// about refunds. This module knows nothing about the database.
//
// Model (read the FINAL examples before changing anything here):
// When a refund arrives after its original week has locked, run a
// READ-ONLY simulation of every week from the purchase's week up to
// the present, using the original per-week policy (B and T exactly as
// booked — week-close supplies stored snapshots for closed weeks) and
// every other input exactly as booked, reducing ONLY that purchase's
// charge by the total refunded so far. Post ONE restoration entry in
// the current week per refund. Locked history is never edited, and
// this module never mutates its inputs (tests freeze-compare them).
//
// HORIZON RULE (load-bearing, proven by the FINAL variant example):
// the caller supplies weeks from the purchase week through the LAST
// COMPLETED week only (week_start < current week start). The
// in-progress current week is NEVER in the horizon: an empty current
// week would absorb outstanding debt in the baseline run and turn
// the FINAL variant's "$50 surplus + $100 debt cut" into "$150
// surplus + $0 debt cut". Week-close enforces this horizon; this
// module trusts the weeks array it is given.
//
// Definitions used throughout:
// - weeks: sorted array [{ week_start, B, T, charges_cents }], where
//   charges_cents is the week's normal charges AS BOOKED, including
//   the target purchase's NORMAL portion (purchase amount minus its
//   fund allocation) in the purchase week, and including every other
//   booked input for that week (other charges, other refunds as the
//   caller booked them — see week-close's simulation-charges rule).
// - purchaseAmountCents: the purchase's gross charge (positive).
// - fundAllocationCents: the portion of that purchase allocated to the
//   Extra Fund (0 for a normal purchase, equal to the purchase amount
//   for a fully fund-paid purchase). A fund purchase's normal portion
//   is purchaseAmountCents - fundAllocationCents and is what sits in
//   the purchase week's charges_cents.
// - totalRefundedCents: cumulative POSTED refunds for this purchase
//   (pending refunds are never passed in — see postedRefundTotalCents).
//
// Outputs (per cumulative refund total):
// - restoredSurplusCents: increase in TOTAL earned surplus across the
//   simulated weeks, reduced run minus baseline run. The temp-covered
//   portion restores $0 automatically: reducing the charge first
//   removes the temp-covered slice (base-covered spending stays),
//   so a $475 purchase in a $375 + $100-temp week refunded $100
//   yields $0, and refunded $150 yields $50. No special-casing.
// - debtReductionCents: drop in debt still outstanding at the END of
//   the simulation (outgoing debt of the last simulated week).
//   If later weeks already absorbed the debt, this is $0.
// - fundCreditCents: refund of a fund purchase credits the fund
//   directly and does not change surplus. Fund-first ordering for a
//   SPLIT purchase (part fund, part normal) is owner-confirmed
//   (Nov 5, 2026 — N1 Option A, fund-first counted once;
//   MATH_DECISIONS_N1_N2.md; engine.mjs
//   linkedRefundNormalPortionCents implements the same split in the
//   walk, so the two agree). The FINAL spec's acceptance cases cover
//   only fully-fund purchases; the split ordering itself is settled
//   by that owner decision, not pending confirmation.
// - heldCents: refund amount beyond the original charge. It restores
//   nothing and is queued for admin review (held_refunds table).
//
// Incremental rule: for a new refund, restoration = total(cumulative
// including this refund) MINUS total(cumulative before this refund).
// This makes partial refunds order-independent (the total depends only
// on the cumulative amount) and guarantees a refund event is never
// restored twice. It also handles the lock-boundary straddle: a prior
// refund that arrived while the purchase week was still open already
// benefited history through open-window recompute, and total(prior
// cumulative) is exactly that banked effect, so the later locked
// refund restores only its own increment — never a second copy of
// the open-window benefit. Week-close computes both totals with this
// module and posts only the increment.
//
// Invariants enforced here: every component is >= 0; the posted
// increment's (surplus + debt + fund) never exceeds the refundable
// part of the new refund (defensive clamp on surplus, then debt —
// it should never trigger on valid inputs, because reducing charges
// cannot reduce surplus or increase outstanding debt).
//
// Shortfall ordering is NOT in this module: week-close applies the
// posted surplus + fund credits like released surplus, offsetting any
// recorded fund shortfall FIRST (via update_fund_shortfall), and only
// the remainder reaches the fund ledger as spendable money.

import { computeWeek, weekStartsBetween } from './engine.mjs';

function int(v, name) {
  const n = Number(v ?? 0);
  if (!Number.isFinite(n) || !Number.isInteger(n) || n < 0) {
    throw new Error(`restoration: expected a non-negative integer cents value for ${name}, got ${String(v)}`);
  }
  return n;
}

// Simulate a chain of weeks. Returns per-week results plus totals.
// Pure: does not mutate `weeks`.
export function simulateWeeks(weeks, initialDebtCents) {
  const sorted = [...(weeks ?? [])].sort((a, b) => (a.week_start < b.week_start ? -1 : 1));
  let D = int(initialDebtCents, 'initialDebtCents');
  const perWeek = [];
  let totalSurplus = 0;
  for (const w of sorted) {
    const result = computeWeek({
      B: int(w.B, 'B'),
      T: int(w.T, 'T'),
      D,
      C: int(w.charges_cents, 'charges_cents'),
    });
    perWeek.push({ week_start: w.week_start, ...result });
    totalSurplus += result.earnedSurplus;
    D = result.outgoingDebt;
  }
  return { perWeek, totalSurplus, outgoingDebt: D };
}

// Total restoration for a cumulative posted-refund amount.
// Pure: does not mutate `weeks` or any argument.
export function computeRestorationTotal(args) {
  const {
    weeks,
    purchaseWeekStart,
    purchaseAmountCents,
    fundAllocationCents = 0,
    totalRefundedCents,
    initialDebtCents = 0,
  } = args ?? {};
  const purchaseAmount = int(purchaseAmountCents, 'purchaseAmountCents');
  const fundAllocation = int(fundAllocationCents, 'fundAllocationCents');
  const totalRefunded = int(totalRefundedCents, 'totalRefundedCents');
  if (fundAllocation > purchaseAmount) {
    throw new Error('restoration: fundAllocationCents cannot exceed purchaseAmountCents');
  }
  const sorted = [...(weeks ?? [])].sort((a, b) => (a.week_start < b.week_start ? -1 : 1));
  const purchaseWeek = sorted.find((w) => w.week_start === purchaseWeekStart);
  if (!purchaseWeek) {
    throw new Error(`restoration: purchase week ${purchaseWeekStart} is not in the simulation weeks`);
  }

  const heldCents = Math.max(0, totalRefunded - purchaseAmount);
  const refundableCents = Math.min(totalRefunded, purchaseAmount);
  // Fund-first ordering for split purchases (owner-confirmed Nov 5,
  // 2026 — N1 Option A; see the header note).
  const fundCreditCents = Math.min(refundableCents, fundAllocation);
  const normalRefundCents = refundableCents - fundCreditCents;

  const baseline = simulateWeeks(sorted, initialDebtCents);
  const reducedWeeks = sorted.map((w) => {
    if (w.week_start !== purchaseWeekStart) return w;
    return {
      ...w,
      charges_cents: Math.max(0, int(w.charges_cents, 'charges_cents') - normalRefundCents),
    };
  });
  const reduced = simulateWeeks(reducedWeeks, initialDebtCents);

  const restoredSurplusCents = Math.max(0, reduced.totalSurplus - baseline.totalSurplus);
  const debtReductionCents = Math.max(0, baseline.outgoingDebt - reduced.outgoingDebt);
  return {
    refundableCents,
    heldCents,
    fundCreditCents,
    restoredSurplusCents,
    debtReductionCents,
    baseline: { totalSurplus: baseline.totalSurplus, outgoingDebt: baseline.outgoingDebt },
    reduced: { totalSurplus: reduced.totalSurplus, outgoingDebt: reduced.outgoingDebt },
  };
}

// Incremental restoration for ONE new refund, given the cumulative
// totals before and after it. `priorTotal` is the total for the
// cumulative refunds BEFORE this refund (zeros when this is the
// first refund); `newTotal` is the total including this refund.
// Returns the increment to post for this refund, capped so
// surplus + debt + fund never exceed the refundable part of it.
export function computeIncrementalRestoration({ priorTotal, newTotal, newRefundCents }) {
  const zero = {
    refundableCents: 0, heldCents: 0, fundCreditCents: 0,
    restoredSurplusCents: 0, debtReductionCents: 0,
  };
  const prior = priorTotal ?? zero;
  const next = newTotal ?? zero;
  const refund = int(newRefundCents, 'newRefundCents');
  let surplus = Math.max(0, next.restoredSurplusCents - prior.restoredSurplusCents);
  let debt = Math.max(0, next.debtReductionCents - prior.debtReductionCents);
  const fund = Math.max(0, next.fundCreditCents - prior.fundCreditCents);
  const held = Math.max(0, next.heldCents - prior.heldCents);
  // Cap: the refundable part of this refund is the refund minus the
  // part of it that went to the held queue (excess over the charge).
  const cap = Math.max(0, refund - held);
  const sum = surplus + debt + fund;
  if (sum > cap) {
    let over = sum - cap;
    const cutSurplus = Math.min(surplus, over);
    surplus -= cutSurplus;
    over -= cutSurplus;
    const cutDebt = Math.min(debt, over);
    debt -= cutDebt;
    over -= cutDebt;
    // Fund credit is direct and is never cut; any residual `over`
    // after cutting surplus and debt to zero would indicate invalid
    // inputs and is left visible in the returned sum for the caller
    // to notice (week-close records the capped values as computed).
  }
  return {
    restoredSurplusCents: surplus,
    debtReductionCents: debt,
    fundCreditCents: fund,
    heldCents: held,
  };
}

// Sum of POSTED refunds only. Pending/provisional refunds contribute
// 0, and a pending refund later removed likewise leaves no trace,
// because it never entered any total this function returns.
// `refunds` rows: { amount_cents (negative for a refund), kind,
// state, excluded }. Amounts are taken as absolute values.
export function postedRefundTotalCents(refunds) {
  return (refunds ?? [])
    .filter((r) => r && !r.excluded && r.state !== 'reversed'
      && r.kind === 'refund' && r.state === 'verified')
    .reduce((s, r) => s + Math.abs(r.amount_cents ?? 0), 0);
}

// All week starts from a purchase week through a current week, for
// building a simulation horizon. Thin wrapper kept here so callers
// use one import for restoration work.
export function simulationWeekStarts(purchaseWeekStart, currentWeekStart) {
  return weekStartsBetween(purchaseWeekStart, currentWeekStart);
}
