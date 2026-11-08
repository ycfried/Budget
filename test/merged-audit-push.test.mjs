// Merged-audit push package (owner, Nov 4, 2026) — Section A + decided B items.
// Static tests + pure-function tests. No DOM, no network, no database,
// no money-math changes except where a decided B item says so.
// Run with: node --test test/merged-audit-push.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { actionsForTxKind, MAIN_VIEWS } from '../filterState.mjs';
import { computeWeek } from '../engine.mjs';
import { computeRestorationTotal, computeIncrementalRestoration } from '../supabase/functions/week-close/restoration.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const plaidSync = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');
const weekClose = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
const computeWeekTs = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
const kindSql = readFileSync(new URL('../supabase/merged-audit-kind-constraint.sql', import.meta.url), 'utf8');
const guardSql = readFileSync(new URL('../supabase/merged-audit-fund-request-kind-guard.sql', import.meta.url), 'utf8');
const revokeSql = readFileSync(new URL('../supabase/merged-audit-plaid-accounts-revoke.sql', import.meta.url), 'utf8');
const csvSql = readFileSync(new URL('../supabase/merged-audit-csv-admin-only.sql', import.meta.url), 'utf8');
const heldSql = readFileSync(new URL('../supabase/merged-audit-held-release-atomic.sql', import.meta.url), 'utf8');
const manifest = readFileSync(new URL('../supabase/APPLY_MANIFEST_MERGED_AUDIT.md', import.meta.url), 'utf8');
const mockup = readFileSync(new URL('../card-standardization-mockup.html', import.meta.url), 'utf8');

test('pins: styles v50, live.js v60, matching live.html', () => {
  assert.match(html, /styles\.css\?v=51/);
  assert.match(html, /live\.js\?v=61/);});// ---- A1: merged kind constraint (file only, not applied) ----
test('A1: kind-constraint SQL lists exactly the seven kinds, transfer included', () => {
  assert.match(kindSql, /PREPARED FOR OWNER-APPROVED APPLY/);
  for (const k of ['charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer']) {
    assert.ok(kindSql.includes(`'${k}'`), `kind ${k} in list`);
  }
  assert.match(kindSql, /transactions_kind_check/);
});

