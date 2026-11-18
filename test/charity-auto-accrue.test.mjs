// Charity auto-accrual tests (build 44, item 5) — run with:
//   node --test test/charity-auto-accrue.test.mjs
// Source assertions in the existing audit-test style, plus live
// behaviour checks of the pure helpers the hook shares with the
// edge functions (EMAIL_SOURCES / classifyKind decide which rows
// can ever reach the RPC). The SQL itself cannot run without a live
// database — the live pass (dashboard apply, then a test-household
// income row accruing once at 10%) is still owed after deploy.
// DECISION PINNED HERE: accrual is VERIFIED-only (pending→posted
// transition), never provisional; transfers, refunds, payments and
// cashback never accrue; record_charity_income stays admin-only and
// is not modified by this build.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  accrueCharityForIncomeTx,
  classifyKind,
  EMAIL_SOURCES,
  isEmailSource,
} from '../supabase/functions/_shared/canonical.ts';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const accrueSql = read('../supabase/charity-auto-accrue.sql');
const plaidSync = read('../supabase/functions/plaid-sync/index.ts');
const gmailPoll = read('../supabase/functions/gmail-poll/index.ts');
const ingest = read('../supabase/functions/ingest-amex-alert/index.ts');
const r13 = read('../supabase/r13-charity.sql');

// --- SQL: link column + idempotency index ---------------------------------

test('accrual SQL: charity_income links to the transaction, once per active row', () => {
  assert.match(accrueSql, /alter table public\.charity_income/);
  assert.match(accrueSql, /add column if not exists transaction_id uuid references public\.transactions\(id\) on delete set null/);
  assert.match(accrueSql, /create unique index if not exists charity_income_household_transaction_uidx/);
  assert.match(accrueSql, /on public\.charity_income \(household_id, transaction_id\)/);
  assert.match(accrueSql, /where status = 'active'/);
});

test('accrual SQL: entry point is service-role-only, record_charity_income untouched', () => {
  assert.match(accrueSql, /create or replace function public\.accrue_charity_for_transaction\(p_transaction_id uuid\)/);
  assert.match(accrueSql, /security definer/);
  assert.match(accrueSql, /if auth\.role\(\) <> 'service_role' then raise exception 'service role only'/);
  assert.ok(accrueSql.includes('grant execute on function public.accrue_charity_for_transaction(uuid) to service_role;'));
  assert.ok(accrueSql.includes('revoke execute on function public.accrue_charity_for_transaction(uuid) from authenticated;'));
  assert.ok(!accrueSql.includes('function public.record_charity_income'), 'this file must not redefine the admin-only RPC');
  assert.match(r13, /if auth\.uid\(\) is null then raise exception 'not authenticated'/);
});

// --- SQL: rate, rounding, guards, idempotent return ------------------------

test('accrual SQL: rate resolves from charity_settings, default 10% (1000 bp)', () => {
  assert.match(accrueSql, /select default_rate_bp into v_rate from public\.charity_settings where household_id = v_tx\.household_id/);
  assert.match(accrueSql, /v_rate := coalesce\(v_rate, 1000\)/);
});

test('accrual SQL: committed is half-up in bigint, same formula as R13', () => {
  assert.match(accrueSql, /v_committed := \(v_amount::bigint \* v_rate \+ 5000\) \/ 10000;/);
  assert.match(accrueSql, /v_amount := abs\(v_tx\.amount_cents\)/);
});

test('accrual SQL: double-invoke returns the existing income_id (replayed)', () => {
  assert.match(accrueSql, /where household_id = v_tx\.household_id/);
  assert.match(accrueSql, /and transaction_id = p_transaction_id/);
  assert.match(accrueSql, /and status = 'active'/);
  assert.match(accrueSql, /'replayed', true/);
  assert.match(accrueSql, /on conflict \(household_id, transaction_id\) where status = 'active' do nothing/);
  assert.match(accrueSql, /Lost a race with a concurrent accrual: return the row that won/);
});

test('accrual SQL: non-income, provisional, excluded, and pre-Nov rows are refused', () => {
  assert.match(accrueSql, /if v_tx\.kind <> 'income' then/);
  assert.match(accrueSql, /return jsonb_build_object\('accrued', false, 'reason', 'not_income'\)/);
  assert.match(accrueSql, /if v_tx\.state <> 'verified' then/);
  assert.match(accrueSql, /return jsonb_build_object\('accrued', false, 'reason', 'not_verified'\)/);
  assert.match(accrueSql, /if coalesce\(v_tx\.excluded, false\) then/);
  assert.match(accrueSql, /if v_tx\.date < date '2026-11-01' then/);
  assert.match(accrueSql, /return jsonb_build_object\('accrued', false, 'reason', 'before_nov_2026'\)/);
});

// --- Hook: plaid-sync accrues on insert-verified and on transition --------

