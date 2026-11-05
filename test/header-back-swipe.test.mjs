// Header-back-swipe (owner, Nov 4, 2026): header-only cards are not
// cards, every Back control is the same light brand blue, and swipe
// right goes back. Plus the Profile Password label size (owner, Nov 4):
// Password must be the same size as Name and Email.
// Style/gesture only — no figure, math, flow, or destination change
// (Back/swipe-back destinations are the same as the Back buttons).
// Static tests only — no DOM, no network, no database.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

test('pins bumped to v43/v53', () => {
  assert.ok(html.includes('styles.css?v=43'));
  assert.ok(html.includes('live.js?v=53'));
});

test('header-only cards are plain headers, not cards', () => {
  // The three header-only cards are now .page-head, not .card.
  for (const id of ['section-settings-head', 'section-prevweeks-head', 'section-activity-head']) {
    assert.match(html, new RegExp(`<div class="page-head" id="${id}">`), `${id} is a plain header`);
    assert.equal(html.includes(`<div class="card" id="${id}">`), false, `${id} is no longer a card`);
    assert.ok(html.includes(`id="${id}"`), `${id} id kept so VIEWS/focus still work`);
  }
  // Titles, Back controls, and the PrevWeeks/Activity subtext lines stay.
  assert.ok(html.includes('<h2 tabindex="-1">Settings</h2>'));
  assert.ok(html.includes('<h2 tabindex="-1">Previous Weeks</h2>'));
  assert.ok(html.includes('<h2 tabindex="-1">Activity</h2>'));
  assert.ok(html.includes('Closed weeks, read-only. Tap a week to see its summary and its transactions.'));
  assert.ok(html.includes('Who did what, and when — not the transaction list.'));
  // Plain header has no card chrome, and is hidden until showView shows it.
  assert.match(css, /body\.live \.page-head \{ background: none; border: 0; box-shadow: none;[^}]*padding: 4px 4px 12px;/);
  assert.match(css, /#view-app > \.card, #view-app > \.grid, #view-app > p, #view-app > \.page-head \{ display: none; \}/);
  // VIEWS still list the header ids (showView shows/hides by id, not by .card).
  assert.match(js, /settings: \[[^\]]*section-settings-head/);
  assert.match(js, /prevweeks: \[[^\]]*section-prevweeks-head/);
  assert.match(js, /activity: \[[^\]]*section-activity-head/);
});

test('every Back control is the same light brand blue, none is grey', () => {
  // #60a5fa was considered but is ~2.5:1 on white, too light for 15px
  // link text; #3b82f6 is the brand light blue that stays readable.
  assert.match(css, /\.back-link, body\.live \.settings-back-link \{ background: none; border: 0; color: #3b82f6; font-weight: 700; font-size: 15px;/);
  // #475569 still exists in the file (a status pill and a comment
  // documenting the old colour) — what must be gone is any Back rule
  // using it.
  assert.doesNotMatch(css, /\.settings-back-link \{[^}]*#475569/, 'header Back is no longer grey');
  assert.doesNotMatch(css, /\.back-link, body\.live \.settings-back-link \{[^}]*#475569/, 'shared Back rule is no longer grey');
  // Header Backs keep their ids and handlers.
  for (const id of ['settingsBackBtn', 'prevWeeksBackBtn', 'activityBackBtn']) {
    assert.ok(html.includes(`id="${id}"`), `${id} present`);
  }
  // Form Backs and sign-up Backs are back-links now, not pale/grey buttons.
  for (const id of ['manualBackBtn', 'csvBackBtn', 'charityBackBtn', 'fundAddBackBtn', 'charityIncomeBackBtn', 'fundUseBackBtn', 'fundAskBackBtn', 'authNameBackBtn', 'householdNameBackBtn']) {
    assert.match(html, new RegExp(`<button[^>]*class="back-link"[^>]*id="${id}"|<button id="${id}" class="back-link"`), `${id} is a back-link`);
  }
  assert.equal(html.includes('id="authNameBackBtn" class="btn btn-tertiary"'), false, 'sign-up Back is no longer grey tertiary');
  assert.equal(html.includes('id="householdNameBackBtn" class="btn btn-tertiary"'), false, 'household Back is no longer grey tertiary');
  // Destinations unchanged: Back buttons still call the same actions.
  assert.ok(js.includes("$('manualBackBtn')?.addEventListener('click', () => setAddForm('options'))"));
  assert.ok(js.includes("document.getElementById('settingsBackBtn')?.addEventListener('click', () => showView(previousView || 'week'))"));
  assert.ok(js.includes("document.getElementById('prevWeeksBackBtn')?.addEventListener('click', () => showView('purchases'))"));
});

test('swipe right goes back, with a threshold that leaves scrolling alone', () => {
  const swipe = js.slice(js.indexOf('// Header-back-swipe'), js.indexOf('// R5 + R6:'));
  assert.ok(swipe.includes('swipeBackAction'), 'swipe-back mapping exists');
  // Threshold: more than 80px right, at least twice the vertical move, under 1.5s.
  assert.match(swipe, /dx <= 80/);
  assert.match(swipe, /Math\.abs\(dx\) < 2 \* Math\.abs\(dy\)/);
  assert.match(swipe, /dt > 1500/);
  // Passive listeners, never preventDefault — vertical scrolling untouched.
  assert.match(swipe, /\{ passive: true \}/);
  assert.equal(swipe.includes('preventDefault'), false, 'swipe never blocks scrolling');
  // Same destinations as the Back buttons.
  assert.match(swipe, /currentView === 'settings'.*showView\(previousView \|\| 'week'\)/);
  assert.match(swipe, /currentView === 'prevweeks' \|\| currentView === 'activity'.*showView\('purchases'\)/);
  assert.match(swipe, /addFormOpen === 'manual'.*setAddForm\('options'\)/);
  assert.match(swipe, /fundFormOpen.*setFundForm\(null\)/);
  // Ignored: starts on buttons/links/inputs, inside horizontal scrollers, or while a sheet is open.
  assert.match(swipe, /closest\('input, textarea, select, button, a, \[contenteditable\]'\)/);
  assert.match(swipe, /getElementById\('sheetOverlay'\)/);
  assert.match(swipe, /txFiltersSheet/);
  // Home has no Back action: no mapping for currentView 'week'/'purchases'/'money'.
  assert.equal(/currentView === 'week'/.test(swipe), false, 'no swipe-back on Home');
});

test('Profile Password is the same size as Name and Email labels', () => {
  assert.ok(html.includes('<h3>Password</h3>'), 'Password text unchanged');
  assert.match(css, /#section-profile h3 \{ font-size: 14px; font-weight: 600; margin-top: 20px; \}/);
  assert.match(css, /label \{ font-size: 14px; font-weight: 600; \}/);
});
