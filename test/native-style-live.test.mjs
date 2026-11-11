// Native-style-live (owner, Nov 4, 7:11 PM): port the approved
// mockup direction into the live web app, plus the original-picture
// logo everywhere (owner, Nov 4, 7:12 PM, as clarified Nov 4 evening:
// the original sent picture itself, NOT the text-based SVG recreation,
// NOT a redraw or trace; SVG work is paused).
// Static tests only — no live data, no network, no money math.
// UI only: no figure, week, fund, or charity math changes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { titleCaseMerchant, relativeDayLabel } from '../filterState.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const manifest = JSON.parse(readFileSync(new URL('../manifest-live.json', import.meta.url), 'utf8'));

test('pins: styles v53, live.js v69, matching live.html', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=69/);});test('combined hero: Available + progress + Spent/% + allowance + purchases, in one card', () => {
  const hero = html.slice(html.indexOf('id="section-week"'), html.indexOf('id="section-stats"'));
  for (const id of ['weeklyAvailable', 'weekProgressBar', 'heroSpentLine', 'heroUsedPct', 'heroAllowance', 'heroPurchaseCount']) {
    assert.ok(hero.includes(`id="${id}"`), `hero contains ${id}`);
  }
  assert.match(js, /heroSpentLine.*formatCents\(charges\)/s);
  assert.match(js, /heroPurchaseCount.*thisWeekTxns\.length/s);
  assert.match(js, /heroAllowance.*baseAllowanceCents/s);
});

test('Charity and Extra Fund pots below the hero keep their tap targets and expand in place (no sheets)', () => {
  assert.match(html, /data-home-card="charity"/);
  assert.match(html, /data-home-card="fund"/);
  assert.match(html, /pot-chevron/);
  assert.match(html, /data-home-card="charity"[^>]*aria-expanded="false"/);
  assert.match(html, /data-home-card="fund"[^>]*aria-expanded="false"/);
  assert.match(js, /toggleFundCard/);
  assert.equal(js.includes('openCharitySheet'), false);
  assert.equal(js.includes('openFundSheet'), false);
});

test('bottom sheets: handle + top Cancel + rounded top corners only, no centred modal', () => {
  assert.match(js, /sheet-handle/);
  assert.match(js, /sheet-top-cancel/);
  assert.match(js, /id="sheetCancelTop"/);
  assert.match(css, /#sheetOverlay \.sheet \{[^}]*border-radius: 20px 20px 0 0/);
  assert.match(css, /body\.live \.tx-sheet-card \{[^}]*border-radius: 20px 20px 0 0/);
  assert.match(css, /body\.live \.add-popup-card \{[^}]*border-radius: 20px 20px 0 0/);
  assert.match(css, /body\.live \.add-popup-overlay \{[^}]*align-items: flex-end/);
  assert.match(css, /safe-area-inset-bottom/);
  assert.match(js, /syncScrollLock/);
});

test('no fourth tab and no Home History row; Past Weeks is its own page linked from Transactions (merged-audit B3)', () => {
  assert.equal(html.includes('id="section-history-row"'), false);
  assert.match(html, /<h2 tabindex=\"-1\">Past Weeks<\/h2>/);
  assert.match(js, /prevweeks: \[[^\]]*section-prevweeks-head[^\]]*section-history-filter[^\]]*section-week-history/);
  assert.match(js, /activity: \[[^\]]*section-activity-head[^\]]*section-activity/);
  assert.equal(/purchases: \[[^\]]*section-week-history/.test(js), false, 'Transactions view no longer embeds week history');
  // Navigation is still exactly Home, Transactions, Funds — no
  // fourth History tab, and no nav link to the old activity view.
  assert.equal((html.match(/class="app-nav-link"/g) || []).length, 3);
  assert.equal(html.includes('data-view="activity"'), false);
});

