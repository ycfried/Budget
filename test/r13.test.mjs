// R13 Charity tests — run with:
//   node --test test/r13.test.mjs
// Pure committed-per-income math (half-up, per income, override
// replaces the default) plus static guards on
// supabase/r13-charity.sql: admin-only RPCs, November 2026 start,
// pending-or-posted + unlocked-only marking, and no weekly-math writes.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { charityCommittedCents } from '../engine.mjs';

// --- committed math ---------------------------------------------------
test('R13: 10% of $100.00 commits $10.00', () => {
  assert.equal(charityCommittedCents(10000, 1000), 1000);
});

test('R13: half-up rounding per income ($10.05 at 10% -> $1.01)', () => {
  assert.equal(charityCommittedCents(1005, 1000), 101);
});

test('R13: an override replaces the default (20% of $50.00 is $10.00, not $15.00)', () => {
  assert.equal(charityCommittedCents(5000, 2000), 1000);
});

test('R13: a 0% rate commits nothing; remaining can go negative (ahead)', () => {
  assert.equal(charityCommittedCents(5000, 0), 0);
  const committed = charityCommittedCents(10000, 1000);
  const given = 1500;
  assert.ok(committed - given < 0, 'given above committed means ahead');
});

// --- SQL guards -------------------------------------------------------
const sql = readFileSync(new URL('../supabase/r13-charity.sql', import.meta.url), 'utf8');

test('R13 SQL: charity joins the transaction kinds', () => {
  assert.match(sql, /'charity'/);
  assert.match(sql, /transactions_kind_check/);
});

test('R13 SQL: every RPC is admin-only', () => {
  const adminGuards = sql.match(/admin only/g) ?? [];
  assert.equal(adminGuards.length, 5, 'set rate, record income, correct income, record gift, mark gift');
});

test('R13 SQL: charity starts November 2026, never earlier', () => {
  assert.match(sql, /2026-11-01/);
});

test('R13 SQL: marking requires a pending or posted, unexcluded, non-fund charge in an unlocked week', () => {
  assert.match(sql, /only a pending or posted transaction can be marked/);
  assert.match(sql, /state not in \('provisional', 'verified'\)/);
  assert.match(sql, /week is locked/);
  assert.match(sql, /fund_allocation_cents/);
});

test('R13 SQL: corrections are append-only (reversed, never edited away)', () => {
  assert.match(sql, /status = 'reversed'/);
  assert.match(sql, /replaces_id/);
});

test('R13 SQL: no weekly-math writes anywhere in the file', () => {
  assert.doesNotMatch(sql, /week_closes/);
  assert.doesNotMatch(sql, /surplus_releases/);
  assert.doesNotMatch(sql, /fund_ledger/);
});