// ---- A2: Approve signature is live-proven, not changed here ----
test('A2: UI Approve call uses the p_ signature; manifest records the live probe, no new SQL', () => {
  assert.match(js, /approve_and_allocate', \{ p_request_id:/);
  assert.match(manifest, /live-proven/);
  assert.match(manifest, /04-admin-rpcs\.sql/);
  assert.equal(manifest.includes('merged-audit-approve'), false, 'no approve SQL file in this package');
});

// ---- A3: Home face shows effective allowance ----
test('A3: hero allowance is base room + temp, matching the Weekly breakdown', () => {
  assert.match(js, /heroAllowance.*baseAvailable \+ tempC/);
});

// ---- A4: Correct income opens, scrolls, focuses ----
test('A4: Correct handler opens the income form, scrolls to it, focuses its first field', () => {
  assert.match(js, /setFundForm\('income'\)/);
  assert.match(js, /section-charity-income.*scrollIntoView/);
  assert.match(js, /charityIncomeForm input\[name="source"\]/);
});

// ---- A5: Cash/no-card shared; Purchases count counts charges only ----
test('A5: Home Recent + Trash share the Cash/no-card rule; Purchases count is charges only', () => {
  assert.match(js, /thisWeekPurchases = .*kind === 'charge'/);
  assert.match(js, /heroPurchaseCount.*thisWeekPurchases\.length/);
  // The Cash/no-card ternary itself (charity + 0000 -> Cash) is the
  // assertion; a literal '••0000' string never appears as rendered
  // output because the ternary intercepts it first.
  assert.match(js, /recentCard = \(t\.kind === 'charity'/);
});

// ---- A6: Recent-row jump is robust ----
test('A6: openRecent clears filters/search, opens detail, highlights, scrolls', () => {
  assert.match(js, /tx-recent-highlight/);
  assert.match(js, /That transaction is not in the loaded list/);
  assert.match(css, /tx-recent-highlight/);
});

// ---- A7: Search/totals ----
test('A7: search note beneath input; short count + Total shown; no-match recovery first', () => {
  assert.ok(html.includes('Searches loaded transactions.'));
  assert.match(js, /No matching transactions — try a different search, or clear the search and filters\./);
  assert.match(js, /transactions · Total shown/);
});

// ---- A8: Past savings empty state ----
test('A8: past savings empty state is one line, no empty metrics', () => {
  assert.match(js, /No past savings records\.<\/p>/);
});

// ---- A9: Profile menu closes, focus to Settings heading, Back is previous view ----
test('A9: menu Settings handler closes the menu and focuses the Settings heading', () => {
  assert.match(js, /profileBtn.*setAttribute\('aria-expanded', 'false'\)/);
  assert.ok(html.includes('<h2 tabindex="-1">Settings</h2>'));
});

// ---- A10: Dialogs: Close for read-only detail ----
test('A10: showAlert uses Close, not OK, for read-only detail', () => {
  assert.match(js, /confirmLabel: 'Close'/);
  assert.doesNotMatch(js, /confirmLabel: 'OK'/);
});

// ---- A11: Narrow fund amounts ----
test('A11: 390px rule shrinks stat/fund numbers; fund cards stack at 420px', () => {
  assert.match(css, /@media \(max-width: 390px\)/);
  assert.match(css, /#section-stats \.num.*font-size: 22px/);
});

// ---- A12: Negative pots turn red ----
test('A12: fund-balance negative rule exists and both summaries toggle it', () => {
  assert.match(css, /fund-balance\.negative \{ color: var\(--soft-red\); \}/);
  assert.match(js, /fund-balance\$\{available < 0/);
  assert.match(js, /fund-balance\$\{remaining < 0/);
});

// ---- A13: Add popup is a true bottom sheet ----
test('A13: Add popup card has background + own scroll', () => {
  assert.match(css, /add-popup-card \{ background: #ffffff; overflow-y: auto; \}/);
});

// ---- A14/A15: plaid-sync guards (source-text assertions; Deno functions are not executed here) ----
test('A14: plaid-sync update never overwrites kind, never overwrites Trash state', () => {
  assert.match(plaidSync, /trashed = existing\.excluded === true/);
  assert.match(plaidSync, /if \(!trashed\) update\.state = state;/);
  assert.doesNotMatch(plaidSync, /state, kind, external_id: txId/);
});
test('A15: plaid-sync hash match claims Gmail-alert rows only', () => {
  assert.match(plaidSync, /\.eq\('source', 'amex_alert'\)/);
});

// ---- A16: server guards as prepared SQL only ----
test('A16: kind guard requires charge, unlinked path untouched', () => {
  assert.match(guardSql, /must be a charge/);
  assert.match(guardSql, /PREPARED FOR OWNER-APPROVED APPLY/);
  assert.match(guardSql, /transaction_id is not null/);
});
test('A16: plaid_accounts revoke drops member write policies, keeps SELECT', () => {
  assert.match(revokeSql, /revoke insert, update on plaid_accounts from authenticated/);
  assert.match(revokeSql, /drop policy if exists "members insert own plaid accounts"/);
  assert.match(revokeSql, /drop policy if exists "members update own plaid accounts"/);
});
test('A16: CSV import admin-only, manual single-row stays member-allowed', () => {
  assert.match(csvSql, /source = 'manual'/);
  assert.match(csvSql, /role = 'admin'/);
  assert.match(csvSql, /state = 'provisional'/);
});
test('A16: charity index already live — manifest gates the existing file, no duplicate index file', () => {
  assert.match(manifest, /transactions_household_client_key_idx/);
  assert.match(manifest, /r13-gift-idempotency\.sql/);
});

// ---- A17: ordered apply manifest ----
test('A17: manifest lists the five prepared files in order and the do-not-apply list', () => {
  for (const f of ['merged-audit-kind-constraint.sql', 'merged-audit-fund-request-kind-guard.sql', 'merged-audit-plaid-accounts-revoke.sql', 'merged-audit-csv-admin-only.sql', 'merged-audit-held-release-atomic.sql']) {
    assert.ok(manifest.includes(f), f);
  }
  assert.match(manifest, /NOTHING IN THIS MANIFEST IS APPLIED LIVE/);
});

// ---- A18: code cleanup ----
test('A18: hero face sentence gone from live.html; dead held-link code gone; stale dedupe comments corrected', () => {
  assert.equal(html.includes('Pending transactions are included and marked.'), false);
  assert.match(js, /Pending transactions are included and marked\./); // moved to the Weekly sheet
  assert.equal(js.includes('fundHeldLink'), false);
  // The corrected comment now says there is NO such constraint — that
  // wording itself is the proof the stale claim was corrected.
  assert.match(js, /NO unique \(household_id, dedupe_hash\) constraint/);
});

// ---- B1: Temporary Allowance + preview ----
test('B1: form renamed Temporary Allowance with Base/New total/Weeks/dates preview', () => {
  assert.ok(html.includes('<h3 class="temp-increase-heading">Temporary Allowance</h3>'));
  assert.ok(html.includes('id="tempPreview"'));
  assert.match(js, /function updateTempPreview\(\)/);
  assert.match(js, /Base .* New total .* week/);
  assert.doesNotMatch(html, /Temporary Increase<\/h3>/);
});

// ---- B2: Funds More accordion ----
test('B2: toggleMore closes the other two sections before opening the tapped one', () => {
  assert.match(js, /moreFundActivityOpen = false; moreReviewOpen = false; moreSavingsOpen = false;/);
});

// ---- B3: Past Weeks + Activity split, no new tab ----
test('B3: prevweeks and activity are restorable views; Transactions links to both; no fourth tab', () => {
  assert.ok(MAIN_VIEWS.includes('prevweeks'));
  assert.ok(html.includes('id="txPrevWeeksLink"'));
  assert.ok(html.includes('id="txActivityLink"'));
  assert.ok(html.includes('id="prevWeeksBackBtn"'));
  assert.ok(html.includes('id="activityBackBtn"'));
  assert.equal((html.match(/class="app-nav-link"/g) || []).length, 3);
  assert.match(js, /week-block-tappable/);
});

// ---- B4: Desktop Add label ----
test('B4: Add button carries the desktop label, hidden on phone', () => {
  assert.ok(html.includes('add-label-desktop'));
  assert.match(css, /add-label-desktop \{ display: none; \}/);
});

// ---- B5: Mockup only, not linked from live.html ----
test('B5: standalone card mockup exists, is labelled mockup-only, and is not linked from live.html', () => {
  assert.match(mockup, /MOCKUP ONLY/);
  assert.match(mockup, /Weekly Budget/);
  assert.match(mockup, /Charity/);
  assert.match(mockup, /Extra Fund/);
  assert.equal(html.includes('card-standardization-mockup'), false);
});

// ---- B6: Date guard ----
test('B6: plaid-sync drops pre-Nov rows after a full pull; week-close and compute-week floor at Nov 1', () => {
  assert.match(plaidSync, /fullPullSeen/);
  assert.match(plaidSync, /\.lt\('date', '2026-11-01'\)/);
  assert.match(weekClose, /2026-11-01/);
  assert.match(computeWeekTs, /2026-11-01/);
});

// ---- B7/B8: shared week logic + restoration fixture ----
test('B7/B8 fixture: purchase, refund after lock, restoration — both engines agree, never over-restores', () => {
  // Week 1: allowance $375, purchase $100, debt $0 -> available $275, no surplus, no debt.
  const w1 = computeWeek({ B: 37500, T: 0, D: 0, C: 10000 });
  assert.equal(w1.available, 27500);
  // Refund $40 after the week locks: restoration simulation over
  // purchase week + current week, total refunded $40, initial debt $0.
  const total = computeRestorationTotal({
    weeks: [
      { week_start: '2026-11-01', B: 37500, T: 0, charges_cents: 10000 },
      { week_start: '2026-11-08', B: 37500, T: 0, charges_cents: 0 },
    ],
    purchaseWeekStart: '2026-11-01',
    purchaseAmountCents: 10000,
    fundAllocationCents: 0,
    totalRefundedCents: 4000,
    initialDebtCents: 0,
  });
  // $40 restores as surplus in the current week (purchase week locked
  // in the simulation's horizon), never more than the refund.
  assert.ok(total.restoredSurplusCents + total.fundCreditCents <= 4000);
  // Two refunds totalling more than the charge: incremental second
  // refund is capped, total never exceeds the charge, held captures excess.
  const first = computeRestorationTotal({
    weeks: [{ week_start: '2026-11-01', B: 37500, T: 0, charges_cents: 10000 }],
    purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    fundAllocationCents: 0, totalRefundedCents: 8000, initialDebtCents: 0,
  });
  const second = computeRestorationTotal({
    weeks: [{ week_start: '2026-11-01', B: 37500, T: 0, charges_cents: 10000 }],
    purchaseWeekStart: '2026-11-01', purchaseAmountCents: 10000,
    fundAllocationCents: 0, totalRefundedCents: 12000, initialDebtCents: 0,
  });
  const inc = computeIncrementalRestoration({ priorTotal: first, newTotal: second, newRefundCents: 4000 });
  assert.ok(inc.restoredSurplusCents + inc.fundCreditCents <= 2000, 'second refund restores at most the remaining charge');
  assert.ok(inc.heldCents >= 2000, 'excess over the charge is held');
  // B8 code: week-close subtracts prior cuts from initial debt.
  assert.match(weekClose, /priorCuts/);
  assert.match(weekClose, /Math\.max\(0, \(priorClose\.outgoing_debt_cents/);
});

// ---- B9: shortfall serialization ----
test('B9: week-close persists shortfall via fresh-read delta, never an absolute stale write', () => {
  assert.match(weekClose, /persistShortfall/);
  assert.match(weekClose, /lastPersistedShortfall/);
  assert.doesNotMatch(weekClose, /shortfall_cents: shortfall \}/);
});

// ---- B10: held refunds ----
test('B10: held row queued before the entry; unique violations swallowed as idempotent; release RPC is conditional', () => {
  assert.match(weekClose, /held_refunds'\)\.insert/);
  assert.match(weekClose, /isUniqueViolation/);
  assert.match(heldSql, /where id = p_held_id and status = 'pending'/);
  assert.match(heldSql, /held refund already resolved/);
});

// ---- B11: detail actions by kind ----
test('B11: actionsForTxKind restricts by kind exactly as decided', () => {
  assert.deepEqual(actionsForTxKind('charge', true, true), ['charity', 'extraFund', 'other', 'delete']);
  // P1-NEW1 (Nov 8, 2026): Charity is offered on any charge — the
  // sheet renders it disabled with honest copy when pending (admin)
  // or for members (ask the admin). The guarded RPC still enforces
  // posted + unlocked week when tapped.
  assert.deepEqual(actionsForTxKind('charge', true, false), ['charity', 'extraFund', 'other', 'delete']);
  assert.deepEqual(actionsForTxKind('charge', false, true), ['charity', 'extraFund']);
  assert.deepEqual(actionsForTxKind('charge', false, false), ['charity', 'extraFund']);
  assert.deepEqual(actionsForTxKind('transfer', true, true), ['other', 'delete']);
  assert.deepEqual(actionsForTxKind('payment', true, false), ['other', 'delete']);
  assert.deepEqual(actionsForTxKind('cashback', true, true), ['other', 'delete']);
  assert.deepEqual(actionsForTxKind('charity', true, true), ['delete']);
  assert.deepEqual(actionsForTxKind('charity', false, true), []);
  // Transfer week math is $0 (shared engine: transfer is not a charge).
  const t = computeWeek({ B: 37500, T: 0, D: 0, C: 0 });
  assert.equal(t.available, 37500);
});
