// Follow-ups Nov 6, 2026 (owner feedback, same branch):
// E. Email Alerts layout — connected email first, buttons below,
//    no standalone "Connected" line, "Last checked" only.
// F. Temporary Allowance fields — Weeks narrow and adjacent to New
//    total, clear space before Set new total, preview sentence gone.
// Invite inline — code box in the Account & Household card with
//    Copy/Share, no sheet, no "Share invite code" button.
// Member names — a row shows the person's NAME, never "Member".
// No live data, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

// --- E. Email Alerts layout ----------------------------------------------

test('E. Email buttons sit BELOW the connected email, not above it', () => {
  const section = html.slice(html.indexOf('id="section-email"'), html.indexOf('id="settingsCard"'));
  const listAt = section.indexOf('id="emailConnectionsList"');
  const btnsAt = section.indexOf('id="connectEmailBtn"');
  const pollAt = section.indexOf('id="pollEmailBtn"');
  const headingAt = section.indexOf('Connected Email');
  assert.ok(headingAt > 0 && listAt > headingAt, 'Connected Email heading and list come first');
  assert.ok(btnsAt > listAt && pollAt > listAt, 'Connect email and Check email now come after the connected email');
  assert.ok(section.indexOf('id="emailMsg"') > btnsAt, 'the result line sits under the buttons');
  // Button treatments unchanged: Connect primary blue, Check grey.
  assert.ok(section.includes('id="connectEmailBtn" class="btn btn-primary"'));
  assert.ok(section.includes('id="pollEmailBtn" class="btn btn-tertiary"'));
});

test('E. No standalone "Connected" line in an email row; "Last checked" stays', () => {
  const emailBlock = js.slice(js.indexOf("const emailCard = $('section-email');"), js.indexOf('// Extra Fund summary'));
  const code = emailBlock.replace(/\/\/[^\n]*/g, '');
  assert.equal(code.includes("'Connected'"), false, 'no redundant Connected status word is rendered');
  assert.match(code, /`Last checked \$\{fmtDateTime\(c\.last_poll_at\)\}`/, 'Last checked is the one small grey line under the email');
  assert.match(code, /Needs reconnect — access was revoked or expired\./, 'a real problem still gets a line');
  assert.match(code, /None — connect an email below\./, 'empty state points below, where the buttons now are');
});

// --- F. Temporary Allowance fields ---------------------------------------

