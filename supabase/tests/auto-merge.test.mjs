// Bank+Email auto-merge tests (build 30, task I) — run with:
//   node --test supabase/tests/auto-merge.test.mjs
// Pure eligibility helpers + the bank-first guard from
// supabase/functions/_shared/canonical.ts, imported directly (Node
// type-strips .ts). The SQL mirror (auto-merge-bank-email.sql:
// bank_email_merge_check / try_auto_merge_bank_email /
// auto_merge_pending_bank_email_duplicates) must stay in step with
// the rules pinned here. The SQL itself cannot run without a live
// database; the live pass is verified by the deploy steps in
// BUILD30_SERVER_DEPLOY.md.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  autoMergeEligible,
  findCoveringBankRow,
  isToiremorgMerchant,
} from '../functions/_shared/canonical.ts';

const HH = 'household-1';

const bank = (over = {}) => ({
  id: 'bank-1', household_id: HH, merchant: 'AMAZON', source: 'plaid',
  date: '2026-11-14', amount_cents: 7999, card_suffix: '1005', kind: 'charge',
  ...over,
});
const email = (over = {}) => ({
  id: 'email-1', household_id: HH, merchant: 'AMAZON MARKEPLACE NA PA', source: 'amex_alert',
  date: '2026-11-13', amount_cents: 7999, card_suffix: '1005', kind: 'charge',
  ...over,
});

// --- the three live Amazon pairs ---------------------------------------
// $6.35 Nov 15 both Counted; $79.99 Bank Nov 14 Excluded / Email Nov
// 13 Counted; $19.07 Bank Nov 13 Excluded / Email Nov 12 Counted.
// The first is the plain eligible shape; the other two differ only
// in that the bank row arrives excluded, which the PENDING-QUEUE
// pass (not the ingestion check) repairs by un-excluding the bank
// row — so the ingestion check refuses an excluded bank row, and
// the queue pass is what merges those two. Both behaviours are
// pinned here.

test('live pair shape: $79.99 Amazon, 1 day apart, related merchants -> eligible', () => {
  assert.deepEqual(autoMergeEligible(bank(), email()), { eligible: true, reason: 'ok' });
});

test('live pair shape: $6.35 same-day pair -> eligible', () => {
  assert.deepEqual(autoMergeEligible(
    bank({ amount_cents: 635, date: '2026-11-15' }),
    email({ amount_cents: 635, date: '2026-11-15' }),
  ), { eligible: true, reason: 'ok' });
});

test('live pair shape: $19.07, 1 day apart, email suffix unknown -> eligible', () => {
  assert.deepEqual(autoMergeEligible(
    bank({ amount_cents: 1907, date: '2026-11-13' }),
    email({ amount_cents: 1907, date: '2026-11-12', card_suffix: '0000' }),
  ), { eligible: true, reason: 'ok' });
});

test('ingestion check refuses an excluded bank row (the queue pass, not ingestion, repairs it)', () => {
  assert.equal(autoMergeEligible(bank({ excluded: true }), email()).eligible, false);
  assert.equal(autoMergeEligible(bank({ excluded: true }), email()).reason, 'bank row excluded');
});

// --- safeguards ---------------------------------------------------------

test('SAFEGUARD: TOIREMORG pair never auto-merges, any spelling', () => {
  assert.equal(isToiremorgMerchant('TOIREMORG'), true);
  assert.equal(isToiremorgMerchant('TOIREMORG CHARITY'), true);
  assert.equal(isToiremorgMerchant('=TOIREMORG'), true);
  const pair = autoMergeEligible(
    bank({ merchant: 'TOIREMORG', amount_cents: 200, date: '2026-11-03' }),
    email({ merchant: 'TOIREMORG CHARITY', amount_cents: 200, date: '2026-11-03' }),
  );
  assert.equal(pair.eligible, false);
  assert.equal(pair.reason, 'toiremorg pair never auto-merges');
});

test('SAFEGUARD: a pair the owner already resolved as Separate never auto-merges', () => {
  const r = autoMergeEligible(bank(), email(), { resolvedPair: true });
  assert.equal(r.eligible, false);
  assert.equal(r.reason, 'pair already resolved');
});

test('NEVER two bank rows, NEVER two email rows', () => {
  assert.equal(autoMergeEligible(bank(), bank({ id: 'bank-2' })).eligible, false);
  assert.equal(autoMergeEligible(email(), email({ id: 'email-2' })).eligible, false);
  assert.equal(autoMergeEligible(email(), bank()).reason, 'bank row is not plaid');
});

// --- strictness: every condition must hold ------------------------------

test('amount must match exactly', () => {
  assert.equal(autoMergeEligible(bank(), email({ amount_cents: 8000 })).reason, 'amount differs');
});

test('kind must match', () => {
  assert.equal(autoMergeEligible(bank(), email({ kind: 'charity' })).reason, 'kind differs');
});

