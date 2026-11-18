// Refund-link suggestions + the live max(uuid) bug — run with:
//   node --test test/refund-link-suggestions.test.mjs
// The matcher lives in refundSuggestions.mjs (pure, imported
// directly); live.js renders its output in the Review area's
// "Refund Links" section. Spec: Nov 9, 2026 — suggestions reuse
// the server auto-link's matcher (same card, purchase within 90
// days, refund fits in the purchase's remaining refund room),
// merchant matching mirrors canonical.ts. Nothing here links
// anything: Link calls the existing link_refund RPC.
//
// The second half is the bug that made this feature necessary:
// auto_link_refund / link_refunds_to_purchase picked their
// candidate with `select count(*), max(<alias>.id)` — Postgres has
// no max() for uuid (ERROR 42883 live, Nov 9, 2026), so EVERY
// auto-link call errored and live auto-linking never worked.
// Ingestion calls it best-effort, so the error was swallowed and
// refunds arrived unlinked. The fix (array_agg) is in
// supabase/refund-linking.sql; these tests are the static net that
// would have caught it — the suite never executes SQL (the N5 gap),
// so it scans the SQL instead.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import {
  normalizeMerchant,
  merchantsRelated,
  aliasSetFromRows,
  merchantMatches,
  remainingRefundRoom,
  computeRefundSuggestions,
  REFUND_SUGGESTION_REASONS,
} from '../refundSuggestions.mjs';

const refund = (over = {}) => ({ id: 'r1', merchant: 'AMAZON', amount_cents: -1059, date: '2026-11-05', card_suffix: '1005', source: 'plaid', ...over });
const purchase = (over = {}) => ({ id: 'p1', merchant: 'AMAZON', amount_cents: 1059, date: '2026-11-02', card_suffix: '1005', source: 'plaid', ...over });
const suggest = (args) => computeRefundSuggestions({
  refunds: [], purchases: [], aliases: [], dismissals: [], linkedTotals: new Map(), ...args,
});

// --- normalization / relatedness (mirrors canonical.ts) --------------

test('normalize: case and spacing do not matter', () => {
  assert.equal(normalizeMerchant('amazon  '), 'AMAZON');
  assert.equal(normalizeMerchant('Amazon Markeplace   NA PA'), 'AMAZON MARKEPLACE NA PA');
});

test('related: AMAZON is related to AMAZON MARKEPLACE NA PA (Nov 3 case)', () => {
  assert.equal(merchantsRelated('AMAZON', 'AMAZON MARKEPLACE NA PA'), true);
  assert.equal(merchantsRelated('AMAZON MARKEPLACE NA PA', 'AMAZON'), true);
});

test('related: identical names are not related (equality is separate)', () => {
  assert.equal(merchantsRelated('COLEL CHABAD', 'COLEL CHABAD'), false);
});

test('related: different merchants are not related', () => {
  assert.equal(merchantsRelated('KEREN HATZEDAKA', 'TOIREMORG CHARITY'), false);
});

test('matches: equal, related, and alias all match', () => {
  assert.equal(merchantMatches('AMAZON', 'AMAZON', new Set()), true);
  assert.equal(merchantMatches('AMAZON', 'AMAZON MARKEPLACE NA PA', new Set()), true);
  const aliases = aliasSetFromRows([{ name_a: 'AMAZON', name_b: 'AMZN MKTP US' }]);
  assert.equal(merchantMatches('AMAZON', 'AMZN MKTP US', aliases), true);
  assert.equal(merchantMatches('AMAZON', 'WALMART', aliases), false);
});

test('room: a fully refunded purchase has no room left', () => {
  assert.equal(remainingRefundRoom(1059, 1059), 0);
  assert.equal(remainingRefundRoom(1059, 500), 559);
  assert.equal(remainingRefundRoom(1059, 0), 1059);
});

// --- suggestion rules -------------------------------------------------

