// Loading-indicators (owner, Nov 3, 10:01 PM): the loading symbols
// were ugly — dots, dashes and a plain spinner. Loading surfaces now
// use brand-palette skeleton shimmer bars and an on-brand S-mark
// treatment. Static tests only — no live data, no network, no money
// math. Values, labels and data behavior are unchanged; only what
// shows while content loads changes.
//
// Scope note: the "—" that remains in live.js appears only in
// error/unavailable paths (clearWeekNumbers, fund/charity read
// failures), each with an explanatory aria-label or adjacent error
// text — those are failure indicators, not loading symbols, and are
// deliberately left alone rather than dressed up as loading bars.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

test('figure placeholders are skeleton bars, not dots or dashes', () => {
  const hero = html.slice(html.indexOf('id="weeklyAvailable"'), html.indexOf('id="weeklyAvailable"') + 400);
  assert.match(hero, /skel-figure/, 'hero figure is a skeleton bar');
  assert.doesNotMatch(hero, />…</, 'hero figure has no "…" placeholder');
  const charity = html.slice(html.indexOf('id="homeCharityPrimary"'), html.indexOf('id="homeCharityPrimary"') + 300);
  assert.match(charity, /skel-num/, 'charity figure is a skeleton bar');
  assert.doesNotMatch(charity, />—</, 'charity figure has no "—" placeholder');
  const fund = html.slice(html.indexOf('id="homeFundPrimary"'), html.indexOf('id="homeFundPrimary"') + 300);
  assert.match(fund, /skel-num/, 'fund figure is a skeleton bar');
  assert.doesNotMatch(fund, />…</, 'fund figure has no "…" placeholder');
  assert.doesNotMatch(html, /•••/, 'no literal "•••" anywhere in live.html');
});

test('recent transactions load behind skeleton rows, not "Loading…" text', () => {
  const list = html.slice(html.indexOf('id="recentList"'), html.indexOf('id="section-history-row"'));
  assert.match(list, /aria-busy="true"/, 'recent list is marked busy');
  assert.match(list, /aria-label="Loading recent transactions"/, 'recent list has an accessible loading label');
  assert.equal((list.match(/skel-row/g) || []).length, 4, 'exactly 4 skeleton rows');
  assert.doesNotMatch(list, /Loading…/, 'no visible "Loading…" text in the recent list');
  assert.match(list, /skel-tile/, 'skeleton rows have a merchant tile placeholder');
  assert.match(list, /skel-line/, 'skeleton rows have shimmer lines');
});

test('full-page loading view uses the on-brand mark, not the plain spinner', () => {
  assert.doesNotMatch(html, /loading-spinner/, 'plain spinner div is gone');
  assert.match(html, /loading-brand-ring/, 'thin rotating brand ring present');
  assert.match(html, /loading-brand-s">S</, 'pulsing S mark present');
  assert.match(html, /Loading your budget…/, 'loading words kept');
});

test('skeleton shimmer is brand-palette, slow, and reduced-motion safe', () => {
  assert.match(css, /\.skel \{[^}]*background: #dbeafe/, 'skeleton base is pale blue');
  assert.match(css, /rgba\(47, 107, 255, 0\.18\)/, 'shimmer sweep is brand-blue tinted');
  assert.match(css, /skel-sweep 2\.2s/, 'shimmer sweep is slow');
  assert.match(css, /prefers-reduced-motion: reduce\) \{\s*body\.live \.skel::after[^}]*animation: none/, 'reduced motion stops the shimmer');
  assert.match(css, /loading-ring 2\.4s/, 'brand ring turns slowly');
});

test('real content clears the busy state when it lands', () => {
  assert.equal((js.match(/removeAttribute\('aria-busy'\)/g) || []).length, 4,
    'hero, fund, charity and recent renders all clear aria-busy');
  assert.match(js, /\$\('weeklyAvailable'\)\.removeAttribute\('aria-busy'\)/, 'hero clears busy');
  assert.match(js, /recentEl\.removeAttribute\('aria-busy'\)/, 'recent list clears busy');
});

test('skeletons are sized like the figures they stand in for', () => {
  assert.match(css, /\.skel-figure \{[^}]*height: 40px/, 'hero skeleton matches the 42px figure height');
  assert.match(css, /\.skel-num \{[^}]*height: 28px/, 'stat skeleton matches the 24px figure height');
  assert.match(css, /\.skel-tile \{[^}]*width: 36px; height: 36px/, 'tile placeholder matches row tile size');
});