test('F. Weeks is narrow and adjacent to New total; space before the button', () => {
  assert.match(css, /\.temp-increase-row \{ display: flex; align-items: flex-start; gap: 12px; flex-wrap: nowrap; \}/, 'the two fields share one row with a 12px gap');
  assert.match(css, /\.temp-increase-row \.temp-field-label \{ flex: 0 1 200px;/, 'New total is capped so Weeks sits close beside it');
  assert.match(css, /\.temp-increase-row \.temp-field-label\.weeks-field \{ flex: 0 0 64px; \}/, 'Weeks is one-digit narrow');
  assert.match(css, /body\.live #addTempBtn \{ margin-top: 12px; \}/, 'clear space between the fields and Set new total');
});

test('F. Preview sentence is gone; the preview itself still appears on values', () => {
  assert.equal(html.includes('Enter a new total and weeks'), false);
  assert.equal(js.includes('Enter a new total and weeks'), false);
  assert.match(js, /pv\.textContent = `Base \$\{baseText\} · New total \$\{formatCents\(cents\)\}/, 'the preview text itself is unchanged once values are entered');
});

// --- Invite code inline ----------------------------------------------------

test('Invite code is shown inline in the card: big code box, Copy + Share', () => {
  assert.ok(html.includes('id="inviteCodeBox"'), 'code box lives in the Account & Household card');
  assert.ok(html.includes('id="inviteCodeText" class="invite-code"'), 'code is large monospace');
  assert.ok(html.includes('id="inviteCopyBtn" class="btn btn-primary"'), 'Copy is primary blue');
  assert.ok(html.includes('id="inviteShareBtn" class="btn btn-tertiary"'), 'Share is grey tertiary');
  assert.ok(html.includes('Members join with the invite code below.'), 'plain intro line, no machinery');
  assert.match(css, /body\.live \.invite-code \{[^}]*font-size: 28px; font-weight: 700; letter-spacing: 4px;/, 'code is big and clear');
  assert.match(css, /body\.live \.invite-code-box \{[^}]*border: 1\.5px solid #2f6bff;/, 'code box is outlined in brand blue');
});

test('Invite Code sheet and Share button are gone; the old sentence is gone', () => {
  assert.equal(html.includes('settingsShareIdBtn'), false);
  assert.equal(js.includes("title: 'Invite Code'"), false, 'no Invite Code sheet is opened anywhere');
  assert.equal(js.includes('Copied to clipboard.'), false);
  assert.equal(html.includes('Removing a member or changing a role needs a server step'), false, 'no internal-machinery sentence');
  assert.equal(js.includes("getElementById('settingsShareIdBtn')"), false, 'no code wires the old button (a comment may name it)');
});

test('Share calls the native share sheet with the code in the text; Copy is the fallback', () => {
  const share = js.slice(js.indexOf('async function shareInviteCode'), js.indexOf('let currentInviteCode'));
  assert.match(share, /await navigator\.share\(\{ title: 'OnBudget invite code', text \}\)/, 'native share sheet with the code in the text');
  assert.match(share, /`Join my household on OnBudget with invite code \$\{code\}`/, 'prefilled message carries the code');
  assert.match(share, /if \(e\?\.name === 'AbortError'\) return;/, 'dismissing the sheet does not copy');
  assert.match(share, /await copyInviteCode\(\);/, 'no native share means Copy');
  const copy = js.slice(js.indexOf('async function copyInviteCode'));
  assert.match(copy, /await navigator\.clipboard\.writeText\(currentInviteCode\)/, 'Copy writes the code');
  assert.match(copy, /btn\.textContent = 'Copied'/, 'brief Copied confirmation on the button');
  assert.match(js, /loadInviteCodeInline\(\);/, 'the code is loaded with the members list on refresh');
  assert.match(js, /if \(household\?\.role !== 'admin'\) \{ box\.hidden = true;/, 'members never see the code');
});

// --- Member names ------------------------------------------------------------

const memberStart = js.indexOf('function memberDisplayName');
const memberSrc = js.slice(memberStart, js.indexOf('  try {', memberStart));
const memberDisplayName = new Function(`${memberSrc}; return memberDisplayName;`)();

test('Member rows show a personal name, never "Member"', () => {
  const me = { id: 'u-admin', user_metadata: { full_name: 'Shuki Friedman' }, email: 'ycfried1@gmail.com' };
  // The owner's row, as seen live: stored name absent, metadata name present.
  assert.equal(memberDisplayName({ user_id: 'u-admin', display_name: null, role: 'admin' }, me), 'Shuki Friedman');
  // A stored display name wins over metadata.
  assert.equal(memberDisplayName({ user_id: 'u-admin', display_name: 'Shuki', role: 'admin' }, me), 'Shuki');
  // No stored name and no metadata name: the email prefix, not "Member".
  const noName = { id: 'u-admin', user_metadata: {}, email: 'ycfried1@gmail.com' };
  assert.equal(memberDisplayName({ user_id: 'u-admin', display_name: null, role: 'admin' }, noName), 'ycfried1');
  // Another member with a stored name reads it.
  const spouse = { id: 'u-spouse', user_metadata: {}, email: 'chayasf1@gmail.com' };
  assert.equal(memberDisplayName({ user_id: 'u-other', display_name: 'Chaya', role: 'member' }, spouse), 'Chaya');
  // No name anywhere for another member: never the word "Member".
  assert.notEqual(memberDisplayName({ user_id: 'u-other', display_name: null, role: 'member' }, spouse), 'Member');
  assert.notEqual(memberDisplayName({ user_id: 'u-other', display_name: '  ', role: 'member' }, spouse), 'Member');
});

test('Members render uses memberDisplayName, with (you) on the current user', () => {
  assert.match(js, /const name = memberDisplayName\(m, me\);/);
  assert.match(js, /const you = me && m\.user_id === me\.id \? ' \(you\)' : '';/);
  assert.equal(js.includes("|| 'Member';"), false, 'the old Member fallback is gone');
});
