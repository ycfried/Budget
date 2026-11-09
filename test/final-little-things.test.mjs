// Final little things (owner, Nov 4, 2026) — five items, branch-only.
// 1. Home on every fresh load, never on in-app navigation.
// 2. Sign-in/up smart fill: logo on top, natural card, useful bottom line.
// 3. Refined Title Case audit, platform-wide (minor words lower).
// 4. Profile: Save Name + Save Email both primary blue; Change Password grey.
// 5. Merchant/bank/card icons off dead Clearbit, onto Google favicon.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const html = readFileSync(path.join(root, '..', 'live.html'), 'utf8');
const css = readFileSync(path.join(root, '..', 'styles.css'), 'utf8');
const js = readFileSync(path.join(root, '..', 'live.js'), 'utf8');

// 1. Home on load: boot always starts on Home ('week'), ignoring any
// saved last-view restore. In-app navigation is untouched: showView
// still writes hb-view, it is just inert on boot.
test('home on load: boot ignores saved last view, in-app navigation still writes it', () => {
  assert.match(js, /let currentView = 'week';\nlet previousView = 'week';/);
  assert.equal(js.includes('resolveRestoredView('), false, 'no restore call in live.js (comment only)');
  assert.match(js, /localStorage\.setItem\(VIEW_STORAGE_KEY, name\)/, 'showView still records the view for the session');
});

// 2. Sign-in/up smart fill: logo on top, natural-height card, bottom line.
test('sign-in/up smart fill: logo block, natural card, bottom line, no stretch', () => {
  assert.equal(html.includes('class="auth-brand"'), true);
  assert.equal(html.includes('class="auth-foot"'), true);
  assert.ok(html.includes('Your household budget, shared in one place.'));
  assert.ok(html.includes('Bank and email are read-only &mdash; nothing is ever moved or changed.'));
  assert.match(css, /body\.live #view-auth, body\.live #view-household \{ flex: 0 0 auto; display: block; \}/);
  assert.equal(css.includes('#view-auth { flex: 1 1 auto'), false, 'old stretch rule gone');
  assert.match(css, /body\.live \.auth-brand-logo \{ width: 72px; height: 72px; border-radius: 50%; \}/);
});

// 3. Refined Title Case: minor words lower unless first word.
test('title case: Or Join a Household, headings and sheet titles refined', () => {
  assert.ok(html.includes('Or Join a Household'));
  assert.equal(html.includes('Or Join A Household'), false);
  for (const h of ['Recent Transactions', 'Add a Transaction by Hand',
    'Import Transactions from a CSV File', 'Give to Charity', 'Connected Accounts',
    'Connected Email', 'Account &amp; Household', 'Delete Account', 'Money Added',
    'Charity Income', 'Refund Restorations &amp; Held Refunds', 'Possible Duplicates',
    'Add Money', 'Charity Income &amp; Rate', 'Record Income', 'Use Fund Money',
    'Ask for Fund Money', 'Past Weeks', 'Week History']) {
    assert.ok(html.includes(h), `heading present: ${h}`);
  }
  for (const t of ["title: 'Approve from the Fund'", "title: 'Fund Is Short'",
    "title: 'Forgot Password?'",
    "title: 'Reclassify Transaction'", "title: 'Move to Trash'",
    "title: 'Change Allowance'", 'Release Held Refund',
    'Mark as Charity Gift', 'Delete Everything?']) {
    assert.ok(js.includes(t), `sheet/dialog title present: ${t}`);
  }
  // Charity period: the sheet title is gone with the sheet — the
  // period now lives as the small line in the expanded Charity card.
  assert.ok(js.includes('November 2026 onward'), 'charity period kept in the expansion');
  // Sentence-case subtitles deliberately untouched.
  assert.ok(html.includes('Create a household as admin, or join one with an invite code.'));
});

// 4. Profile buttons: both saves primary blue, Change Password grey tertiary.
test('profile buttons: Save Name and Save Email primary blue, Change Password grey', () => {
  assert.ok(html.includes('id="saveProfileNameBtn" class="btn btn-primary"'));
  assert.ok(html.includes('id="saveProfileEmailBtn" class="btn btn-primary"'));
  assert.ok(html.includes('id="profilePasswordBtn" class="btn btn-tertiary"'));
});

// 5. Icons: Clearbit gone as a source; Google favicon + brand monogram;
// bank/card icon when the transaction's account is known.
test('icons: Google favicon first, brand monogram fallback, bank icon per transaction', () => {
  assert.equal(js.includes('src="https://logo.clearbit.com'), false, 'no Clearbit image source left');
  assert.ok(js.includes('https://www.google.com/s2/favicons?domain='));
  assert.ok(js.includes('function iconForMerchant('));
  assert.ok(js.includes('function bankIconForTx('));
  assert.ok(js.includes('function iconForTx(t)'));
  assert.ok(js.includes('await loadInstitutionBySuffix()'));
  assert.equal(js.includes('iconForMerchant(t.merchant)'), false, 'all three tx row lists use iconForTx');
});

// Pins bumped consistently with the live-file changes.
test('pins bumped to v53/v65', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=65/);
});
