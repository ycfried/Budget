// Weekly-left-only + profile-menu rework (owner, Nov 3, ~11:20 PM).
// Change A: the Weekly popup is Left only — Spent and Allowance
// rows are removed (balances, not spent totals, show; allowance
// lives in Settings for the admin). The Left value itself is
// computed exactly as before, and the Show transactions button is
// unchanged.
// Change B: the avatar menu header is first name + role pill on one
// line, with the user's email below in small muted text; the role
// wording paragraph is gone entirely, and the Edit-profile row is
// gone (profile editing lives in the Settings Profile card, which
// is unchanged). Menu order after the change: header, Settings,
// Sign out. Static tests only — no live data, no network, no money
// math.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

const sheetFn = js.slice(
  js.indexOf('async function openWeeklySheet()'),
  js.indexOf('const heroWeeklyTarget'),
);
assert.ok(sheetFn.length > 0, 'openWeeklySheet body found');
const visible = sheetFn.slice(
  sheetFn.indexOf('const weeklyRows = ['),
  sheetFn.indexOf('];', sheetFn.indexOf('const weeklyRows = [')),
);

const menuHead = html.slice(
  html.indexOf('<div class="profile-menu-head">'),
  html.indexOf('</div>', html.indexOf('<div class="profile-menu-head">')),
);
const menuRows = html.slice(
  html.indexOf('<div class="profile-menu-rows">'),
  html.indexOf('</div>', html.indexOf('<div class="profile-menu-rows">')),
);

