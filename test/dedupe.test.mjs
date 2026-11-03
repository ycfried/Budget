// Lookalike (duplicate-candidate) helper tests — run with:
//   node --test test/dedupe.test.mjs
// Pure helpers plus a fake-database test of flagLookalikes (no network,
// no real database). The helpers live in
// supabase/functions/_shared/canonical.ts and are imported directly
// (Node type-strips .ts); plaid-sync, gmail-poll and ingest-amex-alert
// ship identical copies, so the tested code IS the deployed code.
// Spec: Nov 3 Amazon case — a lookalike is same date + amount +
// suffix + related merchant names. Lookalikes NEVER auto-merge; they
// are flagged for admin review. Two real identical purchases must
// never be collapsed by similarity alone.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalHash,
  flagLookalikes,
  merchantsRelated,
  pickCanonicalPair,
} from '../supabase/functions/_shared/canonical.ts';

// --- merchantsRelated: the Amazon case -------------------------------

test('related: AMAZON is related to AMAZON MARKEPLACE NA PA (Nov 3 case)', () => {
  assert.equal(merchantsRelated('AMAZON', 'AMAZON MARKEPLACE NA PA'), true);
  assert.equal(merchantsRelated('AMAZON MARKEPLACE NA PA', 'AMAZON'), true);
});

test('related: identical names are not lookalikes (hash handles them)', () => {
  assert.equal(merchantsRelated('COLEL CHABAD', 'COLEL CHABAD'), false);
});

test('related: different merchants are not related', () => {
  assert.equal(merchantsRelated('KEREN HATZEDAKA', 'TOIREMORG CHARITY'), false);
  assert.equal(merchantsRelated('KEREN HATZEDAKA', 'COLEL CHABAD'), false);
});

test('related: short names do not relate (avoid single-letter flags)', () => {
  assert.equal(merchantsRelated('A', 'AMAZON'), false);
});

test('related: case and spacing do not matter', () => {
  assert.equal(merchantsRelated('amazon  ', 'Amazon Markeplace   NA PA'), true);
});

// --- hash proof: the two Amazon spellings hash differently -----------

test('hash: the two Amazon spellings produce different hashes (the bug mechanism)', async () => {
  const h1 = await canonicalHash('AMAZON MARKEPLACE NA PA', '2026-11-02', 1059, '1005');
  const h2 = await canonicalHash('AMAZON', '2026-11-02', 1059, '1005');
  assert.notEqual(h1, h2);
});

// --- pickCanonicalPair -------------------------------------------------

test('canonical: Plaid row wins over email row either order', () => {
  const plaid = { id: 'p', merchant: 'AMAZON', source: 'plaid', created_at: '2026-11-02T20:00:00Z' };
  const email = { id: 'e', merchant: 'AMAZON MARKEPLACE NA PA', source: 'amex_alert', created_at: '2026-11-02T18:00:00Z' };
  assert.deepEqual(pickCanonicalPair(email, plaid).map((r) => r.id), ['p', 'e']);
  assert.deepEqual(pickCanonicalPair(plaid, email).map((r) => r.id), ['p', 'e']);
});

test('canonical: without Plaid, earlier row wins', () => {
  const early = { id: 'a', merchant: 'X', source: 'amex_alert', created_at: '2026-11-02T18:00:00Z' };
  const late = { id: 'b', merchant: 'X', source: 'amex_alert', created_at: '2026-11-02T19:00:00Z' };
  assert.deepEqual(pickCanonicalPair(late, early).map((r) => r.id), ['a', 'b']);
  assert.deepEqual(pickCanonicalPair(early, late).map((r) => r.id), ['a', 'b']);
});

// --- flagLookalikes with a fake database -------------------------------
// Supports only the exact chains flagLookalikes uses. Filters apply
// literally; the candidate check ignores its .or() and returns the
// first canned candidate row (or null).

