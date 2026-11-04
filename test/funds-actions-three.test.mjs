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

test('Funds actions row is exactly Add / Use / Ask, in order', () => {
  const row = html.slice(html.indexOf('id="section-fund-actions"'), html.indexOf('id="fundTopupsDisclosure"'));
  assert.deepEqual(
    [...row.matchAll(/id="(fundAction\w+)"/g)].map((m) => m[1]),
    ['fundActionAddBtn', 'fundActionUseBtn', 'fundActionAskBtn'],
  );
  assert.ok(row.includes('<button class="btn btn-primary" id="fundActionAddBtn"'));
  assert.ok(row.includes('<button class="btn" id="fundActionUseBtn"'));
  assert.ok(row.includes('<button class="btn btn-tertiary" id="fundActionAskBtn"'));
});

test('Record income button is fully gone from the actions card', () => {
  assert.equal(html.includes('fundActionIncomeBtn'), false);
  assert.equal(js.includes('fundActionIncomeBtn'), false);
});

test('Charity sheet offers Record income for admin, via one shared opener', () => {
  // Both entry points (Home card and Funds panel) call the same opener.
  assert.equal((js.match(/await openCharitySheet\(\)/g) ?? []).length, 2);
  // No other direct Charity sheet remains outside the opener.
  const charitySheets = (js.match(/title: 'Charity · November 2026 onward'/g) ?? []).length;
  assert.equal(charitySheets, 1, 'only the shared opener renders the Charity sheet');
  // Admin-gated extra action, Weekly-sheet precedent (primary button,
  // Close second — the sheet renderer handles that ordering).
  assert.match(openerBody, /household\.role === 'admin'/);
  assert.match(openerBody, /extraAction: isAdmin \? \{ label: 'Record income', result: 'record-income' \} : null/);
  assert.match(openerBody, /confirmLabel: 'Close'/);
  // Rows unchanged: Remaining, Committed, Given, Default rate, Period.
  assert.match(js, /\['Remaining',/);
  assert.match(js, /\['Committed', formatCents\(c\.committed\)\]/);
  assert.match(js, /\['Given', formatCents\(c\.given\)\]/);
  assert.match(js, /\['Default rate',/);
  assert.match(js, /\['Period', 'November 2026 onward'\]/);
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
  // Add/Use stay admin-only, Ask stays for everyone; no income button
  // exists for either role to see.
  assert.ok(js.includes("setBtn('fundActionAddBtn', !!isAdmin)"));
  assert.ok(js.includes("setBtn('fundActionUseBtn', !!isAdmin)"));
  assert.ok(js.includes("setBtn('fundActionAskBtn', true)"));
});

test('Extra Fund sheet is untouched', () => {
  assert.equal((js.match(/title: 'Extra Fund', rows: fundBreakdownRows\(f\), confirmLabel: 'Close'/g) ?? []).length, 2);
});

test('Secondary button treatment is untouched', () => {
  // The light-blue deepening was NOT approved with Option A: the
  // secondary fill and text stay exactly as they were.
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{ background: #bfdbfe; border: 0; color: #1e40af;/);
});
