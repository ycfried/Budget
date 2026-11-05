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

test('button levels are three distinct blues plus grey tertiary, no grey secondary fill', () => {
  // Primary: strong blue fill, white text.
  assert.match(css, /body\.live #view-app \.btn-primary, body\.live \.btn-primary \{ background: #2f6bff; color: #fff;/);
  // Secondary (base .btn): pale light blue fill, dark-blue text.
  assert.match(css, /body\.live #view-app \.btn, body\.live \.btn \{ background: #bfdbfe; border: 0; color: #0f172a;/);
  // Tertiary (SUPERSEDED Nov 3, ~11:23 PM, owner Bank-card feedback:
  // the deep blue was too close to primary/secondary, so tertiary
  // is now solid neutral grey fill with ink text, with #view-app
  // scope. The secondary fill above is still pale blue, not grey.)
  assert.match(css, /body\.live #view-app \.btn-tertiary, body\.live \.btn-tertiary \{ background: #e5e7eb; color: #0f172a; border: 1px solid #e5e7eb; \}/);
  // Fourth treatment for four-button rows (formerly outline, now solid ink, never white/pale).
  assert.match(css, /body\.live #view-app \.btn-mid, body\.live \.btn-mid \{ background: #0f172a; color: #fff; border: 1px solid #0f172a; \}/);
  // Sort select matches the secondary button, not the old grey.
  assert.match(css, /body\.live #txSortField \{ background: #bfdbfe;[^}]*color: #0f172a; \}/);
});

test('Funds actions row: exactly three buttons, three different treatments', () => {
  // Funds-actions-three (owner choice, Nov 4, Option A): Record
  // income moved out of the actions card into the Charity sheet, so
  // the row is Add money (primary), Use fund money (secondary),
  // Ask for fund money (tertiary grey) — in that DOM order, and
  // nothing else in the row.
  // Task 7: the Funds actions card is gone; the same three actions
  // live in the Extra Fund sheet (openFundSheet), same order and
  // treatments, and Record income is still not among them.
  assert.equal(html.includes('id="section-fund-actions"'), false);
  assert.equal(html.includes('fundActionIncomeBtn'), false);
  const sheet = js.slice(js.indexOf('async function openFundSheet'), js.indexOf(": [{ label: 'Ask for fund money'"));
  assert.deepEqual([...sheet.matchAll(/label: '([^']+)'/g)].map((m) => m[1]), ['Add money', 'Use fund money', 'Ask for fund money']);
  assert.deepEqual([...sheet.matchAll(/btnClass: '([^']+)'/g)].map((m) => m[1]), ['btn btn-primary', 'btn', 'btn btn-tertiary']);
});

test('transaction detail rows: one Actions line, no five-button row', () => {
  // Send-live-bundle supersedes the old five-button row: details
  // carry one Actions line, and the Actions sheet (see
  // send-live-bundle tests) lists Charity, Extra Fund, Other,
  // Delete. Excluded rows live only in Trash, with Restore there.
  assert.ok(js.includes('data-tx-actions='));
  assert.equal(js.includes('data-mark-charity='), false);
  assert.equal(js.includes('data-exclude='), false);
  assert.ok(js.includes('data-trash-restore='));
});

test('Settings account row: Share only; Change password lives in the Profile card', () => {
  assert.ok(html.includes('<button id="settingsShareIdBtn" class="btn"'));
  // Audit-fixes-morning B2: the Account card's duplicate Change
  // password button is deleted; the Profile card's is the only one.
  assert.equal(html.includes('id="settingsPasswordBtn"'), false);
  assert.ok(html.includes('id="profilePasswordBtn"'));
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
  assert.match(js, /showSheet\(\{ title: 'Charity · November 2026 Onward', rows: charityBreakdownRows\(c\)/);
  // Enter/Space open the card, like the Home stat cards.
  assert.match(js, /e\.key === 'Enter' \|\| e\.key === ' '/);
});

test('Funds card face is Title + Amount only (no secondary-line strings)', () => {
  // The face renderers assign the amount alone (fund) or the signed
  // number (charity, negative remaining) — no "Available"/"Remaining"
  // word, no secondary lines on the face itself. "Ahead by $X" lives
  // "Ahead by $X" lives only in the charity card's aria-label, not
  // in the tap sheet (the sheet's Available row is the signed number,
  // so its rows add up).
  // Merged-audit A12: the face line now carries the negative class
  // for a negative balance (still Title + Amount only, no words).
  const fundFaceLine = js.split('\n').find((l) => l.includes('fs.innerHTML') && l.includes('fund-balance'));
  assert.match(fundFaceLine, /<p class=\"fund-balance\$\{available < 0 \? ' negative' : ''\}\"><strong>\$\{formatCents\(available\)\}<\/strong><\/p>/);
  assert.doesNotMatch(fundFaceLine, /Available/);
  const charityFace = js.slice(js.indexOf("const ch = $('charitySummary')"), js.indexOf("const ch = $('charitySummary')") + 1200);
  assert.match(charityFace, /formatCents\(remaining\)/);
  assert.match(charityFace, /ahead by/);
  // Held still surfaces via the Funds More > Review row label
  // (Review (N) when N > 0) and folded into the fund sheet's
  // Pending; the charity period lives in the sheet title, not a
  // Period row. (Merged-audit A18 removed the dead held-link text.)
  assert.match(js, /Review \(\$\{reviewNeedsCount\}\)/);
  assert.match(js, /title: 'Charity · November 2026 Onward'/);
});

test('fund breakdown rows are exactly Available / Pending / Total', () => {
  const rows = js.slice(js.indexOf('function fundBreakdownRows'), js.indexOf('function charityBreakdownRows'));
  for (const label of ['Spendable', 'Pending', 'Total']) {
    assert.ok(rows.includes(label), `fund sheet missing ${label}`);
  }
  // Old rows are gone from the sheet (Released, Spent, Owed back,
  // and the Held row itself — held is folded into Pending).
  for (const pattern of [/\['Released total',/, /\['Spent from fund',/, /\['Owed back/, /\['Held for review',/]) {
    assert.doesNotMatch(rows, pattern);
  }
});

test('charity breakdown rows are exactly Available / Given / Total', () => {
  const rows = js.slice(js.indexOf('function charityBreakdownRows'), js.indexOf('function charityBreakdownRows') + 1200);
  for (const label of ['Available', 'Given', 'Total']) {
    assert.ok(rows.includes(label), `charity sheet missing ${label}`);
  }
  // Old rows are gone (Remaining label, Committed, Default rate,
  // Period — the period stays in the sheet title, not a row).
  for (const pattern of [/\['Remaining',/, /\['Committed',/, /\['Default rate',/, /\['Period',/]) {
    assert.doesNotMatch(rows, pattern);
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
  assert.match(css, /body\.live \.fund-balance \{ font-size: 34px; font-weight: 800;/);
  // Secondary labels stay small and grey.
  assert.match(css, /--muted: #6b7280;/);
  assert.match(css, /body\.live \.kicker \{ color: #6b7280; font-size: 12px;/);
});
