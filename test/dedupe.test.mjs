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
  longestCommonSubstringLength,
  merchantsRelated,
  merchantsSimilarForReview,
  pickCanonicalPair,
  sharedWholeWords,
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
          // A candidate inserted earlier in this call (pass 1) is
          // visible to a later prior-check (pass 2), as in the real
          // database — otherwise a pair flagged in pass 1 would be
          // flagged a second time in pass 2 of the same call.
          const insertedCand = inserted.filter((i) => i.table === 'duplicate_candidates');
          return Promise.resolve({ data: insertedCand.length ? insertedCand[0].row : (candRows.length ? candRows[0] : null) });
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

test('flag: Royal Farms — identical Bank+Email merchants DO flag (Nov 20, 2026)', async () => {
  // The live pair: Plaid row Nov 19 23:07 UTC, email row Nov 20
  // 02:50 UTC, same dedupe_hash, neither merged nor flagged — the
  // guard had missed the insert and merchantsRelated() returns false
  // for identical names, so no candidate existed until the owner
  // spotted the double-count. The flag must catch it: Plaid
  // canonical, email duplicate, for admin review (never auto-merge).
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'plaid-row', household_id: HH, date: '2026-11-19', merchant: 'ROYAL FARMS',
      amount_cents: 763, card_suffix: '1005', source: 'plaid', created_at: '2026-11-19T23:07:17Z',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'email-row', merchant: 'ROYAL FARMS', date: '2026-11-19', amount_cents: 763,
    card_suffix: '1005', source: 'amex_alert', created_at: '2026-11-20T02:50:54Z',
  });
  assert.equal(n, 1);
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0].table, 'duplicate_candidates');
  assert.equal(inserted[0].row.canonical_transaction_id, 'plaid-row');
  assert.equal(inserted[0].row.duplicate_transaction_id, 'email-row');
});

test('flag: identical Email+Email merchants do not flag (same-source identical purchases stay separate)', async () => {
  // Scope guard for the Royal Farms fix: only CROSS-source
  // (Bank+Email) identical pairs flag. Two identical email rows are
  // two alerts, not a Bank+Email pair, and stay out of Review.
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'email-1', household_id: HH, date: '2026-11-16', merchant: 'WALMART',
      amount_cents: 2416, card_suffix: '1005', source: 'amex_alert', created_at: '2026-11-16T23:20:00Z',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'email-2', merchant: 'WALMART', date: '2026-11-16', amount_cents: 2416,
    card_suffix: '1005', source: 'amex_alert', created_at: '2026-11-20T02:50:55Z',
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

// --- merchantsSimilarForReview: the Yaldel rule (build 65) ------------
// Same date + same amount + similar names flag for Review, never
// auto-merge. Similar = squashes share an 8+ char substring, or
// share 2+ whole words, or one contains the other.

test('similar: Yaldel pair qualifies (shared 16-char substring + 2 words)', () => {
  assert.equal(
    merchantsSimilarForReview('Yaldel Shluchei Harebbe', 'Yaldei Shluchei Harebbe Special Needs'),
    true,
  );
  assert.equal(
    merchantsSimilarForReview('Yaldei Shluchei Harebbe Special Needs', 'Yaldel Shluchei Harebbe'),
    true,
  );
  assert.equal(sharedWholeWords('Yaldel Shluchei Harebbe', 'Yaldei Shluchei Harebbe Special Needs'), 2);
  assert.equal(
    longestCommonSubstringLength('YALDELSHLUCHEIHAREBBE', 'YALDEISHLUCHEIHAREBBESPECIALNEEDS') >= 8,
    true,
  );
});

test('similar: 2+ whole words qualify even without a long substring', () => {
  // Squashes share only "OAKHILL" (7 chars) — the words OAK + HILL carry it.
  assert.equal(merchantsSimilarForReview('Oak Hill Bakery', 'Oak Hill Deli'), true);
  assert.equal(sharedWholeWords('Oak Hill Bakery', 'Oak Hill Deli'), 2);
});

test('similar: one shared word only does not qualify', () => {
  // Shared word AMAZON (1) and shared substring "AMAZON" (6 chars) — both short of the rule.
  assert.equal(merchantsSimilarForReview('Amazon Fresh', 'Amazon Books'), false);
  assert.equal(sharedWholeWords('Amazon Fresh', 'Amazon Books'), 1);
});

test('similar: unrelated names do not qualify', () => {
  assert.equal(merchantsSimilarForReview('Starbucks', 'Star Market'), false);
  assert.equal(merchantsSimilarForReview('Keren Hatzedaka', 'Colel Chabad'), false);
});

test('similar: identical names are not "similar" (handled elsewhere)', () => {
  assert.equal(merchantsSimilarForReview('Keren Hatzedaka', 'Keren Hatzedaka'), false);
});

test('similar: short names do not qualify', () => {
  assert.equal(merchantsSimilarForReview('A', 'Amazon'), false);
});

test('substring: longest common substring is exact on small inputs', () => {
  assert.equal(longestCommonSubstringLength('ABCDEF', 'XBCDEY'), 4);
  assert.equal(longestCommonSubstringLength('ABC', 'XYZ'), 0);
  assert.equal(longestCommonSubstringLength('SHLUCHEIHAREBBE', 'YALDEISHLUCHEIHAREBBE'), 15);
});

// --- flagLookalikes pass 2: the Yaldel rule ----------------------------

test('flag: Yaldel-style pair IS flagged (different suffixes, similar names)', async () => {
  // Live shape: Plaid row (real suffix) + email alert row (suffix
  // '0000', unknown). Pass 1 misses it on the suffix filter; pass 2
  // must catch it with reason 'similar-name', Plaid canonical.
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'email-row', household_id: HH, date: '2026-11-22', merchant: 'YALDEI SHLUCHEI HAREBBE SPECIAL NEEDS',
      amount_cents: 5400, card_suffix: '0000', source: 'amex_alert', created_at: '2026-11-22T18:00:00Z',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'plaid-row', merchant: 'YALDEL SHLUCHEI HAREBBE', date: '2026-11-22', amount_cents: 5400,
    card_suffix: '1005', source: 'plaid', created_at: '2026-11-22T20:00:00Z',
  });
  assert.equal(n, 1);
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0].table, 'duplicate_candidates');
  assert.equal(inserted[0].row.reason, 'similar-name');
  assert.equal(inserted[0].row.canonical_transaction_id, 'plaid-row');
  assert.equal(inserted[0].row.duplicate_transaction_id, 'email-row');
});

