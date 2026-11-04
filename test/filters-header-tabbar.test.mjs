// Filters-header + tab-bar (owner, Nov 3, ~10:37–10:38 PM, two
// screenshots). Static tests only — no live data, no network, no
// money math. Fix 1: the Filters button lives in the Transactions
// header row immediately left of the + button, and the search row
// holds the search input alone. Fix 2: the bottom tab bar is a
// fixed, bottom-pinned, own-layer element with safe-area padding,
// and body bottom clearance exceeds the bar's full height.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

const headRow = html.slice(html.indexOf('tx-head-row'), html.indexOf('tx-search-row'));
const searchRow = html.slice(html.indexOf('tx-search-row'), html.indexOf('txActiveFilters'));

test('Filters button is inside the header row, immediately before the + button', () => {
  assert.ok(headRow.includes('id="txFiltersToggle"'), 'Filters button is in the head row');
  assert.ok(headRow.includes('id="txAddBtn"'), '+ button is in the head row');
  assert.ok(
    headRow.indexOf('id="txFiltersToggle"') < headRow.indexOf('id="txAddBtn"'),
    'Filters comes before + in the header row',
  );
  assert.ok(headRow.includes('class="tx-head-actions"'), 'header buttons are grouped at the right');
  // Fund-sheet-button-rule (owner Nov 4): the header is a two-button
  // row (Filters + Add), so Filters is grey tertiary, not pale.
  assert.ok(headRow.includes('class="btn btn-tertiary"'), 'Filters uses the grey tertiary treatment');
  assert.ok(headRow.includes('btn-primary add-plus-btn'), '+ keeps the primary blue treatment');
  assert.ok(headRow.includes('aria-expanded="false"'), 'Filters keeps aria-expanded');
});

test('search row holds the search input alone', () => {
  assert.ok(searchRow.includes('id="txSearch"'), 'search input is in the search row');
  assert.ok(!searchRow.includes('txFiltersToggle'), 'Filters button is not in the search row');
});

test('Filters focus-return target still exists in JS', () => {
  assert.ok(js.includes("document.getElementById('txFiltersToggle')?.focus()"), 'Show-transactions focus lands on the Filters button');
});

test('tab bar is fixed at the viewport bottom with safe-area padding and its own layer', () => {
  const nav = css.slice(css.indexOf('body.live #view-app .app-nav {'));
  assert.match(nav, /position: fixed; left: 0; right: 0; bottom: 0;/, 'nav is fixed at the bottom');
  assert.match(nav, /padding: 8px 4px calc\(8px \+ env\(safe-area-inset-bottom\)\)/, 'nav padding includes the safe-area inset');
  assert.match(nav, /transform: translateZ\(0\); will-change: transform;/, 'nav is promoted to its own composited layer');
  assert.ok(!/body\.live #view-app \.app-nav \{[^}]*position: sticky/.test(css), 'no sticky rule survives on the live nav');
});

test('body bottom clearance exceeds the tab bar height including safe area', () => {
  // Bar: 8px top pad + (4px link pad + 22px icon + 2px gap + ~14px label + 4px link pad) + 8px bottom pad + safe-area ≈ 62px + safe-area.
  const m = css.match(/body\.live \{[^}]*padding-bottom: calc\((\d+)px \+ env\(safe-area-inset-bottom\)\)/);
  assert.ok(m, 'body padding-bottom is expressed as a base plus the safe-area inset');
  assert.ok(Number(m[1]) >= 62, `body clearance base ${m[1]}px covers the ~62px bar`);
});

test('narrow header cannot push the + button off-screen', () => {
  assert.match(css, /@media \(max-width: 380px\) \{[^}]*tx-head-row/, 'a narrow-screen header rule exists');
  assert.match(css, /add-plus-btn \{ width: 44px; height: 44px;/, '+ button stays 44px');
});

test('tab bar design is unchanged', () => {
  assert.ok(html.includes('data-view="week"') && html.includes('data-view="purchases"') && html.includes('data-view="money"'), 'Home / Transactions / Funds order unchanged');
  assert.match(css, /app-nav-link\.active \{ color: #2f6bff;/, 'active tab color unchanged');
});
