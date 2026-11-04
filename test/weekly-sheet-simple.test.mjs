// Weekly-sheet-simple (owner, Nov 3, 9:53 PM, item 7): the Weekly
// popup opens with ONLY the basic stuff — Left, Spent, Allowance —
// everything else moves behind the "Show how this adds up"
// disclosure, and a "Show transactions" button below opens the
// week's transactions. Static tests only — no live data, no network,
// no money math. Values and formatting are unchanged; only which
// rows are visible on open changes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

// Slice the openWeeklySheet body: from its definition to the hero
// target handlers that follow it.
const sheetFn = js.slice(
  js.indexOf('async function openWeeklySheet()'),
  js.indexOf('const heroWeeklyTarget'),
);
assert.ok(sheetFn.length > 0, 'openWeeklySheet body found');

// The visible-rows array: from "const weeklyRows" to the closing "];".
const visible = sheetFn.slice(
  sheetFn.indexOf('const weeklyRows = ['),
  sheetFn.indexOf('];', sheetFn.indexOf('const weeklyRows = [')),
);
// The disclosure rows: the showSheet disclosure block, plus the
// weeklyDetailRows array that is spread into it.
const disclosure = sheetFn.slice(sheetFn.indexOf('disclosure: {'));
const detailRows = sheetFn.slice(
  sheetFn.indexOf('const weeklyDetailRows = ['),
  sheetFn.indexOf('];', sheetFn.indexOf('const weeklyDetailRows = [')),
);

test('Weekly sheet visible rows are exactly Left, Spent, Allowance, in order', () => {
  const labels = [...visible.matchAll(/\['([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(labels, ['Left', 'Spent', 'Allowance']);
});

test('no other figure row is visible on open', () => {
  for (const label of [
    'Dated this week',
    'Late charges from earlier locked weeks',
    'Carried debt',
    'Temporary increase',
    'Outgoing debt',
    'Week status',
    'Pending refunds excluded',
    'Base spending room',
  ]) {
    assert.equal(visible.includes(`'${label}'`), false, `${label} must not be visible`);
  }
});

test('every moved row exists only inside the disclosure', () => {
  // Moved rows live in weeklyDetailRows, which is spread into the
  // disclosure; Outgoing debt lives in the disclosure's pre-existing
  // rows. None of them is in the visible rows (checked above).
  assert.match(disclosure, /\.\.\.weeklyDetailRows/);
  for (const label of [
    'Dated this week',
    'Late charges from earlier locked weeks',
    'Carried debt',
    'Temporary increase',
    'Week status',
    'Pending refunds excluded',
  ]) {
    assert.equal(detailRows.includes(`'${label}'`), true, `${label} must be in the disclosure rows`);
  }
  // Conditional rows keep their conditions.
  assert.match(sheetFn, /w\.weekLocked \? \[\['Week status'/);
  assert.match(sheetFn, /pendingRefundExcludedCents \?\? 0\) > 0 \? \[\['Pending refunds excluded'/);
  assert.match(sheetFn, /lastSpentBreakdown \? \[\['Dated this week'/);
});

test('disclosure keeps its pre-existing rows, Outgoing debt not duplicated', () => {
  for (const label of ['Base spending room', 'Left', 'Outgoing debt']) {
    assert.equal(disclosure.includes(`'${label}'`), true, `${label} stays in the disclosure`);
  }
  assert.equal((disclosure.match(/'Outgoing debt'/g) ?? []).length, 1);
});

test('Show transactions button exists and opens the week-filtered Transactions view', () => {
  assert.match(sheetFn, /extraAction: \{ label: 'Show transactions', result: 'show-transactions' \}/);
  assert.match(sheetFn, /if \(weeklyResult === 'show-transactions'\) \{\s*txWeekOnly = true;\s*showView\('purchases'\);\s*await refresh\(\);/);
  // Focus lands on the Filters button at the top of the Transactions
  // view, next to the "This week" pill and count line.
  assert.match(sheetFn, /document\.getElementById\('txFiltersToggle'\)\?\.focus\(\)/);
  // No new filter mode: the existing week flag + render path only.
  assert.equal(sheetFn.includes('txWeekFilterMode'), false);
});

test('generic sheet renders an extra primary action without duplicating button treatment', () => {
  assert.match(js, /extraAction = null/);
  assert.match(js, /id="sheetExtra"/);
  assert.match(js, /querySelector\('#sheetExtra'\)\?\.addEventListener\('click', \(\) => done\(extraAction\.result/);
  // With an extra action, confirm drops to the plain treatment.
  assert.match(js, /class="btn\$\{extraAction \? '' : ' btn-primary'\}"/);
});

test('Charity and Extra Fund sheets are untouched by this change', () => {
  assert.match(js, /title: 'Extra Fund', rows: fundBreakdownRows\(f\), confirmLabel: 'Close'/);
  assert.match(js, /title: 'Charity · November 2026 onward', rows: charityBreakdownRows\(c\), confirmLabel: 'Close'/);
  // The extra action is used exactly once: the Weekly sheet.
  assert.equal((js.match(/extraAction: \{/g) ?? []).length, 1);
});

test('hero number remains the only Weekly entry point, numbers-only face', () => {
  assert.match(js, /heroWeeklyTarget\?\.addEventListener\('click', openWeeklySheet\)/);
  assert.equal(js.includes('data-home-card="weekly"'), false);
});
