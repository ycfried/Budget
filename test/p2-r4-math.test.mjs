// Money-math P2 fixes from the Nov 9, 2026 fourth re-audit
// (FULL_AUDIT_2026-11-09_R4.md §6). Branch-only, no live change.
// Run with: node --test test/p2-r4-math.test.mjs
// All amounts are integer cents. $1 = 100.
//
// Covered here:
//   MATH-NEW1 delete_transaction locked-week check — the same 35-day
//         raise as exclude/restore/reclassify, in both SQL copies,
//         plus a hand-computed JS mirror of the lock rule proving the
//         boundary (same style as the M5 cap re-verification in R4 §3).
//   MATH-NEW2 restoration.mjs drift + decision record — the deployed
//         copy is synced (identity asserted in test/p2-engine.test.mjs
//         next to M1); the cited decision source is committed here
//         with its line 57 corrected to the Nov 5 owner decision.
//   P2-B6 (carried) row limits — the transaction fetch in both Edge
//         Functions and the three money-sum reads in live.js now page
//         through whole history instead of silently truncating.
//         Limits deliberately LEFT in place, with the reason each is
//         safe, are listed at the bottom of this file.
//
// The suite never executes SQL or Deno Edge Functions, so the SQL/TS
// pins below are text assertions plus small JS mirrors of the rules —
// the same pattern as the P1/P0 audit test files. Live behaviour is
// verified by the parent's live probes at apply time, not here.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const sql = (p) => readFileSync(new URL(`../supabase/${p}`, import.meta.url), 'utf8');
const fn = (p) => readFileSync(new URL(`../supabase/functions/${p}`, import.meta.url), 'utf8');
const liveJs = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

const deleteStandalone = sql('delete-transaction-rpc.sql');
const adminRpcs = sql('04-admin-rpcs.sql');
const computeWeek = fn('compute-week/index.ts');
const weekClose = fn('week-close/index.ts');

// ---- MATH-NEW1: delete_transaction locked-week check ----

// The exact 35-day pattern, copied from the n4 restore check
// (America/New_York Sunday-week computation). delete_transaction reads
// the row date into tx_date (it previously read no date at all).
const LOCK_PATTERN = /v_now := \(now\(\) at time zone 'America\/New_York'\)::date;\n  v_cur_week := v_now - extract\(dow from v_now\)::int;\n  v_tx_week := tx_date - extract\(dow from tx_date\)::int;\n  if v_cur_week > v_tx_week \+ 35 then\n    raise exception 'week is locked: a locked-week transaction cannot be changed here';/;

test('MATH-NEW1: delete_transaction has the same 35-day lock check as exclude/restore/reclassify', () => {
  assert.match(deleteStandalone, LOCK_PATTERN,
    'delete-transaction-rpc.sql must compute the NY Sunday weeks and raise at 35 days');
  assert.match(adminRpcs, LOCK_PATTERN,
    '04-admin-rpcs.sql §5 must carry the identical check (the two copies stay in sync)');
  // The check reads the row date — the old body selected no date.
  assert.match(deleteStandalone, /select household_id, source, merchant, amount_cents, date\n    into hid, src, merch, amt, tx_date/);
  assert.match(adminRpcs, /select household_id, source, merchant, amount_cents, date\n    into hid, src, merch, amt, tx_date/);
  // The raise precedes the delete in both copies: a locked-week row
  // can never reach the DELETE.
  for (const [name, body] of [['delete-transaction-rpc.sql', deleteStandalone], ['04-admin-rpcs.sql', adminRpcs]]) {
    const raiseAt = body.indexOf("raise exception 'week is locked");
    const deleteAt = body.indexOf('delete from transactions where id = p_transaction_id;');
    assert.ok(raiseAt > 0 && deleteAt > raiseAt, `${name}: lock raise must precede the delete`);
  }
});

test('MATH-NEW1: the two delete_transaction bodies are identical', () => {
  const bodyOf = (s) => {
    const start = s.indexOf('create or replace function public.delete_transaction');
    const end = s.indexOf('$$;', start);
    return s.slice(start, end);
  };
  assert.equal(bodyOf(adminRpcs), bodyOf(deleteStandalone),
    '04 §5 must stay byte-identical in behaviour to the canonical standalone file');
});

