// Refund classification fix (Nov 5, 2026, owner-approved) + design
// items 2, 3, 4 (owner YES Nov 5, 11:41 AM).
// Run with: node --test test/refund-classification-fix.test.mjs
// All amounts are integer cents. $1 = 100.
//
// The week Nov 1–7, 2026, real shape (live truth per FULL_AUDIT_
// 2026-11-08_R2.md §1, from recorded live probes Nov 8, 2:19/2:36 PM):
// gross charges $4,762.30; the four rows below were reclassified by
// the owner Nov 8 (2:16–2:19 PM) and leave week math entirely —
//   MOBILE CHECK DEPOSIT -$7,000.00 = income
//   ONLINE TRANSFER / PAYMENT: CREDIT -$1,012.79 = CC payment
//   PRIME STRATEGIC CORPORATION -$350.00 = transfer (friend's money)
//   NORDSTROM -$158.97 = genuine refund, stays refund
// After correction: the Nordstrom refund nets against the week's
// charges, so net spent C = $4,762.30 − $158.97 = $4,603.33, against
// the week's stored snapshot B = $5,000 (temporary increase /
// override, not the $375 base) — surplus / Extra Fund pending
// $396.67, cross-proven from two independent readings. Charity $700
// recorded for the $7,000 income.
// SUPERSEDED (P2-N15): the Nov 5, 11:04 AM probe behind the first
// audit (charges $3,949.52, spent $3,790.55) was stale — rows kept
// arriving after that probe. Do not restore those figures.
// The charge rows below are synthetic aggregates: only the totals
// ($4,762.30 gross, $4,603.33 net) are the live truth, not the split
// and not the row count (the first audit's "31 purchases" count came
// from the same stale probe and is not re-proven in the records).

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  computeWeek,
  isExcludedFromMath,
  chargeContribution,
  charityCommittedCents,
  applyUnlinkedRefundCap,
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
test('synthetic week: corrected rows give net spent $4,603.33, surplus $396.67, charity $700', () => {
  const rows = [
    { kind: 'charge', state: 'verified', amount_cents: 476230, fund_allocation_cents: 0 },
    { kind: 'income', state: 'verified', amount_cents: -700000 },   // check deposit
    { kind: 'payment', state: 'verified', amount_cents: -101279 },  // CC payment
    { kind: 'transfer', state: 'verified', amount_cents: -35000 },  // friend's money
    { kind: 'refund', state: 'verified', amount_cents: -15897, original_purchase_id: null }, // Nordstrom, genuine
  ];
  const chargesNet = rows.reduce((s, t) => s + chargeContribution(t), 0);
  assert.equal(chargesNet, 476230, 'gross charges $4,762.30; income/payment/transfer contribute $0');
  // Unlinked-refund cap: the one remaining refund nets in full because
  // it is smaller than the week's charges; excess is $0.
  const cap = applyUnlinkedRefundCap(15897, chargesNet, false);
  assert.deepEqual(cap, { nettedCents: 15897, excessCents: 0, chargesAfterCents: 460333 });
  const C = cap.chargesAfterCents;
  assert.equal(C, 460333, 'net spent $4,603.33');
  const purchases = rows.filter((t) => t.kind === 'charge').length;
  assert.equal(purchases, 1, 'one synthetic aggregate charge row (the real-week row count is not re-proven — see the header)');
  // Charity: recording the $7,000 income at the 10% default commits $700.
  assert.equal(charityCommittedCents(700000, 1000), 70000);
  // And computeWeek itself: $4,603.33 spent against the week's stored
  // snapshot B of $5,000 leaves $396.67 — the recorded pending surplus.
  const w = computeWeek({ B: 500000, C });
  assert.equal(w.available, 39667);
  assert.equal(w.earnedSurplus, 39667);
});

// --- Unlinked-refund cap: charges $100 + refund $250 -----------------------
// P2-M5 (Nov 8, 2026): the old test re-implemented Math.min inline and
// never executed any real code, so it passed even with the cap broken.
// It now calls the real helper, applyUnlinkedRefundCap, against
// independently hand-computed expectations — every case below fails
// if the helper's arithmetic, the lock gate, or the excess changes.
test('cap: an unlinked refund bigger than the week nets only up to the charges', () => {
  assert.deepEqual(applyUnlinkedRefundCap(25000, 10000, false),
    { nettedCents: 10000, excessCents: 15000, chargesAfterCents: 0 });
  // Live case: Nov 1–7 gross charges $4,762.30, Nordstrom refund
  // $158.97, open week — nets in full, nothing in excess.
  assert.deepEqual(applyUnlinkedRefundCap(15897, 476230, false),
    { nettedCents: 15897, excessCents: 0, chargesAfterCents: 460333 });
  // Same week once locked: the refund nets $0 and the whole amount is
  // excess (restoration handles locked-week refunds instead).
  assert.deepEqual(applyUnlinkedRefundCap(15897, 476230, true),
    { nettedCents: 0, excessCents: 15897, chargesAfterCents: 476230 });
  // Boundaries: refund exactly the charges; no refund; no charges.
  assert.deepEqual(applyUnlinkedRefundCap(10000, 10000, false),
    { nettedCents: 10000, excessCents: 0, chargesAfterCents: 0 });
  assert.deepEqual(applyUnlinkedRefundCap(0, 10000, false),
    { nettedCents: 0, excessCents: 0, chargesAfterCents: 10000 });
  assert.deepEqual(applyUnlinkedRefundCap(5000, 0, false),
    { nettedCents: 0, excessCents: 5000, chargesAfterCents: 0 });
  // The deployed functions still inline this formula (they cannot
  // import the root file) — pin their text to the same rule so a
  // server-side edit that breaks the cap fails here too.
  assert.match(computeWeekTs, /const unlinkedNetted = weekLocked \? 0 : Math\.min\(unlinkedRefundAbs, Math\.max\(0, chargesNet\)\);/);
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
test('version pins: styles v53, live.js v67', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=67/);
});
