import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const weekClose = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
const deleteAccount = readFileSync(new URL('../supabase/functions/delete-account/index.ts', import.meta.url), 'utf8');

test('1. Home shows 6 recent transactions, and the footer sits directly under the last card', () => {
  assert.match(js, /\.slice\(0, 6\)/, 'Home recent list takes 6 rows, not 4');
  assert.equal(js.includes('.slice(0, 4)'), false, 'no 4-row Home recent slice remains');
  assert.match(css, /body\.live footer\.foot \{ margin-top: 16px; \}/, 'footer sits 16px under the last card');
  assert.equal(css.includes('footer.foot { margin-top: auto; }'), false, 'footer is no longer pushed to the bottom of the viewport');
  assert.match(css, /min-height: calc\(100dvh - 60px\)/, 'page still fills the viewport; the space below the footer is below all content');
});

test('3. Hero sync is grey when no allowance is set, primary blue once one is set', () => {
  assert.match(css, /body\.live #view-app \.hero-sync-btn\.sync-unset \{ background: #e5e7eb; color: #0f172a;/, 'sync-unset is grey tertiary');
  assert.match(css, /body\.live #view-app \.hero-sync-btn \{ background: #2f6bff; color: #fff;/, 'sync is primary blue by default');
  assert.match(js, /heroSyncBtn\.classList\.toggle\('sync-unset', !allowanceExplicitlySet\)/, 'sync-unset tracks whether an allowance is set');
  assert.ok(js.includes("document.getElementById('homeSyncBtn')"), 'toggle targets the hero sync button');
});

test('4. Past Weeks is the one name everywhere', () => {
  assert.equal(html.includes('Previous Weeks'), false, 'no Previous Weeks label remains in live.html');
  assert.equal(html.includes('Past Weeks'), true, 'Past Weeks is the page head and the Transactions link');
  assert.match(html, /<h2 tabindex="-1">Past Weeks<\/h2>/);
  assert.match(html, /aria-label="Open Past Weeks">Past Weeks</);
  assert.equal(js.includes('Previous Weeks'), false, 'no Previous Weeks reference remains in live.js');
});

test('7. Swipe-right is ignored while the Add popup is open', () => {
  const swipe = js.slice(js.indexOf('// Header-back-swipe'), js.indexOf('// R5 + R6:'));
  assert.match(swipe, /if \(addFormOpen\) return null;/);
  assert.equal(swipe.includes("setAddForm('options')"), false, 'swipe never steps back inside the Add popup');
  // The Back button inside the Add popup still works — only the swipe is ignored.
  assert.ok(js.includes("$('manualBackBtn')?.addEventListener('click', () => setAddForm('options'))"));
});

test('14. Week-close re-reads the fund just before a surplus reduction, no lock', () => {
  assert.match(weekClose, /const refreshFundState = async \(\) => \{/, 'refresh helper exists');
  assert.match(weekClose, /fund_shortfall_cents.*eq\('id', householdId\)\.single\(\)/, 're-reads the live shortfall');
  assert.match(weekClose, /from\('fund_ledger'\)\s*\n\s*\.select\('amount_cents'\)\.eq\('household_id', householdId\)/, 're-reads the live ledger sum');
  assert.match(weekClose, /lastPersistedShortfall = freshShortfall/, 'run deltas are reconciled on top of the fresh values');
  assert.equal(weekClose.includes('refreshFundState'), true);
  // Called before each surplus reduction: releaseDue, the A4 decrease, and the delta increase.
  const releaseDue = weekClose.slice(weekClose.indexOf('const releaseDue'));
  assert.match(releaseDue, /await refreshFundState\(\);\s*\n\s*const applied = Math\.min\(shortfall, surplusCents\);/);
  assert.match(weekClose, /Reduction after release \(A4\)[\s\S]{0,400}await refreshFundState\(\);/);
  assert.match(weekClose, /Increase after release \(P1-7\)[\s\S]{0,500}await refreshFundState\(\);/);
  assert.equal(weekClose.includes('for update'), false, 'no new lock was added');
});

test('16. Delete account deletes the auth user first, then memberships and emptied households', () => {
  const delUser = deleteAccount.indexOf('admin.auth.admin.deleteUser(user.id)');
  const delMem = deleteAccount.indexOf(".from('household_members').delete()");
  const delHh = deleteAccount.indexOf(".from('households').delete()");
  assert.ok(delUser > 0 && delMem > 0 && delHh > 0, 'all three deletes are present');
  assert.ok(delUser < delMem, 'auth user is deleted before memberships');
  assert.ok(delMem < delHh, 'memberships are deleted before emptied households');
  assert.match(deleteAccount, /let authDeleted = false;/, 'restore is gated on the auth user still existing');
  assert.match(deleteAccount, /if \(!authDeleted\) await restoreMemberships\(\);/, 'a later failure never tries to restore memberships for a deleted user');
});

test('18. Dates before Nov 1, 2026 are rejected in the manual form and CSV import', () => {
  assert.match(js, /const isPreNovDate = \(d\) => typeof d === 'string' && \/\^\\d\{4\}-\\d\{2\}-\\d\{2\}\$\/\.test\(d\) && d < '2026-11-01';/);
  assert.match(js, /if \(isPreNovDate\(f\.date\.value\)\) \{ done\(\); setFieldError\('Date: transactions start Nov 1, 2026/);
  assert.match(js, /if \(isPreNovDate\(date\)\) \{ errors\.push\(`Skipped row before Nov 1, 2026/);
  assert.match(js, /transactions start Nov 1, 2026/, 'the message names the Nov 1, 2026 start');
  // Charity forms are untouched by this change.
  assert.equal(js.includes('isPreNovDate'), true);
});

test('A. Temporary Allowance $ and Weeks fields: same 46px height, Weeks narrow and adjacent, space before Set new total, no preview sentence', () => {
  assert.match(html, /<label class="temp-field-label">New total/, '$ field has a matching label above it');
  assert.match(html, /<label class="temp-field-label weeks-field">Weeks/, 'Weeks field carries the shared field class');
  // Both controls share one rule: same height, padding, font, border, radius.
  assert.match(css, /\.temp-increase-row \.money-input-row input, body\.live \.temp-increase-row \.weeks-field select \{ width: 100%; height: 46px; margin: 0; padding: 11px 12px; font-size: 16px; border: 1px solid #e5e7eb; border-radius: 12px; min-width: 0; box-sizing: border-box; \}/);
  assert.match(css, /\.temp-increase-row \.temp-field-label \{ flex: 0 1 200px;/, '$ field is capped so Weeks sits adjacent, not far away');
  assert.match(css, /\.temp-increase-row \.temp-field-label\.weeks-field \{ flex: 0 0 64px; \}/, 'Weeks is a narrow 64px — one digit, biggest value 4');
  assert.match(css, /body\.live #addTempBtn \{ margin-top: 12px; \}/, 'field never touches the Set new total button');
  // The preview instruction sentence is gone; the preview itself
  // appears once values are entered, and stays empty until then.
  assert.equal(html.includes('Enter a new total and weeks to see the preview.'), false, 'no preview sentence in the markup');
  assert.equal(js.includes('Enter a new total and weeks to see the preview.'), false, 'no preview sentence in the code');
  assert.match(js, /if \(cents === null \|\| cents < 0\) \{ pv\.textContent = ''; return; \}/, 'empty preview until values are entered');
  assert.equal(css.includes('.weeks-label'), false, 'the old mismatched Weeks label rule is gone');
});

test('B. Set new total is primary blue; Delete account stays pale red; invite is inline Copy/Share, not a Share button', () => {
  assert.match(html, /id="addTempBtn" class="btn btn-primary"/, 'Set new total is primary blue like Save allowance');
  assert.ok(html.includes('<button id="inviteCopyBtn" class="btn btn-primary"'), 'invite Copy is primary blue');
  assert.ok(html.includes('<button id="inviteShareBtn" class="btn btn-tertiary"'), 'invite Share is grey tertiary');
  assert.equal(html.includes('settingsShareIdBtn'), false, 'no Share invite code button remains');
  assert.match(html, /id="settingsDeleteBtn" class="btn btn-danger"/, 'Delete account stays destructive pale red');
  assert.match(html, /id="saveAllowanceBtn" class="btn btn-primary"/, 'Save allowance is still primary blue');
});

test('C. Account & Household shows a members list with name and role; no fake manage buttons', () => {
  assert.match(html, /<h3>Members<\/h3>/);
  assert.ok(html.includes('id="membersList"'), 'members list container exists');
  assert.match(js, /const \{ data: mrows \} = await supabase\.rpc\('list_household_members'\);/, 'members are read via the list-members RPC (owner, Nov 6): the own-row RLS policy cannot list other members');
  assert.match(js, /class="member-row"/, 'each member renders a name + role row');
  assert.match(js, /\(you\)/, 'the signed-in member is marked');
  assert.equal(html.includes('data-member-remove'), false, 'no remove-member button: no safe RPC exists');
  assert.equal(html.includes('data-member-role'), false, 'no change-role button: no safe RPC exists');
  assert.equal(html.includes('Removing a member or changing a role needs a server step that is not built yet.'), false, 'the internal-machinery sentence is gone (owner, Nov 6)');
});

test('D. Trash is its own page, like Past Weeks and Activity', () => {
  assert.match(js, /trash: \['section-trash-head', 'section-trash'\]/, 'Trash is a view');
  assert.match(html, /<h2 tabindex="-1">Trash<\/h2>/, 'Trash has its own page head');
  assert.match(html, /id="trashBackBtn" type="button" aria-label="Back to Transactions">← Back<\/button>/, 'Trash has a Back button to Transactions');
  assert.match(html, /Bank rows you deleted live here\. The admin can bring them back\./, 'explainer lives on the Trash page');
  assert.ok(html.includes('id="section-trash"'), 'Trash card exists');
  assert.equal(html.includes('id="txTrashList"'), false, 'no inline Trash list remains in Transactions');
  assert.equal(html.includes('Close trash'), false, 'no inline close-trash button remains');
  assert.equal(js.includes("localStorage.setItem('hb-view-sub'"), false, 'Trash is no longer a persisted sub-view');
  // The link from Transactions navigates to the page, with the count.
  assert.match(js, /trashBtn\.addEventListener\('click', \(\) => showView\('trash', \{ clearMessages: true \}\)\)/, 'Trash link opens the Trash page');
  assert.match(js, /trashRowCount > 0\) \? '' : 'none'/, 'link still shows only for admins when Trash is non-empty');
  // Restore still works from the Trash page, unchanged.
  assert.match(js, /data-trash-restore=/, 'Restore buttons render on the Trash page');
  assert.match(js, /supabase\.rpc\('restore_transaction', \{ txn_id: b\.dataset\.trashRestore \}\)/, 'Restore calls the same RPC');
  // Swipe-right from the Trash page goes back to Transactions.
  assert.match(js, /currentView === 'trash'\) return \(\) => showView\('purchases'\)/);
});

test('version pins: styles v52, live.js v62', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=63/);
});
