// Delta3 (Nov 3, 2026) tests — run with:
//   node --test test/delta3.test.mjs
// Pure helpers from filterState.mjs: week-close log condition,
// week-close client due-check, CSV transfer classification. Transfer
// exclusion from week math via engine.mjs isExcludedFromMath.
// No DOM, no network, no database. The server-side canonical.ts
// transfer rule cannot run under node (TypeScript), so it is covered
// by the identical-pattern CSV helper test plus the engine exclusion
// test; the live classification copies are verified identical by diff
// in review (all four canonical.ts files, all four engine.mjs files).

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  shouldLogWeekClose,
  isWeekCloseCheckDue,
  classifyCsvKind,
} from '../filterState.mjs';
import { isExcludedFromMath, chargeContribution } from '../engine.mjs';

test('shouldLogWeekClose: a no-op run logs nothing', () => {
  assert.equal(shouldLogWeekClose({ weeksClosed: 0, releasesDone: 0, restorations: 0, heldCreated: 0 }), false);
  assert.equal(shouldLogWeekClose({}), false);
  assert.equal(shouldLogWeekClose(), false);
});

test('shouldLogWeekClose: any real change logs exactly one row', () => {
  assert.equal(shouldLogWeekClose({ weeksClosed: 1 }), true);
  assert.equal(shouldLogWeekClose({ releasesDone: 1 }), true);
  assert.equal(shouldLogWeekClose({ restorations: 1 }), true);
  assert.equal(shouldLogWeekClose({ heldCreated: 1 }), true);
  assert.equal(shouldLogWeekClose({ weeksClosed: 2, releasesDone: 1, restorations: 1, heldCreated: 1 }), true);
});

test('shouldLogWeekClose: legacy held releases are counted, not changed, so they do not log', () => {
  // heldLegacy is not one of the four fields: observing an untouched
  // legacy held release must not create a "Weeks processed" row.
  assert.equal(shouldLogWeekClose({ heldLegacy: 3 }), false);
});

test('isWeekCloseCheckDue: no stored check means due (first load, new household)', () => {
  assert.equal(isWeekCloseCheckDue({ lastCheckedWeekStart: null, currentWeekStart: '2026-11-01' }), true);
  assert.equal(isWeekCloseCheckDue({ currentWeekStart: '2026-11-01' }), true);
});

test('isWeekCloseCheckDue: no current week start means due (fallback — server no-op is silent)', () => {
  assert.equal(isWeekCloseCheckDue({ lastCheckedWeekStart: '2026-11-01', currentWeekStart: null }), true);
  assert.equal(isWeekCloseCheckDue({}), true);
});

test('isWeekCloseCheckDue: same week as the last check means not due (reload spam stopped)', () => {
  assert.equal(isWeekCloseCheckDue({ lastCheckedWeekStart: '2026-11-01', currentWeekStart: '2026-11-01' }), false);
});

test('isWeekCloseCheckDue: a week boundary since the last check means due', () => {
  assert.equal(isWeekCloseCheckDue({ lastCheckedWeekStart: '2026-11-01', currentWeekStart: '2026-11-08' }), true);
  assert.equal(isWeekCloseCheckDue({ lastCheckedWeekStart: '2026-10-25', currentWeekStart: '2026-11-01' }), true);
});

test('isWeekCloseCheckDue: a stored future week (clock skew) does not force a call', () => {
  assert.equal(isWeekCloseCheckDue({ lastCheckedWeekStart: '2026-11-08', currentWeekStart: '2026-11-01' }), false);
});

test('classifyCsvKind: INTERNAL TRANSFER rows import as transfer, either direction', () => {
  assert.equal(classifyCsvKind('INTERNAL TRANSFER DEBIT: SAVINGS -5939', 200000), 'transfer');
  assert.equal(classifyCsvKind('INTERNAL TRANSFER CREDIT: SAVINGS -5939', -200000), 'transfer');
  assert.equal(classifyCsvKind('internal transfer debit: savings', 5000), 'transfer');
  assert.equal(classifyCsvKind('BANK INTERNAL TRANSFER FEE', -100), 'transfer');
});

test('classifyCsvKind: ordinary rows keep the sign rule', () => {
  assert.equal(classifyCsvKind('AMAZON MARKEPLACE NA PA', 1059), 'charge');
  assert.equal(classifyCsvKind('AMAZON REFUND', -1059), 'refund');
  assert.equal(classifyCsvKind('SOME TRANSFER TO A FRIEND', 5000), 'charge');
  assert.equal(classifyCsvKind('TRANSFER TO A FRIEND', -5000), 'refund');
});

test('engine: transfer rows are excluded from week math both directions', () => {
  const out = { kind: 'transfer', state: 'verified', excluded: false, amount_cents: 200000, fund_allocation_cents: 0 };
  const inn = { kind: 'transfer', state: 'verified', excluded: false, amount_cents: -200000, fund_allocation_cents: 0 };
  assert.equal(isExcludedFromMath(out), true);
  assert.equal(isExcludedFromMath(inn), true);
  assert.equal(chargeContribution(out), 0);
  assert.equal(chargeContribution(inn), 0);
});

test('engine: ordinary kinds are untouched by the transfer rule', () => {
  const charge = { kind: 'charge', state: 'verified', excluded: false, amount_cents: 200000, fund_allocation_cents: 0 };
  const refund = { kind: 'refund', state: 'verified', excluded: false, amount_cents: -5000, fund_allocation_cents: 0 };
  assert.equal(isExcludedFromMath(charge), false);
  assert.equal(isExcludedFromMath(refund), false);
  assert.equal(chargeContribution(charge), 200000);
});
