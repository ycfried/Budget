// P1 fixes from the Nov 8, 2026 re-audit (FULL_AUDIT_2026-11-08_R2.md).
// Branch-only tests; live SQL/RPC behaviour is verified by the
// parent's live probes, not by these node tests (Deno functions
// never execute under node --test).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { classifyKind, classifyMerchantOnly } from '../supabase/functions/_shared/canonical.ts';
import { actionsForTxKind, classifyCsvKind } from '../filterState.mjs';
import { chargeContribution } from '../engine.mjs';

const liveJs = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const stylesCss = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const sql = (p) => readFileSync(new URL(`../supabase/${p}`, import.meta.url), 'utf8');

// ---- P1-NEW1: charity classification gap ----

test('P1-NEW1: classifier auto-detects charity merchants on money-out rows', () => {
  assert.equal(classifyKind({}, 'KEREN HATZEDAKA', 200), 'charity');
  assert.equal(classifyKind({}, 'TOIREMORG CHARITY', 200), 'charity');
  assert.equal(classifyKind({}, 'COLEL CHABAD', 500), 'charity');
  assert.equal(classifyKind({}, 'Some Donation Fund', 1000), 'charity');
  assert.equal(classifyMerchantOnly('KEREN HATZEDAKA', 200), 'charity');
  // Payment still wins over a charity-named merchant.
  assert.equal(classifyKind({}, 'CHARITY PAYMENT - THANK YOU', -500), 'payment');
  // A negative charity-named row is a refund of a gift, not a gift.
  assert.equal(classifyKind({}, 'KEREN HATZEDAKA', -200), 'refund');
  // Ordinary merchants are untouched.
  assert.equal(classifyKind({}, 'AMAZON MARKEPLACE NA PA', 1059), 'charge');
  assert.equal(classifyKind({}, 'KLEINS GROCERY', 999), 'charge');
});

test('P1-NEW1: all four canonical.ts copies stay byte-identical', () => {
  const base = readFileSync(new URL('../supabase/functions/_shared/canonical.ts', import.meta.url), 'utf8');
  for (const f of ['plaid-sync', 'ingest-amex-alert', 'gmail-poll']) {
    assert.equal(readFileSync(new URL(`../supabase/functions/${f}/canonical.ts`, import.meta.url), 'utf8'), base, `${f}/canonical.ts drifted`);
  }
  assert.match(base, /CHARITY_PATTERN/);
  assert.match(base, /'charity'/);
});

test('P1-NEW1: CSV classifier matches the server charity rule', () => {
  assert.equal(classifyCsvKind('KEREN HATZEDAKA', 200), 'charity');
  assert.equal(classifyCsvKind('TOIREMORG CHARITY', 200), 'charity');
  assert.equal(classifyCsvKind('KEREN HATZEDAKA', -200), 'refund');
  assert.equal(classifyCsvKind('AMAZON', 1059), 'charge');
});

test('P1-NEW1: Charity is offered on any charge; disabled copy is honest', () => {
  assert.deepEqual(actionsForTxKind('charge', true, false).slice(0, 1), ['charity']);
  assert.deepEqual(actionsForTxKind('charge', false, true).slice(0, 1), ['charity']);
  // The sheet renders the disabled states with honest copy.
  assert.match(liveJs, /Available once this posts/);
  assert.match(liveJs, /Ask the admin to mark this as a gift/);
  assert.match(liveJs, /tx-action-row" data-tx-action="\$\{a\.id\}" type="button"\$\{a\.disabled \? ' disabled' : ''\}/);
  assert.match(stylesCss, /\.tx-action-row\[disabled\]/);
});

test('P1-NEW1: reclassify offers Charity and dispatches to the guarded mark path', () => {
  assert.match(liveJs, /\{ value: 'charity', label: 'Charity' \}/);
  assert.match(liveJs, /if \(newKind === 'charity'\) \{ await doTxCharity\(row\); return; \}/);
  const kindSql = sql('refund-classification-income-kind.sql');
  assert.match(kindSql, /not in \('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'transfer', 'income', 'charity'\)/);
  assert.match(kindSql, /ADMIN OVERRIDE/);
});

test('P1-NEW1: a charity row counts $0 toward week math', () => {
  assert.equal(chargeContribution({ kind: 'charity', amount_cents: 200, state: 'verified' }), 0);
  assert.equal(chargeContribution({ kind: 'charge', amount_cents: 200, state: 'verified' }), 200);
});
