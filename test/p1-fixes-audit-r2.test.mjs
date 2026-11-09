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
  // (a) Open week: cap arithmetic only — the $4,603.33 input is the
  // Nov 1–7 NET spent C (R2 §1; gross charges $4,762.30, Nordstrom
  // $158.97 already netted), used here as the charges figure for the
  // cap example. Live C stays $4,603.33; this case double-nets it
  // only as an arithmetic example, not as a live claim (P2-B19).
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

// ---- P1-B3: no raw server/DB errors reach clients ----

test('P1-B3: every 500 body is a generic string; the detail goes to console.error only', () => {
  const expected = {
    'compute-week': ['could not compute week'],
    'week-close': ['restoration failed partway', 'could not close week'],
    'plaid-exchange': ['could not store plaid item', 'could not complete bank connection'],
    'plaid-sync': ['bank sync failed'],
    'gmail-poll': ['email check failed'],
    'ingest-amex-alert': ['could not save email alert'],
    'plaid-disconnect': ['could not disconnect bank'],
    'plaid-account-disconnect': ['could not disconnect account'],
    'gmail-oauth-start': ['could not start email connection'],
    'gmail-disconnect': ['could not disconnect email'],
    'plaid-link': ['could not create bank link'],
    'plaid-webhook-register': ['request failed', 'could not update automatic sync'],
  };
  for (const [fn, messages] of Object.entries(expected)) {
    const src = readFileSync(new URL(`../supabase/functions/${fn}/index.ts`, import.meta.url), 'utf8');
    assert.doesNotMatch(src, /error: String\(/, `${fn} leaks no raw exception text`);
    assert.doesNotMatch(src, /error: `[^`]*\$\{[^}]*message[^}]*\}/, `${fn} interpolates no error detail`);
    for (const m of messages) assert.ok(src.includes(`error: '${m}'`), `${fn} returns generic '${m}'`);
    assert.match(src, /console\.error\(/, `${fn} logs the detail server-side`);
  }
});

// ---- P1-B4: held-release atomicity ----