test('Trash is a quiet text link above the list, only when non-empty, admin only', () => {
  assert.match(html, /class="quiet-link trash-link"/);
  assert.equal(html.includes('trash-bin-row'), false);
  assert.match(js, /trashRowCount > 0\) \? '' : 'none'/);
  const trashPos = html.indexOf('id="txTrashBtn"');
  assert.ok(trashPos > 0 && trashPos < html.indexOf('id="txList"'), 'Trash link sits above the transaction list');
});

test('Funds More card preserved; unified sentence and Budget sentence kept', () => {
  assert.ok(html.includes('id="section-fund-more"'));
  assert.ok(html.includes('id="moreFundActivityBtn"'));
  assert.equal((html.match(/Look only — it never moves, sends, or changes anything\./g) || []).length, 2);
  assert.ok(html.includes('Only the admin can change these.'));
});

test('button tiers kept: primary, pale, grey, ink mid', () => {
  assert.match(css, /#2f6bff/);
  assert.match(css, /#bfdbfe/);
  assert.match(css, /#e5e7eb/);
  assert.match(css, /#0f172a/);
  // Feedback-bundle: error toasts are RED (owner override of the
  // no-red-toasts rule, errors only); the toast itself stays blue.
  assert.match(css, /body\.live \.toast\.error \{ background: #fef2f2; color: #dc2626; border: 1px solid #fecaca; font-weight: 600; \}/);
  assert.match(css, /body\.live \.toast \{[^}]*background: #2f6bff/);
});

test('display-side readability: Title Case merchants, Today/Yesterday, truncation', () => {
  assert.equal(titleCaseMerchant('AMAZON MARKEPLACE NA PA'), 'Amazon Markeplace Na Pa');
  assert.equal(titleCaseMerchant('EXXONMOBIL'), 'Exxonmobil');
  assert.equal(titleCaseMerchant(''), '');
  assert.equal(relativeDayLabel('2026-11-04', '2026-11-04'), 'Today');
  assert.equal(relativeDayLabel('2026-11-03', '2026-11-04'), 'Yesterday');
  assert.equal(relativeDayLabel('2026-11-01', '2026-11-04'), null);
  assert.match(js, /displayMerchant\(t\.merchant\)/);
  assert.match(js, /displayDay\(t\.date\)/);
  assert.match(css, /text-overflow: ellipsis/);
});

test('logo: original picture everywhere — header O, loading mark, manifest sizes, favicons', () => {
  // Header wordmark: circular picture as the O, then "nBudget".
  assert.match(html, /aria-label="OnBudget"><img class="wordmark-logo" src="icon-192.png"[^>]*>nBudget/);
  assert.match(css, /\.wordmark-logo \{[^}]*width: 1em; height: 1em/);
  // Loading mark: picture, not the old S-only mark.
  assert.match(html, /loading-brand-logo" src="icon-192.png"/);
  assert.equal(html.includes('loading-brand-s'), false);
  assert.equal(css.includes('.loading-brand-s'), false);
  // Manifest icons exist at the declared sizes (checked by file name;
  // pixel sizes verified by the parent's image check on the PNGs).
  for (const icon of manifest.icons) {
    assert.ok(existsSync(new URL(`../${icon.src}`, import.meta.url)), `manifest icon exists: ${icon.src}`);
  }
  assert.ok(existsSync(new URL('../apple-touch-icon.png', import.meta.url)), 'Apple touch icon exists');
  assert.ok(existsSync(new URL('../favicon-32.png', import.meta.url)), '32px favicon exists');
  assert.ok(existsSync(new URL('../favicon-16.png', import.meta.url)), '16px favicon exists');
  assert.match(html, /favicon-32\.png" sizes="32x32"/);
  assert.match(html, /favicon-16\.png" sizes="16x16"/);
  // The SVG recreation is NOT referenced as the logo anywhere.
  assert.equal(html.includes('onbudget-logo.svg'), false);
  assert.equal(js.includes('onbudget-logo.svg'), false);
});
