// Refund classification fix (Nov 5, 2026, owner-approved) + design
// items 2, 3, 4 (owner YES Nov 5, 11:41 AM).
// Run with: node --test test/refund-classification-fix.test.mjs
// All amounts are integer cents. $1 = 100.
//
// The week Nov 1–7, 2026, real shape (live probe Nov 5, 11:04 AM):
// charges $3,949.52 (19 provisional $255.66 + 16 verified $3,693.86),
// four "refund" rows totalling -$8,521.76. Owner confirmed:
//   MOBILE CHECK DEPOSIT -$7,000.00 = income
//   ONLINE TRANSFER / PAYMENT: CREDIT -$1,012.79 = CC payment
//   PRIME STRATEGIC CORPORATION -$350.00 = transfer (friend's money)
//   NORDSTROM -$158.97 = genuine refund, stays refund
// After correction: remaining refund $158.97 only, spent $3,790.55,
// Purchases 31, charity $700 recorded for the $7,000 income.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  computeWeek,
  isExcludedFromMath,
  chargeContribution,
  charityCommittedCents,
} from '../engine.mjs';
import { classifyCsvKind } from '../filterState.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const resetHtml = readFileSync(new URL('../reset.html', import.meta.url), 'utf8');
const canonical = readFileSync(new URL('../supabase/functions/_shared/canonical.ts', import.meta.url), 'utf8');
const plaidSync = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');
const computeWeekTs = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
const weekCloseTs = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
const rpcSql = readFileSync(new URL('../supabase/refund-classification-income-kind.sql', import.meta.url), 'utf8');

// --- Design item 2: inline errors on sign-in / join -----------------------
test('2. Sign-in failure stays in the inline soft-red box, not a toast', () => {
  assert.match(js, /setResultMsg\('authMsg', 'Incorrect email or password', true\)/);
  assert.equal(js.includes("showToast('Incorrect email or password'"), false, 'no sign-in toast remains');
});
test('2. Join failure stays in the inline soft-red box, not a toast', () => {
  assert.match(js, /setResultMsg\('householdMsg', 'Check the invite code and try again', true\)/);
  assert.equal(js.includes("showToast('Check the invite code and try again'"), false, 'no join toast remains');
});

// --- Design item 3 (Add options): Purchase blue, Donation pale, Upload grey
test('3. Add options: Purchase primary blue, Donation pale, Upload grey tertiary', () => {
  assert.match(html, /class="btn btn-primary add-option-btn" id="addOptionPurchaseBtn"/);
  assert.match(html, /class="btn add-option-btn" id="addOptionDonationBtn"/, 'plain .btn renders pale in the live theme');
  assert.match(html, /class="btn btn-tertiary add-option-btn" id="addOptionUploadBtn"/);
  assert.equal(html.includes('addOptionPurchaseBtn" type="button"><span class="add-option-title">Purchase'), false, 'no unstyled Purchase remains');
});

// --- Design item 3 (reset title) ------------------------------------------
test('3. Reset page browser tab is "OnBudget — Reset Your Password"', () => {
  assert.match(resetHtml, /<title>OnBudget — Reset Your Password<\/title>/);
  assert.equal(resetHtml.includes('Household Budget — Reset Your Password'), false);
});

