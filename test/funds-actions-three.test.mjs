// Funds-actions-three (owner choice, Nov 4, Option A): Record income
// moves OUT of the Funds actions card and INTO the Charity breakdown,
// admin-only. The actions card drops to exactly three buttons
// (Add / Spend / Request); the income form itself does not move, and
// its Back button still returns to Funds.
// Funds expand-in-place (owner approval, Nov 6, 2026): both
// breakdowns now render inside the expanded card, not a bottom
// sheet — openFundSheet / openCharitySheet are gone, replaced by
// fundExpandActions / charityExpandActions + toggleFundCard.
// Static tests only — no live data, no network, no money math. The
// secondary button treatment is deliberately untouched here (the
// light-blue deepening was NOT approved with Option A).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');

test('Funds actions row is exactly Add / Spend / Request, in order (now in the expanded Extra Fund card)', () => {
  assert.equal(html.includes('id="section-fund-actions"'), false);
  const actions = js.slice(js.indexOf('function fundExpandActions'), js.indexOf(": [{ label: 'Request Money'"));
  assert.deepEqual([...actions.matchAll(/label: '([^']+)'/g)].map((m) => m[1]), ['Add Money', 'Spend From Fund', 'Request Money']);
  assert.deepEqual([...actions.matchAll(/btnClass: '([^']+)'/g)].map((m) => m[1]), ['btn btn-primary', 'btn', 'btn btn-tertiary']);
  assert.deepEqual([...actions.matchAll(/result: '([^']+)'/g)].map((m) => m[1]), ['add', 'use', 'ask']);
});

test('Record income button is fully gone from the actions card', () => {
  assert.equal(html.includes('fundActionIncomeBtn'), false);
  assert.equal(js.includes('fundActionIncomeBtn'), false);
});

test('Charity expansion offers Record income for admin, via one shared toggle', () => {
  // Both entry points (Home card and Funds panel) share one toggle.
  assert.equal((js.match(/toggleFundCard\(/g) ?? []).length, 3, 'toggle called from click + keydown + definition-site guard');
  // No sheet opener or Charity sheet title remains anywhere.
  assert.equal(js.includes('openCharitySheet'), false);
  assert.equal(js.includes('openFundSheet'), false);
  assert.equal(js.includes("title: 'Charity · November 2026 Onward'"), false);
  // Admin-gated actions: Record income primary, Close grey tertiary.
  const actions = js.slice(js.indexOf('function charityExpandActions'), js.indexOf(": [{ label: 'Close'"));
  assert.deepEqual([...actions.matchAll(/label: '([^']+)'/g)].map((m) => m[1]), ['Record Income', 'Close']);
  assert.deepEqual([...actions.matchAll(/btnClass: '([^']+)'/g)].map((m) => m[1]), ['btn btn-primary', 'btn btn-tertiary']);
  // Rows (fund-sheet-button-rule, owner Nov 4): Available / Given / Total.
  assert.match(js, /\['Available', formatCents\(c\.remaining\)\]/);
  assert.match(js, /\['Given', formatCents\(c\.given\)\]/);
  assert.match(js, /\['Total', formatCents\(c\.remaining \+ c\.given\)\]/);
  assert.doesNotMatch(js, /\['Committed',/);
  assert.doesNotMatch(js, /\['Default rate',/);
  assert.doesNotMatch(js, /\['Period',/);
});

test('Choosing Record income opens the existing income form', () => {
  assert.match(js, /setFundForm\(result === 'record-income' \? 'income' : result\)/);
  // The form itself is untouched and still admin-gated.
  assert.ok(js.includes("formShown('section-charity-income', 'income')"));
});

test('Income form Back returns to Funds', () => {
  assert.ok(js.includes("$('charityIncomeBackBtn')?.addEventListener('click', () => setFundForm(null))"));
});

test('Member visibility in Funds actions is unchanged', () => {
  // Task 7: Add/Spend stay admin-only, Request stays for everyone —
  // now as the expansion's member branch (Request only, tertiary); no
  // income button exists for either role to see in the fund card.
  assert.ok(js.includes(": [{ label: 'Request Money', result: 'ask', btnClass: 'btn btn-tertiary' }]"));
  assert.ok(js.includes("setBtn('moreFundActivityBtn', !!isAdmin)"));
  assert.ok(js.includes("setBtn('moreReviewBtn', !!isAdmin)"));
  assert.ok(js.includes("setBtn('moreSavingsBtn', true)"));
});

test('Extra Fund expansion rows are unchanged; no sheet Close remains', () => {
  // One detail renderer serves both surfaces (Home + Funds); rows
  // are unchanged and there is no sheet Close button any more —
  // the fund card closes by tapping the card again or the other card.
  assert.match(js, /function fundExpandDetailHtml\(kind, data, isAdmin, withActions = true\)/);
  assert.match(js, /fundBreakdownRows\(data\)/);
  assert.doesNotMatch(js, /showSheet\(\{ title: 'Extra Fund'/);
  const fundActions = js.slice(js.indexOf('function fundExpandActions'), js.indexOf('function charityExpandActions'));
  assert.doesNotMatch(fundActions, /'Close'/, 'fund card has no Close button');
});

test('Secondary button treatment is untouched', () => {
  // The light-blue deepening was NOT approved with Option A: the
  // secondary fill and text stay exactly as they were.
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{ background: #bfdbfe; border: 0; color: #0f172a;/);
});