test('flag: TOIREMORG-style pair is NEVER flagged (owner ruling Nov 3)', async () => {
  // The names qualify as similar on their own (TOIREMORG is
  // contained in TOIREMORGCHARITY) and the date + amount match —
  // the guard must still refuse, on either suffix shape.
  for (const emailSuffix of ['0000', '1005']) {
    const inserted = [];
    const db = fakeDb({
      txRows: [{
        id: 'email-row', household_id: HH, date: '2026-11-03', merchant: 'TOIREMORG CHARITY',
        amount_cents: 200, card_suffix: emailSuffix, source: 'amex_alert',
      }],
      inserted,
    });
    const n = await flagLookalikes(db, HH, {
      id: 'plaid-row', merchant: 'TOIREMORG', date: '2026-11-03', amount_cents: 200,
      card_suffix: '1005', source: 'plaid',
    });
    assert.equal(n, 0, `email suffix ${emailSuffix} must not flag`);
    assert.equal(inserted.length, 0);
  }
});

test('flag: same date + amount but unrelated names are NOT flagged', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'old', household_id: HH, date: '2026-11-22', merchant: 'STAR MARKET',
      amount_cents: 5400, card_suffix: '1005', source: 'plaid',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'new', merchant: 'STARBUCKS', date: '2026-11-22', amount_cents: 5400,
    card_suffix: '1005', source: 'plaid',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});

test('flag: similar names on DIFFERENT known cards are NOT flagged', async () => {
  // Two real donations to similar-named charities on different
  // cards are two real purchases, not one duplicate.
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'email-row', household_id: HH, date: '2026-11-22', merchant: 'YALDEI SHLUCHEI HAREBBE SPECIAL NEEDS',
      amount_cents: 5400, card_suffix: '2005', source: 'amex_alert',
    }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'plaid-row', merchant: 'YALDEL SHLUCHEI HAREBBE', date: '2026-11-22', amount_cents: 5400,
    card_suffix: '1005', source: 'plaid',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});

test('flag: a dismissed (already-resolved) Yaldel-style pair is NEVER re-flagged', async () => {
  const inserted = [];
  const db = fakeDb({
    txRows: [{
      id: 'email-row', household_id: HH, date: '2026-11-22', merchant: 'YALDEI SHLUCHEI HAREBBE SPECIAL NEEDS',
      amount_cents: 5400, card_suffix: '0000', source: 'amex_alert', created_at: '2026-11-22T18:00:00Z',
    }],
    candRows: [{ id: 'cand-1' }],
    inserted,
  });
  const n = await flagLookalikes(db, HH, {
    id: 'plaid-row', merchant: 'YALDEL SHLUCHEI HAREBBE', date: '2026-11-22', amount_cents: 5400,
    card_suffix: '1005', source: 'plaid', created_at: '2026-11-22T20:00:00Z',
  });
  assert.equal(n, 0);
  assert.equal(inserted.length, 0);
});
