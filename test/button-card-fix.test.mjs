// Button-card fix (Nov 3, 2026) static regression tests — run with:
//   node --test test/button-card-fix.test.mjs
// Static source checks only: no DOM, no network, no database.
// Covers the standing button rule (no two adjacent buttons in a row
// share a treatment), the three-blues palette, the Funds card tap
// affordance + Title + Amount face, and the reference typography pass.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

// --- Three blues -------------------------------------------------------

test('button levels are three distinct blues, no grey secondary fill', () => {
  // Primary: strong blue fill, white text.
  assert.match(css, /body\.live #view-app \.btn-primary, body\.live \.btn-primary \{ background: #2f6bff; color: #fff;/);
  // Secondary (base .btn): pale light blue fill, dark-blue text.
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{ background: #bfdbfe; border: 0; color: #1e40af;/);
  // Tertiary (UX-review-fix: owner rejected the pale tint): solid deep fill, white text, with #view-app scope.
  assert.match(css, /body\.live #view-app \.btn-tertiary, body\.live \.btn-tertiary \{ background: #1d4ed8; color: #fff; border: 1px solid #1d4ed8; \}/);
  // Fourth treatment for four-button rows (formerly outline, now solid mid, never white/pale).
  assert.match(css, /body\.live #view-app \.btn-mid, body\.live \.btn-mid \{ background: #3b82f6; color: #fff; border: 1px solid #3b82f6; \}/);
  // Sort select matches the secondary button, not the old grey.
  assert.match(css, /body\.live #txSortField \{ background: #bfdbfe;[^}]*color: #1e40af; \}/);
});

test('Funds actions row: four buttons, four different treatments', () => {
  // DOM order in live.html: Add money (primary), Use fund money
  // (secondary), Ask for fund money (tertiary), Record income (outline).
  assert.ok(html.includes('<button class="btn btn-primary" id="fundActionAddBtn"'));
  assert.ok(html.includes('<button class="btn" id="fundActionUseBtn"'));
  assert.ok(html.includes('<button class="btn btn-tertiary" id="fundActionAskBtn"'));
  assert.ok(html.includes('<button class="btn btn-mid" id="fundActionIncomeBtn"'));
});

test('transaction detail rows: no adjacent duplicate treatment', () => {
  // Admin non-excluded: Exclude (secondary), Mark as charity
  // (tertiary tint), Use Extra Fund (outline), Reclassify (secondary,
  // separated from Exclude by two buttons), Remove (danger).
  assert.ok(js.includes("fundBtn.replace('class=\"btn btn-small\"', 'class=\"btn btn-small btn-mid\"')"));
  assert.ok(js.includes('<button class="btn btn-small btn-tertiary" data-mark-charity='));
  // Admin excluded: Restore (primary) before Reclassify (secondary).
  assert.ok(js.includes('<button class="btn btn-small btn-primary" data-restore='));
});

test('Settings account row: Share (secondary) vs Change password (tertiary)', () => {
  assert.ok(html.includes('<button id="settingsShareIdBtn" class="btn"'));
  assert.ok(html.includes('<button id="settingsPasswordBtn" class="btn btn-tertiary"'));
});

// --- Funds balance cards: tap + face -----------------------------------

test('Funds balance panels are whole-card tap targets with a chevron', () => {
  assert.match(html, /class="fund-balance-panel" data-fund-card="fund" role="button" tabindex="0" aria-label="Show Extra Fund breakdown"/);
  assert.match(html, /class="fund-balance-panel" data-fund-card="charity" role="button" tabindex="0" aria-label="Show Charity breakdown"/);
  assert.match(html, /class="fund-balance-chevron"[^>]*>⌄</);
  assert.match(css, /body\.live \.fund-balance-panel\[role="button"\] \{ cursor: pointer; \}/);
  // Tap handlers open the same breakdown sheets as the Home cards.
  assert.match(js, /document\.querySelectorAll\('\[data-fund-card\]'\)/);
  assert.match(js, /showSheet\(\{ title: 'Extra Fund', rows: fundBreakdownRows\(f\)/);
  assert.match(js, /showSheet\(\{ title: 'Charity · November 2026 onward', rows: charityBreakdownRows\(c\)/);
  // Enter/Space open the card, like the Home stat cards.
  assert.match(js, /e\.key === 'Enter' \|\| e\.key === ' '/);
});

test('Funds card face is Title + Amount only (no secondary-line strings)', () => {
  // The face renderers assign the amount alone (fund) or the signed
  // number (charity, negative remaining) — no "Available"/"Remaining"
  // word, no secondary lines on the face itself. "Ahead by $X" lives
  // only in the charity card's aria-label and tap sheet.
  const fundFaceLine = js.split('\n').find((l) => l.includes("fs.innerHTML = `<p class=\"fund-balance\">"));
  assert.match(fundFaceLine, /<p class="fund-balance"><strong>\$\{formatCents\(available\)\}<\/strong><\/p>/);
  assert.doesNotMatch(fundFaceLine, /Available/);
  const charityFace = js.slice(js.indexOf("const ch = $('charitySummary')"), js.indexOf("const ch = $('charitySummary')") + 1200);
  assert.match(charityFace, /formatCents\(remaining\)/);
  assert.match(charityFace, /ahead by/);
  // Every moved line lives in a breakdown sheet: Held (fund) and Period (charity).
  assert.match(js, /Held for review/);
  assert.match(js, /Period/);
});

test('fund breakdown rows contain every moved Extra Fund line', () => {
  const rows = js.slice(js.indexOf('function fundBreakdownRows'), js.indexOf('function fundBreakdownRows') + 1500);
  for (const label of ['Spendable', 'Pending', 'Owed back', 'Released total', 'Spent', 'Held for review']) {
    assert.ok(rows.includes(label), `fund sheet missing ${label}`);
  }
});

test('charity breakdown rows contain every moved Charity line', () => {
  const rows = js.slice(js.indexOf('function charityBreakdownRows'), js.indexOf('function charityBreakdownRows') + 1200);
  for (const label of ['Remaining', 'Committed', 'Given', 'Default rate', 'Period']) {
    assert.ok(rows.includes(label), `charity sheet missing ${label}`);
  }
});

// --- Typography: reference hierarchy ------------------------------------

test('typography: system sans stack, bold headings, large bold figures, small grey labels', () => {
  // Expanded system sans stack, live scope only; no paid/web font.
  assert.match(css, /--sans: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif;/);
  assert.doesNotMatch(css, /@import|fonts\.googleapis/);
  // Headings bold (700, down from 800 by the UX-review-fix
  // weight rebalance — figures stay 800, headings no longer do).
  assert.match(css, /body\.live h1, body\.live h2, body\.live h3 \{ letter-spacing: -0\.02em; font-weight: 700; \}/);
  // Funds amount is the large bold figure on the card face.
  assert.match(css, /body\.live \.fund-balance \{ font-size: 32px; font-weight: 800;/);
  // Secondary labels stay small and grey.
  assert.match(css, /--muted: #6b7280;/);
  assert.match(css, /body\.live \.kicker \{ color: #6b7280; font-size: 12px;/);
});
