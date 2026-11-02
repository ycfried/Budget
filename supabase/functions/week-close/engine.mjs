// Household Budget — shared budget engine (pure, no I/O, no dependencies).
// Spec: Household Budget — Revised iOS Spec (v2) FINAL, Part A2/A4.
// All amounts are INTEGER CENTS. Never use floating point for money.
// This module is used by the server (Edge Functions) and, for display
// only, by clients. The server is the only authority for budget math.
//
// Canonical inputs for one week (all cents, all >= 0):
//   B    base allowance for the week
//   T    active temporary increment for the week (unused portion earns nothing)
//   D    incoming debt carried into the week
//   C    normal charges for the week (eligible charges net of linked refunds,
//        floored at 0; a refund that arrives after a week locks follows A4
//        refund restoration — it never becomes credit here)
//
// There is NO refund-credit model in this engine. There are no
// carried-in credit, excess-credit, credit-coverage, or outgoing
// credit inputs or outputs. The old credit model (and the deferred
// refund question built on it) is MOOT under the FINAL spec and has
// been retired, not answered. Dashboard
// available = base_available + T - C (FINAL A2). Note this formula
// includes unused T in "available" even though unused T earns no
// surplus (see the $100-temp / $300-spend fixture: surplus $75,
// available $175). That is the spec formula, kept literally.
//
// Refund restoration lives in restoration.mjs (pure simulation), not
// here. This file also carries the transaction-counting rules shared
// by compute-week and week-close so both functions filter rows
// identically. Payment and cash-back kinds are defined by the S3
// workstream; this engine excludes them by kind string whether or
// not the database kind check has been extended yet.

export const ENGINE_SPEC = 'FINAL A2/A4 (B,T,D,C only)';

export function computeWeek(input) {
  const B = int(input.B);
  const T = int(input.T);
  const D = int(input.D);
  const C = int(input.C);
  // Unknown fields (including any legacy credit fields a stale caller
  // sends) are deliberately IGNORED, never read into the math. A stale
  // caller therefore cannot reintroduce refund credit through this function.

  // 1. Debt not absorbed by this week's base becomes carried debt.
  const carriedDebt = Math.max(0, D - B);
  // 2. Base capacity left after paying debt.
  const baseAvailable = Math.max(0, B - D);
  // 3. Charges covered by base.
  const coveredBase = Math.min(C, baseAvailable);
  // 4. Charges above base.
  const overBase = C - coveredBase;
  // 5. Temporary increment covers next (never pays down earlier debt,
  //    and never covers carriedDebt — it only covers overBase).
  const coveredTemp = Math.min(overBase, T);
  // 6. New debt.
  const newDebt = overBase - coveredTemp;

  const outgoingDebt = carriedDebt + newDebt;
  const earnedSurplus = baseAvailable - coveredBase;
  // Dashboard "available this week". Can be negative.
  const available = baseAvailable + T - C;

  return {
    B, T, D, C,
    carriedDebt,
    baseAvailable,
    coveredBase,
    overBase,
    coveredTemp,
    newDebt,
    outgoingDebt,
    earnedSurplus,
    available,
  };
}

function int(v) {
  const n = Number(v ?? 0);
  if (!Number.isFinite(n) || !Number.isInteger(n) || n < 0) {
    throw new Error(`engine: expected a non-negative integer cents value, got ${String(v)}`);
  }
  return n;
}

// ---------------------------------------------------------------------------
// Transaction counting rules (FINAL A4/A7, audit P0-12, P1-5).
// A row is a plain object with: amount_cents, kind, state, excluded,
// fund_allocation_cents. These helpers are pure and shared by
// compute-week and week-close; neither function invents its own filter.
// ---------------------------------------------------------------------------

// True when the row must be excluded from ALL week math.
export function isExcludedFromMath(t) {
  if (!t) return true;
  if (t.excluded === true) return true;
  if (t.state === 'reversed') return true;
  // Payment and cash-back kinds are never week spending (A7: cash-back
  // statement credits are not refunds; excluded by default, admin
  // reclassifies via the reclassify_transaction RPC, after which the
  // row counts under its CURRENT kind).
  if (t.kind === 'payment' || t.kind === 'cashback') return true;
  // Pending/provisional REFUNDS restore nothing and are excluded from
  // week math until they post (state 'verified'). Provisional CHARGES
  // still count — the distinction is by kind + state, not state alone.
  if (t.kind === 'refund' && t.state === 'provisional') return true;
  return false;
}

// True for a pending refund row (used for the excluded-total display).
export function isPendingRefund(t) {
  if (!t || t.excluded === true || t.state === 'reversed') return false;
  return t.kind === 'refund' && t.state === 'provisional';
}

// Absolute cents of pending refunds in a row set (for reporting only;
// these cents are never counted in C).
export function pendingRefundExcludedCents(rows) {
  return (rows ?? [])
    .filter(isPendingRefund)
    .reduce((s, t) => s + Math.abs(t.amount_cents ?? 0), 0);
}

