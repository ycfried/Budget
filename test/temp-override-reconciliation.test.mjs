// Temporary-allowance reconciliation (Nov 11, 2026) — the PR #64
// Fix 1 gap. PR #64 gated the Weekly sheet's reconciliation rows on
// tempCents > 0, but the app's Temporary Allowance form writes a NEW
// TOTAL per week to weekly_allowance_overrides, and compute-week
// folds an override into B with T = 0 — so temp_cents is always 0
// for app-set increases and the rows never appeared live (base
// $375, override $475: Home showed $475, the sheet showed only
// Allowance/Spent/Balance). compute-week now surfaces the override
// as override_cents (null when no override drives B, or a stored
// close snapshot wins); the client derives the delta against the
// stored base and the sheet shows it as a Temporary increase or
// decrease. Tests here are static assertions on the real code plus
// pure-function mirrors of the full data flow — a compute-week-shaped
// response, through the loadWeekNumbers derivation, to the sheet
// rows — so the gap the delta audit missed (server value for the
// real app flow) is asserted, not just the gates. No DOM, no
// network, no database, no money-math changes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const sw = readFileSync(new URL('../live-sw.js', import.meta.url), 'utf8');
const computeWeek = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
const weekClose = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');

const sheetFn = js.slice(
  js.indexOf('async function openWeeklySheet()'),
  js.indexOf('const heroWeeklyTarget'),
);
assert.ok(sheetFn.length > 0, 'openWeeklySheet body found');

const loadWeekFn = js.slice(
  js.indexOf('const loadWeekNumbers = async () => {'),
  js.indexOf('await loadWeekNumbers();'),
);
assert.ok(loadWeekFn.length > 0, 'loadWeekNumbers body found');

test('pins: live.js v69 / styles v53, service-worker cache tracks live.js', () => {
  assert.ok(html.includes('live.js?v=69'), 'live.html pins live.js v69');
  assert.ok(html.includes('styles.css?v=53'), 'live.html pins styles v53');
  assert.ok(sw.includes("CACHE = 'onbudget-live-v69'"), 'service-worker cache tracks the live.js pin');
  assert.ok(sw.includes('(v69)'), 'service-worker comment names the current pin');
});

// ---- Server: compute-week surfaces the override ----

test('compute-week: response carries override_cents, null when a stored snapshot wins', () => {
  assert.ok(computeWeek.includes('override_cents: overrideForUi,'), 'response includes override_cents');
  assert.ok(
    computeWeek.includes('const overrideForUi = (thisClose && thisClose.base_allowance_cents != null) ? null : overrideCents;'),
    'override is surfaced only when it actually drives B — a stored close snapshot nulls it',
  );
  assert.ok(computeWeek.includes('override_cents: the weekly_allowance_overrides value for the'), 'response shape is documented');
});

test('compute-week: an override still folds into B with T = 0 (money math untouched)', () => {
  assert.ok(computeWeek.includes(': overrideCents != null\n      ? overrideCents'), 'B is the override when one exists');
  assert.ok(computeWeek.includes(': overrideCents != null\n      ? 0\n      : tempSum;'), 'T is 0 when an override exists, else the legacy temp sum');
  assert.ok(!computeWeek.includes('overrideDelta'), 'the server does not compute a delta — it returns the raw override value');
});

test('week-close: a week closed with an override stores B = override, T = 0 as its snapshot', () => {
  assert.ok(weekClose.includes("B: snap && snap.base_allowance_cents != null ? snap.base_allowance_cents : overrideByWeek.has(ws) ? overrideByWeek.get(ws)! : household.base_allowance_cents,"), 'close stores the override as B');
  assert.ok(weekClose.includes("T: snap && snap.temp_increase_cents != null ? snap.temp_increase_cents : overrideByWeek.has(ws) ? 0 : tempSum(ws),"), 'close stores T = 0 for an override week');
});

// ---- Client: the delta derivation in loadWeekNumbers ----

