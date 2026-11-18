// plaid-sync removed[] expansion tests (build 44, change 1, Nov 18, 2026)
// Run with: node --test test/plaid-sync-removed.test.mjs
// Pure-function tests of decideRemovedRow / pickPlaidHashClaim (imported
// from _shared/canonical.ts — Node type-strips .ts) plus source
// assertions on plaid-sync/index.ts, which cannot execute under Node
// (it calls Deno.serve at import). The live pass (test-household sync
// with a real pending→posted transition and a real removed[] entry) is
// still owed after deploy; these tests prove the code, not the DB.
//
// Rules pinned here:
//   * provisional rows in removed[] are NEVER auto-excluded;
//   * verified rows are excluded only after the replacement search
//     finds nothing (same merchant + amount + date + card_suffix,
//     in this sync's arrivals or a recent window of household rows);
//   * a replacement LINKs the row to the new id/state (kind kept,
//     duplicate arrival row excluded) instead of trashing it;
//   * the removed[] matcher NEVER uses plaid_pending_transaction_id
//     (it still holds the OLD pending id after a pending→posted link,
//     so matching on it would trash the live posted row);
//   * a posted Plaid tx with no pending_transaction_id claims its
//     provisional predecessor via the dedupe hash — earliest
//     provisional only, never a verified row (two identical real
//     purchases still coexist).

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  decideRemovedRow,
  pickPlaidHashClaim,
} from '../supabase/functions/_shared/canonical.ts';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const plaidSync = read('../supabase/functions/plaid-sync/index.ts');

const verifiedRow = (over = {}) => ({
  state: 'verified',
  excluded: false,
  merchant: 'AMAZON',
  date: '2026-11-17',
  amount_cents: 1059,
  card_suffix: '1005',
  external_id: 'tx-live-1',
  plaid_transaction_id: 'tx-live-1',
  plaid_pending_transaction_id: null,
  ...over,
});

const arrival = (over = {}) => ({
  merchant: 'AMAZON',
  date: '2026-11-17',
  amount_cents: 1059,
  card_suffix: '1005',
  external_id: 'tx-new-9',
  state: 'verified',
  rowId: 'row-new-9',
  pending_transaction_id: null,
  ...over,
});

// --- 1. Provisional rows are never auto-excluded ------------------------

test('provisional row in removed[] is left untouched, even with no arrival', () => {
  const d = decideRemovedRow(verifiedRow({ state: 'provisional' }), []);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'provisional-removed-is-normal');
});

test('provisional row in removed[] is left untouched, even with a replacement arrival', () => {
  const d = decideRemovedRow(verifiedRow({ state: 'provisional' }), [arrival()]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'provisional-removed-is-normal');
});

// --- 2. Verified row with no replacement is excluded --------------------

test('verified row with no arrival is excluded as a genuine reversal', () => {
  const d = decideRemovedRow(verifiedRow(), []);
  assert.equal(d.action, 'exclude');
  assert.equal(d.reason, 'verified-reversal');
});

test('verified row with an unrelated arrival is still excluded', () => {
  const d = decideRemovedRow(verifiedRow(), [
    arrival({ merchant: 'STARBUCKS', amount_cents: 500, external_id: 'tx-other' }),
  ]);
  assert.equal(d.action, 'exclude');
});

// --- 3. Replacement in added[] links, not excludes ----------------------

test('verified row with a same merchant+amount+date+card replacement in added[] is LINKED', () => {
  const d = decideRemovedRow(verifiedRow(), [arrival()]);
  assert.equal(d.action, 'link');
  assert.equal(d.reason, 'replacement-same-merchant-amount-date-card');
  assert.equal(d.replacement.external_id, 'tx-new-9');
  assert.equal(d.replacement.plaid_transaction_id, 'tx-new-9');
  assert.equal(d.replacement.state, 'verified');
  assert.equal(d.replacement.rowId, 'row-new-9');
});

test('replacement match is merchant-normalized (arrival in lowercase still links)', () => {
  const d = decideRemovedRow(verifiedRow(), [arrival({ merchant: 'amazon' })]);
  assert.equal(d.action, 'link');
});