test('P1-B4: canonical resolve_held_refund locks the held row and the households row; old body is bannered', () => {
  const canon = readFileSync(new URL('../supabase/merged-audit-held-release-atomic.sql', import.meta.url), 'utf8');
  assert.match(canon, /CANONICAL DEFINITION of resolve_held_refund/);
  assert.match(canon, /select \* into v_row from held_refunds where id = p_held_id for update;/);
  assert.match(canon, /select fund_shortfall_cents into v_shortfall from households where id = v_row\.household_id for update;/);
  assert.match(canon, /where id = p_held_id and status = 'pending';/);
  assert.match(canon, /raise exception 'held refund already resolved'/);
  const old = readFileSync(new URL('../supabase/restoration-snapshots.sql', import.meta.url), 'utf8');
  assert.match(old, /DO NOT RE-APPLY THE DEFINITION BELOW \(P1-B4/);
});

// ---- P1-B6: fund-request kind guard ----

test('P1-B6: guard requires a linked charge; client gates the same way and surfaces a refusal', () => {
  const guard = readFileSync(new URL('../supabase/merged-audit-fund-request-kind-guard.sql', import.meta.url), 'utf8');
  assert.match(guard, /CANONICAL DEFINITION of validate_fund_request_txn\(\)/);
  assert.match(guard, /if v_kind is distinct from 'charge' then\n        raise exception 'fund request transaction must be a charge';/);
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /if \(row\.kind !== 'charge'\) \{ await showAlert\('Does not qualify', 'Only a charge can be covered by the Extra Fund\./);
  assert.match(live, /\/must be a charge\|different household\/i\.test\(error\.message \|\| ''\) \? error\.message : 'Could not send this request\. Try again\.'/);
});

// ---- P1-B7: delete-account FK gaps + revocation + compensating path ----

test('P1-B7: FK migration covers weekly_allowance_overrides.created_by as SET NULL', () => {
  const mig = readFileSync(new URL('../supabase/delete-account-fk-migration.sql', import.meta.url), 'utf8');
  assert.match(mig, /alter table weekly_allowance_overrides alter column created_by drop not null;/);
  assert.match(mig, /weekly_allowance_overrides_created_by_fkey foreign key \(created_by\) references auth\.users\(id\) on delete set null/);
  assert.match(mig, /'weekly_allowance_overrides'\)/);
});

test('P1-B7: delete-account revokes Plaid + Gmail for emptied households and revokes the invite code on orphan', () => {
  const src = readFileSync(new URL('../supabase/functions/delete-account/index.ts', import.meta.url), 'utf8');
  assert.match(src, /async function revokeHouseholdConnections\(admin: any, householdId: string\)/);
  assert.match(src, /plaid\.com\/item\/remove/);
  assert.match(src, /oauth2\.googleapis\.com\/revoke/);
  assert.match(src, /await revokeHouseholdConnections\(admin, hid\);/);
  // Compensating path: retry, then invite-code revoke on orphan.
  assert.match(src, /\.update\(\{ invite_code: null \}\)\.eq\('id', hid\)/);
  assert.match(src, /household orphaned, invite code revoked/);
  // Revocation never blocks deletion: the helper swallows its own errors.
  assert.match(src, /Revocation failures never block deletion/);
});

// ---- P1-B8: vault RPC grants (escalation check) ----

test('P1-B8: 07 is the canonical service-role-only vault state; plaid-token-column.sql is bannered never-reapply', () => {
  const s07 = readFileSync(new URL('../supabase/07-service-rpc-access.sql', import.meta.url), 'utf8');
  // get_plaid_ciphertext: service_role only, membership branch deleted.
  assert.match(s07, /if auth\.role\(\) <> 'service_role' then raise exception 'service role only'; end if;/);
  assert.doesNotMatch(s07, /get_plaid_ciphertext[\s\S]{0,800}not a household member/);
  assert.match(s07, /grant execute on function public\.get_plaid_ciphertext\(uuid, text\) to service_role;/);
  assert.match(s07, /grant execute on function public\.update_plaid_sync\(uuid, text, text\) to service_role;/);
  assert.match(s07, /revoke execute on function public\.log_webhook_event\(text, text, text\) from authenticated;/);
  assert.match(s07, /grant execute on function public\.log_webhook_event\(text, text, text\) to service_role;/);
  // update_plaid_sync keeps a membership branch in the body, but it
  // is unreachable while the grants are service_role-only.
  assert.match(s07, /grant execute on function public\.update_plaid_sync\(uuid, text, text\) to service_role;/);
  const ptc = readFileSync(new URL('../supabase/plaid-token-column.sql', import.meta.url), 'utf8');
  assert.match(ptc, /DO NOT RE-APPLY THIS FILE \(P1-B8/);
  assert.match(ptc, /CANONICAL vault state is\n-- supabase\/07-service-rpc-access\.sql/);
  // B2 correction: log_webhook_event must be service_role-only in
  // both webhook files — the plaid-webhook function uses the service
  // key, and an anon/authenticated grant would let any client record
  // fake webhook events.
  for (const f of ['webhook-events.sql', 'webhook-events-household-id.sql']) {
    const src = readFileSync(new URL(`../supabase/${f}`, import.meta.url), 'utf8');
    assert.match(src, /grant execute on function log_webhook_event\(text, text, text\) to service_role;/);
    assert.doesNotMatch(src, /grant execute on function log_webhook_event\(text, text, text\) to anon, authenticated;/);
  }
});

// ---- P1-B5/B9: one canonical kind constraint; footgun files bannered ----

test('P1-B5/B9: refund-classification file is the canonical 8-kind constraint; superseded kind lists are bannered', () => {
  const canon = readFileSync(new URL('../supabase/refund-classification-income-kind.sql', import.meta.url), 'utf8');
  assert.match(canon, /CANONICAL KIND CONSTRAINT \(P1-B5/);
  assert.match(canon, /check \(kind in \('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income'\)\)/);
  const merged = readFileSync(new URL('../supabase/merged-audit-kind-constraint.sql', import.meta.url), 'utf8');
  assert.match(merged, /SUPERSEDED — DO NOT APPLY \(P1-B5/);
  assert.match(merged, /THE CANONICAL KIND CONSTRAINT IS\n-- supabase\/refund-classification-income-kind\.sql/);
  const schema = readFileSync(new URL('../supabase/schema.sql', import.meta.url), 'utf8');
  assert.match(schema, /kind text not null check \(kind in \('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income'\)\)/);
});

test('P1-B9: every footgun file carries a never-reapply banner; the member-UPDATE revoke is prepared', () => {
  const checks = [
    ['fix-transactions-upsert.sql', /DO NOT RE-APPLY THIS FILE \(P1-B9/],
    ['fix-grants.sql', /DO NOT RE-GRANT member SELECT on plaid_items \(P1-B9/],
    ['fix-plaid-grants.sql', /DO NOT RE-APPLY THIS FILE \(P1-B9/],
    ['n13-invite-rate-limit.sql', /DO NOT RE-APPLY THIS FILE \(P1-B9/],
    ['05-transaction-mutation-rpcs.sql', /SUPERSEDED — DO NOT APPLY IN FULL \(P1-B9/],
    ['04-admin-rpcs.sql', /DO NOT APPLY IN FULL \(P1-B9/],
  ];
  for (const [f, re] of checks) {
    const src = readFileSync(new URL(`../supabase/${f}`, import.meta.url), 'utf8');
    assert.match(src, re, `${f} is bannered`);
  }
  // The grant itself is commented out of fix-grants.sql (not re-grantable by applying it).
  const fg = readFileSync(new URL('../supabase/fix-grants.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(fg.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n'), /grant select on plaid_items to authenticated;/);
  const revoke = readFileSync(new URL('../supabase/revoke-member-transaction-update.sql', import.meta.url), 'utf8');
  assert.match(revoke, /revoke update on transactions from authenticated;/);
  assert.match(revoke, /drop policy if exists "members update own transactions" on transactions;/);
});

// ---- P1-C1: cursor persist checked; Nov 1 floor on the list ----

test('P1-C1: plaid-sync checks the cursor persist and names failed institutions; the list is floored at Nov 1', () => {
  const ps = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');
  assert.match(ps, /const \{ error: cursorErr \} = await supabaseAdmin\.rpc\('update_plaid_sync'/);
  assert.match(ps, /cursor persist failed for item/);
  assert.match(ps, /failedInstitutions\.push\(item\.institution_name \?\? item\.plaid_item_id\);/);
  assert.match(ps, /failed_institutions: failedInstitutions/);
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /\.gte\('date', '2026-11-01'\)/);
  assert.match(live, /failedNames\.length \? ` — \$\{failedNames\.join\(', '\)\}` : ''/);
});

// ---- P1-C2: duplicate guard at connect ----

test('P1-C2: plaid-exchange checks for duplicates before returning connected, and the client reports them', () => {
  const pe = readFileSync(new URL('../supabase/functions/plaid-exchange/index.ts', import.meta.url), 'utf8');
  assert.match(pe, /async function checkDuplicateAtConnect\(/);
  assert.match(pe, /const dup = await checkDuplicateAtConnect\(supabaseAdmin, householdId, data\.item_id, body\.institution_name \?\? null, data\.access_token, clientId, secret, env\);/);
  assert.match(pe, /if \(dup\) return json\(\{ item_id: data\.item_id, connected: false, duplicate: true, duplicate_of: dup \}\);/);
  // Same rule as plaid-sync: every candidate account covered by an
  // older keeper at the same institution (mask + name).
  assert.match(pe, /normDup\(keeper\.institution_name\) !== normDup\(institutionName\)/);
  assert.match(pe, /normDup\(k\.mask\) === normDup\(acct\.mask\) && normDup\(k\.name\) === normDup\(acct\.name\)/);
  // Fail open: any check failure keeps the connection.
  assert.match(pe, /duplicate check failed open/);
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /ex\.duplicate\n          \? 'This bank is already connected — the duplicate connection was removed\. Past transactions stay\.'/);
});

// ---- P1-C4: load failures name the kind; callFn is status-aware ----

test('P1-C4: a dead session says "Sign in again"; other failures offer a retry; callFn surfaces status', () => {
  const live = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
  assert.match(live, /txReadErrorKind = \(!readSession \|\| \/jwt expired\|invalid jwt\|unauthorized\|PGRST301\/i\.test/);
  assert.match(live, /Your sign-in expired — sign in again to see transactions\. <button class="btn btn-small" data-tx-signin-again/);
  assert.match(live, /Could not load transactions — the server did not answer\. Nothing here is a complete list\. <button class="btn btn-small" data-tx-retry-load/);
  assert.match(live, /\$\('signOutBtn'\)\?\.click\(\)/);
  assert.match(live, /data-tx-retry-load.*refresh\(\)/s);
  assert.match(live, /if \(!res\.ok\) return \{ \.\.\.data, error: data\.error \?\? `request failed \(\$\{res\.status\}\)`, status: res\.status \};/);
  assert.match(live, /return \{ error: 'network error — check your connection', status: 0 \};/);
});

// ---- P1-C6: webhook dedupe includes the JWT iat ----

test('P1-C6: the webhook dedupe hash includes payload.iat so same-count events never collide', () => {
  const src = readFileSync(new URL('../supabase/functions/plaid-webhook/index.ts', import.meta.url), 'utf8');
  assert.match(src, /const dedupe = await sha256Hex\(`\$\{body\.item_id\}\|\$\{code\}\|\$\{body\.new_transactions \?\? ''\}\|\$\{payload\.iat\}`\);/);
  assert.doesNotMatch(src, /sha256Hex\(`\$\{body\.item_id\}\|\$\{code\}\|\$\{body\.new_transactions \?\? ''\}`\)/);
});
