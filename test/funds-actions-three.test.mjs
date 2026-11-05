// Funds-actions-three (owner choice, Nov 4, Option A): Record income
// moves OUT of the Funds actions card and INTO the Charity breakdown
// sheet, admin-only. The actions card drops to exactly three buttons
// (Add / Use / Ask); the income form itself does not move, and its
// Back button still returns to the three-button actions card.
// Static tests only — no live data, no network, no money math. The
// secondary button treatment is deliberately untouched here (the
// light-blue deepening was NOT approved with Option A).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');

const opener = js.slice(js.indexOf('async function openCharitySheet()'));
assert.ok(opener.length > 0, 'openCharitySheet exists');
const openerBody = opener.slice(0, opener.indexOf('\n}\n') + 3);

test('Funds actions row is exactly Add / Use / Ask, in order (now in the Extra Fund sheet)', () => {
  assert.equal(html.includes('id="section-fund-actions"'), false);
  const sheet = js.slice(js.indexOf('async function openFundSheet'), js.indexOf(": [{ label: 'Ask for fund money'"));
  assert.deepEqual([...sheet.matchAll(/label: '([^']+)'/g)].map((m) => m[1]), ['Add money', 'Use fund money', 'Ask for fund money']);
  assert.deepEqual([...sheet.matchAll(/btnClass: '([^']+)'/g)].map((m) => m[1]), ['btn btn-primary', 'btn', 'btn btn-tertiary']);
});

test('Record income button is fully gone from the actions card', () => {
  assert.equal(html.includes('fundActionIncomeBtn'), false);
  assert.equal(js.includes('fundActionIncomeBtn'), false);
});

test('Charity sheet offers Record income for admin, via one shared opener', () => {
  // Both entry points (Home card and Funds panel) call the same opener.
  assert.equal((js.match(/await openCharitySheet\(\)/g) ?? []).length, 2);
  // No other direct Charity sheet remains outside the opener.
  const charitySheets = (js.match(/title: 'Charity · November 2026 Onward'/g) ?? []).length;
  assert.equal(charitySheets, 1, 'only the shared opener renders the Charity sheet');
  // Admin-gated extra action, Weekly-sheet precedent (primary button,
  // Close second — the sheet renderer handles that ordering).
  assert.match(openerBody, /household\.role === 'admin'/);
  assert.match(openerBody, /extraAction: isAdmin \? \{ label: 'Record income', result: 'record-income' \} : null/);
  assert.match(openerBody, /confirmLabel: 'Close'/);
  // Rows (fund-sheet-button-rule, owner Nov 4): Available / Given / Total.
  assert.match(js, /\['Available', formatCents\(c\.remaining\)\]/);
  assert.match(js, /\['Given', formatCents\(c\.given\)\]/);
  assert.match(js, /\['Total', formatCents\(c\.remaining \+ c\.given\)\]/);
  assert.doesNotMatch(js, /\['Committed',/);
  assert.doesNotMatch(js, /\['Default rate',/);
  assert.doesNotMatch(js, /\['Period',/);
});

test('Choosing Record income opens the existing income form', () => {
  assert.match(openerBody, /if \(result === 'record-income'\) setFundForm\('income'\)/);
  // The form itself is untouched and still admin-gated.
  assert.ok(js.includes("formShown('section-charity-income', 'income')"));
});

test('Income form Back returns to the three-button actions card', () => {
  assert.ok(js.includes("$('charityIncomeBackBtn')?.addEventListener('click', () => setFundForm(null))"));
});

test('Member visibility in Funds actions is unchanged', () => {
  // Task 7: Add/Use stay admin-only, Ask stays for everyone — now
  // as the sheet's member branch (Ask only, tertiary); no income
  // button exists for either role to see.
  assert.ok(js.includes(": [{ label: 'Ask for fund money', result: 'ask', btnClass: 'btn btn-tertiary' }]"));
  assert.ok(js.includes("setBtn('moreFundActivityBtn', !!isAdmin)"));
  assert.ok(js.includes("setBtn('moreReviewBtn', !!isAdmin)"));
  assert.ok(js.includes("setBtn('moreSavingsBtn', true)"));
});

test('Extra Fund sheet rows and Close are untouched; only actions were added', () => {
  // Task 7: one sheet function now serves both openers (Home
  // read-only, Funds with actions); rows and Close are unchanged.
  assert.ok(js.includes('await openFundSheet(false)'));
  assert.ok(js.includes('await openFundSheet(true)'));
  assert.ok(js.includes("showSheet({ title: 'Extra Fund', rows: fundBreakdownRows(f), actions, confirmLabel: 'Close' })"));
});

test('Secondary button treatment is untouched', () => {
  // The light-blue deepening was NOT approved with Option A: the
  // secondary fill and text stay exactly as they were.
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{ background: #bfdbfe; border: 0; color: #0f172a;/);
});