test('loadWeekNumbers: override delta is derived from override_cents and the stored base, never for locked weeks', () => {
  assert.ok(loadWeekFn.includes("const overrideCents = Number.isInteger(r.override_cents) ? r.override_cents : null;"), 'override_cents is read, non-integers treated as absent');
  assert.ok(
    loadWeekFn.includes('const overrideDeltaCents = overrideCents != null && Number.isInteger(baseAllowanceCents) && !r.week_locked\n        ? overrideCents - baseAllowanceCents : 0;'),
    'delta is override minus stored base, and only for open weeks with a known base',
  );
  assert.ok(loadWeekFn.includes('overrideDeltaCents,'), 'the delta is stored on currentWeekData for the sheet');
});

// ---- Full data flow: compute-week response -> sheet rows ----

// Mirror of loadWeekNumbers' derivation (same conditions, same
// order) driven by a compute-week-shaped response.
function deriveWeekData(r, baseAllowanceCents) {
  const overrideCents = Number.isInteger(r.override_cents) ? r.override_cents : null;
  const overrideDeltaCents = overrideCents != null && Number.isInteger(baseAllowanceCents) && !r.week_locked
    ? overrideCents - baseAllowanceCents : 0;
  return {
    baseAvailableCents: r.base_available_cents,
    tempCents: r.temp_cents,
    carriedDebtCents: r.carried_debt_cents,
    chargesCents: r.charges_cents,
    availableCents: r.available_cents,
    weekLocked: !!r.week_locked,
    baseAllowanceCents,
    overrideDeltaCents,
  };
}

// Mirror of openWeeklySheet's row building (same gates, same order,
// same values). Values here are magnitudes: a decrease row shows
// the amount of the decrease, matching formatCents(-tempDelta).
function fmt(cents) { return `$${(cents / 100).toFixed(2)}`; }
function sheetRows(w) {
  const rows = [];
  const overrideDelta = w.overrideDeltaCents ?? 0;
  const tempDelta = overrideDelta !== 0 ? overrideDelta : (w.tempCents ?? 0);
  const hasTemp = tempDelta > 0;
  const hasTempDecrease = tempDelta < 0;
  const hasDebt = (w.carriedDebtCents ?? 0) > 0;
  const allowance = (w.baseAvailableCents ?? 0) + (w.tempCents ?? 0);
  if (Number.isInteger(w.baseAllowanceCents) && (hasTemp || hasTempDecrease || hasDebt)) rows.push(['Base allowance', fmt(w.baseAllowanceCents)]);
  if (hasTemp) rows.push(['Temporary increases', fmt(tempDelta)]);
  if (hasTempDecrease) rows.push(['Temporary decrease', fmt(-tempDelta)]);
  if (hasDebt) rows.push(['Carried debt', fmt(w.carriedDebtCents)]);
  rows.push(['Allowance', fmt(allowance)]);
  rows.push(['Spent', fmt(w.chargesCents)]);
  rows.push(['Balance', fmt(w.availableCents)]);
  return rows;
}

const rows = (response, base) => sheetRows(deriveWeekData(response, base));

test('data flow: override higher than base — the exact live case that failed', () => {
  // Base $375, override $475, no debt, no spending. The server
  // returns B = 47500 folded into base_available, temp_cents 0.
  assert.deepEqual(rows({
    base_available_cents: 47500, temp_cents: 0, carried_debt_cents: 0,
    charges_cents: 0, available_cents: 47500, week_locked: false, override_cents: 47500,
  }, 37500), [
    ['Base allowance', '$375.00'],
    ['Temporary increases', '$100.00'],
    ['Allowance', '$475.00'],
    ['Spent', '$0.00'],
    ['Balance', '$475.00'],
  ]);
});

test('data flow: override lower than base shows a Temporary decrease', () => {
  assert.deepEqual(rows({
    base_available_cents: 27500, temp_cents: 0, carried_debt_cents: 0,
    charges_cents: 0, available_cents: 27500, week_locked: false, override_cents: 27500,
  }, 37500), [
    ['Base allowance', '$375.00'],
    ['Temporary decrease', '$100.00'],
    ['Allowance', '$275.00'],
    ['Spent', '$0.00'],
    ['Balance', '$275.00'],
  ]);
});