test('exact single: one matching purchase is an only-match suggestion', () => {
  const out = suggest({ refunds: [refund()], purchases: [purchase()] });
  assert.equal(out.length, 1);
  assert.equal(out[0].reason, 'only-match');
  assert.equal(out[0].strength, 'exact');
  assert.equal(REFUND_SUGGESTION_REASONS['only-match'].length > 0, true);
});

test('exact multi: two identical purchases are both suggested, pick one', () => {
  const out = suggest({
    refunds: [refund()],
    purchases: [purchase({ id: 'p1' }), purchase({ id: 'p2', date: '2026-11-03' })],
  });
  assert.equal(out.length, 2);
  assert.ok(out.every((s) => s.reason === 'exact-multi'));
  assert.deepEqual(out.map((s) => s.purchase.id).sort(), ['p1', 'p2']);
});

test('partial: a smaller refund that fits is suggested as partial', () => {
  const out = suggest({ refunds: [refund({ amount_cents: -500 })], purchases: [purchase()] });
  assert.equal(out.length, 1);
  assert.equal(out[0].reason, 'partial');
});

test('different-merchant: same amount and card, different place is suggested with a warning', () => {
  const out = suggest({ refunds: [refund()], purchases: [purchase({ merchant: 'WALMART' })] });
  assert.equal(out.length, 1);
  assert.equal(out[0].reason, 'different-merchant');
});

test('partial + different merchant: too weak, not suggested', () => {
  const out = suggest({ refunds: [refund({ amount_cents: -500 })], purchases: [purchase({ merchant: 'WALMART' })] });
  assert.equal(out.length, 0);
});

test('wrong card: never suggested, even with same amount and merchant', () => {
  const out = suggest({ refunds: [refund()], purchases: [purchase({ card_suffix: '2005' })] });
  assert.equal(out.length, 0);
});

test('null suffix: never matches, on either side (P2-N8 rule)', () => {
  assert.equal(suggest({ refunds: [refund({ card_suffix: null })], purchases: [purchase()] }).length, 0);
  assert.equal(suggest({ refunds: [refund()], purchases: [purchase({ card_suffix: null })] }).length, 0);
});

test('window: purchase after the refund, or older than 90 days, is not suggested', () => {
  assert.equal(suggest({ refunds: [refund()], purchases: [purchase({ date: '2026-11-06' })] }).length, 0);
  assert.equal(suggest({ refunds: [refund()], purchases: [purchase({ date: '2026-08-06' })] }).length, 0);
  // Exactly 90 days before is in the window (same boundary as auto-link).
  assert.equal(suggest({ refunds: [refund()], purchases: [purchase({ date: '2026-08-07' })] }).length, 1);
});

test('room: fully refunded purchase is not suggested; part-refunded with room is', () => {
  const linked = new Map([['p1', 1059]]);
  assert.equal(suggest({ refunds: [refund()], purchases: [purchase()], linkedTotals: linked }).length, 0);
  const partLinked = new Map([['p1', 500]]);
  assert.equal(suggest({ refunds: [refund({ amount_cents: -500 })], purchases: [purchase()], linkedTotals: partLinked }).length, 1);
  // Refund bigger than the remaining room does not fit.
  assert.equal(suggest({ refunds: [refund({ amount_cents: -600 })], purchases: [purchase()], linkedTotals: partLinked }).length, 0);
});

test('dismissed: a dismissed pair never reappears; other pairs still do', () => {
  const out = suggest({
    refunds: [refund()],
    purchases: [purchase({ id: 'p1' }), purchase({ id: 'p2', date: '2026-11-03' })],
    dismissals: [{ refund_id: 'r1', purchase_id: 'p1' }],
  });
  assert.equal(out.length, 1);
  assert.equal(out[0].purchase.id, 'p2');
});

test('live Nordstrom case (Nov 9, 2026): $158.97 refund, no $158.97 charge — no suggestion', () => {
  // The only other Nordstrom row is a $58.29 NORDSTROM RACK charge:
  // smaller than the refund, so it cannot be the purchase (a refund
  // cannot exceed its purchase), and the amount does not match.
  // The refund correctly stays unlinked with no suggestion.
  const out = suggest({
    refunds: [refund({ id: 'nord-refund', merchant: 'NORDSTROM', amount_cents: -15897, date: '2026-11-02' })],
    purchases: [purchase({ id: 'nord-rack', merchant: 'NORDSTROM RACK', amount_cents: 5829, date: '2026-11-02' })],
  });
  assert.equal(out.length, 0);
});

