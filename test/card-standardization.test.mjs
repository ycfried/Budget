// Card standardization B5 (owner pick, Nov 4, 2026; mockup:
// card-standardization-mockup.html): same heading style, same
// chevron, same label-then-amount order on the amount cards.
// Style/consistency only — no figure, math, flow, or destination
// change. Static tests only — no live data, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const block = css.slice(css.indexOf('/* Card standardization B5'));

test('hero has a visible Weekly Budget heading with a down chevron, not a tap target', () => {
  assert.match(html, /<h2 class="hero-title">Weekly Budget <span class="hero-title-chevron" aria-hidden="true">⌄<\/span><\/h2>/);
  const title = html.match(/<h2 class="hero-title"[^>]*>/)[0];
  assert.doesNotMatch(title, /role="button"|tabindex/);
  assert.match(block, /body\.live \.hero-title \{[^}]*font-size: 17px; font-weight: 700;[^}]*color: #0f172a;/);
  assert.match(block, /body\.live \.hero-title-chevron \{[^}]*color: #2f6bff;[^}]*font-size: 22px;/);
});

test('hero amount keeps the strongest type (44px)', () => {
  assert.match(css, /body\.live \.hero \{ padding: 28px 24px 24px; \}/);
  assert.match(css, /body\.live \.hero \.big \{ font-size: 44px; line-height: 1\.1; \}/);
});

test('Home pot headings are the 17px standard, amounts 34px, chevrons down', () => {
  for (const card of ['charity', 'fund']) {
    assert.match(html, new RegExp(`data-home-card="${card}"[^>]*><span class="pot-chevron" aria-hidden="true">⌄<\\/span>`));
  }
  assert.match(block, /body\.live #section-stats \.stat-card \.kicker \{[^}]*font-size: 17px; font-weight: 700;[^}]*color: #0f172a;/);
  assert.match(css, /body\.live \.num, body\.live #section-stats \.num, body\.live \.fund-balance \{ font-size: 34px; color: #0f172a; \}/);
  assert.match(block, /body\.live \.pot-chevron \{[^}]*color: #2f6bff;[^}]*font-size: 22px;/);
});

test('Funds panel headings are the 17px standard, amounts 34px, chevrons down', () => {
  assert.match(html, /data-fund-card="fund"[^>]*>\s*<div class="fund-balance-head"><h2>Extra Fund<\/h2><\/div>/);
  assert.match(html, /data-fund-card="charity"[^>]*>\s*<div class="fund-balance-head"><h2>Charity<\/h2><\/div>/);
  assert.match(html, /<span class="fund-balance-chevron" aria-hidden="true">⌄<\/span>/g);
  assert.match(block, /body\.live \.fund-balance-head h2 \{[^}]*font-size: 17px; font-weight: 700;[^}]*color: #0f172a;/);
  assert.match(css, /body\.live \.fund-balance \{ font-size: 34px; font-weight: 800;/);
});

test('label-then-amount order is kept on every amount card', () => {
  const hero = html.slice(html.indexOf('id="section-week"'), html.indexOf('id="section-stats"'));
  assert.ok(hero.indexOf('hero-title') < hero.indexOf('id="weeklyAvailable"'), 'hero title before amount');
  const charity = html.slice(html.indexOf('data-home-card="charity"'), html.indexOf('data-home-card="fund"'));
  assert.ok(charity.indexOf('kicker') < charity.indexOf('homeCharityPrimary'), 'charity label before amount');
  const fundPanel = html.slice(html.indexOf('data-fund-card="fund"'), html.indexOf('data-fund-card="charity"'));
  assert.ok(fundPanel.indexOf('<h2>Extra Fund</h2>') < fundPanel.indexOf('id="fundSummary"'), 'fund label before amount');
});

test('no pot or fund chevron points right any more', () => {
  assert.doesNotMatch(html, /pot-chevron"[^>]*>›/);
  assert.doesNotMatch(html, /fund-balance-chevron"[^>]*>›/);
});

test('pins bumped to v39/v49', () => {
  assert.match(html, /styles\.css\?v=39/);
  assert.match(html, /live\.js\?v=49/);
});