test('dates more than 2 days apart do not merge', () => {
  assert.equal(autoMergeEligible(bank(), email({ date: '2026-11-11' })).reason, 'dates more than 2 days apart');
  // 2 days apart is the boundary and DOES merge.
  assert.equal(autoMergeEligible(bank(), email({ date: '2026-11-12' })).eligible, true);
});

test('different card suffixes do not merge; unknown suffix matches', () => {
  assert.equal(autoMergeEligible(bank(), email({ card_suffix: '2005' })).reason, 'card suffix differs');
  assert.equal(autoMergeEligible(bank({ card_suffix: '0000' }), email()).eligible, true);
});

test('unrelated merchants do not merge (two different $19.07 purchases stay separate)', () => {
  const r = autoMergeEligible(
    bank({ merchant: 'WHOLE FOODS', amount_cents: 1907 }),
    email({ merchant: 'AMAZON MARKEPLACE NA PA', amount_cents: 1907 }),
  );
  assert.equal(r.eligible, false);
  assert.equal(r.reason, 'merchants not related');
});

test('a confirmed alias makes unrelated spellings mergeable', () => {
  const r = autoMergeEligible(
    bank({ merchant: 'AMZN MKTP US' }),
    email({ merchant: 'AMAZON MARKEPLACE NA PA' }),
    { aliases: [{ name_a: 'AMZN MKTP US', name_b: 'AMAZON MARKEPLACE NA PA' }] },
  );
  assert.equal(r.eligible, true);
});

test('a shared rule display name makes different spellings mergeable', () => {
  const rules = [
    { pattern_key: 'AMAZON', pattern_squash: 'AMAZON', match_type: 'prefix', display_name: 'AMAZON', fixed_kind: null },
  ];
  const r = autoMergeEligible(bank({ merchant: 'AMAZON' }), email({ merchant: 'AMAZON MARKEPLACE NA PA' }), { rules });
  assert.equal(r.eligible, true);
});

test('an excluded email row does not merge (already merged away)', () => {
  assert.equal(autoMergeEligible(bank(), email({ excluded: true })).reason, 'email row excluded');
});

test('different households never merge', () => {
  assert.equal(autoMergeEligible(bank(), email({ household_id: 'household-2' })).reason, 'different households');
});

// --- findCoveringBankRow (bank-first guard, fake db) --------------------
// Supports only the chains findCoveringBankRow uses: select/eq/gte/
// lte/limit, awaited as a thenable.

function fakeDb({ txRows }) {
  return {
    from(table) {
      const chain = {
        _filters: [],
        select() { return chain; },
        eq(k, v) { chain._filters.push(['eq', k, v]); return chain; },
        gte(k, v) { chain._filters.push(['gte', k, v]); return chain; },
        lte(k, v) { chain._filters.push(['lte', k, v]); return chain; },
        limit(n) { chain._limit = n; return chain; },
        then(res) {
          let rows = txRows.filter((r) => chain._filters.every(([op, k, v]) => (
            op === 'eq' ? r[k] === v : op === 'gte' ? r[k] >= v : r[k] <= v
          )));
          if (chain._limit) rows = rows.slice(0, chain._limit);
          return Promise.resolve({ data: rows }).then(res);
        },
      };
      return chain;
    },
  };
}

const ALERT = { merchant: 'AMAZON MARKEPLACE NA PA', date: '2026-11-13', amount_cents: 7999, card_suffix: '1005', kind: 'charge' };

test('guard: covering bank row found (same amount, 1 day apart, related merchant)', async () => {
  const db = fakeDb({ txRows: [bank()] });
  const found = await findCoveringBankRow(db, HH, ALERT);
  assert.equal(found?.id, 'bank-1');
});

test('guard: no bank row -> null (alert inserts normally)', async () => {
  const db = fakeDb({ txRows: [] });
  assert.equal(await findCoveringBankRow(db, HH, ALERT), null);
});

test('guard: TOIREMORG alert is never swallowed by the guard', async () => {
  const db = fakeDb({ txRows: [bank({ merchant: 'TOIREMORG', amount_cents: 200, date: '2026-11-03' })] });
  const found = await findCoveringBankRow(db, HH, {
    merchant: 'TOIREMORG CHARITY', date: '2026-11-03', amount_cents: 200, card_suffix: '1005', kind: 'charge',
  });
  assert.equal(found, null);
});

test('guard: an unrelated same-amount bank row does not cover the alert', async () => {
  const db = fakeDb({ txRows: [bank({ merchant: 'WHOLE FOODS' })] });
  assert.equal(await findCoveringBankRow(db, HH, ALERT), null);
});

test('guard: a bank row 3 days away does not cover the alert', async () => {
  const db = fakeDb({ txRows: [bank({ date: '2026-11-10' })] });
  assert.equal(await findCoveringBankRow(db, HH, ALERT), null);
});
