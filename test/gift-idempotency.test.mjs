// Gift idempotency tests — run with:
//   node --test test/gift-idempotency.test.mjs
// Static guards on supabase/r13-gift-idempotency.sql (Round 3,
// bug 8): a replayed client key returns the original gift instead
// of a second row, writes no second audit row, and real identical
// gifts (fresh keys) are unaffected.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../supabase/r13-gift-idempotency.sql', import.meta.url), 'utf8');

test('gift idempotency SQL: transactions gains a client_key column', () => {
  assert.match(sql, /add column if not exists client_key text/);
});

test('gift idempotency SQL: one partial unique index scopes keys per household', () => {
  assert.match(sql, /transactions_household_client_key_idx/);
  assert.match(sql, /\(household_id, client_key\)/);
  assert.match(sql, /where client_key is not null/);
});

test('gift idempotency SQL: the RPC takes an optional client key', () => {
  assert.match(sql, /p_client_key text default null/);
});

test('gift idempotency SQL: a replay returns the original row without inserting', () => {
  assert.match(sql, /where household_id = p_household_id and client_key = v_key/);
  assert.match(sql, /'replayed', true/);
});

test('gift idempotency SQL: the insert is conflict-guarded and the audit row is insert-only', () => {
  assert.match(sql, /on conflict \(household_id, client_key\) where client_key is not null do nothing/);
  // The audit insert must come after the replay/conflict returns,
  // so a replayed key never writes a second audit row.
  const auditAt = sql.indexOf("Charity gift recorded");
  const replayAt = sql.indexOf("'replayed', true");
  assert.ok(auditAt > replayAt, 'audit insert follows the replay returns');
});

test('gift idempotency SQL: the RPC stays admin-only', () => {
  assert.match(sql, /raise exception 'admin only'/);
});
