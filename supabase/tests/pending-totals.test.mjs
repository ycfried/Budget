// Pending-totals + same-hash-guard tests (build 58, owner
// Nov 22, 2026) — run with:
//   node --test supabase/tests/pending-totals.test.mjs
// Pure helpers from supabase/functions/_shared/canonical.ts and
// supabase/functions/_shared/engine.mjs, imported directly (Node
// type-strips .ts). The SQL mirror
// (supabase/reclassify-income-accrual.sql v4: provisional income
// accrues; the trigger reverses on exclude / reclassify-away) must
// stay in step with the rules pinned here. The SQL itself cannot
// run without a live database; the live pass is verified by the
// steps in that file's header (test household first).
//
// Rules pinned:
//  1. Pending counts toward totals: a provisional charge counts
//     in week math; a provisional refund counts nothing until it
//     posts; a provisional income row accrues charity immediately.
//  2. A pending transaction that disappears (in removed[] with no
//     replacement anywhere) auto-reverses — decideRemovedRow
//     returns 'exclude' for it. A replacement / re-issue signal
//     still leaves it alone (Nov 17 safeguard, kept).
//  3. Same-source duplicates: a live row with the same
//     dedupe_hash already exists -> the alert is a duplicate
//     (findExistingSameHash returns its id).

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  accrueCharityForIncomeTx,
  decideRemovedRow,
  findExistingSameHash,
} from '../functions/_shared/canonical.ts';
import {
  chargeContribution,
  isExcludedFromMath,
} from '../functions/_shared/engine.mjs';

const HH = 'household-1';

// --- decideRemovedRow ------------------------------------------------
// A provisional Plaid row in removed[]: the pending transaction
// either posted under a new id (a signal in this sync's arrivals)
// or truly disappeared (no signal anywhere).

const provisionalRow = (over = {}) => ({
  state: 'provisional', excluded: false, merchant: 'AMAZON',
  date: '2026-11-22', amount_cents: 4496, card_suffix: '1005',
  external_id: 'plaid-pending-1', plaid_transaction_id: 'plaid-pending-1',
  ...over,
});
const verifiedRow = (over = {}) => ({
  state: 'verified', excluded: false, merchant: 'AMAZON',
  date: '2026-11-22', amount_cents: 4496, card_suffix: '1005',
  external_id: 'plaid-posted-1', plaid_transaction_id: 'plaid-posted-1',
  ...over,
});
const postedArrival = (over = {}) => ({
  merchant: 'AMAZON', date: '2026-11-22', amount_cents: 4496,
  card_suffix: '1005', external_id: 'plaid-posted-2',
  state: 'verified', rowId: 'row-2', pending_transaction_id: 'plaid-pending-1',
  ...over,
});

test('removed: provisional + no arrival -> exclude (auto-reverse, build 58)', () => {
  assert.deepEqual(decideRemovedRow(provisionalRow(), []), {
    action: 'exclude', reason: 'provisional-disappeared',
  });
});

test('removed: provisional + posted replacement arrival -> link (it posted)', () => {
  const d = decideRemovedRow(provisionalRow(), [postedArrival()]);
  assert.equal(d.action, 'link');
  assert.equal(d.replacement?.external_id, 'plaid-posted-2');
});

test('removed: provisional + same-merchant/amount/date arrival -> leave (re-issue)', () => {
  const d = decideRemovedRow(provisionalRow(), [postedArrival({ state: 'provisional', external_id: 'plaid-pending-1' })]);
  assert.equal(d.action, 'leave');
});

test('removed: provisional + pending-link arrival -> leave (re-issue)', () => {
  // The pending-link signal is for when the merchant string
  // legitimately differs between the pending and posted versions,
  // so the replacement-link check (same merchant) does not fire —
  // the link on amount + date is the signal instead.
  const d = decideRemovedRow(provisionalRow(), [postedArrival({ merchant: 'AMAZON MKTPLACE PMTS', external_id: 'plaid-other', pending_transaction_id: 'plaid-pending-1' })]);
  assert.equal(d.action, 'leave');
  assert.equal(d.reason, 'reissue-pending-link');
});

test('removed: verified + no arrival -> exclude (genuine reversal, unchanged)', () => {
  assert.deepEqual(decideRemovedRow(verifiedRow(), []), {
    action: 'exclude', reason: 'verified-reversal',
  });
});

test('removed: already-excluded row -> leave', () => {
  assert.deepEqual(decideRemovedRow(provisionalRow({ excluded: true }), []), {
    action: 'leave', reason: 'already-excluded',
  });
  assert.deepEqual(decideRemovedRow(verifiedRow({ state: 'reversed' }), []), {
    action: 'leave', reason: 'already-excluded',
  });
});

test('removed: unknown state -> leave', () => {
  assert.deepEqual(decideRemovedRow(verifiedRow({ state: 'pending' }), []), {
    action: 'leave', reason: 'not-verified',
  });
});

// --- week math: provisional charges count -----------------------------

const charge = (over = {}) => ({
  kind: 'charge', state: 'provisional', excluded: false,
  amount_cents: 4496, fund_allocation_cents: 0, ...over,
});

