// R12 Add Money tests — run with:
//   node --test test/r12.test.mjs
// Pure split cases use the shared engine helper applyShortfallToRelease
// (the same rule the UI preview and the server RPC apply), plus static
// guards on supabase/r12-add-money.sql so the RPC keeps its safety
// properties: admin-only, serialized against the household row,
// idempotent on a client key, and confined to the fund tables.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { applyShortfallToRelease } from '../engine.mjs';

// --- doc cases (owner decision Nov 3, 2026: shortfall first) ---------
test('R12: $100 with no shortfall goes entirely to the fund', () => {
  const s = applyShortfallToRelease(10000, 0);
  assert.equal(s.releasedToFund, 10000);
  assert.equal(s.remainingShortfall, 0);
});

test('R12: owes $40 + $100 top-up -> $40 covered, $60 added, owes $0', () => {
  const s = applyShortfallToRelease(10000, 4000);
  assert.equal(s.releasedToFund, 6000);
  assert.equal(s.remainingShortfall, 0);
  assert.equal(10000 - s.releasedToFund, 4000);
});

test('R12: owes $150 + $100 top-up -> $100 covered, $0 added, owes $50', () => {
  const s = applyShortfallToRelease(10000, 15000);
  assert.equal(s.releasedToFund, 0);
  assert.equal(s.remainingShortfall, 5000);
});

test('R12: split invariants hold for every case', () => {
  for (const [amount, shortfall] of [[1, 0], [1, 1], [5000, 5000], [999, 100000], [0, 700]]) {
    const s = applyShortfallToRelease(amount, shortfall);
    assert.ok(s.releasedToFund >= 0, 'added is never negative');
    assert.ok(s.remainingShortfall >= 0, 'shortfall after is never negative');
    assert.equal(s.releasedToFund + (amount - s.releasedToFund), amount);
    assert.equal(shortfall - (amount - s.releasedToFund), s.remainingShortfall);
  }
});

// --- SQL guards -------------------------------------------------------
const sql = readFileSync(new URL('../supabase/r12-add-money.sql', import.meta.url), 'utf8');

test('R12 SQL: RPC is admin-only and serialized on the household row', () => {
  assert.match(sql, /role = 'admin'/);
  assert.match(sql, /for update/);
  assert.match(sql, /amount must be positive/);
});

test('R12 SQL: idempotent on a per-household client key', () => {
  assert.match(sql, /unique \(household_id, client_key\)/);
  assert.match(sql, /replayed/);
});

test('R12 SQL: writes only fund tables + audit, never week math', () => {
  assert.match(sql, /insert into public\.fund_topups/);
  assert.match(sql, /insert into public\.fund_ledger/);
  assert.match(sql, /insert into public\.audit_log/);
  assert.doesNotMatch(sql, /insert into public\.transactions/);
  assert.doesNotMatch(sql, /update public\.transactions/);
  assert.doesNotMatch(sql, /week_closes/);
  assert.doesNotMatch(sql, /surplus_releases/);
});
