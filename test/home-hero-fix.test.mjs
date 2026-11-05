// Home hero fix (owner feedback, Nov 4, 2026, ~11:12 PM, on the
// Home top area). Branch-only build; static tests only — no live
// data, no network. Base: main 5c674c8 (PR #39, live v39/v49).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

// Specificity, computed by hand (a,b,c) = (IDs, classes, elements):
// - old blue rule `body.live .hero-number-row .hero-sync-btn` = (0,3,1)
// - pale rule `body.live #view-app .btn` = (1,2,1) — the #view-app
//   ID made it win, which is why the sync button still looked pale
//   on the owner's device even though a blue rule existed.
// - new rule `body.live #view-app .hero-sync-btn` = (1,2,1), tied
//   with the pale rule and placed AFTER it, so it wins the tie.
// - the button also no longer carries the plain `btn` class, so the
//   pale rule does not match it at all.
test('profile button is white with dark icon and light grey border, no blue, no glow', () => {
  assert.match(css, /body\.live \.profile-btn \{ background: #fff; border: 1px solid #e5e7eb; color: #0f172a; box-shadow: none; \}/);
  assert.doesNotMatch(css, /body\.live \.profile-btn \{ background: #2f6bff/);
});

test('hero title chevron is gone entirely; heading and big-number target stay', () => {
  assert.match(html, /<h2 class="hero-title">Weekly Budget<\/h2>/);
  assert.doesNotMatch(html, /hero-title-chevron/);
  assert.doesNotMatch(css, /hero-title-chevron/);
  assert.match(html, /id="weeklyAvailable"[^>]*aria-label="Show Weekly Budget breakdown"/);
});

test('pot chevrons are higher and further left, still down and brand blue', () => {
  assert.match(css, /body\.live \.pot-chevron \{ position: absolute; right: 20px; bottom: 18px; font-size: 22px; font-weight: 700; color: #2f6bff; \}/);
  for (const card of ['charity', 'fund']) {
    assert.match(html, new RegExp(`data-home-card="${card}"[^>]*><span class="pot-chevron" aria-hidden="true">⌄<\\/span>`));
  }
});

test('hero card is white with a brand-blue outline, no blue wash, no blue shadow', () => {
  assert.match(css, /body\.live \.hero \{ background: #fff; border: 1\.5px solid #2f6bff; box-shadow: none; \}/);
  assert.doesNotMatch(css, /body\.live \.hero \{ background: linear-gradient/);
  assert.doesNotMatch(css, /body\.live \.hero \{[^}]*rgba\(47, 107, 255/);
});

test('hero sync button is primary blue via an ID-strength, ancestor-independent rule, and carries no btn class', () => {
  assert.match(html, /class="hero-sync-btn" id="homeSyncBtn"/);
  assert.doesNotMatch(html, /class="btn hero-sync-btn" id="homeSyncBtn"/);
  const numRow = html.slice(html.indexOf('class="hero-number-row"'), html.indexOf('id="homeSyncBtn"') + 30);
  assert.ok(numRow.includes('id="homeSyncBtn"'), 'sync button still lives in hero-number-row');
  assert.match(css, /body\.live #view-app \.hero-sync-btn \{ background: #2f6bff; color: #fff; border: 0; box-shadow: none; \}/);
  assert.match(css, /\.hero-number-row \.hero-sync-btn \{[^}]*width: 44px; height: 44px;[^}]*border-radius: 50%/);
});

test('pins bumped to v43/v53', () => {
  assert.match(html, /styles\.css\?v=43/);
  assert.match(html, /live\.js\?v=53/);
});