// --- Hand-computed mirror of the lock rule (M5 style) ---
// SQL: v_cur_week = current date's Sunday (America/New_York),
// v_tx_week = transaction date's Sunday; locked iff
// v_cur_week > v_tx_week + 35 days. Both sides are Sundays, so the
// difference is a multiple of 7: 35 days is NOT locked (35 > 35 is
// false), 42 days IS locked. Weekdays verified with `date -d`:
// 2026-11-01 Sun, 2026-11-02 Mon, 2026-11-07 Sat, 2026-11-08 Sun,
// 2026-12-06 / 2026-12-13 / 2026-12-20 Sun.
function sundayWeek(iso) {
  const d = new Date(iso + 'T00:00:00Z');
  const sunday = new Date(d);
  sunday.setUTCDate(d.getUTCDate() - d.getUTCDay()); // Sunday = 0, as in extract(dow)
  return sunday.toISOString().slice(0, 10);
}
function isLocked(txDate, today) {
  const txWeek = new Date(sundayWeek(txDate) + 'T00:00:00Z');
  const curWeek = new Date(sundayWeek(today) + 'T00:00:00Z');
  return (curWeek - txWeek) / 86400000 > 35;
}

test('MATH-NEW1: lock-rule mirror — Sunday-week computation', () => {
  assert.equal(sundayWeek('2026-11-01'), '2026-11-01'); // Sunday stays
  assert.equal(sundayWeek('2026-11-02'), '2026-11-01'); // Monday -> that Sunday
  assert.equal(sundayWeek('2026-11-07'), '2026-11-01'); // Saturday -> that Sunday
  assert.equal(sundayWeek('2026-11-08'), '2026-11-08'); // next Sunday
});

test('MATH-NEW1: lock-rule mirror — 35-day boundary, hand-computed', () => {
  // Tx in the Nov 1 week (Sun Nov 1): 35 days later is Sun Dec 6 —
  // still editable; 42 days later is Sun Dec 13 — locked.
  assert.equal(isLocked('2026-11-01', '2026-12-06'), false, 'Nov 1 tx, Dec 6 today: 35 days, not locked');
  assert.equal(isLocked('2026-11-01', '2026-12-13'), true, 'Nov 1 tx, Dec 13 today: 42 days, locked');
  // Same week via a Saturday row: the week start, not the row date,
  // is what counts.
  assert.equal(isLocked('2026-11-07', '2026-12-06'), false, 'Nov 7 (Sat, Nov 1 week), Dec 6: not locked');
  assert.equal(isLocked('2026-11-07', '2026-12-13'), true, 'Nov 7 (Sat, Nov 1 week), Dec 13: locked');
  // Tx in the Nov 8 week: boundary shifts one week later.
  assert.equal(isLocked('2026-11-08', '2026-12-13'), false, 'Nov 8 tx, Dec 13 today: 35 days, not locked');
  assert.equal(isLocked('2026-11-08', '2026-12-20'), true, 'Nov 8 tx, Dec 20 today: 42 days, locked');
  // The money-effect case from R4 §6: a manual row dated Mon Nov 2
  // ages into a locked week, so the admin can no longer delete it
  // (and its pending late charge cannot be removed from week math).
  assert.equal(isLocked('2026-11-02', '2026-12-13'), true, 'Nov 2 manual row, Dec 13 today: locked, delete refuses');
  assert.equal(isLocked('2026-11-02', '2026-12-06'), false, 'Nov 2 manual row, Dec 6 today: still open');
});

// ---- MATH-NEW2: decision record in the repo, line 57 corrected ----

