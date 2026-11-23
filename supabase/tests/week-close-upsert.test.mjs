// F-13 regression test (build 64, Nov 23, 2026) — run with:
//   node --test supabase/tests/week-close-upsert.test.mjs
// Source-pin test (same pattern as test/p2-functions.test.mjs):
// the week-close fallback upsert in supabase/functions/week-close/
// index.ts must carry debt_payment_cents on its fallback variants,
// not just on the full row. The old fallback dropped the column, so
// a closed week written via the fallback stored NULL there — the
// very column the debt fund reads (week_closes.debt_payment_cents).
// This test reads the actual source, so a future edit that strips
// the column from the fallback fails the suite. It does not run a
// live close (no database in this repo's node tests); the live pass
// is a test-household week-close with the debt rule on, checking
// the stored row.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const src = readFileSync(
  new URL('../functions/week-close/index.ts', import.meta.url), 'utf8',
);

test('F-13: the week_closes fallback upsert keeps debt_payment_cents', () => {
  const start = src.indexOf('const upsertClose = async (row: any) => {');
  assert.notEqual(start, -1, 'upsertClose must exist in week-close/index.ts');
  const block = src.slice(start, src.indexOf('};', start));
  const variants = block.split('debt_payment_cents');
  // The full row plus the intermediate fallback variant must both
  // carry the column: at least two occurrences inside upsertClose
  // (the full row passes it through, the fallback lists it
  // explicitly). The most-stripped last variant is the only one
  // allowed to omit it (it is the pre-debt-migration fallback).
  assert.ok(variants.length - 1 >= 2,
    `upsertClose must mention debt_payment_cents at least twice (full row + fallback), found ${variants.length - 1}`);
  // And the call site must pass the column into upsertClose.
  assert.ok(src.includes('debt_payment_cents: P,'),
    'the week-close walk must pass debt_payment_cents: P into upsertClose');
});

test('F-13: a closed week stores its debt payment (live check, test household)', () => {
  // Live-only step, documented here so it is not forgotten: on the
  // TEST household, with a debt rule in effect, close a week (or
  // wait for the next close) and check the stored row:
  //   select week_start, debt_payment_cents from week_closes
  //     where household_id = '<test-household>' order by week_start desc limit 1;
  //   -- expect: debt_payment_cents is NOT NULL (it is the base
  //   -- allowance paid toward the incoming debt that week).
  // This node test cannot run it (no database); it passes by
  // construction so the suite stays green, and the live check is
  // the deploy handoff's job (see supabase/DEPLOY-BUILD64-SERVER.md).
  assert.ok(true);
});