test('same triple on a DIFFERENT card is a re-issue (leave), not a link', () => {
  const d = decideRemovedRow(verifiedRow(), [arrival({ card_suffix: '2005' })]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'reissue-same-merchant-amount-date');
});

test('same quadruple from a PENDING arrival is a re-issue (leave), not a link', () => {
  const d = decideRemovedRow(verifiedRow(), [arrival({ state: 'provisional' })]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'reissue-same-merchant-amount-date');
});

test('arrival carrying the row’s own live id is a re-delivery (leave), not a self-link', () => {
  const d = decideRemovedRow(verifiedRow(), [arrival({ external_id: 'tx-live-1' })]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'reissue-same-merchant-amount-date');
});

test('arrival without a known card suffix can never be a replacement link', () => {
  const d = decideRemovedRow(verifiedRow(), [arrival({ card_suffix: null })]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'reissue-same-merchant-amount-date');
});

// --- 4. Stale plaid_pending_transaction_id never matches -----------------

test('removed[] id equal to the row’s STALE plaid_pending_transaction_id does not trash it', () => {
  // Live posted row: external_id is the new posted id; the pending id
  // survives only in plaid_pending_transaction_id. An arrival whose
  // pending link is that stale id, with a different merchant, must
  // NOT count as a re-issue signal — the old rowIds set (which
  // included plaid_pending_transaction_id) would have left it, and
  // the old deferred query would have matched the row at all.
  // With the stale arm gone, nothing shields it: it excludes — which
  // is exactly why the QUERY must not find the row in the first place
  // (see the source assertion below); the decision itself must not
  // treat the stale pending id as a live id.
  const row = verifiedRow({
    external_id: 'tx-posted-2',
    plaid_transaction_id: 'tx-posted-2',
    plaid_pending_transaction_id: 'tx-pending-OLD',
  });
  const d = decideRemovedRow(row, [
    arrival({ merchant: 'WHOLE FOODS', external_id: 'tx-new-9', pending_transaction_id: 'tx-pending-OLD' }),
  ]);
  assert.equal(d.action, 'exclude');
  assert.equal(d.reason, 'verified-reversal');
});

test('pending link against the row’s LIVE id still counts as a re-issue', () => {
  const d = decideRemovedRow(verifiedRow(), [
    arrival({ merchant: 'WHOLE FOODS', external_id: 'tx-new-9', pending_transaction_id: 'tx-live-1' }),
  ]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'reissue-pending-link');
});

test('already-excluded / reversed rows are left alone, never re-excluded', () => {
  assert.equal(decideRemovedRow(verifiedRow({ excluded: true }), []).action, 'leave');
  assert.equal(decideRemovedRow(verifiedRow({ state: 'reversed' }), []).action, 'leave');
  assert.equal(decideRemovedRow(verifiedRow({ state: 'excluded' }), []).action, 'leave');
  assert.equal(decideRemovedRow(verifiedRow({ state: 'excluded' }), []).reason, 'already-excluded');
});

// --- 5. Plaid hash-fallback claim (fix 3) -------------------------------

test('hash fallback claims the EARLIEST provisional Plaid row', () => {
  const first = { id: 'prov-1', source: 'plaid', state: 'provisional', excluded: false };
  const second = { id: 'prov-2', source: 'plaid', state: 'provisional', excluded: false };
  assert.equal(pickPlaidHashClaim([first, second]), first);
  assert.equal(pickPlaidHashClaim([second, first]), second);
});

test('hash fallback never claims a verified row (identical real purchases coexist)', () => {
  const verified = { id: 'ver-1', source: 'plaid', state: 'verified', excluded: false };
  assert.equal(pickPlaidHashClaim([verified]), null);
  const provisional = { id: 'prov-1', source: 'plaid', state: 'provisional', excluded: false };
  assert.equal(pickPlaidHashClaim([verified, provisional]), provisional);
});

test('hash fallback never claims an excluded or non-Plaid row', () => {
  assert.equal(
    pickPlaidHashClaim([{ id: 'x', source: 'plaid', state: 'provisional', excluded: true }]),
    null,
  );
  assert.equal(
    pickPlaidHashClaim([{ id: 'x', source: 'amex_alert', state: 'provisional', excluded: false }]),
    null,
  );
  assert.equal(pickPlaidHashClaim([]), null);
});