// True for a posted refund row (posted = state 'verified').
export function isPostedRefund(t) {
  if (!t || t.excluded === true || t.state === 'reversed') return false;
  return t.kind === 'refund' && t.state === 'verified';
}

// Contribution of a charge row to a week's C: amount net of the portion
// allocated to the Extra Fund. Refunds, payments, cash-back, excluded
// and reversed rows contribute 0 here — refunds are applied only via
// linkage (open weeks) or restoration (locked weeks), never by
// blindly netting every negative row.
export function chargeContribution(t) {
  if (isExcludedFromMath(t)) return 0;
  if (t.kind === 'charge' || t.kind === 'fund_charge') {
    return (t.amount_cents ?? 0) - (t.fund_allocation_cents ?? 0);
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Week helpers — America/New_York, Sunday 00:00 to next Sunday 00:00.
// Dates are handled as NY calendar dates (YYYY-MM-DD strings) so DST never
// shifts a purchase into the wrong week.
// ---------------------------------------------------------------------------

// NY calendar parts for a Date (defaults to now).
export function nyParts(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(date);
  const get = (t) => parts.find((p) => p.type === t).value;
  return { year: Number(get('year')), month: Number(get('month')), day: Number(get('day')) };
}

export function nyTodayString(date = new Date()) {
  const { year, month, day } = nyParts(date);
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

// Weekday (0=Sunday..6=Saturday) for a YYYY-MM-DD calendar date.
export function weekdayOf(dateStr) {
  const [y, m, d] = dateStr.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

// Sunday (YYYY-MM-DD) that starts the week containing dateStr.
export function weekStartOf(dateStr) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const utc = new Date(Date.UTC(y, m - 1, d));
  utc.setUTCDate(utc.getUTCDate() - utc.getUTCDay());
  return utc.toISOString().slice(0, 10);
}

// Add whole days to a YYYY-MM-DD date string.
export function addDays(dateStr, days) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const utc = new Date(Date.UTC(y, m - 1, d));
  utc.setUTCDate(utc.getUTCDate() + days);
  return utc.toISOString().slice(0, 10);
}

// All week starts from `fromWeekStart` through `toWeekStart`, inclusive.
export function weekStartsBetween(fromWeekStart, toWeekStart) {
  const out = [];
  let cur = fromWeekStart;
  while (cur <= toWeekStart) {
    out.push(cur);
    cur = addDays(cur, 7);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Week close / surplus release / shortfall (spec A4).
// ---------------------------------------------------------------------------

// Legacy on-time release date: a week closed on the Sunday it ends has
// its surplus pending 7 days, so release = weekStart + 14 days. Kept
// for compatibility with rows closed on time. NEW closes must use
// releaseDateFromCloseDate (actual close date + 7 days, fixing the
// late-close skip in audit P1-6).
export function surplusReleaseDate(weekStart) {
  return addDays(weekStart, 14);
}

// P1-6 fix: the 7-day pending window runs from the ACTUAL close date,
// not from the week end. A week first closed 6 weeks late therefore
// still waits 7 days before releasing.
export function releaseDateFromCloseDate(closeDateStr) {
  return addDays(closeDateStr, 7);
}

export function makeSurplusRelease(weekStart, earnedSurplusCents) {
  return {
    weekStart,
    amountCents: earnedSurplusCents,
    releaseDate: surplusReleaseDate(weekStart),
    released: false,
  };
}

// Net a release against an outstanding shortfall (spec A4 shortfall rule).
// Returns { releasedToFund, remainingShortfall }.
export function applyShortfallToRelease(releaseAmountCents, shortfallCents) {
  const applied = Math.min(releaseAmountCents, shortfallCents);
  return {
    releasedToFund: releaseAmountCents - applied,
    remainingShortfall: shortfallCents - applied,
  };
}

// A late charge reduces already-released surplus: fund goes to at most zero,
// any remainder becomes a shortfall (never a negative fund, never a clawback
// from the normal weekly budget).
// Returns { fundAvailable, shortfall }.
export function reduceFundForLateCharge(fundAvailableCents, surplusReductionCents) {
  if (surplusReductionCents <= fundAvailableCents) {
    return { fundAvailable: fundAvailableCents - surplusReductionCents, shortfall: 0 };
  }
  return {
    fundAvailable: 0,
    shortfall: surplusReductionCents - fundAvailableCents,
  };
}

// Open window: a week stays open for 28 days after it ends (weekEnd =
// weekStart + 7 days). A charge dated in a week whose end is more than 28
// days before the current week start is LOCKED: it keeps its true date but
// posts as an adjustment in the current week and locked history never changes.
export function isWeekLocked(weekStart, currentWeekStart) {
  const weekEnd = addDays(weekStart, 7);
  const lockDate = addDays(weekEnd, 28);
  return currentWeekStart > lockDate;
}

export function formatCents(cents) {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  return `${sign}$${(abs / 100).toFixed(2)}`;
}