test('data flow: override higher plus carried debt reconciles', () => {
  // Override $475, debt $100, spent $50: room is 475 − 100 = 375.
  assert.deepEqual(rows({
    base_available_cents: 37500, temp_cents: 0, carried_debt_cents: 10000,
    charges_cents: 5000, available_cents: 32500, week_locked: false, override_cents: 47500,
  }, 37500), [
    ['Base allowance', '$375.00'],
    ['Temporary increases', '$100.00'],
    ['Carried debt', '$100.00'],
    ['Allowance', '$375.00'],
    ['Spent', '$50.00'],
    ['Balance', '$325.00'],
  ]);
});

test('data flow: override lower plus carried debt reconciles, floored at $0', () => {
  // Override $275, debt $300: room is max(0, 275 − 300) = 0. The
  // rows suggest 375 − 100 − 300 = −25; the Allowance row shows
  // the $0 floor, the same convention as the existing debt rows.
  assert.deepEqual(rows({
    base_available_cents: 0, temp_cents: 0, carried_debt_cents: 30000,
    charges_cents: 0, available_cents: 0, week_locked: false, override_cents: 27500,
  }, 37500), [
    ['Base allowance', '$375.00'],
    ['Temporary decrease', '$100.00'],
    ['Carried debt', '$300.00'],
    ['Allowance', '$0.00'],
    ['Spent', '$0.00'],
    ['Balance', '$0.00'],
  ]);
});

test('data flow: normal week keeps exactly three rows', () => {
  assert.deepEqual(rows({
    base_available_cents: 37500, temp_cents: 0, carried_debt_cents: 0,
    charges_cents: 12000, available_cents: 25500, week_locked: false, override_cents: null,
  }, 37500), [
    ['Allowance', '$375.00'],
    ['Spent', '$120.00'],
    ['Balance', '$255.00'],
  ]);
});

test('data flow: override equal to the base changes nothing', () => {
  assert.deepEqual(rows({
    base_available_cents: 37500, temp_cents: 0, carried_debt_cents: 0,
    charges_cents: 0, available_cents: 37500, week_locked: false, override_cents: 37500,
  }, 37500), [
    ['Allowance', '$375.00'],
    ['Spent', '$0.00'],
    ['Balance', '$375.00'],
  ]);
});

test('data flow: legacy temp increase with no override still works', () => {
  assert.deepEqual(rows({
    base_available_cents: 37500, temp_cents: 5000, carried_debt_cents: 0,
    charges_cents: 0, available_cents: 42500, week_locked: false, override_cents: null,
  }, 37500), [
    ['Base allowance', '$375.00'],
    ['Temporary increases', '$50.00'],
    ['Allowance', '$425.00'],
    ['Spent', '$0.00'],
    ['Balance', '$425.00'],
  ]);
});

test('data flow: locked week is inert — an override in the response is ignored', () => {
  // The server nulls override_cents when a snapshot wins; this
  // case simulates a stale/mismatched response to prove the
  // client gate too — the override must not re-explain a locked
  // week, with or without debt.
  assert.deepEqual(rows({
    base_available_cents: 47500, temp_cents: 0, carried_debt_cents: 0,
    charges_cents: 0, available_cents: 47500, week_locked: true, override_cents: 47500,
  }, 37500), [
    ['Allowance', '$475.00'],
    ['Spent', '$0.00'],
    ['Balance', '$475.00'],
  ]);
  assert.deepEqual(rows({
    base_available_cents: 0, temp_cents: 0, carried_debt_cents: 40000,
    charges_cents: 0, available_cents: 0, week_locked: true, override_cents: 47500,
  }, 37500), [
    ['Base allowance', '$375.00'],
    ['Carried debt', '$400.00'],
    ['Allowance', '$0.00'],
    ['Spent', '$0.00'],
    ['Balance', '$0.00'],
  ]);
});

test('data flow: stored base unknown — no Base row and no override line', () => {
  // The delta cannot be computed without a base, so the sheet
  // shows the effective allowance with no explanation, as before.
  assert.deepEqual(rows({
    base_available_cents: 47500, temp_cents: 0, carried_debt_cents: 0,
    charges_cents: 0, available_cents: 47500, week_locked: false, override_cents: 47500,
  }, null), [
    ['Allowance', '$475.00'],
    ['Spent', '$0.00'],
    ['Balance', '$475.00'],
  ]);
});