// --- 6. Caller wiring (source assertions on plaid-sync/index.ts) --------

test('fix 1: deferred removed[] query never matches plaid_pending_transaction_id', () => {
  // The removed[] lookup must use live ids only. (The upsert's step-2
  // pending→posted link lookup still uses plaid_pending_transaction_id
  // — that is the correct direction: a posted tx finding its pending
  // predecessor. Only the removed[] matcher must never use it.)
  assert.doesNotMatch(plaidSync, /plaid_pending_transaction_id\.eq\.\$\{removedId\}/);
  assert.match(plaidSync, /\.or\(`external_id\.eq\.\$\{removedId\},plaid_transaction_id\.eq\.\$\{removedId\}`\)/);
});

test('fix 2: sync arrivals carry card_suffix from the account mask, plus the new id/state/row id', () => {
  assert.match(plaidSync, /card_suffix: maskByAccount\.get\(tx\.account_id\) \?\? '0000'/);
  assert.match(plaidSync, /external_id: tx\.transaction_id \? String\(tx\.transaction_id\) : null/);
  assert.match(plaidSync, /state: tx\.pending \? 'provisional' : 'verified'/);
  assert.match(plaidSync, /rowId: upsert\.id \?\? null/);
});

test('fix 2: a link decision updates the row to the new ids/state and excludes the duplicate row', () => {
  assert.match(plaidSync, /decision\.action === 'link'/);
  assert.match(plaidSync, /external_id: replacement\.external_id/);
  assert.match(plaidSync, /plaid_transaction_id: replacement\.plaid_transaction_id/);
  assert.match(plaidSync, /state: replacement\.state/);
  assert.match(plaidSync, /\.update\(\{ state: 'excluded', excluded: true \}\)/);
  // Refund links pointing at the duplicate are re-pointed at the survivor.
  assert.match(plaidSync, /original_purchase_id: row\.id/);
  // The response counts links separately from exclusions.
  assert.match(plaidSync, /removed_linked: removedLinked/);
});

test('fix 2: an exclude decision first searches a recent window of household rows', () => {
  assert.match(plaidSync, /findRecentReplacement/);
  assert.match(plaidSync, /90 \* 24 \* 60 \* 60 \* 1000/);
  assert.match(plaidSync, /\.eq\('source', 'plaid'\)\.eq\('state', 'verified'\)\.eq\('excluded', false\)/);
  assert.match(plaidSync, /\.gte\('created_at', since\)/);
});

test('fix 3: posted tx with no pending link claims the earliest provisional Plaid row by hash', () => {
  assert.match(plaidSync, /pickPlaidHashClaim\(data \? \[data\] : \[\]\)/);
  assert.match(plaidSync, /\.eq\('dedupe_hash', hash\)/);
  assert.match(plaidSync, /\.eq\('source', 'plaid'\)\.eq\('state', 'provisional'\)\.eq\('excluded', false\)/);
  assert.match(plaidSync, /\.order\('created_at', \{ ascending: true \}\)\.limit\(1\)/);
  assert.match(plaidSync, /if \(!existing && state === 'verified'\)/);
});

test('fix 3: upsert returns the row id so arrivals can carry it', () => {
  assert.match(plaidSync, /return \{ result: 'updated', id: existing\.id \}/);
  assert.match(plaidSync, /return \{ result: 'updated', id: raced\.id \}/);
  assert.match(plaidSync, /return \{ result: 'added', id: inserted\.id \}/);
});

// --- 7. Canonical copies stay byte-identical -----------------------------

test('all four canonical.ts copies are byte-identical', () => {
  const shared = read('../supabase/functions/_shared/canonical.ts');
  for (const p of [
    '../supabase/functions/plaid-sync/canonical.ts',
    '../supabase/functions/ingest-amex-alert/canonical.ts',
    '../supabase/functions/gmail-poll/canonical.ts',
  ]) {
    assert.equal(read(p), shared, `${p} drifted from _shared/canonical.ts`);
  }
});