test('plaid-sync: verified income accrues at insert; provisional accrues on transition only', () => {
  assert.match(plaidSync, /await accrueCharityForIncomeTx\(supabaseAdmin, householdId, inserted\.id, kind, state\)/);
  assert.match(plaidSync, /if \(!trashed && state === 'verified' && existing\.state !== 'verified'\) \{\n\s+await accrueCharityForIncomeTx\(supabaseAdmin, householdId, existing\.id, existing\.kind \?\? kind, state\);/);
});

test('plaid-sync: the hook uses the STORED kind (kind is insert-only, A14)', () => {
  assert.match(plaidSync, /existing\.kind \?\? kind/);
  const selects = plaidSync.match(/\.select\('id,state,excluded,source,kind'\)/g) ?? [];
  assert.ok(selects.length >= 4, `expected kind on the lookup selects, found ${selects.length}`);
});

test('email ingest: accrual wired after insert, dormant while rows are provisional', () => {
  assert.match(gmailPoll, /await accrueCharityForIncomeTx\(supabaseAdmin, householdId, inserted\.id, kind, 'provisional'\)/);
  assert.match(ingest, /await accrueCharityForIncomeTx\(supabase, householdId, inserted\.id, kind, 'provisional'\)/);
});

// --- Helper: never accrues the wrong kinds ---------------------------------

test('helper: refund, payment, cashback, transfer, and provisional rows never call the RPC', async () => {
  const calls = [];
  const fakeAdmin = {
    from: () => { throw new Error('must not query for non-income rows'); },
    rpc: (...args) => { calls.push(args); return Promise.resolve({ error: null }); },
  };
  for (const kind of ['refund', 'payment', 'cashback', 'transfer', 'charge', 'charity']) {
    await accrueCharityForIncomeTx(fakeAdmin, 'hh-1', 'tx-1', kind, 'verified');
  }
  await accrueCharityForIncomeTx(fakeAdmin, 'hh-1', 'tx-1', 'income', 'provisional');
  await accrueCharityForIncomeTx(fakeAdmin, 'hh-1', 'tx-1', 'income', 'excluded');
  assert.deepEqual(calls, [], 'no RPC call for any non-verified-income row');
});

test('helper: skips the RPC when the charity_income link already exists', async () => {
  const calls = [];
  const fakeAdmin = {
    from: () => ({
      select: () => ({ eq: () => ({ eq: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: { id: 'income-1' } }) }) }) }) }),
    }),
    rpc: (...args) => { calls.push(args); return Promise.resolve({ error: null }); },
  };
  await accrueCharityForIncomeTx(fakeAdmin, 'hh-1', 'tx-1', 'income', 'verified');
  assert.deepEqual(calls, [], 'already-linked rows must not re-call the RPC');
});

test('helper: verified income with no link calls the accrual RPC once', async () => {
  const calls = [];
  const fakeAdmin = {
    from: () => ({
      select: () => ({ eq: () => ({ eq: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null }) }) }) }) }),
    }),
    rpc: (...args) => { calls.push(args); return Promise.resolve({ error: null }); },
  };
  await accrueCharityForIncomeTx(fakeAdmin, 'hh-1', 'tx-1', 'income', 'verified');
  assert.deepEqual(calls, [['accrue_charity_for_transaction', { p_transaction_id: 'tx-1' }]]);
});

test('helper: a missing SQL apply (RPC error) never throws into the sync', async () => {
  const fakeAdmin = {
    from: () => ({
      select: () => ({ eq: () => ({ eq: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null }) }) }) }) }),
    }),
    rpc: () => Promise.resolve({ error: { message: 'function does not exist' } }),
  };
  await accrueCharityForIncomeTx(fakeAdmin, 'hh-1', 'tx-1', 'income', 'verified');
});

// --- Classifier: only genuine income can ever reach the hook ---------------

test('classifier: deposits and depository inflows are income; payments/cashback are not', () => {
  assert.equal(classifyKind({}, 'CHECK DEPOSIT', -350000, 'depository'), 'income');
  assert.equal(classifyKind({}, 'MOBILE DEPOSIT', -101279, 'depository'), 'income');
  assert.equal(classifyKind({}, 'AMEX EPAYMENT', -50000, 'credit'), 'payment');
  assert.equal(classifyKind({}, 'CASH BACK REWARD', -2500, 'credit'), 'cashback');
  assert.equal(classifyKind({}, 'INTERNAL TRANSFER', -10000, 'depository'), 'transfer');
  assert.equal(classifyKind({}, 'AMAZON MARKEPLACE NA PA', -1059, 'credit'), 'refund');
});

// --- Email source set (build 44, item 4) -----------------------------------

test('email sources: single set, Amex only — no invented Chase/Capital One source', () => {
  assert.deepEqual([...EMAIL_SOURCES], ['amex_alert']);
  assert.equal(isEmailSource('amex_alert'), true);
  assert.equal(isEmailSource('chase_alert'), false);
  assert.equal(isEmailSource('capital_one_alert'), false);
  assert.equal(isEmailSource('plaid'), false);
  assert.ok(!plaidSync.includes('chase_alert') && !plaidSync.includes('capital_one'));
});
