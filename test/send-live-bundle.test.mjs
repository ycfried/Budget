// Send-live-bundle (owner approvals, Nov 4, 2026) — static tests +
// pure-function tests. No DOM, no network, no database, no money
// math changes except the documented weekly-allowance override
// selection (B = override, T = 0), which the engine already
// computes as baseAvailable = max(0, B - D), available =
// baseAvailable + T - C. Run with: node --test test/send-live-bundle.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { computeWeek } from '../engine.mjs';
import { activityDotClass, activityTitle } from '../filterState.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const sql = readFileSync(new URL('../supabase/weekly-allowance-override.sql', import.meta.url), 'utf8');
const computeWeekTs = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
const weekCloseTs = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
const sheetFn = js.slice(js.indexOf('async function openWeeklySheet()'), js.indexOf('const heroWeeklyTarget'));
const tempFn = js.slice(js.indexOf("$('addTempBtn')"), js.indexOf("$('saveAllowanceBtn')"));
const actionsFn = js.slice(js.indexOf('async function openTxActionsSheet'), js.indexOf('async function doTxCharity'));

test('version pins: styles v43, live.js v53', () => {
  assert.match(html, /styles\.css\?v=43/);
  assert.match(html, /live\.js\?v=53/);});
test('1. Weekly popup rows are Allowance, Spent, Balance in order, and the equation holds', () => {
  const visible = sheetFn.slice(sheetFn.indexOf('const weeklyRows = ['), sheetFn.indexOf('];', sheetFn.indexOf('const weeklyRows = [')));
  assert.deepEqual([...visible.matchAll(/\['([^']+)'/g)].map((m) => m[1]), ['Allowance', 'Spent', 'Balance']);
  assert.match(sheetFn, /weeklyAllowanceCents = \(w\.baseAvailableCents \?\? w\.baseRoomCents \?\? 0\) \+ \(w\.tempCents \?\? 0\)/);
  assert.match(sheetFn, /\['Allowance', formatCents\(weeklyAllowanceCents\)\]/);
  assert.match(sheetFn, /\['Spent', formatCents\(w\.chargesCents\)\]/);
  assert.match(sheetFn, /\['Balance', formatCents\(w\.availableCents\)\]/);
  assert.match(sheetFn, /extraAction: \{ label: 'Show transactions', result: 'show-transactions' \}/);
  assert.match(sheetFn, /confirmLabel: 'Close'/);
  // Equation, via the engine: Allowance (base room + temp) - Spent = Balance.
  const r = computeWeek({ B: 42500, T: 0, D: 10000, C: 5000 });
  assert.equal(r.baseAvailable, 32500);
  assert.equal(r.baseAvailable + r.T - r.C, r.available);
  assert.equal(r.available, 27500);
});

test('2. Pale option B: fill stays #bfdbfe, wording is ink #0f172a', () => {
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{ background: #bfdbfe; border: 0; color: #0f172a;/);
  assert.match(css, /body\.live #view-app \.btn-primary, body\.live \.btn-primary \{ background: #2f6bff; color: #fff; \}/);
  assert.match(css, /body\.live #view-app \.btn-tertiary, body\.live \.btn-tertiary \{ background: #e5e7eb; color: #0f172a; border: 1px solid #e5e7eb; \}/);
  assert.match(css, /body\.live #view-app \.btn-mid, body\.live \.btn-mid \{ background: #0f172a; color: #fff; border: 1px solid #0f172a; \}/);
  // Three-button middles are still plain .btn (pale): Funds Use
  // (now in the Extra Fund sheet, Task 7) and Filters Reset. Bank
  // Sync is no longer a pale middle (settings-bank-buttons, Nov 4):
  // the bank row is two buttons, Connect primary + Sync tertiary.
  assert.match(js, /label: 'Use fund money', result: 'use', btnClass: 'btn'/);
  assert.ok(html.includes('<button class="btn" id="txFiltersResetBtn"'));
  assert.ok(html.includes('<button id="syncBankBtn" class="btn btn-tertiary"'));
});

test('3. History row REMOVED (native-style-live): Past weeks live inside Transactions, no Home row', () => {
  assert.equal(html.includes('id="section-history-row"'), false);
  assert.equal(html.includes('View history'), false);
  assert.match(html, /<a class="quiet-link" data-view="purchases"[^>]*>See all<\/a>/);
  // Merged-audit B3: history sections moved to the prevweeks view; Transactions stays the current list only.
  assert.match(js, /prevweeks: \[[^\]]*section-history-filter[^\]]*section-week-history/);
  assert.equal(js.includes('section-history-row'), false);
});

test('4. Hero card: white like other cards, with a brand-blue outline — wash removed (home-hero-fix)', () => {
  // Home-hero-fix (owner, Nov 4): the blue wash did not match the
  // rest of the page. White background, 1.5px brand-blue outline,
  // no blue shadow — life from the outline, not a coloured fill.
  assert.match(css, /body\.live \.hero \{ background: #fff; border: 1\.5px solid #2f6bff; box-shadow: none; \}/);
  assert.match(css, /body\.live \.card \{[^}]*box-shadow: 0 4px 16px rgba\(15, 23, 42, \.06\); \}/);
});

test('5. Add popup: no visible Add header, aria-label stays, Cancel is grey, options unchanged, members see Purchase only', () => {
  const card = html.slice(html.indexOf('id="addOptionsCard"'), html.indexOf('id="addPopupFormSlot"'));
  assert.equal(card.includes('<h3>Add</h3>'), false);
  assert.ok(html.includes('id="addPopupOverlay" class="add-popup-overlay hidden" role="dialog" aria-modal="true" aria-label="Add"'));
  assert.ok(html.includes('<button class="btn btn-tertiary" id="addOptionsCloseBtn"'));
  for (const id of ['addOptionPurchaseBtn', 'addOptionDonationBtn', 'addOptionUploadBtn']) assert.ok(html.includes(`id="${id}"`));
  assert.match(js, /addOptionDonationBtn.*isAdmin \? '' : 'none'/s);
  assert.match(js, /addOptionUploadBtn.*isAdmin \? '' : 'none'/s);
});

test('6. Activity timeline: dots, plain titles, Admin/Member, jargon translated display-side', () => {
  assert.equal(activityDotClass('Charity income recorded', ''), 'charity');
  assert.equal(activityDotClass('Weeks processed', ''), 'system');
  assert.equal(activityDotClass('Transaction added by hand', ''), 'money');
  assert.equal(activityTitle('Weeks processed', 35), '35 weeks closed');
  assert.equal(activityTitle('Weeks processed', 1), '1 week closed');
  assert.equal(activityTitle('Transaction added by hand', 1), 'Transaction added by hand');
  assert.match(js, /activity-dot activity-dot-\$\{dot\}/);
  assert.match(js, /activityTitle\(g\.action, g\.count\)/);
  assert.match(js, /activityDotClass\(g\.action, g\.detail\)/);
  assert.match(js, /basis points\/gi/);
  assert.match(js, /Number\(n\) \/ 100/);
});

test('7. Back header: one line, Settings left, light-blue Back text right, no subtitle, form Backs are back-links too', () => {
  // Merged-audit A9: Settings heading is focusable (focus moves to it when Settings opens).
  assert.match(html, /<div class=\"settings-head-line\"><h2 tabindex=\"-1\">Settings<\/h2><button class=\"settings-back-link\" id=\"settingsBackBtn\"[^>]*>← Back<\/button><\/div>/);
  assert.equal(html.includes('id="settingsIntro"'), false);
  assert.equal(html.includes('Connections, Budget, and Account &amp; household.'), false);
  // Header-back-swipe (owner, Nov 4): Back is ALWAYS light blue #3b82f6, bold — the old grey #475569 looked dead.
  assert.match(css, /\.back-link, body\.live \.settings-back-link \{ background: none; border: 0; color: #3b82f6; font-weight: 700;/);
  // Form-level Backs are the same shared back-link now (owner: Back should ALWAYS be light blue).
  assert.ok(html.includes('id="manualBackBtn"'));
  assert.match(html, /<button class="back-link" id="manualBackBtn"/);
});

test('8. Unified sentence on Bank and Email; Email heading Title Case, long paragraph deleted', () => {
  const bank = html.slice(html.indexOf('id="section-bank"'), html.indexOf('id="section-email"'));
  const email = html.slice(html.indexOf('id="section-email"'), html.indexOf('id="settingsCard"'));
  assert.ok(bank.includes('<h2>Bank Connection</h2>'));
  assert.ok(bank.includes('<p class="muted small">Look only — it never moves, sends, or changes anything.</p>'));
  assert.ok(email.includes('<h2>Email Alerts</h2>'));
  assert.ok(email.includes('<p class="muted small">Look only — it never moves, sends, or changes anything.</p>'));
  for (const gone of ['never your whole mailbox', 'stay provisional until the bank confirms them', 'does not change any existing email setup', 'The app can see transactions.', 'Email alerts (read-only)']) {
    assert.equal(html.includes(gone), false, `removed sentence/fragment still present: ${gone}`);
  }
  // Status lines are not headings and are untouched.
  assert.ok(js.includes("Connected (read-only)"));
});

test('9. Budget card: heading Budget with Admin pill, sentence kept', () => {
  const card = html.slice(html.indexOf('id="settingsCard"'), html.indexOf('id="section-settings-account"'));
  assert.match(card, /<h2>Budget <span class="role-pill" id="budgetRolePill">Admin<\/span><\/h2>/);
  assert.equal(card.includes('Budget (admin only)'), false);
  assert.ok(card.includes('<p class="muted small">Only the admin can change these.</p>'));
});

test('10. Temporary increase layout + Weeks selector + override logic (lower totals work)', () => {
  const card = html.slice(html.indexOf('id="settingsCard"'), html.indexOf('id="section-settings-account"'));
  assert.ok(card.includes('<h3>Weekly Allowance</h3>'));
  // Merged-audit B1: form renamed Temporary Allowance (no 'Increase', so lower totals fit).
  assert.ok(card.includes('<h3 class="temp-increase-heading">Temporary Allowance</h3>'));
  assert.equal(card.includes('Amount ($)'), false);
  assert.equal(card.includes('Amount for this week ($)'), false);
  assert.ok(card.includes('<span class="money-prefix" aria-hidden="true">$</span><input id="baseAllowanceInput"'));
  assert.ok(card.includes('<span class="money-prefix" aria-hidden="true">$</span><input id="tempIncreaseInput"'));
  assert.match(card, /<select id="tempIncreaseWeeks"[^>]*><option value="1">1<\/option><option value="2">2<\/option><option value="3">3<\/option><option value="4">4<\/option><\/select>/);
  assert.match(css, /\.temp-increase-heading \{ margin-top: 28px; \}/);
  // Handler: new total via override once per week, never temp RPC.
  assert.match(tempFn, /supabase\.rpc\('set_weekly_allowance_override', \{ p_household_id: household\.household_id, p_week_start: weekStart, p_allowance_cents: cents \}\)/);
  assert.equal(tempFn.includes("supabase.rpc('add_temp_increase'"), false);
  assert.match(tempFn, /Weekly allowance set to \$\{formatCents\(cents\)\} for \$\{weeks\} week/);
  assert.match(tempFn, /Math\.min\(4, Math\.max\(1, weeksRaw\)\)/);
  assert.match(tempFn, /cents === null \|\| cents < 0/);
});

test('10b. Override math: debt still comes off the top, T = 0', () => {
  // Lower total: override $300, carried debt $375 -> room $0.
  const low = computeWeek({ B: 30000, T: 0, D: 37500, C: 5000 });
  assert.equal(low.baseAvailable, 0);
  assert.equal(low.available, -5000);
  // Higher total: override $425, debt $100 -> room $325, spent $50 -> $275 left.
  const high = computeWeek({ B: 42500, T: 0, D: 10000, C: 5000 });
  assert.equal(high.baseAvailable, 32500);
  assert.equal(high.available, 27500);
});

test('10c. Override SQL (review only): table, unique, RLS, RPC upsert + temp delete + audit', () => {
  assert.match(sql, /NOT YET APPLIED/);
  assert.match(sql, /create table if not exists weekly_allowance_overrides/);
  assert.match(sql, /unique \(household_id, week_start\)/);
  assert.match(sql, /allowance_cents integer not null check \(allowance_cents >= 0\)/);
  assert.match(sql, /grant select on weekly_allowance_overrides to authenticated/);
  assert.match(sql, /members read own weekly allowance overrides/);
  assert.match(sql, /create or replace function public\.set_weekly_allowance_override\(p_household_id uuid, p_week_start date, p_allowance_cents integer\)/);
  assert.match(sql, /on conflict \(household_id, week_start\)/);
  assert.match(sql, /delete from temp_increases/);
  assert.match(sql, /'Weekly allowance set'/);
  assert.match(sql, /allowance must be zero or positive/);
  assert.match(sql, /admin only/);
});

test('10d. Server override selection: compute-week and week-close, snapshot precedence', () => {
  assert.match(computeWeekTs, /weekly_allowance_overrides/);
  assert.match(computeWeekTs, /overrideCents/);
  assert.match(computeWeekTs, /overrideCents != null[\s\S]{0,20}\? 0/);
  assert.match(weekCloseTs, /overrideByWeek/);
  assert.match(weekCloseTs, /overrideByWeek\.has\(ws\) \? 0 : tempSum\(ws\)/);
  // Snapshot still wins over a later override in both functions.
  assert.ok(computeWeekTs.includes('Snapshot precedence'));
  assert.ok(weekCloseTs.includes('Snapshot precedence'));
});

test('11. Detail Actions sheet: exactly Charity, Extra Fund, Other, Delete; charity Delete-only; member Extra Fund only', () => {
  assert.ok(js.includes('data-tx-actions='));
  assert.equal(js.includes('data-exclude='), false);
  assert.equal(js.includes('data-mark-charity='), false);
  assert.equal(js.includes('data-reclassify='), false);
  assert.equal(js.includes('data-remove-tx='), false);
  assert.equal(js.includes('data-delete-tx='), false);
  // Merged-audit B11: actions now come from the shared
  // actionsForTxKind helper (kind-restricted); the exact sets are
  // asserted in merged-audit-push.test.mjs.
  assert.match(js, /actionsForTxKind\(row\.kind, isAdmin, row\.state === 'verified'\)/);
  assert.match(actionsFn, /label: 'Charity'/);
  assert.match(actionsFn, /label: 'Extra Fund'/);
  assert.match(actionsFn, /label: 'Other'/);
  assert.match(actionsFn, /label: 'Delete'/);
  assert.match(js, /Charity gifts cannot be covered by the Extra Fund/);
  assert.match(js, /Moved to trash bin\./);
  assert.match(js, /delete_transaction/);
  assert.match(js, /exclude_transaction/);
});

test('11b. Trash (native-style-live): quiet text link above the list, only when non-empty, admin only', () => {
  assert.ok(html.includes('id="txTrashBtn"'));
  assert.match(html, /class="quiet-link trash-link"/);
  assert.equal(html.includes('🗑'), false, 'no emoji pill trash button');
  assert.ok(html.includes('id="trashList"'));
  assert.match(js, /trashRowCount > 0\) \? '' : 'none'/);
  assert.match(js, /data-trash-restore=/);
  assert.match(js, /restore_transaction/);
  assert.equal(html.includes('<option value="excluded">Excluded</option>'), false);
  assert.match(js, /!isExcludedRow\(t\)/);
  assert.match(js, /deleted bank rows live in the Trash link above the list/);
});
