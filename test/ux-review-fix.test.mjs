// UX-review fix (Nov 3, 2026) static regression tests — run with:
//   node --test test/ux-review-fix.test.mjs
// Static source checks only: no DOM, no network, no database.
// Covers the owner-sent UI/UX review items plus the owner updates
// folded into the same package (blank shell, duplicates card, solid
// button colors, Funds chevrons, weight rebalance, Weekly sheet
// paragraph, numbers-only stat cards, profile name, Show password,
// Add card header + hide-by-default).

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const reset = readFileSync(new URL('../reset.html', import.meta.url), 'utf8');

// --- P1: transfer gating + charity dash + weekly kicker ---------------
test('Use Extra Fund is offered only for charges', () => {
  assert.match(js, /const qualifiesForFund = t\.kind === 'charge';/);
  assert.match(js, /!isAdmin \? \(qualifiesForFund \? fundBtn : ''\)/);
  assert.match(js, /qualifiesForFund \? fundBtnAdmin : ''/);
  // Defensive handler gate for stale DOM.
  assert.match(js, /if \(row && row\.kind !== 'charge'\) \{ await showAlert\('Does not qualify'/);
});

test('charity Home figure is a confirmed number, never a dash on success', () => {
  // Success path assigns the signed number; the catch block still
  // assigns the dash for the failed-load state. (Loading-indicators:
  // the success line also clears the skeleton aria-busy flag, so the
  // match allows the braced form.)
  assert.match(js, /if \(cp\) \{ cp\.textContent = formatCents\(remaining\); cp\.removeAttribute\('aria-busy'\); \}/);
  assert.doesNotMatch(js, /committed === 0 && given === 0\) \? '—'/);
});

test('weekly hero kicker is neutral and the sign-instruction sentence is gone', () => {
  assert.ok(html.includes('<div class="kicker">This week · <span id="weekLabel">'));
  assert.doesNotMatch(html, /Available this week/);
  assert.doesNotMatch(html, /If the big number is negative/);
});

// --- Blank shell --------------------------------------------------------
test('boot shows the current view before refresh, and refresh re-shows on failure', () => {
  const boot = js.slice(js.indexOf('async function boot()'), js.indexOf('async function boot()') + 1200);
  assert.match(boot, /await show\('app'\);\s*\/\/ UX-review-fix, blank shell[\s\S]*?showView\(currentView\);/);
  assert.match(js, /try \{ if \(household\) showView\(currentView\); \} catch/);
});

// --- Buttons: solid colors, no adjacent duplicates ---------------------
test('button levels are solid colors, no pale tint or white outline', () => {
  // Tertiary (SUPERSEDED Nov 3, ~11:23 PM, owner Bank-card feedback):
  // solid neutral grey, not the former deep blue, never the rejected
  // pale tint or a white outline.
  assert.match(css, /body\.live #view-app \.btn-tertiary, body\.live \.btn-tertiary \{ background: #e5e7eb; color: #0f172a; border: 1px solid #e5e7eb; \}/);
  assert.match(css, /body\.live #view-app \.btn-mid, body\.live \.btn-mid \{ background: #0f172a; color: #fff; border: 1px solid #0f172a; \}/);
  // The btn-tertiary RULE itself (not comments elsewhere) is grey, never the rejected tint.
  const tertiaryRule = css.split('\n').find((l) => l.includes('.btn-tertiary {'));
  assert.ok(tertiaryRule && tertiaryRule.includes('#e5e7eb') && !tertiaryRule.includes('#eef4ff'), tertiaryRule);
  // No btn-outline RULE or usage remains (the name survives only in
  // CSS comments explaining the rename to btn-mid).
  assert.doesNotMatch(css, /btn-outline\s*\{/);
  assert.doesNotMatch(html, /btn-outline/);
  assert.doesNotMatch(js, /btn-outline/);
  // Funds actions: primary, pale, grey — three buttons, three
  // treatments (Record income left the row for the Charity sheet).
  assert.ok(html.includes('<button class="btn btn-primary" id="fundActionAddBtn"'));
  assert.ok(html.includes('<button class="btn" id="fundActionUseBtn"'));
  assert.ok(html.includes('<button class="btn btn-tertiary" id="fundActionAskBtn"'));
  assert.equal(html.includes('fundActionIncomeBtn'), false);
  // Detail: Mark (tertiary grey) vs Use Fund (mid) are different.
  assert.ok(js.includes('class="btn btn-small btn-tertiary" data-mark-charity='));
  assert.ok(js.includes("class=\"btn btn-small btn-mid\""));
});

// --- Held button removed; held amount folds into fund Pending -----
test('held button removed; held amount folds into the fund sheet Pending', () => {
  // Audit-fixes-morning B1: the Funds "Held for review" button and
  // its wrap are gone from the HTML (it duplicated the Review
  // card's opener on the same page). The guarded JS references
  // remain as no-ops, and the fund sheet's Pending row folds held
  // weeks in (fund-sheet-button-rule, owner Nov 4) — no Held row.
  assert.equal(html.includes('id="fundHeldLinkWrap"'), false);
  assert.equal(html.includes('id="fundHeldLinkBtn"'), false);
  assert.equal(css.includes('#fundHeldLinkWrap'), false);
  assert.match(js, /fundHeldLinkBtn.*addEventListener\('click'/);
  assert.match(js, /getElementById\('reviewDetails'\)/);
  assert.match(js, /details\.open = true/);
  const fundRows = js.slice(js.indexOf('function fundBreakdownRows'), js.indexOf('function charityBreakdownRows'));
  assert.ok(fundRows.includes('heldTotal'), 'fund sheet Pending must fold in held weeks');
  assert.doesNotMatch(fundRows, /\['Held for review',/);
});

test('bank Disconnect identifies the exact connection by masked accounts', () => {
  assert.match(js, /const connMasks = acctRows\.filter/);
  assert.match(js, /Disconnect \$\{connId\}/);
  assert.match(js, /stop syncing this connection only/);
});

// --- Sign-in / profile / password ---------------------------------------
test('sign-in: primary Sign in, password toggle, recovery copy on failure', () => {
  assert.ok(html.includes('id="togglePasswordBtn"'));
  assert.match(js, /togglePasswordBtn.*addEventListener\('click'/);
  assert.match(js, /Forgot password\? below to reset it/);
  // Auth-card-cleanup: the "New to OnBudget?" lead-in is gone (the
  // side-by-side buttons make the choice self-evident).
  assert.equal(html.includes('New to OnBudget?'), false);
});

test('profile menu shows a name header; profile editing lives in Settings, not the menu', () => {
  assert.ok(html.includes('id="profileName"'));
  // Weekly-left-only-profile-menu (owner, Nov 3, ~11:20 PM): the
  // Edit-profile row is gone from the avatar menu; the Settings
  // Profile card itself is unchanged.
  assert.equal(html.includes('id="menuEditProfileBtn"'), false);
  assert.ok(html.includes('id="menuSettingsBtn"'));
  assert.ok(html.includes('id="signOutBtn"'));
  assert.ok(html.includes('id="section-profile"'));
  assert.match(js, /user_metadata\?\.full_name \|\| s\?\.user\?\.user_metadata\?\.name/);
  assert.match(js, /supabase\.auth\.updateUser\(\{ data: \{ full_name: name \} \}\)/);
  assert.match(js, /supabase\.auth\.updateUser\(\{ email \}\)/);
  assert.ok(html.includes('does not change until you confirm it'));
  assert.match(js, /until you confirm it/);
  // No SQL for this item: the profile save paths are auth only.
  assert.doesNotMatch(js, /display_name.*update|UPDATE household_members/);
});

test('Show/Hide toggle exists on every password field', () => {
  // Sign-in field.
  assert.ok(html.includes('id="togglePasswordBtn"'));
  // Change-password sheet (generic showSheet password branch).
  assert.match(js, /safeType === 'password'/);
  assert.match(js, /aria-label', showing \? 'Hide password' : 'Show password'/);
  // Reset page: both fields.
  assert.ok(reset.includes('id="toggleNewPasswordBtn"'));
  assert.ok(reset.includes('id="toggleConfirmPasswordBtn"'));
});

// --- Filter sheet keyboard ----------------------------------------------
test('filter sheet: Escape closes, Tab is trapped, focus returns', () => {
  assert.match(js, /if \(e\.key === 'Escape'\) \{ e\.preventDefault\(\); document\.getElementById\('txFiltersCancelBtn'\)\?\.click\(\); document\.getElementById\('txFiltersToggle'\)\?\.focus\(\);/);
  assert.match(js, /const focusables = \[\.\.\.f\.querySelectorAll\('select, input, button'\)\]/);
});

// --- Duplicates card ------------------------------------------------------
test('duplicates render as vertical comparison cards, not bank rows', () => {
  assert.match(js, /card\.className = 'dedupe-card'/);
  assert.match(js, /dedupe-merchant/);
  assert.match(js, /Match: \$\{matchParts\.join\(', '\)\}\./);
  assert.match(css, /body\.live \.dedupe-card \{/);
  assert.match(css, /body\.live \.dedupe-pair \{ display: grid;/);
});

// --- Funds chevrons + weight rebalance ------------------------------------
test('Funds chevrons sit bottom-right and face down', () => {
  assert.match(html, /<span class="fund-balance-chevron"[^>]*>⌄<\/span>/);
  assert.doesNotMatch(html, /fund-balance-chevron"[^>]*>›/);
  assert.match(css, /align-self: flex-end; margin-top: auto;/);
});

test('weight rebalance: figures 800, headings 700, buttons 600', () => {
  assert.match(css, /body\.live \.hero \.big \{ font-size: 42px; font-weight: 800;/);
  assert.match(css, /body\.live \.num \{ font-size: 26px; font-weight: 800;/);
  assert.match(css, /body\.live \.fund-balance \{ font-size: 32px; font-weight: 800;/);
  assert.match(css, /body\.live h1, body\.live h2, body\.live h3 \{ letter-spacing: -0\.02em; font-weight: 700; \}/);
  assert.match(css, /font-size: 15px; font-weight: 600; \}\s*body\.live #view-app \.btn-primary/);
  // No other body.live 800 weights remain.
  const live800 = [...css.matchAll(/body\.live[^}]*?font-weight: 800/g)];
  assert.equal(live800.length, 3, `expected only the 3 figure rules at 800, got ${live800.length}`);
});

// --- Weekly sheet + stat cards --------------------------------------------
// Weekly-sheet-trim (owner correction, Nov 3, ~9:59 PM, supersedes
// the PR #21 disclosure design): the Weekly sheet has no calculation
// paragraph AND no disclosure — the equation rows are gone from the
// sheet entirely, not hidden behind a tap.
test('Weekly sheet calculation is gone from the sheet, never a paragraph', () => {
  assert.doesNotMatch(js, /How it fits together/);
  const sheetFn = js.slice(
    js.indexOf('async function openWeeklySheet()'),
    js.indexOf('const heroWeeklyTarget'),
  );
  assert.equal(sheetFn.includes('disclosure:'), false, 'no disclosure in the Weekly sheet');
  assert.equal(sheetFn.includes(`'Base spending room'`), false, 'no Base spending room row in the Weekly sheet');
});

test('Home stat cards are Title + Amount only, words in aria-labels', () => {
  assert.doesNotMatch(html, /homeWeeklySecondary|homeFundSecondary|homeCharitySecondary/);
  // Excluded-decisions: the small Weekly card is gone — the hero number
  // carries the same figure and the same aria words (see
  // test/excluded-decisions.test.mjs for the full hero-target tests).
  assert.match(js, /\$\('weeklyAvailable'\)\.innerHTML = formatCentsHtml\(avail\);/);
  assert.match(js, /\$\('weeklyAvailable'\)\.classList\.toggle\('negative', avail < 0\)/);
  assert.match(js, /Weekly Budget, over budget by/);
  assert.match(js, /Charity, no charity tracked yet, show breakdown/);
  assert.match(css, /body\.live \.stat-card \.num\.negative \{ color: var\(--soft-red\); \}/);
});

// --- Add popup --------------------------------------------------------------
// Add-plus-button (owner design Nov 3, 9:49 PM): the old inline
// choice card is gone; the Transactions header has a blue + button
// that opens an options popup, and each option moves its existing
// form section into the popup. The list is still the page when no
// popup is open.
test('Add is a blue + button opening an options popup, no choice card', () => {
  assert.doesNotMatch(html, /section-add-choice/);
  assert.doesNotMatch(html, /Add \/ Import transaction/);
  assert.match(html, /id="txAddBtn"[^>]*aria-label="Add">\+</);
  assert.match(html, /id="addPopupOverlay"/);
  assert.match(html, /id="addOptionPurchaseBtn"/);
  assert.match(html, /id="addOptionDonationBtn"/);
  assert.match(html, /id="addOptionUploadBtn"/);
  assert.match(js, /\$\('txAddBtn'\)\?\.addEventListener\('click', \(\) => setAddForm\('options'\)\);/);
  assert.match(js, /addFormOpen === 'options'/);
});

// --- Filters sheet: one label per group, pairs side-by-side ------------
test('filters sheet has no repeated heading+label and pairs share a line', () => {
  const sheet = html.slice(html.indexOf('id="txFiltersSheet"'), html.indexOf('id="txCount"'));
  assert.doesNotMatch(sheet, /<h4>Status<\/h4>/);
  assert.doesNotMatch(sheet, /<h4>Card \/ Account<\/h4>/);
  assert.doesNotMatch(sheet, /<h4>Sorting<\/h4>/);
  assert.doesNotMatch(sheet, /Amount from|Amount to/);
  // Filters-compact (Nov 3, 2026): amounts are Min/Max, dates live
  // under a "When" heading — the v29 From ($)/To ($) and Dates labels
  // were replaced by the simpler system, not removed by accident.
  assert.ok(sheet.includes('<label>Min'));
  assert.ok(sheet.includes('<label>Max'));
  assert.ok(sheet.includes('<h4>Amount</h4>'));
  assert.ok(sheet.includes('<h4>When</h4>')); // When groups several distinct fields, so its heading stays.
  assert.equal((sheet.match(/tx-sheet-pair/g) || []).length, 2, 'exactly the date pair and the amount pair');
  assert.match(css, /body\.live \.tx-sheet-pair \{ display: grid; grid-template-columns: 1fr 1fr;/);
  // No filter logic touched: ids and option values unchanged.
  assert.ok(sheet.includes('id="txStatusSelect"'));
  assert.ok(sheet.includes('id="txMinAmount"'));
  assert.ok(sheet.includes('id="txMaxAmount"'));
  assert.ok(sheet.includes('id="txFromDate"'));
  assert.ok(sheet.includes('id="txToDate"'));
});

// --- Savings wording + manual field errors + CSV numbering ------------------
test('savings wording is plain, single empty message, no attestation', () => {
  assert.doesNotMatch(js, /attestation/);
  assert.match(js, /No past savings records yet/);
  assert.match(js, /missing balance, not \$0/);
});

test('manual field errors are inline, CSV preview is numbered', () => {
  assert.ok(html.includes('id="manualFormError"'));
  assert.match(js, /setFieldError\('Amount: enter a positive amount\.'/);
  assert.match(js, /previewRows\.map\(\(r, i\) =>/);
  assert.match(js, /\$\{i \+ 1\}\. \$\{esc\(r\.date\)\}/);
});
