// Fund-sheet-button-rule (owner, Nov 4, 2026): Extra Fund and Charity
// breakdown sheets are exactly three rows each, and two-button rows
// are primary + grey tertiary (pale reserved for three-button middles).
// Static tests only — no live data, no network, no money math beyond
// executing the shipped row functions themselves (sliced out of
// live.js, as the plainAccountType test does), so the arithmetic is
// tested as real code, not a copy.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { formatCents } from '../engine.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

// The row functions read the free variable `household` and the
// imported formatCents; both are supplied to the sliced code.
const fundSrc = js.slice(js.indexOf('function fundBreakdownRows'), js.indexOf('function charityBreakdownRows'));
const charitySrc = js.slice(js.indexOf('function charityBreakdownRows'), js.indexOf('// Button-card-fix: Funds balance cards'));
const fundBreakdownRows = new Function('household', 'formatCents', `${fundSrc}; return fundBreakdownRows;`);
const charityBreakdownRows = new Function('household', 'formatCents', `${charitySrc}; return charityBreakdownRows;`);

// --- Change A: Extra Fund sheet ---------------------------------------

test('A: fund sheet is exactly Available / Pending / Total (screenshot arithmetic)', () => {
  const fund = fundBreakdownRows({ role: 'admin' }, formatCents);
  // Screenshot numbers: available $67.11, pending releases $0.00,
  // held $375.00 → Pending $375.00, Total $442.11.
  const rows = fund({ available: 6711, pending: 0, heldTotal: 37500 });
  assert.deepEqual(rows, [
    ['Spendable available', '$67.11'],
    ['Pending', '$375.00'],
    ['Total', '$442.11'],
  ]);
});

test('A: fund Pending folds pending releases and held weeks; member wording kept', () => {
  const admin = fundBreakdownRows({ role: 'admin' }, formatCents);
  assert.deepEqual(admin({ available: 10000, pending: 2500, heldTotal: 1500 }), [
    ['Spendable available', '$100.00'],
    ['Pending', '$40.00'],
    ['Total', '$140.00'],
  ]);
  const member = fundBreakdownRows({ role: 'member' }, formatCents);
  assert.equal(member({ available: 10000, pending: 0, heldTotal: 0 })[0][0], 'Available to request');
  // Missing heldTotal (old callers) folds as zero, never NaN.
  assert.deepEqual(admin({ available: 5000, pending: 2000 }), [
    ['Spendable available', '$50.00'],
    ['Pending', '$20.00'],
    ['Total', '$70.00'],
  ]);
});

test('A: fund Home card aria-label carries the folded Pending, no owed-back mention', () => {
  assert.ok(js.includes('const pendingAll = pending + heldTotal;'));
  const label = js.slice(js.indexOf('const pendingAll'), js.indexOf('const pendingAll') + 500);
  assert.match(label, /pendingAll\)\} pending, show breakdown/);
  assert.doesNotMatch(label, /owed back/);
});

// --- Change C: Charity sheet ------------------------------------------

test('C: charity sheet is exactly Available / Given / Total, rows add up', () => {
  const charity = charityBreakdownRows({ role: 'admin' }, formatCents);
  assert.deepEqual(charity({ remaining: 5000, given: 3000, committed: 8000 }), [
    ['Available', '$50.00'],
    ['Given', '$30.00'],
    ['Total', '$80.00'],
  ]);
});

test('C: charity negative remaining stays a signed number and still adds up', () => {
  const charity = charityBreakdownRows({ role: 'admin' }, formatCents);
  // Remaining -$20.00 + given $120.00 = total $100.00 (the old Committed).
  const rows = charity({ remaining: -2000, given: 12000, committed: 10000 });
  assert.deepEqual(rows, [
    ['Available', '-$20.00'],
    ['Given', '$120.00'],
    ['Total', '$100.00'],
  ]);
  assert.doesNotMatch(rows.map(([label]) => label).join(','), /Ahead by/);
});

test('C: charity sheet title keeps the period; Record income action stays; rate card stays', () => {
  assert.match(js, /title: 'Charity · November 2026 onward', rows: charityBreakdownRows\(c\), extraAction: isAdmin \? \{ label: 'Record income', result: 'record-income' \} : null/);
  assert.ok(html.includes('id="charityRateCurrent"'), 'Funds Charity income & rate card keeps the default rate line');
});

