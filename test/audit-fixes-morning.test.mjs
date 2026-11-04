// Audit-fixes-morning (owner approval, Nov 4, 2026, to the overnight
// audit's decision list): B1 held button removed, A1 btn-mid to ink,
// C3 Disconnect top-aligned, C2 plain-language account types, B2
// duplicate Change password removed (+ stale Settings intro sentence).
// Static tests only — no live data, no network, no money math. The
// mapping test executes the shipped plainAccountType function itself
// (sliced out of live.js), so it tests the real code, not a copy.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

test('B1: Funds Held-for-review button and wrap are gone; Review card stays the single opener', () => {
  assert.equal(html.includes('id="fundHeldLinkWrap"'), false);
  assert.equal(html.includes('id="fundHeldLinkBtn"'), false);
  assert.equal(html.includes('Held money is waiting for the admin'), false);
  assert.equal(css.includes('#fundHeldLinkWrap'), false);
  // The Review card's own opener is untouched.
  assert.ok(html.includes('id="section-fund-review"'));
  assert.ok(html.includes('<summary id="reviewSummary">Open review</summary>'));
  // The held amount still lives in the fund breakdown sheet row.
  assert.match(js, /\['Held for review',/);
  // Guarded JS references remain as no-ops, never unguarded throws.
  assert.match(js, /getElementById\('fundHeldLinkWrap'\)\?/);
  assert.match(js, /\$\('fundHeldLinkBtn'\)\?\.addEventListener/);
});

test('A1: btn-mid is dark ink, distinct from primary, secondary, and tertiary grey', () => {
  const rule = css.match(/body\.live #view-app \.btn-mid, body\.live \.btn-mid \{[^}]*\}/);
  assert.ok(rule, 'btn-mid rule found');
  assert.match(rule[0], /background: #0f172a/);
  assert.match(rule[0], /color: #fff/);
  assert.doesNotMatch(rule[0], /#3b82f6/);
  // Not grey either: it must not collide with the grey tertiary Ask button.
  assert.doesNotMatch(rule[0], /#e5e7eb/);
  // The other three levels are unchanged.
  assert.match(css, /body\.live #view-app \.btn-primary, body\.live \.btn-primary \{[^}]*background: #2f6bff/);
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{[^}]*background: #bfdbfe/);
  assert.match(css, /body\.live #view-app \.btn-tertiary, body\.live \.btn-tertiary \{[^}]*background: #e5e7eb/);
  // Detail-row Use Extra Fund (btn-mid/ink) still sits between grey
  // Mark as charity and secondary Reclassify in the row builder.
  assert.ok(js.includes('class="btn btn-small btn-tertiary" data-mark-charity='));
  assert.ok(js.includes('class="btn btn-small btn-mid"'));
});

test('C3: Disconnect button inside .bank-row is top-aligned; row and logo rules unchanged', () => {
  const rule = css.match(/body\.live \.bank-row \.btn-danger \{[^}]*\}/);
  assert.ok(rule, 'bank-row Disconnect rule found');
  assert.match(rule[0], /align-self: flex-start/);
  const row = css.match(/body\.live \.bank-row \{[^}]*\}/);
  assert.ok(row, 'bank-row rule found');
  assert.match(row[0], /align-items: center/);
  const logo = css.match(/body\.live \.bank-row \.bank-logo, body\.live \.bank-row \.bank-logo-tile \{[^}]*\}/);
  assert.ok(logo, 'bank-row logo rule found');
  assert.match(logo[0], /align-self: flex-start/);
  // No row-level alignment change and no merchant-tile rule.
  assert.doesNotMatch(css, /\.tx-icon[^{]*\{[^}]*align-self: flex-start/);
});

test('C2: plain-language account types, executed from the shipped function', () => {
  const fnSrc = js.slice(js.indexOf('function plainAccountType'), js.indexOf('// Transaction state pill'));
  assert.ok(fnSrc.includes('Credit card') && fnSrc.includes('Bank account'), 'mapping function found');
  const plainAccountType = new Function(`${fnSrc}; return plainAccountType;`)();
  assert.equal(plainAccountType('credit', 'credit card'), 'Credit card');
  assert.equal(plainAccountType('depository', 'checking'), 'Checking');
  assert.equal(plainAccountType('depository', 'savings'), 'Savings');
  assert.equal(plainAccountType('depository', 'money market'), 'Bank account');
  assert.equal(plainAccountType('loan', 'personal'), 'Loan');
  assert.equal(plainAccountType('investment', 'brokerage'), 'Investment');
  assert.equal(plainAccountType('other', 'other'), '');
  assert.equal(plainAccountType(null, null), '');
  assert.equal(plainAccountType('CREDIT', 'CREDIT CARD'), 'Credit card');
  // The render line uses the single label, never the raw Plaid fields.
  assert.match(js, /const typeLabel = plainAccountType\(acct\.type, acct\.subtype\)/);
  assert.doesNotMatch(js, /` · \$\{acct\.type\}`/);
  assert.doesNotMatch(js, /` \(\$\{acct\.subtype\}\)`/);
});

test('B2: duplicate Change password deleted from the Account card; Profile card keeps its own', () => {
  assert.equal(html.includes('id="settingsPasswordBtn"'), false);
  assert.ok(html.includes('id="profilePasswordBtn"'));
  const acct = html.slice(html.indexOf('id="section-settings-account"'), html.indexOf('id="settingsDeleteBtn"'));
  assert.match(acct, /Invite code and account deletion live here now/);
  assert.doesNotMatch(acct, /password/);
  // Profile card handler untouched.
  assert.match(js, /getElementById\('profilePasswordBtn'\)\?\.addEventListener\('click', changePasswordFlow\)/);
});

test('Stale Settings intro sentence deleted', () => {
  assert.equal(html.includes('Bank and email connections moved here from Funds'), false);
  assert.ok(html.includes('id="settingsIntro"'));
});
