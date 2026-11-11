// Weekly-sheet-trim (owner correction, Nov 3, ~9:59 PM, supersedes
// the PR #21 disclosure design), as narrowed by weekly-left-only
// (owner approval, Nov 3, ~11:20 PM): the Weekly popup contains
// EXACTLY one row — Left — plus the "Show Transactions" button.
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

// The rows-building block: from "const weeklyRows = [];" to the
// Unlinked-refunds push that follows the three base rows.
const visible = sheetFn.slice(
  sheetFn.indexOf('const weeklyRows = [];'),
  sheetFn.indexOf("if (unlinkedExcess > 0) weeklyRows.push"),
);

test('Weekly sheet rows are Allowance, Spent, Balance — plus reconciliation rows when debt/temp changes the number', () => {
  // Send-live-bundle supersedes Left-only. Three rows is the normal
  // week. R6-NEW-P1-1: when carried debt or a temporary increase
  // changes the number, Base allowance / Temporary increases /
  // Carried debt lines appear above the three base rows, so a $0
  // allowance explains itself instead of reading as a bug.
  // Temp-override reconciliation (Nov 11, 2026): a lower override
  // shows a Temporary decrease row in the same position.
  const labels = [...visible.matchAll(/weeklyRows\.push\(\['([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(labels, ['Base allowance', 'Temporary increases', 'Temporary decrease', 'Carried debt', 'Allowance', 'Spent', 'Balance']);
  assert.ok(visible.includes("weeklyRows.push(['Balance', formatCents(w.availableCents)])"));
  assert.ok(visible.includes("weeklyRows.push(['Spent', formatCents(w.chargesCents)])"));
});

test('no detail row appears anywhere in the Weekly sheet', () => {
  // R6-NEW-P1-1: 'Carried debt' and 'Temporary increases' are now
  // legitimate reconciliation rows (they appear only when debt or
  // temp changes the number), so they are no longer forbidden here.
  // Same for 'Temporary decrease' (Nov 11, 2026: a lower override).
  for (const label of [
    'Dated this week',
    'Late charges from earlier locked weeks',
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
  assert.match(sheetFn, /extraAction: \{ label: 'Show Transactions', result: 'show-transactions' \}/);
  // R6-NEW-P1-2: the shortcut clears a leftover date range (a
  // Past-Weeks range would AND with This week to an empty list)
  // and resets the page limit before opening the view.
  assert.match(sheetFn, /if \(weeklyResult === 'show-transactions'\) \{\s*txWeekOnly = true;[\s\S]*?txFromDate = '';\s*txToDate = '';\s*resetTxLimit\(\);\s*showView\('purchases'\);\s*await refresh\(\);/);
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
  // NEW-P2-5 (Nov 9, 2026): the dead `actions` branch is deleted, so the
  // confirm ternary is now extraAction-only.
  assert.match(js, /class="btn\$\{extraAction \? ' btn-tertiary' : ' btn-primary'\}"/);
});

test('Extra Fund / Charity cards expand in place; no sheet opener remains; rows unchanged', () => {
  // Funds expand-in-place (owner, Nov 6): neither card calls showSheet
  // any more — the breakdown rows render inside the expanded card.
  assert.equal(js.includes('openFundSheet'), false);
  assert.equal(js.includes('openCharitySheet'), false);
  assert.doesNotMatch(js, /showSheet\(\{ title: 'Extra Fund'/);
  assert.doesNotMatch(js, /title: 'Charity · November 2026 Onward'/);
  assert.match(js, /fundExpandDetailHtml\(kind, kind === 'fund' \? currentFundData : currentCharityData/);
  // The extra action is now used exactly once: Weekly sheet
  // (Show transactions). Charity Record income is a button in the
  // expanded card, not a sheet extra action.
  assert.equal((js.match(/extraAction:/g) ?? []).length, 1);
});

test('hero number remains the only Weekly entry point, numbers-only face', () => {
  assert.match(js, /heroWeeklyTarget\?\.addEventListener\('click', openWeeklySheet\)/);
  assert.equal(js.includes('data-home-card="weekly"'), false);
});
