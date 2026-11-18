// Home stacked fund/charity cards (owner approval, Nov 8, 2026, on the
// home-stacked-fund-charity.png mockup): Charity ABOVE Extra Fund,
// stacked vertically, both full-width — one column, not two.
//
// The bug (reproduced live Nov 8, 2:38 PM, deterministic): Home had
// Charity and Extra Fund side by side in a two-column row and the
// expanded card spanned both columns (grid-column: 1 / -1). Charity is
// first in the row so it looked in place; Extra Fund is second, so
// going full-width wrapped the whole card down below the small
// Charity card — the box landed underneath Charity, displaced from
// where the user tapped. Stacked, each card expands downward in
// place and the other stays collapsed in its own spot.
//
// Static tests plus execution of the shipped detail-builder functions
// (sliced out of live.js, as the funds-expand-in-place test does), so
// the rows are tested as real code, not a copy. No live data, no
// network, no money math beyond the shipped row functions.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { formatCents } from '../engine.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Slice the shipped builders out of live.js and execute them.
const slice = (start, end) => js.slice(js.indexOf(start), js.indexOf(end));
const combined = [
  slice('function fundBreakdownRows', 'function charityBreakdownRows'),
  slice('function charityBreakdownRows', '// Button-card-fix: Funds balance cards and Home stat cards'),
  slice('function fundExpandActions', 'function charityExpandActions'),
  slice('function charityExpandActions', 'function fundExpandDetailHtml'),
  slice('function fundExpandDetailHtml', 'function syncFundCardExpansion'),
].join('\n');
const builders = new Function('household', 'formatCents', 'esc', `${combined}; return { fundExpandActions, charityExpandActions, fundExpandDetailHtml };`);
const admin = builders({ role: 'admin' }, formatCents, esc);
const member = builders({ role: 'member' }, formatCents, esc);

const fundData = { available: 0, pending: 39667, heldTotal: 0 };
const charityData = { remaining: 70000, given: 0, committed: 70000 };

// The Home stat-card grid (#section-stats) in live.html.
const stats = html.slice(html.indexOf('id="section-stats"'), html.indexOf('id="section-recent"'));

// --- Stacked layout ------------------------------------------------------

test('Home stats are stacked: #section-stats is a single column', () => {
  assert.match(css, /body\.live #section-stats \{ grid-template-columns: minmax\(0, 1fr\); gap: 10px; \}/);
  assert.doesNotMatch(css, /#section-stats \{ grid-template-columns: repeat\(2,/);
  // No later rule re-introduces two columns for #section-stats.
  assert.equal((css.match(/#section-stats \{ grid-template-columns:/g) ?? []).length, 1);
});

test('No grid-column span rule for Home stat cards remains', () => {
  assert.doesNotMatch(css, /#section-stats \.stat-card\.fund-expanded \{ grid-column/);
  assert.doesNotMatch(css, /\.stat-card\.fund-expanded \{ grid-column/);
});

test('Charity sits above Extra Fund in the Home grid, both direct children', () => {
  const charityAt = stats.indexOf('data-home-card="charity"');
  const fundAt = stats.indexOf('data-home-card="fund"');
  assert.ok(charityAt > -1 && fundAt > -1, 'both Home stat cards present');
  assert.ok(charityAt < fundAt, 'Charity above Extra Fund in DOM order');
  assert.match(stats, /<div class="card stat-card" data-home-card="charity"/);
  assert.match(stats, /<div class="card stat-card" data-home-card="fund"/);
});

test('Both Home cards still start collapsed with a down chevron', () => {
  assert.match(html, /data-home-card="charity"[^>]*aria-expanded="false"/);
  assert.match(html, /data-home-card="fund"[^>]*aria-expanded="false"/);
  assert.match(stats, /<span class="pot-chevron" aria-hidden="true">⌄<\/span>/);
});

test('Pot chevron still sits bottom-right, brand blue', () => {
  assert.match(css, /body\.live \.pot-chevron \{ position: absolute; right: 20px; bottom: 18px; font-size: 22px; font-weight: 700; color: #2f6bff; \}/);
});

// --- Behaviour unchanged -------------------------------------------------

test('Accordion still single-open: toggling one card closes the other', () => {
  assert.match(js, /let expandedFundCard = null; \/\/ 'fund' \| 'charity' \| null — at most one card expanded, Home and Funds together/);
  const toggle = js.slice(js.indexOf('function toggleFundCard'), js.indexOf('function fundBreakdownRows'));
  assert.match(toggle, /expandedFundCard = expandedFundCard === kind \? null : kind;/);
  assert.match(js, /const expanded = expandedFundCard === kind;/);
});

test('Home stays read-only: expanded Home cards render rows only, no buttons', () => {
  const fundHome = admin.fundExpandDetailHtml('fund', fundData, true, false);
  const charityHome = admin.fundExpandDetailHtml('charity', charityData, true, false);
  assert.equal(fundHome.includes('<button'), false, 'no buttons on the Home fund card');
  assert.equal(charityHome.includes('<button'), false, 'no buttons on the Home charity card');
  // Members see the same rows-only Home cards.
  assert.equal(member.fundExpandDetailHtml('fund', fundData, false, false).includes('<button'), false);
  assert.equal(member.fundExpandDetailHtml('charity', charityData, false, false).includes('<button'), false);
});

test('Row contents unchanged: fund Spendable available / Pending / Total, charity Available / Given / Total', () => {
  const fundHome = admin.fundExpandDetailHtml('fund', fundData, true, false);
  assert.match(fundHome, /Spendable available<\/span><strong>\$0\.00<\/strong>/);
  assert.match(fundHome, /Pending<\/span><strong>\$396\.67<\/strong>/);
  assert.match(fundHome, /Total<\/span><strong>\$396\.67<\/strong>/);
  const charityHome = admin.fundExpandDetailHtml('charity', charityData, true, false);
  assert.match(charityHome, /Available<\/span><strong>\$700\.00<\/strong>/);
  assert.match(charityHome, /Given<\/span><strong>\$0\.00<\/strong>/);
  assert.match(charityHome, /Total<\/span><strong>\$700\.00<\/strong>/);
  assert.match(charityHome, /November 2026 onward/);
});

// --- Funds page untouched ------------------------------------------------

test('Funds page untouched: balance grid still side by side, stacking only at <=420px', () => {
  assert.match(css, /body\.live \.fund-balance-grid \{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; align-items: stretch; \}/);
  assert.match(css, /@media \(max-width: 420px\) \{\s*body\.live \.fund-balance-grid \{ grid-template-columns: 1fr; \}/);
  assert.doesNotMatch(css, /\.fund-balance-panel\.fund-expanded \{ grid-column/);
  // Funds DOM order unchanged: Extra Fund panel before Charity panel.
  const funds = html.slice(html.indexOf('id="section-fund-balances"'), html.indexOf('id="section-fund-more"'));
  assert.ok(funds.indexOf('data-fund-card="fund"') < funds.indexOf('data-fund-card="charity"'));
});

test('Pins: styles v53, live.js v69', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=69/);
});
