// Owner-reported Home/charity fixes, Nov 8, 2026 (three screenshots
// + two messages): pending gifts could not be marked as charity;
// Purchases showed a bare dash when transactions failed to load; the
// hero sync icon's arc over-extended past its arrowhead; the Home
// stat-card chevron overlapped the Total amount on an expanded card.
// Static tests only: no live data, no network, no money math.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const liveJs = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const markSql = readFileSync(new URL('../supabase/pending-charity-mark.sql', import.meta.url), 'utf8');
const r13Sql = readFileSync(new URL('../supabase/r13-charity.sql', import.meta.url), 'utf8');

// ---- Pending charity marking ----
test('Pending charity: the RPC accepts provisional or verified, keeps state, keeps every other guard', () => {
  assert.match(markSql, /state not in \('provisional', 'verified'\)/, 'pending or posted accepted');
  assert.match(markSql, /only a pending or posted transaction can be marked/, 'refusal names both states');
  assert.match(markSql, /only a charge can be marked as a charity gift/, 'charge-only guard kept');
  assert.match(markSql, /an excluded transaction cannot be marked/, 'excluded guard kept');
  assert.match(markSql, /fund_allocation_cents/, 'no-fund-allocation guard kept');
  assert.match(markSql, /charity starts November 2026/, 'November 2026 floor kept');
  assert.match(markSql, /week is locked/, 'locked-week guard kept');
  assert.match(markSql, /admin only/, 'admin-only guard kept');
  // The update sets kind only — state is untouched, so a pending gift
  // stays pending and counts toward Given only once it posts.
  assert.match(markSql, /update public\.transactions set kind = 'charity' where id = p_transaction_id;/);
  assert.doesNotMatch(markSql, /set kind = 'charity', state/);
});

test('Pending charity: the canonical r13 file carries the same relaxed guard', () => {
  assert.match(r13Sql, /state not in \('provisional', 'verified'\)/);
  assert.match(r13Sql, /only a pending or posted transaction can be marked/);
});

test('Pending charity: Given still counts verified charity rows only', () => {
  assert.match(liveJs, /\.eq\('kind', 'charity'\)\s*\n?\s*\.eq\('state', 'verified'\)/, 'charity aggregates filter verified');
});

test('Pending charity: the Actions sheet offers Charity live to the admin on a pending charge', () => {
  assert.match(liveJs, /Counts as a charity gift once it posts/);
  assert.match(liveJs, /Counts it as a charity gift, out of weekly spending/);
  assert.doesNotMatch(liveJs, /Available once this posts/);
  // Disabled only for non-admins now — a pending charge no longer
  // disables the row for the admin.
  assert.match(liveJs, /disabled: !isAdmin \}/);
  assert.match(liveJs, /It counts as charity given once it posts\./, 'pending confirm says it counts once posted');
});

// ---- Purchases dash -> N/A ----
test('Purchases shows N/A, never a bare dash, when transactions failed to load', () => {
  assert.match(html, /id="heroPurchaseCount">N\/A</, 'initial value is N/A');
  assert.doesNotMatch(html, /id="heroPurchaseCount">—</, 'no bare dash in the hero');
  assert.match(liveJs, /heroCount\.textContent = txReadFailed \? 'N\/A' : String\(thisWeekPurchases\.length\)/, 'failed load writes N/A, loaded week writes the count');
});

// ---- Hero sync icon ----
test('Hero sync icon is a single closed refresh glyph; the old over-extended arc is gone', () => {
  assert.doesNotMatch(html, /M21 12a9 9 0 1 1-2\.64-6\.36/, 'old arc removed');
  assert.match(html, /M17\.65 6\.35C16\.2 4\.9 14\.21 4 12 4c-4\.42 0/, 'Material refresh path present');
  assert.match(html, /id="homeSyncBtn"[^>]*aria-label="Sync bank"/, 'button kept');
});

// ---- Expanded stat-card chevron clearance ----
test('Expanded Home stat cards leave clear space below the detail for the chevron', () => {
  assert.match(css, /#section-stats \.stat-card\.fund-expanded \.fund-expand \{ padding-bottom: 44px; \}/);
  // The chevron itself is unchanged (absolute, bottom-right).
  assert.match(css, /body\.live \.pot-chevron \{ position: absolute; right: 20px; bottom: 18px;/);
});
