// Home-hero-stat-alignment (owner feedback, Nov 4, morning):
// (1) the hero Sync button sat in .hero-head beside the week kicker,
// high above the big number — crowding/truncating the kicker and
// adding card height. It now sits in .hero-number-row, vertically
// centered against the number. (2) The Home Charity stat-card kicker
// read "Charity · November 2026 onward" and wrapped to two lines,
// pushing its number lower than Extra Fund's; the face kicker is now
// just "Charity". The period is NOT lost: the Charity breakdown
// sheet title and Period row still carry it. Static tests only —
// no live data, no network, no money math.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

const hero = html.slice(html.indexOf('id="section-week"'), html.indexOf('id="section-stats"'));
assert.ok(hero.length > 0, 'hero section found');

test('sync button is in the number row, not the head row', () => {
  const head = hero.slice(hero.indexOf('class="hero-head"'), hero.indexOf('class="hero-number-row"'));
  assert.equal(head.includes('id="homeSyncBtn"'), false, 'no sync button in hero-head');
  const numRow = hero.slice(hero.indexOf('class="hero-number-row"'));
  assert.ok(numRow.includes('id="homeSyncBtn"'), 'sync button lives in hero-number-row');
  assert.ok(numRow.includes('id="weeklyAvailable"'), 'number lives in the same row');
});

test('sync button is a sibling of the number target, never nested in it', () => {
  const between = hero.slice(hero.indexOf('id="weeklyAvailable"'), hero.indexOf('id="homeSyncBtn"'));
  const closeIdx = between.indexOf('</div>');
  const btnIdx = between.indexOf('<button');
  assert.ok(closeIdx !== -1, 'number element closes before the button');
  assert.ok(btnIdx !== -1, 'button follows the number');
  assert.ok(closeIdx < btnIdx, 'number closes before the button opens: siblings, not nested');
});

test('number row is vertically centered and kicker row is full width', () => {
  const rule = css.match(/body\.live \.hero-number-row \{[^}]*\}/);
  assert.ok(rule, '.hero-number-row rule found');
  assert.match(rule[0], /display: flex/);
  assert.match(rule[0], /align-items: center/);
  const headRule = css.match(/body\.live \.hero-head \{[^}]*\}/);
  assert.ok(headRule, '.hero-head rule found');
  assert.doesNotMatch(headRule[0], /justify-content: space-between/, 'head row no longer squeezes kicker beside a button');
});

test('sync button keeps its identity, treatment hook, and the number keeps its target', () => {
  assert.match(hero, /id="homeSyncBtn"[^>]*aria-label="Sync bank"/);
  assert.match(hero, /id="weeklyAvailable"[^>]*role="button"[^>]*tabindex="0"/);
  assert.match(hero, /id="weeklyAvailable"[^>]*aria-label="Show Weekly Budget breakdown"/);
  assert.match(css, /\.hero-number-row \.hero-sync-btn \{[^}]*width: 44px; height: 44px/);
});

test('Home stat kickers are one line each: Charity and Extra Fund', () => {
  const charity = html.match(/data-home-card="charity"[^>]*><span class="pot-chevron"[^>]*>⌄<\/span><div class="kicker">([^<]*)<\/div>/);
  assert.ok(charity, 'Home charity card found');
  assert.equal(charity[1], 'Charity', 'Home charity kicker is exactly "Charity"');
  const fund = html.match(/data-home-card="fund"[^>]*><span class="pot-chevron"[^>]*>⌄<\/span><div class="kicker">([^<]*)<\/div>/);
  assert.ok(fund, 'Home fund card found');
  assert.equal(fund[1], 'Extra Fund', 'Home fund kicker is exactly "Extra Fund"');
  assert.equal(html.includes('data-home-card="charity"'), true);
});

test('period is not lost: Charity sheet title still carries it (Period row removed by fund-sheet-button-rule)', () => {
  assert.match(js, /title: 'Charity · November 2026 onward'/);
  assert.doesNotMatch(js, /\['Period', 'November 2026 onward'\]/);
});

test('Funds Charity panel heading is untouched (already just Charity)', () => {
  assert.match(html, /data-fund-card="charity"[^>]*>\s*<div class="fund-balance-head"><h2>Charity<\/h2><\/div>/);
});

test('version pins: styles v43, live.js v53 after the PR #32 merge', () => {
  assert.match(html, /styles\.css\?v=43/);
  assert.match(html, /live\.js\?v=53/);});