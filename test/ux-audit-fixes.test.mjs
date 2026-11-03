// UX audit fixes (Nov 3, 2026) tests — run with:
//   node --test test/ux-audit-fixes.test.mjs
// Pure helpers from engine.mjs and filterState.mjs: money grouping
// (audit 11), weekly reconciliation (audit 02), activity wording +
// grouping (audit 09). No DOM, no network, no database.

import test from 'node:test';
import assert from 'node:assert/strict';
import { formatCents } from '../engine.mjs';
import {
  weeklyReconciliation,
  householdActivityText,
  groupDayActivity,
} from '../filterState.mjs';

test('formatCents: thousands separators, sign, cents', () => {
  assert.equal(formatCents(562608), '$5,626.08');
  assert.equal(formatCents(733043), '$7,330.43');
  assert.equal(formatCents(37500), '$375.00');
  assert.equal(formatCents(0), '$0.00');
  assert.equal(formatCents(-10050), '-$100.50');
  assert.equal(formatCents(99), '$0.99');
});

test('weeklyReconciliation: debt absorbed by the allowance is not outgoing', () => {
  // The old client formula added the full incoming debt (10000);
  // engine.mjs says outgoing is only the unabsorbed part (0 here).
  const w = weeklyReconciliation({ allowance: 37500, carried: 10000, temp: 0, spent: 0 });
  assert.equal(w.baseRoom, 27500);
  assert.equal(w.left, 27500);
  assert.equal(w.unabsorbed, 0);
  assert.equal(w.newDebt, 0);
  assert.equal(w.outgoing, 0);
});

test('weeklyReconciliation: engine fixture debt chain', () => {
  const w = weeklyReconciliation({ allowance: 37500, carried: 42500, temp: 0, spent: 0 });
  assert.equal(w.baseRoom, 0);
  assert.equal(w.unabsorbed, 5000);
  assert.equal(w.outgoing, 5000);
});

test('weeklyReconciliation: spending above room becomes new debt', () => {
  const w = weeklyReconciliation({ allowance: 37500, carried: 0, temp: 10000, spent: 50000 });
  assert.equal(w.baseRoom, 37500);
  assert.equal(w.left, -2500);
  assert.equal(w.newDebt, 2500);
  assert.equal(w.outgoing, 2500);
  assert.equal(w.left, w.baseRoom + 10000 - 50000);
});

test('householdActivityText: week-close summary in plain language', () => {
  assert.equal(
    householdActivityText('5 week(s) closed, 0 release(s), 0 restoration(s), 0 held refund(s).'),
    '5 weeks closed, 0 surpluses released, 0 refunds restored, 0 refunds held for review.',
  );
  assert.equal(
    householdActivityText('1 week(s) closed, 1 release(s), 1 restoration(s), 1 held refund(s).'),
    '1 week closed, 1 surplus released, 1 refund restored, 1 refund held for review.',
  );
});

test('householdActivityText: canonical wording mapped, never leaked', () => {
  const out = householdActivityText('Merged duplicate X (AMAZON 1059 cents) into canonical Y (AMAZON 1059 cents).');
  assert.ok(!out.includes('canonical'));
  assert.ok(out.includes('into the original bank row'));
});

test('groupDayActivity: identical Weeks processed rows collapse with a count', () => {
  const rows = [1, 2, 3].map((i) => ({
    action: 'Weeks processed',
    detail: '5 weeks closed, 0 surpluses released, 0 refunds restored, 0 refunds held for review.',
    actor: 'Admin',
    time: `Nov 3, 6:3${i} PM`,
  }));
  const grouped = groupDayActivity(rows);
  assert.equal(grouped.length, 1);
  assert.equal(grouped[0].count, 3);
  assert.equal(grouped[0].time, 'Nov 3, 6:31 PM');
});

test('groupDayActivity: user actions never collapse, even when identical', () => {
  const rows = [1, 2].map(() => ({
    action: 'Transaction excluded',
    detail: 'AMAZON $10.59 — reason: duplicate.',
    actor: 'Admin',
    time: 'Nov 3, 6:32 PM',
  }));
  const grouped = groupDayActivity(rows);
  assert.equal(grouped.length, 2);
  assert.ok(grouped.every((g) => g.count === 1));
});

test('groupDayActivity: different details stay separate', () => {
  const grouped = groupDayActivity([
    { action: 'Weeks processed', detail: '5 weeks closed.', actor: 'Admin', time: 'Nov 3, 6:32 PM' },
    { action: 'Weeks processed', detail: '3 weeks closed.', actor: 'Admin', time: 'Nov 3, 6:31 PM' },
  ]);
  assert.equal(grouped.length, 2);
});
