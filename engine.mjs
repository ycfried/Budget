// Household Budget — shared budget engine (pure, no I/O, no dependencies).
// Spec: Household Budget — Revised iOS Spec (v2), Part A2/A4.
// All amounts are INTEGER CENTS. Never use floating point for money.
// This module is used by BOTH the browser PWA (app.js) and the Node server
// (server.mjs) so there is exactly one formula. Do not copy it elsewhere.
//
// Canonical inputs for one week (all cents, all >= 0 unless noted):
//   B    base allowance for the week
//   T    active temporary increment for the week (unused portion earns nothing)
//   R_in carried-in refund credit (from previous weeks)
//   X    new excess refund credit created this week (refunds above the week's charges)
//   D    incoming debt carried into the week
//   C    normal charges for the week (eligible charges net of linked refunds, floored at 0)
//
// FIN-REFUND-001 (DEFERRED, UNRESOLVED — see OPEN_QUESTIONS.md):
// With B=37500, D=0, X=10000, C=0 this function returns BOTH earned_surplus=37500
// AND outgoing_credit=10000, exactly as the spec's later test states it. That
// combination may double-benefit (released surplus + full carried credit).
// The owner has deferred the policy decision. This engine does NOT invent a
// policy: it reports both numbers and the PWA flags outputs that depend on
// this case as NOT production-certified. See the skipped test in
// test/engine.test.mjs.

export function computeWeek(input) {
  const B = int(input.B);
  const T = int(input.T);
  const R_in = int(input.R_in);
  const X = int(input.X);
  const D = int(input.D);
  const C = int(input.C);

  // 1. Apply credit to debt first.
  const R = R_in + X;
  const debtPaidByCredit = Math.min(D, R);
  const D2 = D - debtPaidByCredit; // debt remaining after credit
  const R2 = R - debtPaidByCredit; // credit remaining after paying debt

  // 2. Debt not absorbed by this week's base becomes carried debt.
  const carriedDebt = Math.max(0, D2 - B);
  // 3. Base capacity left after paying debt.
  const baseAvailable = Math.max(0, B - D2);
  // 4. Charges covered by base.
  const coveredBase = Math.min(C, baseAvailable);
  // 5. Charges above base.
  const overBase = C - coveredBase;
  // 6. Temporary increment covers next (never pays down earlier debt, and
  //    never covers carriedDebt — it only covers overBase).
  const coveredTemp = Math.min(overBase, T);
  // 7. Carried refund credit covers what is left, after the temporary increment.
  const coveredCredit = Math.min(overBase - coveredTemp, R2);
  const newDebt = overBase - coveredTemp - coveredCredit;

  const outgoingDebt = carriedDebt + newDebt;
  const outgoingCredit = R2 - coveredCredit;
  const earnedSurplus = baseAvailable - coveredBase;
  // Dashboard "available this week". Can be negative. Uses R2 (credit after
  // paying incoming debt, before covering this week's charges) — this matches
  // the spec's worked example: $40 debt + $100 excess refund, no charges
  // gives available = $375 + $60 = $435.
  const available = baseAvailable + T + R2 - C;

  return {
    B, T, R_in, X, D, C,
    debtPaidByCredit,
    carriedDebt,
    baseAvailable,
    coveredBase,
    overBase,
    coveredTemp,
    coveredCredit,
    newDebt,
    outgoingDebt,
    outgoingCredit,
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

// A closed week's surplus is pending for 7 days after the week closes
// (close = the Sunday the week ends, i.e. weekStart + 7 days), then released.
// So release date = weekStart + 14 days.
export function surplusReleaseDate(weekStart) {
  return addDays(weekStart, 14);
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
