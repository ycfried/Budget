// Funds expand-in-place (owner approval, Nov 6, 2026, on the
// funds-expand-in-place mockup): the Extra Fund and Charity cards
// expand IN PLACE instead of opening a bottom sheet. No overlay, no
// dimmed page, no sheet. Tap again, or tap the other card, and it
// closes. Static tests plus execution of the shipped detail-builder
// functions themselves (sliced out of live.js, as the
// fund-sheet-button-rule test does), so the rows, buttons, and
// treatments are tested as real code, not a copy. No live data, no
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

const fundData = { available: 6711, pending: 0, heldTotal: 37500 };
const charityData = { remaining: 5000, given: 3000, committed: 8000 };
const btnLabels = (detailHtml) => [...detailHtml.matchAll(/<button[^>]*>([^<]+)<\/button>/g)].map((m) => m[1]);
const btnClasses = (detailHtml) => [...detailHtml.matchAll(/<button class="([^"]+)"[^>]*>/g)].map((m) => m[1]);

// --- Extra Fund expands in place ---------------------------------------

test('Extra Fund expands in place: three rows + three buttons, in order and treatment', () => {
  const detail = admin.fundExpandDetailHtml('fund', fundData, true);
  assert.match(detail, /data-fund-expand="fund"/);
  assert.match(detail, /class="fund-expand"/);
  // Same three rows as the old sheet (screenshot arithmetic).
  assert.ok(detail.includes('<span>Spendable available</span><strong>$67.11</strong>'));
  assert.ok(detail.includes('<span>Pending</span><strong>$375.00</strong>'));
  assert.ok(detail.includes('<span>Total</span><strong>$442.11</strong>'));
  // Mockup labels, in order: Add money / Spend from fund / Request money.
  assert.deepEqual(btnLabels(detail), ['Add Money', 'Spend from Fund', 'Request Money']);
  // Treatments: primary blue, pale middle, grey tertiary.
  assert.deepEqual(btnClasses(detail), ['btn btn-primary', 'btn', 'btn btn-tertiary']);
  assert.deepEqual([...detail.matchAll(/data-fund-action="([^"]+)"/g)].map((m) => m[1]), ['add', 'use', 'ask']);
  // No Close button on the fund card — tap the card again to close.
  assert.equal(detail.includes('Close'), false);
  // No sheet/overlay markup in the expansion.
  assert.equal(detail.includes('sheetOverlay'), false);
  assert.equal(detail.includes('sheet-handle'), false);
});

test('Extra Fund expansion for a member is Request money only, grey tertiary', () => {
  const detail = member.fundExpandDetailHtml('fund', fundData, false);
  assert.deepEqual(btnLabels(detail), ['Request Money']);
  assert.deepEqual(btnClasses(detail), ['btn btn-tertiary']);
  assert.ok(detail.includes('<span>Available to request</span>'));
});

test('fundExpandActions returns the same three actions (admin) / one (member)', () => {
  assert.deepEqual(admin.fundExpandActions(true).map((a) => a.label), ['Add Money', 'Spend from Fund', 'Request Money']);
  assert.deepEqual(member.fundExpandActions(false).map((a) => a.label), ['Request Money']);
});

// --- Charity expands in place ------------------------------------------

test('Charity expands in place: three rows + Record income blue + Close grey', () => {
  const detail = admin.fundExpandDetailHtml('charity', charityData, true);
  assert.match(detail, /data-fund-expand="charity"/);
  assert.ok(detail.includes('<span>Available</span><strong>$50.00</strong>'));
  assert.ok(detail.includes('<span>Given</span><strong>$30.00</strong>'));
  assert.ok(detail.includes('<span>Total</span><strong>$80.00</strong>'));
  assert.ok(detail.includes('November 2026 onward'), 'period kept in the expansion');
  assert.deepEqual(btnLabels(detail), ['Record Income', 'Close']);
  assert.deepEqual(btnClasses(detail), ['btn btn-primary', 'btn btn-tertiary']);
  assert.deepEqual([...detail.matchAll(/data-charity-action="([^"]+)"/g)].map((m) => m[1]), ['record-income', 'close']);
});

test('Charity expansion for a member is Close only', () => {
  const detail = member.fundExpandDetailHtml('charity', charityData, false);
  assert.deepEqual(btnLabels(detail), ['Close']);
  assert.deepEqual(btnClasses(detail), ['btn btn-tertiary']);
});

test('charityExpandActions returns Record income + Close (admin) / Close only (member)', () => {
  assert.deepEqual(admin.charityExpandActions(true).map((a) => a.label), ['Record Income', 'Close']);
  assert.deepEqual(member.charityExpandActions(false).map((a) => a.label), ['Close']);
});

test('no data, no expansion markup', () => {
  assert.equal(admin.fundExpandDetailHtml('fund', null, true), '');
  assert.equal(admin.fundExpandDetailHtml('charity', null, true), '');
});

// --- Home is read-only (assistant decision, Nov 6, 2026) -----------------

test('Home fund card expands to rows only, no action buttons', () => {
  const detail = admin.fundExpandDetailHtml('fund', fundData, true, false);
  assert.ok(detail.includes('<span>Spendable available</span><strong>$67.11</strong>'));
  assert.ok(detail.includes('<span>Pending</span><strong>$375.00</strong>'));
  assert.ok(detail.includes('<span>Total</span><strong>$442.11</strong>'));
  assert.equal(detail.includes('<button'), false, 'no action buttons on Home');
  assert.equal(detail.includes('data-fund-action'), false);
  assert.equal(detail.includes('fund-expand-btns'), false);
});

test('Home charity card expands to rows only, no action buttons', () => {
  const detail = admin.fundExpandDetailHtml('charity', charityData, true, false);
  assert.ok(detail.includes('<span>Available</span><strong>$50.00</strong>'));
  assert.ok(detail.includes('<span>Given</span><strong>$30.00</strong>'));
  assert.ok(detail.includes('<span>Total</span><strong>$80.00</strong>'));
  assert.ok(detail.includes('November 2026 onward'), 'period line stays — it is information, not an action');
  assert.equal(detail.includes('<button'), false);
  assert.equal(detail.includes('data-charity-action'), false);
});

test('Home member card is rows only too', () => {
  const detail = member.fundExpandDetailHtml('fund', fundData, false, false);
  assert.ok(detail.includes('<span>Available to request</span>'));
  assert.equal(detail.includes('<button'), false);
});

test('sync passes withActions=false for Home cards, true for Funds cards', () => {
  const sync = js.slice(js.indexOf('function syncFundCardExpansion'), js.indexOf('function toggleFundCard'));
  assert.match(sync, /fundExpandDetailHtml\(kind, kind === 'fund' \? currentFundData : currentCharityData, household\?\.role === 'admin', !el\.hasAttribute\('data-home-card'\)\)/);
});

test('Funds page default keeps the full buttons (withActions defaults true)', () => {
  const detail = admin.fundExpandDetailHtml('fund', fundData, true);
  assert.deepEqual(btnLabels(detail), ['Add Money', 'Spend from Fund', 'Request Money']);
  const charity = admin.fundExpandDetailHtml('charity', charityData, true);
  assert.deepEqual(btnLabels(charity), ['Record Income', 'Close']);
});

// --- No sheet is opened by a card tap -----------------------------------

test('no sheet opener remains for either card; Weekly sheet is untouched', () => {
  assert.equal(js.includes('openFundSheet'), false);
  assert.equal(js.includes('openCharitySheet'), false);
  assert.doesNotMatch(js, /showSheet\(\{ title: 'Extra Fund'/);
  assert.equal(js.includes("title: 'Charity · November 2026 Onward'"), false);
  // The generic sheet still exists for the Weekly breakdown, alerts,
  // and transaction actions — only the fund/charity sheets are gone.
  assert.match(js, /async function openWeeklySheet\(\)/);
  assert.match(js, /title: 'Weekly Budget'/);
  assert.match(js, /function showSheet\(/);
});

// --- Toggle, collapse, chevron, aria ------------------------------------

test('toggle: tap again collapses, tap the other card closes the first', () => {
  assert.ok(js.includes('let expandedFundCard = null;'), 'at most one card expanded, starting collapsed');
  const toggle = js.slice(js.indexOf('function toggleFundCard'), js.indexOf('function fundBreakdownRows'));
  assert.match(toggle, /expandedFundCard = expandedFundCard === kind \? null : kind;/);
  assert.match(toggle, /syncFundCardExpansion\(\);/);
});

test('sync: aria-expanded toggles, chevron flips down/up, expanded class set', () => {
  const sync = js.slice(js.indexOf('function syncFundCardExpansion'), js.indexOf('function toggleFundCard'));
  assert.match(sync, /el\.setAttribute\('aria-expanded', expanded \? 'true' : 'false'\)/);
  assert.match(sync, /chev\.textContent = expanded \? '⌃' : '⌄'/);
  assert.match(sync, /el\.classList\.toggle\('fund-expanded', expanded\)/);
  assert.match(sync, /detail\?\.remove\(\)/, 'collapsed card removes its detail rows');
  // Both surfaces are synced together, so Home and Funds agree.
  assert.match(sync, /document\.querySelectorAll\('\[data-fund-card\], \[data-home-card\]'\)/);
});

test('all four cards start collapsed with aria-expanded=false and a down chevron', () => {
  for (const attr of ['data-fund-card="fund"', 'data-fund-card="charity"', 'data-home-card="fund"', 'data-home-card="charity"']) {
    assert.ok(html.includes(attr), `card present: ${attr}`);
  }
  assert.equal((html.match(/aria-expanded="false"/g) ?? []).length >= 4, true);
  assert.match(html, /data-fund-card="fund"[^>]*aria-expanded="false"/);
  assert.match(html, /data-fund-card="charity"[^>]*aria-expanded="false"/);
  assert.match(html, /data-home-card="fund"[^>]*aria-expanded="false"/);
  assert.match(html, /data-home-card="charity"[^>]*aria-expanded="false"/);
  assert.match(css, /\.fund-balance-panel\.fund-expanded, body\.live \.stat-card\.fund-expanded \{ border-color: #2f6bff; \}/);
  // Home stacked (owner, Nov 8, 2026): the old two-column span rule is
  // gone — #section-stats is a single column, so an expanded Home card
  // needs no grid-column span. See home-stacked-fund-charity.test.mjs.
  assert.doesNotMatch(css, /#section-stats \.stat-card\.fund-expanded \{ grid-column/);
  // Insertion point: Funds detail goes above the (last-child) chevron;
  // Home detail goes at the end, below the amount — the Home chevron
  // is the first child, so inserting before it would put the rows
  // above the card title.
  assert.match(js, /else if \(el\.querySelector\('\.fund-balance-chevron'\)\) chev\.insertAdjacentHTML\('beforebegin', html\);/);
  assert.match(js, /else el\.insertAdjacentHTML\('beforeend', html\);/);
});

test('keyboard: Enter/Space toggles the focused card only; focus is never trapped', () => {
  const handler = js.slice(js.indexOf("document.querySelectorAll('[data-fund-card], [data-home-card]')"));
  assert.match(handler, /if \(e\.target !== el\) return;/, 'keys on an inner button do not re-toggle the card');
  assert.match(handler, /if \(e\.key === 'Enter' \|\| e\.key === ' '\) \{ e\.preventDefault\(\); toggleFundCard/);
  const toggle = js.slice(js.indexOf('function toggleFundCard'), js.indexOf('function fundBreakdownRows'));
  assert.equal(toggle.includes('.focus()'), false, 'toggling moves no focus and traps none');
});

test('clicking an expanded-card button runs the button, never re-toggles', () => {
  const handler = js.slice(js.indexOf("document.querySelectorAll('[data-fund-card], [data-home-card]')"));
  assert.match(handler, /e\.target\.closest\('\[data-fund-action\], \[data-charity-action\]'\)/);
  assert.match(handler, /e\.stopPropagation\(\)/);
  assert.match(handler, /if \(result === 'close'\) return;/, 'Close collapses without opening a form');
  assert.match(handler, /setFundForm\(result === 'record-income' \? 'income' : result\)/);
});

// --- Forms still open from the expanded card -----------------------------

test('the three fund forms + Record income still open from the expanded card', () => {
  // The click handler maps every action result to its existing form.
  assert.ok(js.includes("formShown('section-fund-add', 'add')"));
  assert.ok(js.includes("formShown('section-fund-use', 'use')"));
  assert.ok(js.includes("formShown('section-fund-ask', 'ask')"));
  assert.ok(js.includes("formShown('section-charity-income', 'income')"));
  // The forms themselves are unchanged in-page cards, not sheets.
  for (const id of ['section-fund-add', 'section-fund-use', 'section-fund-ask', 'section-charity-income']) {
    assert.ok(html.includes(`id="${id}"`), `form card present: ${id}`);
  }
  assert.ok(html.includes('id="fundTopupForm"'), 'Add money form fields untouched');
  assert.ok(html.includes('id="fundAllocateForm"'), 'Use fund money form fields untouched');
  assert.ok(html.includes('id="fundRequestForm"'), 'Request form fields untouched');
  assert.ok(html.includes('id="charityIncomeForm"'), 'Record income form fields untouched');
  assert.ok(html.includes('id="fundAddBackBtn"'), 'form Back buttons untouched');
});

test('More card is unchanged', () => {
  assert.ok(html.includes('id="section-fund-more"'));
  assert.ok(html.includes('id="moreFundActivityBtn"'));
  assert.ok(html.includes('id="moreReviewBtn"'));
  assert.ok(html.includes('id="moreSavingsBtn"'));
  assert.ok(html.includes('Fund Activity'));
  assert.ok(html.includes('Past Savings Records'));
});

test('refresh re-renders an open card so it never shows stale numbers', () => {
  assert.ok(js.includes('syncFundCardExpansion();'), 'sync is called from refresh after the charity load');
  assert.match(js, /already-expanded card re-renders its rows\/buttons too/);
});

// --- Pins -----------------------------------------------------------------

test('pins bumped to v53/v67', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=67/);
});
