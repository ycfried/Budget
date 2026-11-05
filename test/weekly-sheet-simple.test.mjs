// Weekly-sheet-trim (owner correction, Nov 3, ~9:59 PM, supersedes
// the PR #21 disclosure design), as narrowed by weekly-left-only
// (owner approval, Nov 3, ~11:20 PM): the Weekly popup contains
// EXACTLY one row — Left — plus the "Show transactions" button.
// Spent and Allowance were removed from the popup: balances, not
// spent totals, are what shows, and allowance lives in Settings
// for the admin. The "Show how this adds up" disclosure and every
// detail row it held are GONE from the Weekly sheet — not hidden
// behind a tap, not moved elsewhere in the sheet. Static tests only
// — no live data, no network, no money math. Values and formatting
// are unchanged; only the sheet's contents change.
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

test('Weekly sheet visible rows are exactly Allowance, Spent, Balance', () => {
  // Send-live-bundle supersedes Left-only.
  const labels = [...visible.matchAll(/\['([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(labels, ['Allowance', 'Spent', 'Balance']);
});

test('no detail row appears anywhere in the Weekly sheet', () => {
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
    assert.equal(sheetFn.includes(`'${label}'`), false, `${label} must not be in the Weekly sheet`);
  }
});

test('no disclosure element exists in the Weekly sheet at all', () => {
  assert.equal(sheetFn.includes('disclosure:'), false, 'no disclosure passed to showSheet');
  assert.equal(sheetFn.includes('Show how this adds up'), false, 'no disclosure label');
  assert.equal(sheetFn.includes('weeklyDetailRows'), false, 'no detail-rows array');
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
  // With an extra action, confirm drops to the grey tertiary
  // treatment (fund-sheet-button-rule, owner Nov 4: two-button rows
  // are primary + grey, never pale).
  assert.match(js, /class="btn\$\{actions \? ' btn-quiet' : extraAction \? ' btn-tertiary' : ' btn-primary'\}"/);
});

test('Extra Fund / Charity sheet openers keep their call shapes; rows changed by fund-sheet-button-rule', () => {
  assert.match(js, /showSheet\(\{ title: 'Extra Fund', rows: fundBreakdownRows\(f\), actions, confirmLabel: 'Close' \}\)/);
  // Funds-actions-three (owner choice, Nov 4, Option A): the Charity
  // sheet keeps its title, rows, and Close label, and gains exactly
  // the admin-gated Record income extra action — nothing else.
  assert.match(js, /title: 'Charity · November 2026 Onward', rows: charityBreakdownRows\(c\), extraAction: isAdmin \? \{ label: 'Record income', result: 'record-income' \} : null, confirmLabel: 'Close'/);
  // The extra action is now used exactly twice: Weekly sheet
  // (Show transactions) and Charity sheet (Record income).
  assert.equal((js.match(/extraAction:/g) ?? []).length, 2);
});

test('hero number remains the only Weekly entry point, numbers-only face', () => {
  assert.match(js, /heroWeeklyTarget\?\.addEventListener\('click', openWeeklySheet\)/);
  assert.equal(js.includes('data-home-card="weekly"'), false);
});