function fakeDb({ txRows, candRows = [], aliasRows = [], inserted }) {
  return {
    from(table) {
      const chain = {
        _filters: [],
        select() { return chain; },
        eq(k, v) { chain._filters.push([k, v]); return chain; },
        neq(k, v) { chain._filters.push([`!${k}`, v]); return chain; },
        or() { return chain; },
        limit() { return chain; },
        maybeSingle() { return chain._exec(); },
        insert(row) { inserted.push({ table, row }); return Promise.resolve({ error: null }); },
        then(res, rej) { return chain._exec().then(res, rej); },
      };
      chain._exec = () => {
        if (table === 'transactions') {
          const rows = txRows.filter((r) => chain._filters.every(([k, v]) => (
            k.startsWith('!') ? r[k.slice(1)] !== v : r[k] === v
          )));
          return Promise.resolve({ data: rows });
        }
        if (table === 'merchant_aliases') return Promise.resolve({ data: aliasRows });
        if (table === 'duplicate_candidates') {
          return Promise.resolve({ data: candRows.length ? candRows[0] : null });
        }
        return Promise.resolve({ data: null });
      };
      return chain;
    },
  };
}

const HH = 'household-1';

test('flag: Amazon pair flags once, Plaid canonical, email duplicate', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'email-row', household_id: HH, date: '2026-11-02', merchant: 'AMAZON MARKEPLACE NA PA',
      amount_cents: 1059, card_suffix: '1005', source: 'amex_alert', created_at: '2026-11-02T18:00:00Z',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'plaid-row', merchant: 'AMAZON', date: '2026-11-02', amount_cents: 1059,
    card_suffix: '1005', source: 'plaid', created_at: '2026-11-02T20:00:00Z',
  });
  assert.equal(n, 1);
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0].table, 'duplicate_candidates');
  assert.equal(inserted[0].row.canonical_transaction_id, 'plaid-row');
  assert.equal(inserted[0].row.duplicate_transaction_id, 'email-row');
});

test('flag: unrelated merchants do not flag', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'keren', household_id: HH, date: '2026-11-03', merchant: 'KEREN HATZEDAKA',
      amount_cents: 200, card_suffix: '1005', source: 'plaid',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'toiremorg', merchant: 'TOIREMORG CHARITY', date: '2026-11-03', amount_cents: 200,
    card_suffix: '1005', source: 'plaid',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});

test('flag: identical merchant names do not flag (real identical purchases stay separate)', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'keren-1', household_id: HH, date: '2026-11-03', merchant: 'KEREN HATZEDAKA',
      amount_cents: 200, card_suffix: '1005', source: 'plaid',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'keren-2', merchant: 'KEREN HATZEDAKA', date: '2026-11-03', amount_cents: 200,
    card_suffix: '1005', source: 'plaid',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});

test('flag: excluded rows are never flagged', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'old', household_id: HH, date: '2026-11-02', merchant: 'AMAZON MARKEPLACE NA PA',
      amount_cents: 1059, card_suffix: '1005', source: 'amex_alert', excluded: true,
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'new', merchant: 'AMAZON', date: '2026-11-02', amount_cents: 1059,
    card_suffix: '1005', source: 'plaid',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});

test('flag: a pair with an existing candidate is never re-flagged', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'email-row', household_id: HH, date: '2026-11-02', merchant: 'AMAZON MARKEPLACE NA PA',
      amount_cents: 1059, card_suffix: '1005', source: 'amex_alert',
    }],
    candRows: [{ id: 'cand-1' }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'plaid-row', merchant: 'AMAZON', date: '2026-11-02', amount_cents: 1059,
    card_suffix: '1005', source: 'plaid',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});

test('flag: a confirmed alias extends detection beyond substrings', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'old', household_id: HH, date: '2026-11-02', merchant: 'AMZN MKTP US',
      amount_cents: 1059, card_suffix: '1005', source: 'plaid',
    }],
    aliasRows: [{ name_a: 'AMZN MKTP US', name_b: 'AMAZON MARKEPLACE NA PA' }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'new', merchant: 'AMAZON MARKEPLACE NA PA', date: '2026-11-02', amount_cents: 1059,
    card_suffix: '1005', source: 'amex_alert',
  });
  assert.equal(n, 1);
  assert.equal(inserted.length, 1);
});