test('week math: provisional charge counts', () => {
  assert.equal(isExcludedFromMath(charge()), false);
  assert.equal(chargeContribution(charge()), 4496);
});

test('week math: verified charge counts', () => {
  assert.equal(chargeContribution(charge({ state: 'verified' })), 4496);
});

test('week math: provisional refund counts nothing until it posts', () => {
  const refund = charge({ kind: 'refund', amount_cents: -4496 });
  assert.equal(isExcludedFromMath(refund), true);
  assert.equal(chargeContribution(refund), 0);
  assert.equal(chargeContribution(charge({ kind: 'refund', state: 'verified', amount_cents: -4496 })), 0);
});

test('week math: excluded / reversed charge counts nothing', () => {
  assert.equal(chargeContribution(charge({ excluded: true })), 0);
  assert.equal(chargeContribution(charge({ state: 'reversed' })), 0);
});

// --- accrueCharityForIncomeTx (fake supabase client) -----------------
// Supports only the chains the helper uses: from().select().eq()
// .maybeSingle() for the pre-check, and rpc() for the accrual.

function fakeSupabase({ alreadyAccrued = false } = {}) {
  const rpcCalls = [];
  return {
    rpcCalls,
    from(table) {
      if (table !== 'charity_income') throw new Error(`unexpected table ${table}`);
      const chain = {
        select() { return chain; },
        eq() { return chain; },
        async maybeSingle() {
          return { data: alreadyAccrued ? { id: 'accrual-1' } : null };
        },
      };
      return chain;
    },
    async rpc(name, params) {
      rpcCalls.push({ name, params });
      return { error: null };
    },
  };
}

test('charity hook: provisional income accrues (build 58)', async () => {
  const db = fakeSupabase();
  await accrueCharityForIncomeTx(db, HH, 'txn-1', 'income', 'provisional');
  assert.equal(db.rpcCalls.length, 1);
  assert.equal(db.rpcCalls[0].name, 'accrue_charity_for_transaction');
  assert.deepEqual(db.rpcCalls[0].params, { p_transaction_id: 'txn-1' });
});

test('charity hook: verified income accrues', async () => {
  const db = fakeSupabase();
  await accrueCharityForIncomeTx(db, HH, 'txn-1', 'income', 'verified');
  assert.equal(db.rpcCalls.length, 1);
});

test('charity hook: already-accrued income does not double-accrue', async () => {
  const db = fakeSupabase({ alreadyAccrued: true });
  await accrueCharityForIncomeTx(db, HH, 'txn-1', 'income', 'provisional');
  assert.equal(db.rpcCalls.length, 0);
});

test('charity hook: non-income kind accrues nothing', async () => {
  const db = fakeSupabase();
  await accrueCharityForIncomeTx(db, HH, 'txn-1', 'charge', 'provisional');
  await accrueCharityForIncomeTx(db, HH, 'txn-1', 'income', 'excluded');
  assert.equal(db.rpcCalls.length, 0);
});

// --- findExistingSameHash (fake db) -----------------------------------
// Supports only the chain the helper uses: select/eq/neq/limit,
// awaited as a thenable.

function fakeTxDb({ txRows }) {
  return {
    from(table) {
      if (table !== 'transactions') throw new Error(`unexpected table ${table}`);
      const chain = {
        _filters: [],
        select() { return chain; },
        eq(k, v) { chain._filters.push(['eq', k, v]); return chain; },
        neq(k, v) { chain._filters.push(['neq', k, v]); return chain; },
        limit(n) { chain._limit = n; return chain; },
        then(res) {
          let rows = txRows.filter((r) => chain._filters.every(([op, k, v]) => (
            op === 'eq' ? r[k] === v : r[k] !== v
          )));
          if (chain._limit) rows = rows.slice(0, chain._limit);
          return Promise.resolve({ data: rows }).then(res);
        },
      };
      return chain;
    },
  };
}

const HASH = '7e672be3261ba7f38c3109d6f86ca09ccffb405a9481675973555f3fb21c76f3';
const liveRow = (over = {}) => ({
  id: 'd38c3916', household_id: HH, dedupe_hash: HASH,
  excluded: false, state: 'provisional', ...over,
});

test('same-hash guard: live row with this hash -> returns its id', async () => {
  const db = fakeTxDb({ txRows: [liveRow()] });
  assert.equal(await findExistingSameHash(db, HH, HASH), 'd38c3916');
});

test('same-hash guard: no row with this hash -> null', async () => {
  const db = fakeTxDb({ txRows: [liveRow({ dedupe_hash: 'other-hash' })] });
  assert.equal(await findExistingSameHash(db, HH, HASH), null);
});

test('same-hash guard: only an excluded row with this hash -> null', async () => {
  const db = fakeTxDb({ txRows: [liveRow({ excluded: true })] });
  assert.equal(await findExistingSameHash(db, HH, HASH), null);
});

test('same-hash guard: only a reversed row with this hash -> null', async () => {
  const db = fakeTxDb({ txRows: [liveRow({ state: 'reversed' })] });
  assert.equal(await findExistingSameHash(db, HH, HASH), null);
});
