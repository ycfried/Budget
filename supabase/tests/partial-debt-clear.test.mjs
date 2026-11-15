// Partial debt clear tests (build 30, task K) — run with:
//   node --test supabase/tests/partial-debt-clear.test.mjs
// computePartialClear from supabase/functions/_shared/engine.mjs
// (synced verbatim to compute-week/engine.mjs and
// week-close/engine.mjs). It mirrors the SQL in
// supabase/partial-debt-clear.sql exactly — same refusals, same
// floor. The SQL itself cannot run without a live database; the
// live behaviour is verified by the deploy steps in
// BUILD30_SERVER_DEPLOY.md (test household only).

import test from 'node:test';
import assert from 'node:assert/strict';
import { computePartialClear } from '../functions/_shared/engine.mjs';

// The real household's balance, used as the worked example. These
// tests never touch it — the number is only arithmetic input here.
const BALANCE = 319444; // $3,194.44

test('full clear (no amount, no percent) clears everything', () => {
  assert.deepEqual(computePartialClear(BALANCE), { clearedCents: 319444, remainingCents: 0 });
});

test('partial clear by amount reduces the balance by exactly that amount', () => {
  assert.deepEqual(computePartialClear(BALANCE, { amountCents: 100000 }), {
    clearedCents: 100000, remainingCents: 219444,
  });
});

test('partial clear by amount: clearing the full balance is allowed', () => {
  assert.deepEqual(computePartialClear(BALANCE, { amountCents: 319444 }), {
    clearedCents: 319444, remainingCents: 0,
  });
});

test('partial clear by percentage: 25% of $3,194.44 is $798.61 (floor, not round)', () => {
  // 319444 * 2500 / 10000 = 79861 exactly; the floor matters on
  // balances that do not divide evenly (see next test).
  assert.deepEqual(computePartialClear(BALANCE, { percentBp: 2500 }), {
    clearedCents: 79861, remainingCents: 239583,
  });
});

test('percentage floors: 10% of $100.01 is $10.00, never $10.01', () => {
  assert.deepEqual(computePartialClear(10001, { percentBp: 1000 }), {
    clearedCents: 1000, remainingCents: 9001,
  });
});

test('percentage: 100% clears everything; 1bp of a small balance clears 1 cent or refuses', () => {
  assert.deepEqual(computePartialClear(BALANCE, { percentBp: 10000 }), {
    clearedCents: 319444, remainingCents: 0,
  });
  assert.deepEqual(computePartialClear(100, { percentBp: 100 }), { clearedCents: 1, remainingCents: 99 });
  // 1bp of 50 cents floors to 0 -> refused, nothing written.
  assert.throws(() => computePartialClear(50, { percentBp: 1 }), /clears nothing/);
});

test('over-amount clear is refused, never silently partial', () => {
  assert.throws(
    () => computePartialClear(BALANCE, { amountCents: 319445 }),
    /amount exceeds remaining debt: 319444 cents/,
  );
});

test('amount and percentage together are refused', () => {
  assert.throws(
    () => computePartialClear(BALANCE, { amountCents: 1000, percentBp: 1000 }),
    /not both/,
  );
});

test('non-positive amount is refused', () => {
  assert.throws(() => computePartialClear(BALANCE, { amountCents: 0 }), /amount must be positive/);
  assert.throws(() => computePartialClear(BALANCE, { amountCents: -500 }), /amount must be positive/);
});

test('percentage outside 1..10000 bp is refused', () => {
  assert.throws(() => computePartialClear(BALANCE, { percentBp: 0 }), /between 1 and 10000/);
  assert.throws(() => computePartialClear(BALANCE, { percentBp: 10001 }), /between 1 and 10000/);
});

test('no debt at all is refused', () => {
  assert.throws(() => computePartialClear(0), /no debt to clear/);
  assert.throws(() => computePartialClear(0, { amountCents: 100 }), /no debt to clear/);
  assert.throws(() => computePartialClear(0, { percentBp: 5000 }), /no debt to clear/);
});

test('balance never goes below zero: cleared + remaining always equals the balance', () => {
  for (const balance of [1, 50, 99, 100, 10001, 319444]) {
    for (const opts of [{}, { amountCents: 1 }, { percentBp: 1 }, { percentBp: 3333 }, { percentBp: 10000 }]) {
      let out;
      try {
        out = computePartialClear(balance, opts);
      } catch {
        continue; // refusals (e.g. 1bp of 1 cent) are the correct outcome
      }
      assert.equal(out.clearedCents + out.remainingCents, balance);
      assert.ok(out.remainingCents >= 0);
      assert.ok(out.clearedCents > 0);
    }
  }
});

test('sequential partial clears compose: two clears sum to the total written off', () => {
  const first = computePartialClear(BALANCE, { amountCents: 100000 });
  const second = computePartialClear(first.remainingCents, { percentBp: 5000 });
  assert.equal(first.clearedCents + second.clearedCents, 100000 + Math.floor(219444 * 5000 / 10000));
  assert.equal(second.remainingCents, BALANCE - first.clearedCents - second.clearedCents);
});
