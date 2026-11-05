// Popup-padding-labels-fix (owner feedback, Nov 4, morning):
// (1) the gap between the last card and the footer sentence was
// 80px of dead scroll — now 32px, with tab-bar clearance untouched.
// (2) Scrolling inside any popup now scrolls the popup only; the
// page behind stays locked until the last overlay closes.
// (3) From/To date pairs never overlap and use short labels.
// (4) Profile card loses its intro + Email h3 + email explainer +
// password note (the note lives in the change-password sheet);
// Email/Password blocks get even 20px section spacing, one card.
// (5) Bank card becomes "Bank Connection" + "The app can see
// transactions." Static tests only — no live data, no network,
// no money math, no button treatments changed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

const profile = html.slice(html.indexOf('id="section-profile"'), html.indexOf('id="section-bank"'));
assert.ok(profile.length > 0, 'profile section found');
const bank = html.slice(html.indexOf('id="section-bank"'), html.indexOf('id="section-email"'));
assert.ok(bank.length > 0, 'bank section found');
const historyFilter = html.slice(html.indexOf('id="section-history-filter"'), html.indexOf('id="section-week-history"'));
assert.ok(historyFilter.length > 0, 'history filter section found');

test('footer gap is 32px: card margin 16 + main bottom 0 + footer top 16', () => {
  assert.match(css, /body\.live main \{ padding: 24px 16px 0;[^}]*\}/, 'main bottom padding is still 0 (min-height/flex added, gap arithmetic unchanged)');
  assert.match(css, /body\.live \.card \{[^}]*margin-bottom: 16px/, 'card margin-bottom stays 16');
  assert.match(css, /\.foot \{ text-align: center; padding: 16px; \}/, 'footer padding stays 16 (top 16)');
});

test('tab-bar clearance is untouched below the footer', () => {
  assert.match(css, /padding-bottom: calc\(72px \+ env\(safe-area-inset-bottom\)\)/, 'body padding-bottom still clears the tab bar');
});

test('scroll lock is derived from the DOM and covers all three overlays', () => {
  assert.match(js, /function anyOverlayOpen\(\)/);
  const fn = js.slice(js.indexOf('function anyOverlayOpen()'), js.indexOf('function syncScrollLock()'));
  assert.ok(fn.includes("getElementById('sheetOverlay')"), 'generic sheet covered');
  assert.ok(fn.includes("getElementById('txFiltersSheet')"), 'filters sheet covered');
  assert.ok(fn.includes("getElementById('addPopupOverlay')"), 'add popup covered');
  assert.match(js, /function syncScrollLock\(\)/);
  assert.match(js, /document\.documentElement\.style\.overflow = 'hidden'/, 'html locked too (iOS Safari needs both)');
  assert.match(js, /document\.body\.style\.overflow = 'hidden'/, 'body locked');
  assert.match(js, /window\.scrollTo\(0, scrollLockY\)/, 'scroll position restored on unlock');
});

test('scroll lock is called on every overlay open and close path', () => {
  assert.match(js, /document\.body\.appendChild\(overlay\);\n    syncScrollLock\(\);/, 'generic sheet open locks');
  assert.match(js, /overlay\.remove\(\);\n      syncScrollLock\(\);/, 'generic sheet close unlocks');
  const calls = js.match(/syncScrollLock\(\);/g) ?? [];
  assert.ok(calls.length >= 6, `expected 6+ syncScrollLock calls (sheet open/close, filters open/close, tab-tap close, add popup), got ${calls.length}`);
});

