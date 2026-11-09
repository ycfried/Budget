// Integration fixes for the P2 batch (third re-audit, Nov 9, 2026):
// items that only surfaced when the four workstream branches merged,
// plus the P2-C5 client half (stale scheduled-sync warning).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const liveJs = read('../live.js');
const liveHtml = read('../live.html');
const css = read('../styles.css');

// --- P2-C5 (client half): stale scheduled-sync warning --------------------
// The functions workstream landed the API half (plaid-sync/gmail-poll
// return minutes_since_previous_sync + stale). The client half lives
// here: when the last successful sync is over 180 minutes old, the
// footer warns instead of staying silent; a fresh stamp or an unknown
// state never warns.
test('P2-C5 (client): footer carries a stale-sync warning element', () => {
  assert.ok(liveHtml.includes('id="syncStaleWarn"'), 'footer has the syncStaleWarn element');
  assert.ok(liveHtml.includes('Scheduled sync hasn\'t run in a while'),
    'warning wording is honest and names the remedy (tap Sync)');
  assert.ok(liveHtml.includes('class="sync-stale-warn"'), 'warning has its own class');
  assert.match(css, /\.sync-stale-warn\s*\{[^}]*color:\s*#dc2626/, 'warning is dark red like other errors');
});

test('P2-C5 (client): staleness is a 180-minute threshold on the last sync stamp', () => {
  assert.match(liveJs, /180 \* 60 \* 1000/, '180-minute threshold in live.js');
  assert.ok(liveJs.includes("staleWarn.hidden = !(bankLastSyncAt && (Date.now() - new Date(bankLastSyncAt).getTime() > 180 * 60 * 1000))"),
    'warning shows only when a known stamp is older than the threshold');
  assert.ok(liveJs.includes("staleWarn2.hidden = true"),
    'unknown sync state (read failed) hides the warning');
});

// --- Integration: cross-workstream test flips -----------------------------
// The functions workstream pinned C7/B14 as "prepared SQL, not yet
// applied"; the SQL workstream fixed both, so those assertions were
// flipped in test/p2-functions.test.mjs (see that file). This test
// guards the merged state directly so a future branch cannot silently
// reintroduce either gap.
test('Integration: plaid_items_public no longer exposes sync_cursor', () => {
  const vault = read('../supabase/03-plaid-vault.sql');
  assert.ok(!vault.includes('sync_cursor,'), 'sync_cursor is gone from the public view select list');
});

test('Integration: charity RPCs compute committed cents in bigint', () => {
  const sql = read('../supabase/r13-charity.sql');
  assert.equal((sql.match(/\(p_amount_cents::bigint \* v_rate \+ 5000\) \/ 10000/g) ?? []).length, 2,
    'both charity RPCs use the bigint product');
});

// --- Integration: pins -----------------------------------------------------
// live.js and styles.css both changed in this batch, so both pins move
// together (v62/v52 -> v64/v53). The service-worker cache name tracks
// the live.js pin so it cannot drift again (P2-F11).
test('Integration: pins are v64/v53 and the service-worker cache tracks live.js', () => {
  assert.ok(liveHtml.includes('live.js?v=64'), 'live.html pins live.js v64');
  assert.ok(liveHtml.includes('styles.css?v=53'), 'live.html pins styles v53');
  const sw = read('../live-sw.js');
  assert.ok(sw.includes("CACHE = 'onbudget-live-v64'"), 'service-worker cache tracks the live.js pin');
});