test('sort: newest refund first, exact before partial', () => {
  const out = suggest({
    refunds: [refund({ id: 'r-old', date: '2026-11-01' }), refund({ id: 'r-new', date: '2026-11-05' })],
    purchases: [
      purchase({ id: 'p-old', date: '2026-10-30' }),
      purchase({ id: 'p-new', date: '2026-11-02' }),
      purchase({ id: 'p-part', merchant: 'AMAZON', amount_cents: 2000, date: '2026-11-03' }),
    ],
  });
  assert.equal(out.length, 4);
  // Newest refund first; its two exact matches (newest purchase
  // first) before its partial; the old refund's only match last.
  assert.equal(out[0].refund.id, 'r-new');
  assert.equal(out[0].reason, 'exact-multi');
  assert.equal(out[0].purchase.id, 'p-new');
  assert.equal(out[1].reason, 'exact-multi');
  assert.equal(out[1].purchase.id, 'p-old');
  assert.equal(out[2].reason, 'partial');
  assert.equal(out[3].refund.id, 'r-old');
  assert.equal(out[3].reason, 'only-match');
});

// --- the max(uuid) bug: static scan of the SQL ------------------------
// The suite never executes SQL (the N5 gap), so this is the net:
// strip SQL comments, then fail on any max() whose argument is an
// identifier ending in 'id' — max() has no uuid overload in
// Postgres, and every such call errors at runtime (42883).

function stripSqlComments(sql) {
  return sql.replace(/--[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
}

test('BUGFIX max(uuid): no max() over an id column anywhere in supabase/*.sql', () => {
  const files = readdirSync(new URL('../supabase', import.meta.url)).filter((f) => f.endsWith('.sql'));
  assert.ok(files.length > 10, `scanned ${files.length} SQL files`);
  const bad = [];
  for (const f of files) {
    const sql = stripSqlComments(readFileSync(new URL(`../supabase/${f}`, import.meta.url), 'utf8'));
    for (const m of sql.matchAll(/\bmax\s*\(\s*([A-Za-z_][\w.]*)\s*[,)]/g)) {
      const arg = m[1];
      if (/(^|\.)id$|_id$/.test(arg)) bad.push(`${f}: max(${arg})`);
    }
  }
  assert.deepEqual(bad, []);
});

test('BUGFIX max(uuid): both auto-link picks use array_agg, matching rules unchanged', () => {
  // Comments quote the old code (the fix comment names max(c.id)),
  // so strip them: this asserts about executable code only.
  const sql = stripSqlComments(readFileSync(new URL('../supabase/refund-linking.sql', import.meta.url), 'utf8'));
  assert.equal(sql.includes('max(c.id)'), false, 'max(c.id) is gone from auto_link_refund');
  assert.equal(sql.includes('max(r.id)'), false, 'max(r.id) is gone from link_refunds_to_purchase');
  assert.equal((sql.match(/array_agg\(/g) ?? []).length, 2, 'both picks use array_agg');
  // The matching rules themselves are untouched by the fix.
  assert.ok(sql.includes('c.card_suffix = v_ref.card_suffix'), 'auto-link card rule intact');
  assert.ok(sql.includes('c.amount_cents = -v_ref.amount_cents'), 'auto-link exact-amount rule intact');
  assert.ok(sql.includes("c.date >= v_ref.date - interval '90 days'"), 'auto-link 90-day rule intact');
  assert.ok(sql.includes('r.card_suffix = v_pur.card_suffix'), 'reverse-link card rule intact');
  assert.ok(sql.includes('r.amount_cents = -v_pur.amount_cents'), 'reverse-link exact-amount rule intact');
  assert.ok(sql.includes("and kind = 'refund'"), 'BE-3 kind filter intact');
});
