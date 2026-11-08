// P1 fixes from the Nov 8, 2026 re-audit (FULL_AUDIT_2026-11-08_R2.md).
// Branch-only tests; live SQL/RPC behaviour is verified by the
// parent's live probes, not by these node tests (Deno functions
// never execute under node --test).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { classifyKind, classifyMerchantOnly } from '../supabase/functions/_shared/canonical.ts';
import { actionsForTxKind, classifyCsvKind, emailConnectionWarnings } from '../filterState.mjs';
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

// ---- P1-R2: Gmail Testing-mode token expiry ----

test('P1-R2: emailConnectionWarnings flags expiring grants and stale checks', () => {
  const now = Date.parse('2026-11-08T12:00:00Z');
  const day = 24 * 3600 * 1000;
  assert.deepEqual(emailConnectionWarnings({ status: 'active', connected_at: '2026-11-02T12:00:00Z', last_poll_at: '2026-11-08T11:00:00Z' }, now), ['expiring']);
  assert.deepEqual(emailConnectionWarnings({ status: 'active', connected_at: '2026-11-06T12:00:00Z', last_poll_at: '2026-11-08T10:00:00Z' }, now), []);
  assert.deepEqual(emailConnectionWarnings({ status: 'active', connected_at: '2026-11-06T12:00:00Z', last_poll_at: '2026-11-06T12:00:00Z' }, now), ['stale']);
  assert.deepEqual(emailConnectionWarnings({ status: 'active', connected_at: '2026-11-01T12:00:00Z', last_poll_at: '2026-11-06T12:00:00Z' }, now), ['expiring', 'stale']);
  // status='error' already shows "Needs reconnect" — no extra lines.
  assert.deepEqual(emailConnectionWarnings({ status: 'error', connected_at: '2026-11-01T12:00:00Z', last_poll_at: '2026-11-06T12:00:00Z' }, now), []);
  // created_at fallback when connected_at is missing (pre-migration rows).
  assert.deepEqual(emailConnectionWarnings({ status: 'active', created_at: '2026-11-02T12:00:00Z', last_poll_at: '2026-11-08T11:00:00Z' }, now), ['expiring']);
});

test('P1-R2: client reads the grant clock, warns before expiry, surfaces poll errors', () => {
  assert.match(liveJs, /select\('id, provider, email_address, status, last_poll_at, last_error, created_at, connected_at'\)/);
  assert.match(liveJs, /Email access expires about 7 days after connecting — reconnect soon to keep alerts coming\./);
  assert.match(liveJs, /Not checked since /);
  assert.match(liveJs, /const firstErr = Array\.isArray\(out\.errors\) && out\.errors\.length \? out\.errors\[0\] : null;/);
  assert.match(liveJs, /access expired — reconnect your email\./);
  const cb = readFileSync(new URL('../supabase/functions/gmail-oauth-callback/index.ts', import.meta.url), 'utf8');
  assert.match(cb, /connected_at: new Date\(\)\.toISOString\(\)/);
  const mig = readFileSync(new URL('../supabase/gmail-connected-at.sql', import.meta.url), 'utf8');
  assert.match(mig, /add column if not exists connected_at timestamptz/);
  assert.match(mig, /set connected_at = created_at/);
  assert.match(mig, /connected_at\n  from public\.email_connections/);
});

// ---- P1-F1/F2/F3: small-screen overflow + fund-request first load ----

test('P1-F1: bank buttons keep the no-wrap row above 360px and stack below it', () => {
  assert.match(stylesCss, /#section-bank \.btn-row \{ flex-wrap: nowrap; \}/);
  assert.match(stylesCss, /@media \(max-width: 360px\) \{\n  body\.live #section-bank \.btn-row \{ flex-wrap: wrap; \}\n  body\.live #section-bank \.btn-row \.btn \{ flex: 1 1 100%; \}\n\}/);
});

test('P1-F2: Transactions heading row wraps instead of overflowing at 320px', () => {
  assert.match(stylesCss, /\.tx-head-row \{ display: flex; justify-content: space-between; align-items: center; gap: 10px; flex-wrap: wrap; \}/);
});

test('P1-F3: fund-request detail fills "Fund available now" lazily at tap time', () => {
  assert.match(liveJs, /<span data-fund-available-now>/);
  assert.match(liveJs, /det\.querySelectorAll\('\[data-fund-available-now\]'\)\.forEach\(\(s\) => \{ s\.textContent = currentFundData \? formatCents\(currentFundData\.available\) : 'not loaded'; \}\)/);
  assert.doesNotMatch(liveJs, /Fund available now: \$\{currentFundData \? formatCents\(currentFundData\.available\) : 'not loaded'\}/);
});

// ---- P1-M1: compute-week vs week-close agree on unlinked refunds ----

test('P1-M1: both functions net unlinked refunds only in open weeks, never locked', () => {
  const cw = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
  const wc = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
  // compute-week: the created_at guard is gone; the lock gates netting.
  assert.doesNotMatch(cw, /t\.created_at > thisClose\.created_at/);
  assert.match(cw, /const unlinkedNetted = weekLocked \? 0 : Math\.min\(unlinkedRefundAbs, Math\.max\(0, chargesNet\)\);/);
  // week-close: unlinkedPostedInWeek returns 0 for locked weeks.
  assert.match(wc, /const unlinkedPostedInWeek = \(ws: string\) => \{\n      if \(isWeekLocked\(ws, currentWeekStart\)\) return 0;/);
  assert.match(wc, /if \(isWeekLocked\(ws, currentWeekStart\)\) return unlinkedAbsInWeek\(ws\);/);
});

// The agreed rule, mirrored in plain JS (the Deno functions never
// execute under node --test): open week nets up to charges, locked
// week nets nothing and exposes the whole amount as excess.
function m1Net(chargesNet, unlinkedAbs, weekLocked) {
  const netted = weekLocked ? 0 : Math.min(unlinkedAbs, Math.max(0, chargesNet));
  return { c: chargesNet - netted, excess: unlinkedAbs - netted };
}

test('P1-M1: (a) open week with a post-close unlinked refund nets it; (b) locked week does not', () => {
  // (a) Open week, charges $4,603.33, post-close unlinked refund $158.97 → nets.
  assert.deepEqual(m1Net(460333, 15897, false), { c: 444436, excess: 0 });
  // (b) Same week once locked → refund nets $0, full amount is excess.
  assert.deepEqual(m1Net(460333, 15897, true), { c: 460333, excess: 15897 });
  // Cap still holds in an open week: refund bigger than charges.
  assert.deepEqual(m1Net(10000, 700000, false), { c: 0, excess: 690000 });
});