test('overlay cards scroll internally and do not chain-scroll the page', () => {
  // Native-style-live: the appended bottom-sheet rule caps the sheet
  // at 88dvh; the original rule's internal-scroll properties still
  // apply (later rules only override the properties they set).
  assert.match(css, /#sheetOverlay \.sheet \{[^}]*max-height: 88dvh/, 'generic bottom sheet height capped');
  assert.match(css, /#sheetOverlay \.sheet \{[^}]*overflow-y: auto; overscroll-behavior: contain; -webkit-overflow-scrolling: touch;/, 'generic sheet scrolls internally');
  assert.match(css, /body\.live \.tx-sheet-card \{[^}]*overflow-y: auto; overscroll-behavior: contain; -webkit-overflow-scrolling: touch;/, 'filters card scrolls internally');
  assert.match(css, /body\.live \.add-popup-overlay \{[^}]*overflow-y: auto; overscroll-behavior: contain; -webkit-overflow-scrolling: touch;/, 'add popup backdrop contains scroll');
});

test('filters From/To pair cannot overlap: minmax tracks, not bare 1fr', () => {
  assert.match(css, /body\.live \.tx-sheet-pair \{ display: grid; grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\); gap: 12px; \}/);
  assert.match(css, /body\.live \.tx-sheet-pair label \{ min-width: 0; \}/);
  assert.match(css, /body\.live \.tx-sheet-pair input \{ width: 100%; box-sizing: border-box; min-width: 0; \}/);
});

test('history From/To sit side by side with short labels (stacking only at <=360px)', () => {
  assert.match(css, /#section-history-filter \.form-row-2 \{ display: grid; grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\); gap: 12px; \}/, 'history pair side by side with a real gap');
  assert.match(css, /@media \(max-width: 360px\) \{\s*#section-history-filter \.form-row-2 \{ grid-template-columns: 1fr; \}/, 'history pair stacks only where two date inputs cannot fit');
  const pair = historyFilter.slice(historyFilter.indexOf('form-row-2'), historyFilter.indexOf('btn-row'));
  assert.ok(pair.includes('id="historyFromInput"') && pair.includes('id="historyToInput"'), 'both date inputs share the one pair row');
  assert.ok(historyFilter.includes('<label>From'), 'visible label is From, not From date');
  assert.ok(historyFilter.includes('<label>To'), 'visible label is To, not To date');
  assert.ok(historyFilter.includes('aria-label="From"'), 'aria-label is From');
  assert.ok(historyFilter.includes('aria-label="To"'), 'aria-label is To');
  assert.equal(historyFilter.includes('From date'), false, 'no From date left in history filter');
  assert.equal(historyFilter.includes('To date'), false, 'no To date left in history filter');
});

test('"Week of" dropped from week headings and hero kicker, nowhere else', () => {
  assert.ok(js.includes('<strong>${fmtLong(c.week_start)}</strong>'), 'week history heading is just the date');
  assert.equal(js.includes('<strong>Week of'), false, 'no Week of in week history headings');
  assert.ok(js.includes('`${fmtLong(weekStart)} (Sun–Sat)`'), 'hero kicker is just the date range');
  assert.equal(js.includes('Week of ${fmtLong(weekStart)}'), false, 'no Week of in hero kicker');
  assert.ok(js.includes('Week of ${fmtLong(r.week_start)} · Restored'), 'activity restoration sentence deliberately untouched');
});

test('profile intro, Email h3, and email explainer are gone; field and button stay', () => {
  assert.equal(profile.includes('Your name shows at the top of the profile menu'), false, 'intro paragraph deleted');
  assert.equal(profile.includes('<h3>Email</h3>'), false, 'Email h3 deleted');
  assert.equal(profile.includes('Changing your email sends a confirmation'), false, 'email explainer deleted');
  assert.ok(profile.includes('class="profile-email-label">Email'), 'Email field label present');
  assert.ok(profile.includes('id="profileEmailInput"'), 'Email input present');
  assert.ok(profile.includes('id="saveProfileEmailBtn" class="btn"'), 'Save email button present with treatment unchanged');
});

test('password note moved out of the profile card into the change-password sheet', () => {
  assert.equal(profile.includes('Password must be at least 8 characters.'), false, 'note gone from profile card');
  assert.ok(profile.includes('<h3>Password</h3>'), 'Password h3 stays');
  assert.ok(profile.includes('id="profilePasswordBtn"'), 'Change password button stays');
  assert.ok(js.includes('Password requirement: at least 8 characters.'), 'change-password sheet already states the requirement (no duplication)');
});

test('profile blocks share even 20px section spacing, still one card', () => {
  assert.match(css, /#section-profile \.profile-email-label \{ display: block; margin-top: 20px; \}/, 'Email label spacing');
  assert.match(css, /#section-profile h3 \{ font-size: 14px; font-weight: 600; margin-top: 20px; \}/, 'Password h3 matches the Name/Email label size (14px/600)');
  assert.equal(profile.split('class="card"').length, 2, 'exactly one card-class occurrence in the slice — the trailing bank div fragment at the slice boundary — so profile is still one card, not split');
});

test('settings header and back button untouched', () => {
  assert.ok(html.includes('id="settingsBackBtn"'), 'Settings back button present');
  // Merged-audit A9: Settings heading is focusable so focus can move to it when Settings opens.
  assert.ok(html.includes('<h2 tabindex="-1">Settings</h2>'), 'Settings heading present and focusable');
});

test('bank card heading and sentence are the short versions, nothing else retitled', () => {
  assert.ok(bank.includes('<h2>Bank Connection</h2>'), 'heading is exactly Bank Connection');
  assert.equal(bank.includes('(read-only)'), false, 'no (read-only) in the bank heading');
  // Send-live-bundle: the unified sentence replaces the shortened text.
  assert.ok(bank.includes('<p class="muted small">Look only — it never moves, sends, or changes anything.</p>'), 'sentence is exactly the unified text');
  assert.equal(bank.includes('never move money'), false, 'old sentence gone');
  assert.ok(html.includes('<h2>Profile</h2>'), 'Profile heading untouched');
  // Send-live-bundle: the separate History card is gone; History
  // is one tappable row on Home instead.
  assert.equal(html.includes('id="section-history-row"'), false, 'Home History row removed (Past weeks live inside Transactions)');
  assert.equal(html.includes('id="section-history-link"'), false, 'separate History card gone');
});

test('version pins: styles v42, live.js v52', () => {
  assert.match(html, /styles\.css\?v=42/);
  assert.match(html, /live\.js\?v=52/);});
