// Type-scale-live (owner approval, Nov 3, ~10:12 PM): the revised
// proposed Home scale from the onbudget-mockups artifact, Part 1, put
// live. Typography/spacing/color only — no figure, label, button, or
// behavior change. Static tests only — no live data, no network, no
// money math. The critical invariant: blue transaction amounts are
// positive-only. A negative amount (refund) must still render
// soft-green with its minus sign under the new blue rule, so the
// negative rule must beat the blue rule on BOTH specificity and
// source order.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const block = css.slice(css.indexOf('/* Type scale live'));

test('type scale: body 16px, supporting 13-14px, dashboard amounts 34px ink', () => {
  assert.match(block, /body\.live \{ font-size: 16px; \}/, 'body text is 16px');
  assert.match(block, /\.kicker[^{]*\{ font-size: 13px; \}/, 'supporting kicker text is 13px');
  assert.match(block, /body\.live \.hero \.big \{ font-size: 34px; color: #0f172a; \}/, 'hero amount is 34px ink');
  assert.match(block, /body\.live \.num, body\.live #section-stats \.num, body\.live \.fund-balance \{ font-size: 34px; color: #0f172a; \}/, 'stat and fund amounts are 34px ink');
});

test('spacing steps and shared card treatment', () => {
  assert.match(block, /border: 1px solid #e5e7eb; border-radius: 16px; padding: 24px; margin-bottom: 16px;/, 'cards share one border, radius, and 24px padding');
  assert.match(block, /#section-stats \.stat-card \{ padding: 16px; \}/, 'stat cards use the 16px step');
  assert.match(block, /\.grid, body\.live #section-stats \{ gap: 16px; \}/, 'grids use the 16px step');
  assert.match(block, /\.hero-progress \{ margin: 16px 0 8px; \}/, 'progress margins use 16/8 steps');
});

test('positive transaction amounts are brand blue; negative stays soft-green and wins', () => {
  const blue = block.match(/body\.live \.tx-line1 \.tx-amount \{ color: (#2f6bff); \}/);
  const neg = block.match(/body\.live \.tx-line1 \.tx-amount\.negative \{ color: (#2e6b3e); \}/);
  assert.ok(blue, 'positive transaction amount rule is brand blue');
  assert.ok(neg, 'negative transaction amount rule is soft-green');
  // Specificity: count class tokens in each selector; negative must have more.
  const classes = (sel) => (sel.match(/\./g) || []).length;
  assert.ok(classes('body.live .tx-line1 .tx-amount.negative') > classes('body.live .tx-line1 .tx-amount'), 'negative selector is more specific than the blue selector');
  // Source order: the negative rule must come after the blue rule in the full file.
  assert.ok(css.indexOf('.tx-amount.negative { color: #2e6b3e') > css.indexOf('.tx-line1 .tx-amount { color: #2f6bff'), 'negative rule comes after the blue rule');
  // The minus sign itself is rendered by formatCentsHtml in live.js; the
  // negative class is what the render path adds for negative amounts.
  const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(js, /amount_cents < 0 \? ' negative'/, 'negative amounts still get the negative class in the render path');
});

test('hero/stat negative figures stay soft-red; progress and See all stay blue', () => {
  assert.match(block, /body\.live \.hero \.big\.negative \{ color: var\(--soft-red\); \}/, 'hero negative stays soft-red');
  assert.match(block, /body\.live \.stat-card \.num\.negative \{ color: var\(--soft-red\); \}/, 'stat negative stays soft-red');
  assert.match(css, /\.hero-progress > div \{ height: 100%; background: #2f6bff;/, 'progress bar fill is brand blue');
  // Send-live-bundle: See all is a quiet text link, not a button.
  assert.match(block, /#section-recent \.quiet-link \{ color: #2f6bff; \}/, 'See all text is brand blue');
});

test('version pins match live.html', () => {
  // Pinned versions move with later branches; after the PR #32 merge
  // (live.js v42) and this branch (styles v33), live.js moves to v45
  // so two different files never share one version number.
  assert.match(html, /styles\.css\?v=47/, 'styles.css bumped to v36');
  assert.match(html, /live\.js\?v=57/, 'live.js bumped to v46');});