// --- Change B: two-button rule -----------------------------------------

test('B: every audited two-button row uses grey tertiary for its non-primary button', () => {
  const pairs = [
    ['sign-in Create account', /id="signUpBtn" class="btn btn-tertiary"/],
    ['sign-up Back', /id="authNameBackBtn" class="btn btn-tertiary"/],
    ['household choice Join', /id="joinHouseholdBtn" class="btn btn-tertiary btn-block"/],
    ['household naming Back', /id="householdNameBackBtn" class="btn btn-tertiary"/],
    ['manual Cancel', /class="btn btn-tertiary" id="manualCancelBtn"/],
    ['Transactions Filters', /id="txFiltersToggle" class="btn btn-tertiary"/],
    ['email Check now', /id="pollEmailBtn" class="btn btn-tertiary"/],
    ['charity income Cancel correction', /class="btn btn-tertiary" id="charityIncomeCancelBtn"/],
    ['history Clear filter', /class="btn btn-tertiary" id="historyFilterClearBtn"/],
    ['dedupe Separate', /sepBtn\.className = 'btn btn-small btn-tertiary'/],
  ];
  for (const [name, pattern] of pairs) {
    const hay = pattern.source.includes('sepBtn') ? js : html;
    assert.match(hay, pattern, `two-button row not grey: ${name}`);
  }
});

test('B: sheet buttons follow the two-button rule; single-button sheets keep primary Close', () => {
  // Confirm is tertiary exactly when an extra action is present
  // (Weekly / Charity sheets: primary action + grey Close); the
  // no-extra path keeps the primary confirm, so single-button
  // sheets (alerts, fund sheet) still close on a primary button.
  assert.match(js, /<button class="btn\$\{actions \? ' btn-quiet' : extraAction \? ' btn-tertiary' : ' btn-primary'\}" type="button" id="sheetConfirm">/);
  // Cancel moved to the sheet top (native-style-live bottom sheet):
  // a quiet top-left Cancel, not a bottom button, same semantics.
  assert.match(js, /<button class="sheet-top-cancel" type="button" id="sheetCancelTop">/);
});

test('B: three-button middles still pale; pale definition untouched', () => {
  // Task 7: Funds actions (Add primary, Use plain pale middle, Ask
  // tertiary) live in the Extra Fund sheet, not a card.
  assert.match(js, /label: 'Add money', result: 'add', btnClass: 'btn btn-primary'/);
  assert.match(js, /label: 'Use fund money', result: 'use', btnClass: 'btn'/);
  assert.match(js, /label: 'Ask for fund money', result: 'ask', btnClass: 'btn btn-tertiary'/);
  // Filters: Apply primary, Reset plain (pale middle), Cancel tertiary.
  assert.match(html, /class="btn btn-primary" id="txFiltersApplyBtn"/);
  assert.match(html, /class="btn" id="txFiltersResetBtn"/);
  assert.match(html, /class="btn btn-tertiary" id="txFiltersCancelBtn"/);
  // Connect bank: Connect primary, Sync plain (pale middle), Enable tertiary.
  assert.match(html, /id="connectBankBtn" class="btn btn-primary"/);
  assert.match(html, /id="syncBankBtn" class="btn"/);
  assert.match(html, /id="registerWebhookBtn" class="btn btn-tertiary"/);
  // The pale fill itself is not redefined by this branch.
  assert.ok(css.includes('#bfdbfe'), 'pale secondary fill must still exist for three-button middles');
});

test('B: deliberately untouched rows — hero sync, detail rows, quiet Decline, + popup', () => {
  assert.match(html, /class="btn hero-sync-btn" id="homeSyncBtn"/);
  // Send-live-bundle: detail rows are one Actions line now; the
  // old Exclude/Use Fund buttons are gone (see send-live-bundle).
  assert.ok(js.includes('data-tx-actions='), 'detail Actions line present');
  assert.equal(js.includes('data-exclude='), false, 'detail Exclude gone');
  assert.ok(js.includes('class="btn btn-small btn-quiet" data-decline='), 'request Decline stays quiet, not pale');
  assert.ok(html.includes('id="addOptionPurchaseBtn"'), '+ popup options untouched');
});
