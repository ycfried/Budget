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

// ---- P1-M2: locked-week mutation guard ----

test('P1-M2: exclude and reclassify raise on locked weeks (same 35-day rule as mark-as-charity)', () => {
  const n4 = readFileSync(new URL('../supabase/n4-pre-exclusion-state.sql', import.meta.url), 'utf8');
  const rcl = readFileSync(new URL('../supabase/refund-classification-income-kind.sql', import.meta.url), 'utf8');
  for (const [name, src] of [['exclude', n4], ['reclassify', rcl]]) {
    assert.match(src, /v_cur_week > v_tx_week \+ 35/, `${name} has the 35-day lock check`);
    assert.match(src, /raise exception 'week is locked: a locked-week transaction cannot be changed here'/, `${name} raises on locked weeks`);
  }
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /\/locked\/i\.test\(error\.message \|\| ''\) \? error\.message : 'Could not reclassify this transaction\. Try again\.'/);
  assert.match(live, /\/locked\/i\.test\(error\.message \|\| ''\) \? error\.message : 'Could not delete this transaction\. Try again\.'/);
});

// ---- P1-M3: canonical merged restore_transaction ----

test('P1-M3: restore is the merged version — snapshot + reversed + refund check, no phantom columns', () => {
  const n4 = readFileSync(new URL('../supabase/n4-pre-exclusion-state.sql', import.meta.url), 'utf8');
  assert.match(n4, /if v_row\.state <> 'excluded' and v_row\.state <> 'reversed' then/);
  assert.match(n4, /if v_row\.pre_exclusion_state is null then\n    raise exception 'cannot restore: no prior state recorded'/);
  assert.match(n4, /if v_row\.kind = 'refund' and v_row\.original_purchase_id is not null then/);
  assert.match(n4, /raise exception 'cannot restore refund: original transaction is missing'/);
  assert.match(n4, /v_state := v_row\.pre_exclusion_state;/);
  // The investigation doc's verbatim SQL referenced columns that do
  // not exist in the schema — the canonical file's executable body
  // must not (comments may name them to explain the correction).
  const code = n4.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
  for (const col of ['refund_of_transaction_id', 'source_transaction_id', 'excluded_at', 'excluded_by', 'excluded_reason', 'exclusion_note']) {
    assert.doesNotMatch(code, new RegExp(col), `no phantom column ${col}`);
  }
  assert.match(n4, /CANONICAL FILE for exclude_transaction \+ restore_transaction/);
});

// ---- P1-B1: approve_and_allocate canonical version ----

test('P1-B1: approve-ambiguity-fix.sql is the canonical strong version; the other two are bannered never-reapply', () => {
  const canon = readFileSync(new URL('../supabase/approve-ambiguity-fix.sql', import.meta.url), 'utf8');
  assert.match(canon, /CANONICAL DEFINITION of approve_and_allocate/);
  assert.match(canon, /for update/);
  assert.match(canon, /amount exceeds requested amount/);
  assert.match(canon, /remainder_cents/);
  assert.match(canon, /fund_allocation_cents \+ p_amount_cents/);
  assert.match(canon, /create or replace function public\.approve_and_allocate\(p_request_id uuid, p_amount_cents integer, p_override_reason text\)/);
  const fl = readFileSync(new URL('../supabase/fund-ledger.sql', import.meta.url), 'utf8');
  assert.match(fl, /DO NOT RE-APPLY THE approve_and_allocate DEFINITION BELOW/);
  const s04 = readFileSync(new URL('../supabase/04-admin-rpcs.sql', import.meta.url), 'utf8');
  assert.match(s04, /DO NOT RE-APPLY THIS SECTION \(P1-B1/);
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /supabase\.rpc\('approve_and_allocate', \{ p_request_id: b\.dataset\.approve, p_amount_cents: cents, p_override_reason: null \}\)/);
});

// ---- P1-B2: webhook_events household_id ----

test('P1-B2: webhook_events policy is a direct household check; log_webhook_event stamps household_id', () => {
  const mig = readFileSync(new URL('../supabase/webhook-events-household-id.sql', import.meta.url), 'utf8');
  assert.match(mig, /add column if not exists household_id uuid references households\(id\) on delete cascade/);
  assert.match(mig, /update webhook_events w\n  set household_id = p\.household_id\n  from plaid_items p/);
  assert.match(mig, /using \(household_id in \(select household_id from household_members/);
  assert.doesNotMatch(mig.split('VERIFICATION')[0], /plaid_item_id in \(select plaid_item_id from plaid_items/);
  assert.match(mig, /insert into webhook_events \(plaid_item_id, webhook_code, dedupe_hash, household_id\)/);
  const canon = readFileSync(new URL('../supabase/webhook-events.sql', import.meta.url), 'utf8');
  assert.match(canon, /household_id uuid references households\(id\) on delete cascade/);
  assert.match(canon, /using \(household_id in \(select household_id from household_members/);
  // The client read needs no change — it filters by plaid_item_id,
  // which still works once the policy returns rows.
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /supabase\.from\('webhook_events'\)/);
});