test('MATH-NEW2: the N1/N2 decision record is committed, and fund-first is recorded as confirmed', () => {
  const p = new URL('../MATH_DECISIONS_N1_N2.md', import.meta.url);
  assert.ok(existsSync(p), 'MATH_DECISIONS_N1_N2.md must be in the repo (was untracked in the working copy only)');
  const doc = readFileSync(p, 'utf8');
  assert.doesNotMatch(doc, /fund-first is an S2 interpretation the owner has not confirmed/,
    'line 57 must no longer say fund-first is unconfirmed');
  assert.match(doc, /fund-first is owner-confirmed \(Nov 5, 2026 — N1 Option A, fund-first counted once;/,
    'line 57 records the Nov 5 owner decision (N1 Option A)');
  assert.match(doc, /HANDOFF\.md "Math fixes N1 \+ N2"/,
    'the correction cites the HANDOFF record of the decision');
  assert.match(doc, /the owner picked Option A for N1 and Option A for N2 on Nov 5, 2026/,
    'the header update note records both decisions');
});

test('MATH-NEW2: the deployed restoration copy no longer asks for owner confirmation', () => {
  const deployed = fn('week-close/restoration.mjs');
  assert.equal(deployed.includes('needs an owner confirmation'), false,
    'week-close/restoration.mjs must not say the split ordering needs confirmation');
  assert.ok(deployed.includes('owner-confirmed Nov 5,'),
    'the deployed copy records the Nov 5 confirmation');
  // Byte identity itself is asserted in test/p2-engine.test.mjs (M1
  // extension); this test pins the drift symptom, that one the cause.
});

// ---- P2-B6 (carried): row limits that could silently truncate money ----

test('B6: both Edge Functions page the whole transaction history (no .limit(10000))', () => {
  for (const [name, src] of [['compute-week/index.ts', computeWeek], ['week-close/index.ts', weekClose]]) {
    assert.doesNotMatch(src, /\.limit\(10000\);/, `${name} must not cap the transaction fetch at 10000 (the B6 comment may still name the old cap)`);
    assert.match(src, /async function fetchHouseholdTxns\(/, `${name} must page via fetchHouseholdTxns`);
    assert.match(src, /const PAGE = 1000;/, `${name} pages in 1000-row pages (inside the PostgREST per-response cap)`);
    assert.match(src, /\.order\('created_at', \{ ascending: true \}\)\n\s+\.order\('id', \{ ascending: true \}\)\n\s+\.range\(from, from \+ PAGE - 1\)/,
      `${name} pages in a stable order so rows cannot be skipped or doubled across pages`);
    assert.match(src, /if \(\(data \?\? \[\]\)\.length < PAGE\) return \{ rows, error: null \};/,
      `${name} stops paging on a short page`);
    assert.match(src, /await fetchHouseholdTxns\(supabase, householdId, true\)/,
      `${name} fetches with the linkage column first`);
    assert.match(src, /await fetchHouseholdTxns\(supabase, householdId, false\)/,
      `${name} keeps the pre-migration fallback (no original_purchase_id)`);
  }
});

test('B6: live.js pages the money-sum reads and the CSV preview dedupe (no .limit(1000) left)', () => {
  assert.match(liveJs, /async function fetchAllPages\(makeQuery\) \{/,
    'live.js must define the fetchAllPages helper');
  assert.match(liveJs, /const PAGE = 1000;/, 'fetchAllPages pages in 1000-row pages');
  assert.match(liveJs, /await makeQuery\(from, from \+ PAGE - 1\)/, 'fetchAllPages passes the page window to the query');
  // Each caller applies .range(a, b) on its ordered query — three
  // money-sum call sites plus the CSV preview dedupe fetch (R5-NEW2):
  // four .range(a, b) uses.
  assert.equal((liveJs.match(/\.range\(a, b\)/g) || []).length, 4,
    'exactly four .range(a, b) call sites (charity income, charity gifts, savings, CSV dedupe)');
  assert.match(liveJs, /if \(\(data \?\? \[\]\)\.length < PAGE\) return rows;/, 'fetchAllPages stops on a short page');
  // Charity Committed: active income rows.
  assert.match(liveJs, /const incRows = await fetchAllPages\(\(a, b\) => supabase\.from\('charity_income'\)/,
    'Committed must page all active charity_income rows');
  // Charity Given: verified, unexcluded charity rows since Nov 2026.
  assert.match(liveJs, /const giftRows = await fetchAllPages\(\(a, b\) => supabase\.from\('transactions'\)/,
    'Given must page all verified charity gift rows');
  // Savings transfer/withdrawal/interest sums.
  assert.match(liveJs, /savRows = await fetchAllPages\(\(a, b\) => supabase\.from\('savings_ledger'\)/,
    'savings sums must page all savings_ledger rows');
  // R5-NEW2 (Nov 9, 2026): the CSV preview dedupe fetch pages too —
  // no .limit(1000) call remains anywhere in live.js. Comments may
  // still name the old cap; count calls, not words.
  const caps = liveJs.match(/\.limit\(1000\);/g) || [];
  assert.equal(caps.length, 0, 'no .limit(1000) call may remain in live.js');
  assert.match(liveJs, /const existing = await fetchAllPages\(\(a, b\) => supabase\.from\('transactions'\)/,
    'CSV preview dedupe must page all existing transactions');
  assert.doesNotMatch(liveJs, /\.limit\(10000\)/, 'no .limit(10000) in live.js');
});

// --- Mirror of the fetchAllPages loop (same algorithm as live.js) ---
// Proves the paging terminates with every row for multi-page stores
// and that a failed page throws instead of returning a partial sum.
async function fetchAllPagesMirror(makeQuery) {
  const rows = [];
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await makeQuery(from, from + PAGE - 1);
    if (error) throw error;
    rows.push(...(data ?? []));
    if ((data ?? []).length < PAGE) return rows;
  }
}

test('B6: paging-loop mirror — 2500 rows arrive in 3 pages, none dropped', async () => {
  const store = Array.from({ length: 2500 }, (_, i) => ({ id: i + 1 }));
  const calls = [];
  const rows = await fetchAllPagesMirror(async (a, b) => {
    calls.push([a, b]);
    return { data: store.slice(a, b + 1), error: null };
  });
  assert.equal(rows.length, 2500, 'all 2500 rows returned');
  assert.deepEqual(rows.map((r) => r.id), store.map((r) => r.id), 'rows in order, none doubled or skipped');
  assert.deepEqual(calls, [[0, 999], [1000, 1999], [2000, 2999]], 'three 1000-row pages');
});

test('B6: paging-loop mirror — a failed page throws, never a partial sum', async () => {
  const store = Array.from({ length: 1500 }, (_, i) => ({ id: i + 1 }));
  await assert.rejects(
    fetchAllPagesMirror(async (a, b) => {
      if (a === 1000) return { data: null, error: new Error('read failed') };
      return { data: store.slice(a, b + 1), error: null };
    }),
    /read failed/,
    'a page error must throw so the caller shows an error state, not a partial total',
  );
  const empty = await fetchAllPagesMirror(async () => ({ data: [], error: null }));
  assert.deepEqual(empty, [], 'an empty store returns [] after one page');
});

// ---- R5-NEW2 (Nov 9, 2026): CSV preview dedupe sees the whole history ----
// Executes the SHIPPED fetchAllPages + csvRowKey (sliced out of live.js,
// like the fund builders) against a 2,500-row store, then runs the
// preview's own dedupe over the returned rows: a CSV row duplicating
// store row #1501 — past the first 1000-row page, invisible to the old
// bare .limit(1000) fetch — must be flagged Duplicate, and a genuinely
// new row must stay New.
test('R5-NEW2: CSV preview dedupe catches a duplicate past row 1000', async () => {
  const slice = (start, end) => liveJs.slice(liveJs.indexOf(start), liveJs.indexOf(end));
  const helpers = new Function(`${slice('const normalizeMerchant', 'function parseAmountLive')}
${slice('async function fetchAllPages(makeQuery)', 'async function refresh()')}; return { csvRowKey, fetchAllPages };`)();
  const store = Array.from({ length: 2500 }, (_, i) => ({
    merchant: `MERCHANT ${i + 1}`, amount_cents: 100 + i, date: '2026-11-02', card_suffix: '1005',
  }));
  const calls = [];
  const existing = await helpers.fetchAllPages(async (a, b) => {
    calls.push([a, b]);
    return { data: store.slice(a, b + 1), error: null };
  });
  assert.equal(existing.length, 2500, 'all 2500 existing rows returned');
  assert.deepEqual(calls, [[0, 999], [1000, 1999], [2000, 2999]], 'three 1000-row pages');
  const existingKeys = new Set(existing.map((t) => helpers.csvRowKey({
    merchant: t.merchant, date: t.date, amountCents: t.amount_cents, suffix: t.card_suffix,
  })));
  const dupePast1000 = { merchant: 'MERCHANT 1501', date: '2026-11-02', amountCents: 1600, suffix: '1005' };
  assert.equal(existingKeys.has(helpers.csvRowKey(dupePast1000)), true,
    'a CSV row duplicating store row #1501 (past the first page) is a Duplicate');
  const fresh = { merchant: 'BRAND NEW SHOP', date: '2026-11-02', amountCents: 99999, suffix: '1005' };
  assert.equal(existingKeys.has(helpers.csvRowKey(fresh)), false, 'a genuinely new row stays New');
});

// ---- Limits deliberately LEFT in place (documented safe, not fixed) ----
//   * (R5-NEW2, Nov 9, 2026: the CSV preview dedupe fetch used to be
//     here — it now pages the whole history with fetchAllPages, so it
//     is no longer a deliberate limit.)
//   * Display lists (live.js .limit(50)/.limit(100), week_closes
//     .limit(100), audit_log 1000 when date-filtered): lists the user
//     scrolls, not figures — every money total on those pages comes
//     from a paged aggregate above or from compute-week, and the
//     audit/history count lines use exact-count queries.
//   * Transactions list (.limit(txLimit + 1)): user-driven paging with
//     an explicit Load-more button; the count line says "total of the
//     rows shown".
//   * Edge Function reads with no limit (week_closes, temp_increases,
//     weekly_allowance_overrides, restoration_entries, held_refunds,
//     surplus_releases, fund_ledger): one row per week or per event —
//     ~52 rows/year for weekly tables, admin-action counts for the
//     rest — far below the 1000-row per-response cap for decades, and
//     a short read there is loud (an error or an empty result), not a
//     silently smaller money figure. (fund_ledger in week-close is
//     re-read for the shortfall reconcile only.)
//   * Matcher candidate windows (canonical.ts .limit(20), .limit(1)
//     single-row lookups): dedupe/match windows, not sums — a missed
//     candidate means a row stays unmerged (visible in review), never
//     a wrong total.
//   * plaid-sync / gmail-poll staleness fields use the most-recent row
//     only (.limit(1) / MAX): status signals, not money.
