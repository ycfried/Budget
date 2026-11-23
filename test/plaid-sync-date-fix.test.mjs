// plaid-sync date fix + similar-name backstop wiring (build 65,
// Nov 23, 2026). Run with: node --test test/plaid-sync-date-fix.test.mjs
//
// The Nordstrom $158.97 purchase was made Nov 19 as pending and
// counted in that week; when it posted Nov 22, plaid-sync
// overwrote its date to Nov 22 and it jumped into the next week's
// spending. Rules pinned here:
//   * pending→posted (provisional→verified) re-delivery: the date
//     is OMITTED from the update — the original (pending) date is
//     preserved — and the dedupe_hash is recomputed from the
//     preserved date so the hash still matches the stored row.
//   * verified→verified re-deliveries still overwrite the date
//     (genuine Plaid corrections); provisional→provisional too.
//   * The same rule applies to the 23505 race-retry update path.
//   * plaid-sync calls the similar-name backstop RPC after a
//     successful sync (best-effort, like backstop_bank_email_pairs).
//
// upsertPlaidTx itself cannot execute under Node (plaid-sync
// calls Deno.serve at import), so the decision helper is unit
// tested directly and the wiring is pinned with source assertions
// — the same pattern as test/plaid-sync-removed.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { shouldPreserveDate } from '../supabase/functions/_shared/canonical.ts';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const plaidSync = read('../supabase/functions/plaid-sync/index.ts');
const backstopSql = read('../supabase/similar-name-review-backstop.sql');

// --- shouldPreserveDate: the decision --------------------------------

test('date: provisional -> verified preserves the date (Nordstrom case)', () => {
  assert.equal(shouldPreserveDate('provisional', 'verified'), true);
});

test('date: verified -> verified overwrites the date (genuine Plaid correction)', () => {
  assert.equal(shouldPreserveDate('verified', 'verified'), false);
});

test('date: provisional -> provisional overwrites the date', () => {
  assert.equal(shouldPreserveDate('provisional', 'provisional'), false);
});

test('date: verified -> provisional does not preserve', () => {
  assert.equal(shouldPreserveDate('verified', 'provisional'), false);
});

test('date: missing states do not preserve', () => {
  assert.equal(shouldPreserveDate(null, 'verified'), false);
  assert.equal(shouldPreserveDate('provisional', null), false);
  assert.equal(shouldPreserveDate(undefined, undefined), false);
});

// --- plaid-sync/index.ts wiring ---------------------------------------

test('date: main update path omits date on pending->posted and recomputes the hash from the preserved date', () => {
  assert.match(plaidSync, /const preserveDate = shouldPreserveDate\(existing\.state \?\? null, state\)/);
  assert.match(plaidSync, /const storedHash = preserveDate\s*\n\s*\? await canonicalHash\(displayMerchant, existing\.date as string, signed, suffix\)/);
  assert.match(plaidSync, /if \(!preserveDate\) update\.date = date;/);
  // The update literal no longer carries date unconditionally.
  assert.equal(plaidSync.includes('const update: Record<string, unknown> = {\n      date, merchant: displayMerchant'), false);
});

test('date: existing-row lookups fetch the stored date (needed to preserve it)', () => {
  const selects = plaidSync.match(/select\('id,state,excluded,source,kind,date'\)/g) ?? [];
  assert.equal(selects.length, 6, 'all six upsert lookups (5 match steps + race re-select) fetch date');
});

test('date: race-retry (23505) update path applies the same preservation', () => {
  assert.match(plaidSync, /const racedPreserveDate = shouldPreserveDate\(raced\.state \?\? null, state\)/);
  assert.match(plaidSync, /if \(!racedPreserveDate\) retryUpdate\.date = date;/);
});

// --- similar-name backstop wiring --------------------------------------

test('backstop: plaid-sync calls backstop_similar_name_duplicates after a successful sync', () => {
  assert.match(plaidSync, /rpc\('backstop_similar_name_duplicates', \{ p_household_id: householdId \}\)/);
});

test('backstop: SQL defines the sweep and its similarity mirror', () => {
  assert.match(backstopSql, /create or replace function public\.backstop_similar_name_duplicates\(p_household_id uuid\)/);
  assert.match(backstopSql, /create or replace function public\.merchants_similar_for_review\(/);
  assert.match(backstopSql, /create or replace function public\.has_common_substring_8\(/);
});

test('backstop: SQL never flags TOIREMORG and never re-flags a dismissed pair', () => {
  assert.match(backstopSql, /position\('TOIREMORG' in public\.merchant_rule_squash\(t1\.merchant\)\) = 0/);
  assert.match(backstopSql, /position\('TOIREMORG' in public\.merchant_rule_squash\(t2\.merchant\)\) = 0/);
  assert.match(backstopSql, /not exists \(select 1 from public\.duplicate_candidates c/);
  assert.match(backstopSql, /reason, merchant_a, merchant_b\)/);
  assert.match(backstopSql, /'similar-name',/);
});