test('Weekly sheet rows are exactly one Left row with the correct value', () => {
  const labels = [...visible.matchAll(/\['([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(labels, ['Left']);
  assert.ok(visible.includes("['Left', formatCents(w.availableCents)]"));
  assert.equal(visible.includes("'Spent'"), false, 'no Spent row in the popup');
  assert.equal(visible.includes("'Allowance'"), false, 'no Allowance row in the popup');
  assert.match(sheetFn, /extraAction: \{ label: 'Show transactions', result: 'show-transactions' \}/);
  assert.match(sheetFn, /confirmLabel: 'Close'/);
});

test('Weekly hero figure is unchanged (same Left value)', () => {
  assert.match(js, /\$\('weeklyAvailable'\)\.innerHTML = formatCentsHtml\(avail\)/);
});

test('profile menu header is first name + role pill on one line', () => {
  // One profile-name line containing both the name element and the
  // role pill, in that order.
  const nameLine = menuHead.match(/<p class="profile-name">.*?<\/p>/s);
  assert.ok(nameLine, 'profile-name line found in the menu header');
  assert.ok(nameLine[0].includes('id="profileName"'));
  assert.ok(nameLine[0].includes('id="profileRole"'));
  assert.ok(nameLine[0].indexOf('id="profileName"') < nameLine[0].indexOf('id="profileRole"'));
  // The pill sits on the same line via a flex row with a small gap.
  const rule = css.match(/body\.live \.profile-name \{[^}]*\}/);
  assert.ok(rule, '.profile-name rule found');
  assert.match(rule[0], /display: flex/);
  assert.match(rule[0], /gap: 8px/);
});

test('profile menu header shows first name only, never the full name', () => {
  // Both places that set the menu header take the first token.
  assert.match(js, /headerName = \(displayName \|\| s\?\.\user\?\.\email \|\| '—'\)\.split\(\/\\s\+\/\)\[0\]/);
  assert.match(js, /pn\.textContent = name\.split\(\/\\s\+\/\)\[0\] \|\| name/);
  // No assignment of a full display name / full saved name to the header.
  assert.doesNotMatch(js, /pn\.textContent = displayName \|\|/);
  assert.doesNotMatch(js, /pn\.textContent = name;/);
  // The email fallback (no space) is preserved: split keeps it whole.
  assert.equal('ycfried1@gmail.com'.split(/\s+/)[0], 'ycfried1@gmail.com');
  assert.equal('Shuki Friedman'.split(/\s+/)[0], 'Shuki');
});

test('profile menu header shows the email below, small and non-bold, without duplication', () => {
  const emailLine = menuHead.match(/<p class="small muted" id="profileEmail">.*?<\/p>/s);
  assert.ok(emailLine, 'email line present in the menu header, after the name line');
  assert.ok(menuHead.indexOf('profile-name') < menuHead.indexOf('id="profileEmail"'));
  // small + muted classes: small, non-bold text (no <strong>).
  assert.equal(emailLine[0].includes('<strong'), false);
  // No-duplication rule: the email line hides when the header itself
  // fell back to the email.
  assert.match(js, /pe2\.classList\.toggle\('hidden', pn2\.textContent !== '—' && pn2\.textContent === pe2\.textContent\)/);
});

test('role pill is capitalized Admin/Member; role wording paragraph is gone', () => {
  assert.match(js, /pr\.textContent = household\.role \? household\.role\.charAt\(0\)\.toUpperCase\(\) \+ household\.role\.slice\(1\)/);
  assert.equal(html.includes('id="profileHousehold"'), false, 'no wording-paragraph element in the menu');
  assert.equal(js.includes('profileHousehold'), false, 'no wording-paragraph rendering in JS');
  assert.equal(js.includes('you manage this household'), false, 'no admin wording text');
  assert.equal(js.includes('you can view the budget and ask for fund money'), false, 'no member wording text');
});

test('menu has no Edit-profile row and still has Settings + Sign out, in order', () => {
  assert.equal(html.includes('id="menuEditProfileBtn"'), false, 'no Edit-profile button in the menu');
  assert.equal(js.includes('menuEditProfileBtn'), false, 'no JS references to the removed button');
  assert.ok(menuRows.includes('id="menuSettingsBtn"'), 'Settings row present');
  assert.ok(menuRows.includes('id="signOutBtn"'), 'Sign out row present');
  assert.ok(menuRows.indexOf('id="menuSettingsBtn"') < menuRows.indexOf('id="signOutBtn"'), 'Settings before Sign out');
  // Settings row still opens the Settings view (where the Profile card lives).
  assert.match(js, /menuSettingsBtn.*addEventListener\('click'/s);
});

test('bank-row logo tile sits at the top of the block, row otherwise unchanged', () => {
  // Scoped rule: only the logo tile inside .bank-row gets flex-start.
  const tileRule = css.match(/body\.live \.bank-row \.bank-logo, body\.live \.bank-row \.bank-logo-tile \{[^}]*\}/);
  assert.ok(tileRule, 'bank-row logo rule found');
  assert.match(tileRule[0], /align-self: flex-start/);
  // The row itself still centers its other children (Disconnect
  // button stays where it is) — its alignment is not changed.
  const rowRule = css.match(/body\.live \.bank-row \{[^}]*\}/);
  assert.ok(rowRule, '.bank-row rule found');
  assert.match(rowRule[0], /display: flex/);
  assert.match(rowRule[0], /align-items: center/);
  assert.match(rowRule[0], /gap: 12px/);
  assert.match(rowRule[0], /padding: 12px 0/);
  // Transaction merchant tiles are untouched: no align-self rule
  // targets them.
  assert.doesNotMatch(css, /\.tx-icon-logo[^{]*\{[^}]*align-self/);
  assert.doesNotMatch(css, /\.tx-logo[^{]*\{[^}]*align-self/);
});

test('Settings Profile card itself is unchanged', () => {
  assert.ok(html.includes('id="section-profile"'));
  assert.ok(html.includes('id="profileNameInput"'));
  assert.ok(html.includes('id="saveProfileNameBtn"'));
  assert.ok(html.includes('id="saveProfileEmailBtn"'));
});

// --- Sign-up Name requirement (owner, Nov 3, ~11:22 PM) --------------
const signUpFn = js.slice(
  js.indexOf("$('signUpBtn').addEventListener('click'"),
  js.indexOf("$('signOutBtn').addEventListener('click'"),
);
assert.ok(signUpFn.length > 0, 'signUp handler found');
const signInFn = js.slice(
  js.indexOf("$('signInBtn').addEventListener('click'"),
  js.indexOf("$('signUpBtn').addEventListener('click'"),
);
assert.ok(signInFn.length > 0, 'signIn handler found');

test('auth card has a Name input for new accounts', () => {
  const input = html.match(/<input id="authName"[^>]*>/);
  assert.ok(input, 'authName input present');
  assert.match(input[0], /autocomplete="name"/);
  assert.match(input[0], /maxlength="80"/);
  // Clearly labeled for a new account, grouped with Create account.
  const authCard = html.slice(html.indexOf('id="view-auth"'), html.indexOf('id="view-household"'));
  assert.ok(authCard.includes('Name for a new account'));
  assert.ok(authCard.indexOf('id="authName"') < authCard.indexOf('id="signUpBtn"'));
  assert.ok(authCard.indexOf('New to OnBudget?') < authCard.indexOf('id="authName"'));
});

test('sign-up with an empty name is refused before signUp is called', () => {
  // The named error + focus on the Name field, via the existing
  // fail() pattern, and it must precede the Supabase call.
  assert.match(signUpFn, /if \(!signName\?\.value\.trim\(\)\) \{ fail\('Enter a name for your new account\.', signName\); return; \}/);
  assert.ok(signUpFn.indexOf("fail('Enter a name for your new account.'") < signUpFn.indexOf('supabase.auth.signUp('));
  // fail() writes authMsg and focuses the field.
  assert.match(signUpFn, /const fail = \(msg, field\) => \{ \$\('authMsg'\)\.textContent = msg; if \(field\) field\.focus\(\)/);
});

test('sign-up with a name passes full_name in metadata', () => {
  assert.match(signUpFn, /supabase\.auth\.signUp\(\{\s*email: signEmail\.value\.trim\(\), password: signPw\.value,\s*options: \{ data: \{ full_name: signName\.value\.trim\(\) \} \},?\s*\}\)/);
});

test('sign-in ignores the Name field entirely', () => {
  assert.equal(signInFn.includes('authName'), false, 'sign-in handler never reads the Name field');
  assert.match(signInFn, /supabase\.auth\.signInWithPassword\(\{\s*email: \$\('authEmail'\)\.value\.trim\(\), password: \$\('authPassword'\)\.value,/);
});

// --- Tertiary button treatment (owner, Nov 3, ~11:23 PM) ------------
test('tertiary buttons are grey fill with ink text, distinct from primary and secondary', () => {
  // Both live selectors in the one rule.
  const rule = css.match(/body\.live #view-app \.btn-tertiary, body\.live \.btn-tertiary \{[^}]*\}/);
  assert.ok(rule, 'tertiary rule found (both live selectors)');
  assert.match(rule[0], /background: #e5e7eb/, 'tertiary fill is neutral grey');
  assert.match(rule[0], /color: #0f172a/, 'tertiary text is ink');
  assert.doesNotMatch(rule[0], /#1d4ed8/, 'no deep blue left in the tertiary rule');
  // Solid fill, not an outline: border matches the fill.
  assert.match(rule[0], /border: 1px solid #e5e7eb/);
  // Primary and secondary are untouched.
  const primary = css.match(/body\.live #view-app \.btn-primary, body\.live \.btn-primary \{[^}]*\}/);
  assert.ok(primary, 'primary rule found');
  assert.match(primary[0], /background: #2f6bff/);
  const secondary = css.match(/body\.live #view-app \.btn, body\.live \.btn \{[^}]*\}/);
  assert.ok(secondary, 'secondary (base .btn) rule found');
  assert.match(secondary[0], /background: #bfdbfe/);
  assert.match(secondary[0], /color: #1e40af/);
  // btn-mid is ink (audit-fixes-morning A1), not mid blue.
  assert.match(css, /body\.live #view-app \.btn-mid, body\.live \.btn-mid \{ background: #0f172a; color: #fff;/);
});

test('no two adjacent buttons share a treatment after the tertiary change', () => {
  // Bank card (the reported row): Connect primary, Sync secondary,
  // Enable automatic sync tertiary-grey — all three distinct.
  const bank = html.slice(html.indexOf('id="section-bank"'), html.indexOf('id="bankMsg"'));
  const bankBtns = [...bank.matchAll(/<button[^>]*class="btn([^"]*)"/g)].map((m) => m[1].trim());
  assert.deepEqual(bankBtns, ['btn-primary', '', 'btn-tertiary']);
  // Filters sheet: Apply primary, Reset secondary, Cancel tertiary.
  const sheet = html.slice(html.indexOf('id="txFiltersSheet"'), html.indexOf('id="txCount"'));
  const sheetBtns = [...sheet.matchAll(/<button[^>]*class="btn([^"]*)"/g)].map((m) => m[1].trim());
  assert.ok(sheetBtns.includes('btn-primary'));
  assert.ok(sheetBtns.includes('btn-tertiary'));
  // Funds actions: primary, secondary, tertiary in order (Record
  // income left the row for the Charity sheet, funds-actions-three).
  const funds = html.slice(html.indexOf('id="section-fund-actions"'), html.indexOf('id="fundTopupsDisclosure"'));
  const fundBtns = [...funds.matchAll(/<button[^>]*class="btn([^"]*)"/g)].map((m) => m[1].trim());
  assert.deepEqual(fundBtns, ['btn-primary', '', 'btn-tertiary']);
  // Settings Account card: Share only (audit-fixes-morning B2
  // deleted the duplicate Change password button).
  const acct = html.slice(html.indexOf('id="section-settings-account"'), html.indexOf('id="settingsDeleteBtn"'));
  const acctBtns = [...acct.matchAll(/<button[^>]*class="btn([^"]*)"/g)].map((m) => m[1].trim());
  assert.deepEqual(acctBtns, ['']);
});