// --- Design item 4: failure dialogs soft red ------------------------------
test('4. showAlert renders the soft-red error sheet; success sheets stay white', () => {
  assert.match(js, /kind = null/, 'showSheet takes a kind');
  assert.match(js, /kind === 'error' \? ' sheet-error' : ''/, 'error kind adds the sheet-error class');
  assert.match(js, /const showAlert = \(title, message\) => showSheet\(\{ title, message, confirmLabel: 'Close', kind: 'error' \}\)/);
  assert.match(js, /const showConfirm = \(title, message, confirmLabel = 'OK'\) => showSheet\(\{ title, message, confirmLabel, cancelLabel: 'Cancel' \}\)/, 'showConfirm passes no error kind — it stays white');
  assert.match(css, /#sheetOverlay \.sheet\.sheet-error \{ background: #fef2f2; border: 1px solid #fecaca; \}/);
  assert.match(css, /#sheetOverlay \.sheet\.sheet-error h3 \{ color: #dc2626; \}/);
});

// --- Classifier: canonical.ts (all four copies must match) -----------------
test('classifier: deposit pattern, widened payment pattern, income kind, depository default', () => {
  assert.match(canonical, /export const DEPOSIT_PATTERN = \/CHECK DEPOSIT\|MOBILE DEPOSIT\|\\bDEPOSIT\\b\/i;/);
  assert.match(canonical, /PAYMENT\\s\*:\\s\*CREDIT\|PAYMENT CREDIT\|\\\/ \?PAYMENT\|EPAYMENT\|E-PAYMENT\|ACH PAYMENT/);
  assert.match(canonical, /'income'/, 'income is a TxKind');
  assert.match(canonical, /accountType\?: string/);
  assert.match(canonical, /if \(signedAmountCents < 0 && DEPOSIT_PATTERN\.test\(name\)\) return 'income';/);
  assert.match(canonical, /if \(signedAmountCents < 0 && accountType === 'depository'\) return 'income';/);
  for (const copy of ['plaid-sync', 'gmail-poll', 'ingest-amex-alert']) {
    const other = readFileSync(new URL(`../supabase/functions/${copy}/canonical.ts`, import.meta.url), 'utf8');
    assert.equal(other, canonical, `${copy}/canonical.ts is identical to _shared/canonical.ts`);
  }
});
test('classifier: plaid-sync passes the account type through', () => {
  assert.match(plaidSync, /const typeByAccount = new Map<string, string>\(\);/);
  assert.match(plaidSync, /typeByAccount\.set\(acc\.account_id, String\(acc\.type\)\)/);
  assert.match(plaidSync, /upsertPlaidTx\(supabaseAdmin, householdId, tx, maskByAccount, typeByAccount\)/);
  assert.match(plaidSync, /classifyKind\(tx, merchantRaw, signed, typeByAccount\?\.get\(tx\.account_id\)\)/);
});

// --- Classifier cases, via the CSV mirror (same patterns, same order) ------
test('classifier cases: deposit is income, payment credit is payment, real refunds stay refunds', () => {
  assert.equal(classifyCsvKind('MOBILE CHECK DEPOSIT', -700000), 'income');
  assert.equal(classifyCsvKind('ONLINE TRANSFER / PAYMENT: CREDIT', -101279), 'payment');
  assert.equal(classifyCsvKind('AMEX EPAYMENT', -20000), 'payment');
  assert.equal(classifyCsvKind('ACH PAYMENT', -50000), 'payment');
  assert.equal(classifyCsvKind('AMAZON', -1059), 'refund', 'a genuine return is still a refund');
  assert.equal(classifyCsvKind('NORDSTROM', -15897), 'refund');
  assert.equal(classifyCsvKind('DEPOSIT', 5000), 'charge', 'a positive deposit charge is not income');
  assert.equal(classifyCsvKind('INTERNAL TRANSFER', -5000), 'transfer');
  assert.equal(classifyCsvKind('PRIME STRATEGIC CORPORATION', -35000), 'refund', 'an unmatched name still falls through to refund — the live row is corrected by reclassification, not by the classifier');
});

// --- Engine: income contributes $0, is excluded from week math -------------
test('engine: income is excluded from week math and contributes $0', () => {
  assert.equal(isExcludedFromMath({ kind: 'income', state: 'verified' }), true);
  assert.equal(chargeContribution({ kind: 'income', amount_cents: -700000, state: 'verified' }), 0);
  assert.equal(chargeContribution({ kind: 'payment', amount_cents: -101279, state: 'verified' }), 0);
  assert.equal(chargeContribution({ kind: 'transfer', amount_cents: -35000, state: 'verified' }), 0);
  for (const copy of ['compute-week', 'week-close', '_shared']) {
    const other = readFileSync(new URL(`../supabase/functions/${copy}/engine.mjs`, import.meta.url), 'utf8');
    assert.match(other, /if \(t\.kind === 'income'\) return true;/, `${copy}/engine.mjs excludes income`);
  }
});

// --- Synthetic week: the corrected Nov 1–7 week ----------------------------
test('synthetic week: corrected rows give spent $3,790.55, Purchases 31, charity $700', () => {
  const rows = [
    { kind: 'charge', state: 'provisional', amount_cents: 25566, fund_allocation_cents: 0 },
    { kind: 'charge', state: 'verified', amount_cents: 369386, fund_allocation_cents: 0 },
    { kind: 'income', state: 'verified', amount_cents: -700000 },   // check deposit
    { kind: 'payment', state: 'verified', amount_cents: -101279 },  // CC payment
    { kind: 'transfer', state: 'verified', amount_cents: -35000 },  // friend's money
    { kind: 'refund', state: 'verified', amount_cents: -15897, original_purchase_id: null }, // Nordstrom, genuine
  ];
  const chargesNet = rows.reduce((s, t) => s + chargeContribution(t), 0);
  assert.equal(chargesNet, 394952, 'charges $3,949.52; income/payment/transfer contribute $0');
  // Unlinked-refund cap: the one remaining refund nets in full because
  // it is smaller than the week's charges; excess is $0.
  const unlinkedAbs = 15897;
  const netted = Math.min(unlinkedAbs, Math.max(0, chargesNet));
  const C = Math.max(0, chargesNet - netted);
  assert.equal(C, 379055, 'spent $3,790.55');
  const purchases = rows.filter((t) => t.kind === 'charge').length;
  assert.equal(purchases, 2, 'charge rows in this fixture (31 in the real week)');
  // Charity: recording the $7,000 income at the 10% default commits $700.
  assert.equal(charityCommittedCents(700000, 1000), 70000);
  // And computeWeek itself: $3,790.55 spent against a $375 allowance.
  const w = computeWeek({ B: 37500, C });
  assert.equal(w.available, 37500 - 379055);
});

// --- Unlinked-refund cap: charges $100 + refund $250 -----------------------
test('cap: an unlinked refund bigger than the week nets only up to the charges', () => {
  const chargesNet = 10000;
  const unlinkedAbs = 25000;
  const netted = Math.min(unlinkedAbs, Math.max(0, chargesNet));
  const excess = unlinkedAbs - netted;
  assert.equal(netted, 10000);
  assert.equal(excess, 15000);
  assert.equal(Math.max(0, chargesNet - netted), 0);
  assert.match(computeWeekTs, /const unlinkedNetted = Math\.min\(unlinkedRefundAbs, Math\.max\(0, chargesNet\)\);/);
  assert.match(computeWeekTs, /unlinked_excess_cents: unlinkedExcessCents/);
  assert.match(weekCloseTs, /const unlinkedExcessInWeek = \(ws: string\) => \{/);
  assert.match(weekCloseTs, /unlinked_excess_by_week: unlinkedExcessByWeek/);
});

// --- List total: net spending only ------------------------------------------
test('list total sums net spending only, not the raw signed sum', () => {
  assert.match(js, /Net spending only: charges minus refunds/);
  assert.equal(js.includes("const shownTotal = shown.filter((t) => !(t.excluded === true || t.state === 'excluded') && (txFilter === 'charity' || t.kind !== 'charity')).reduce((s, t) => s + t.amount_cents, 0);"), false, 'raw signed-sum total is gone');
});

// --- Reclassify options + SQL -----------------------------------------------
test('reclassify options include Income; SQL adds the 8th kind', () => {
  assert.match(js, /\{ value: 'income', label: 'Income' \}/);
  assert.match(rpcSql, /check \(kind in \('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income'\)\)/);
  assert.match(rpcSql, /'charge', 'refund', 'fund_charge', 'payment', 'cashback', 'transfer', 'income'/);
  assert.match(rpcSql, /select count\(\*\) from week_closes where week_start = '2026-11-01';/);
});

// --- Pins -------------------------------------------------------------------
test('version pins: styles v49, live.js v59', () => {
  assert.match(html, /styles\.css\?v=49/);
  assert.match(html, /live\.js\?v=59/);
});
