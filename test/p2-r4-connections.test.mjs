// Connections P2 fixes from the Nov 9, 2026 fourth re-audit
// (FULL_AUDIT_2026-11-09_R4.md §6) — NEW-R4-C1..C4, branch
// p2-r4-connections. The suite runs under node --test and never
// executes Deno Edge Functions, so function-side fixes are asserted
// with source markers plus pure-JS mirrors of the fixed logic (same
// class as the existing audit tests), and the client helpers are
// imported from filterState.mjs and executed directly.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  skipReasonsText,
  bankSyncToast,
  emailCheckMessage,
  adminHouseholdOptions,
} from '../filterState.mjs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const liveJs = read('../live.js');
const plaidSync = read('../supabase/functions/plaid-sync/index.ts');
const gmailPoll = read('../supabase/functions/gmail-poll/index.ts');
const ingest = read('../supabase/functions/ingest-amex-alert/index.ts');

// --- NEW-R4-C3: plaid-sync staleness is the stalest gap -------------------
// Mirror of the fixed computation: per-item gaps in minutes since
// last_sync_at, reported value is the MAX gap (stalest item); null
// stamps contribute no gap; no gaps at all reports null.
const stalestGapMinutes = (lastSyncAts, nowMs) => {
  const gaps = (lastSyncAts ?? [])
    .map((iso) => {
      if (!iso) return null;
      const t = new Date(iso).getTime();
      if (!Number.isFinite(t)) return null;
      return Math.max(0, Math.floor((nowMs - t) / 60000));
    })
    .filter((n) => n !== null);
  return gaps.length ? Math.max(...gaps) : null;
};
const isStaleSync = (minutes) => minutes !== null && minutes > 180;

test('NEW-R4-C3: stalest-gap mirror — one dead item flags stale despite a healthy one', () => {
  const now = Date.parse('2026-11-09T12:00:00Z');
  assert.equal(stalestGapMinutes(['2026-11-09T11:50:00Z', '2026-11-09T06:00:00Z'], now), 360);
  assert.equal(isStaleSync(stalestGapMinutes(['2026-11-09T11:50:00Z', '2026-11-09T06:00:00Z'], now)), true);
  assert.equal(stalestGapMinutes(['2026-11-09T11:50:00Z', '2026-11-09T11:00:00Z'], now), 60);
  assert.equal(isStaleSync(stalestGapMinutes(['2026-11-09T11:50:00Z', '2026-11-09T11:00:00Z'], now)), false);
  assert.equal(stalestGapMinutes([null, null], now), null, 'never-synced items contribute no gap');
  assert.equal(stalestGapMinutes(['2026-11-09T11:50:00Z', null], now), 10, 'a null stamp never masks a real gap');
  assert.equal(stalestGapMinutes([], now), null);
  assert.equal(isStaleSync(null), false, 'null never flags stale');
  assert.equal(isStaleSync(180), false, 'exactly 180 is not stale');
  assert.equal(isStaleSync(181), true);
});

test('NEW-R4-C3: plaid-sync reports the max per-item gap over active items only', () => {
  assert.ok(plaidSync.includes('Math.max(...prevGaps)'), 'reports the max gap, not the freshest stamp');
  assert.ok(!plaidSync.includes('Math.max(...prevSyncTimes)'), 'old freshest-stamp computation is gone');
  assert.ok(!plaidSync.includes('prevSyncTimes'), 'old prevSyncTimes variable is gone');
  assert.ok(plaidSync.includes('activeItems'), 'gap is computed over active items');
  assert.ok(plaidSync.includes('minutesSincePreviousSync > 180'), '180-minute threshold unchanged');
  assert.ok(plaidSync.includes('minutes_since_previous_sync: minutesSincePreviousSync'), 'response field name unchanged');
  // The 502 failure path still carries the staleness fields.
  assert.ok(plaidSync.includes('minutes_since_previous_sync: minutesSincePreviousSync, stale'), 'failure path still reports staleness');
});

test('NEW-R4-C3: gmail-poll already reports the max gap (no change owed there)', () => {
  assert.ok(gmailPoll.includes('Math.max(...prevGaps)'), 'gmail-poll takes the max gap');
  assert.ok(gmailPoll.includes('minutes_since_previous_poll: minutesSincePreviousPoll, stale'));
});

// --- NEW-R4-C1: client reads the API staleness/skip fields -----------------
test('NEW-R4-C1: skipReasonsText formats the per-reason breakdown, most-skipped first', () => {
  assert.equal(skipReasonsText({ 'account-disconnected': 3, 'invalid-amount': 1 }), 'account disconnected ×3, invalid amount ×1');
  assert.equal(skipReasonsText({ 'missing-token': 2 }), 'missing token ×2');
  assert.equal(skipReasonsText({ 'invalid-date': 0, 'insert-failed': 1 }), 'insert failed ×1', 'zero counts are dropped');
  assert.equal(skipReasonsText({}), '');
  assert.equal(skipReasonsText(null), '');
  assert.equal(skipReasonsText(undefined), '');
  assert.equal(skipReasonsText('not-an-object'), '');
});

test('NEW-R4-C1: bankSyncToast keeps the old success text when the API fields are absent', () => {
  const { text, isError } = bankSyncToast({ added: 2, updated: 1, skipped: 0, items: 1 });
  assert.equal(text, 'Sync done: 2 added, 1 updated, 0 skipped across 1 connected account(s).');
  assert.equal(isError, false);
  const dup = bankSyncToast({ added: 0, updated: 0, skipped: 0, items: 2, duplicate_removed: ['item-1'] });
  assert.ok(dup.text.includes('A duplicate bank connection was removed'), 'duplicate-removal sentence unchanged');
  assert.ok(!dup.text.includes("hadn't run in a while"), 'no stale sentence without the API flag');
});

test('NEW-R4-C1: bankSyncToast surfaces the API stale flag and skip reasons', () => {
  const { text, isError } = bankSyncToast({
    added: 1, updated: 0, skipped: 4, items: 2,
    stale: true, minutes_since_previous_sync: 360,
    skipped_by_reason: { 'account-disconnected': 3, 'invalid-amount': 1 },
  });
  assert.equal(isError, false);
  assert.ok(text.includes("Scheduled sync hadn't run in a while before this sync (360 minutes since the last one)."), 'stale sentence with the API gap');
  assert.ok(text.includes('Skipped: account disconnected ×3, invalid amount ×1.'), 'per-reason breakdown');
  const noMins = bankSyncToast({ added: 0, updated: 0, skipped: 0, items: 1, stale: true });
  assert.ok(noMins.text.includes("Scheduled sync hadn't run in a while before this sync."), 'stale sentence without a gap still reads clean');
  assert.ok(!noMins.text.includes('null'), 'no null minutes leak into the toast');
  const fresh = bankSyncToast({ added: 0, updated: 0, skipped: 0, items: 1, stale: false, minutes_since_previous_sync: 12 });
  assert.ok(!fresh.text.includes("hadn't run in a while"), 'stale:false adds no sentence');
  const emptyReasons = bankSyncToast({ added: 0, updated: 0, skipped: 0, items: 1, skipped_by_reason: {} });
  assert.ok(!emptyReasons.text.includes('Skipped:'), 'empty breakdown adds nothing');
});

test('NEW-R4-C1: bankSyncToast failure path still names the failed institutions', () => {
  const { text, isError } = bankSyncToast({ error: 'plaid sync failed', failed_institutions: ['Amex', 'Chase'], stale: true });
  assert.equal(isError, true);
  assert.ok(text.startsWith('Sync failed: plaid sync failed — Amex, Chase'));
  const bare = bankSyncToast({ error: 'bank sync failed' });
  assert.equal(bare.text, 'Sync failed: bank sync failed');
});

test('NEW-R4-C1: emailCheckMessage keeps the old text, adds the API stale sentence', () => {
  const ok = emailCheckMessage({ stored: 1, duplicates: 2, quarantined: 0, unparseable: 0 });
  assert.equal(ok.text, 'Email checked: 1 added, 2 already known, 0 quarantined, 0 could not be read.');
  assert.equal(ok.isError, false);
  const stale = emailCheckMessage({ stored: 0, duplicates: 0, quarantined: 0, unparseable: 0, stale: true, minutes_since_previous_poll: 95 });
  assert.ok(stale.text.includes("Email hadn't been checked in a while before this check (95 minutes since the last one)."));
  const staleNoMins = emailCheckMessage({ stored: 0, duplicates: 0, quarantined: 0, unparseable: 0, stale: true });
  assert.ok(staleNoMins.text.includes("Email hadn't been checked in a while before this check."));
  assert.ok(!staleNoMins.text.includes('null'));
  const fresh = emailCheckMessage({ stored: 0, duplicates: 0, quarantined: 0, unparseable: 0, stale: false });
  assert.ok(!fresh.text.includes("hadn't been checked in a while"));
  const reauth = emailCheckMessage({ errors: [{ connection_id: 'c1', error: 'reauthorization required' }] });
  assert.equal(reauth.text, 'Email check failed: access expired — reconnect your email.');
  assert.equal(reauth.isError, true);
  const topErr = emailCheckMessage({ error: 'email check failed' });
  assert.equal(topErr.text, 'Email check failed: email check failed');
});

test('NEW-R4-C1: live.js wires the sync/poll handlers to the API-field builders', () => {
  assert.ok(liveJs.includes('const { text, isError } = bankSyncToast(out);'), 'runBankSync uses bankSyncToast');
  assert.ok(liveJs.includes('const { text, isError } = emailCheckMessage(out);'), 'poll handler uses emailCheckMessage');
  assert.ok(liveJs.includes("bankSyncToast, emailCheckMessage, adminHouseholdOptions } from './filterState.mjs'"), 'helpers are imported');
  // The old inline builders are gone — the toast/message can only come from the helpers now.
  assert.ok(!liveJs.includes('`Sync done: ${out.added'), 'old inline sync toast is gone');
  assert.ok(!liveJs.includes('`Email checked: ${out.stored'), 'old inline email message is gone');
  assert.ok(!liveJs.includes('const firstErr = Array.isArray(out.errors)'), 'old inline first-error read is gone');
});

// --- NEW-R4-C2: multi-household OAuth 409 has a client path forward --------
test('NEW-R4-C2: adminHouseholdOptions puts the current household first, names fall back', () => {
  const memberships = [{ household_id: 'h1' }, { household_id: 'h2' }, { household_id: 'h3' }];
  const households = [{ id: 'h1', name: 'Home' }, { id: 'h2', name: '  ' }, { id: 'h3', name: 'Shul' }];
  assert.deepEqual(adminHouseholdOptions(memberships, households, 'h2'), [
    { value: 'h2', label: 'Household' },
    { value: 'h1', label: 'Home' },
    { value: 'h3', label: 'Shul' },
  ]);
  assert.deepEqual(adminHouseholdOptions(memberships, households, null), [
    { value: 'h1', label: 'Home' },
    { value: 'h2', label: 'Household' },
    { value: 'h3', label: 'Shul' },
  ]);
  assert.deepEqual(adminHouseholdOptions([{ household_id: 'h1' }, { household_id: 'h1' }], [], null),
    [{ value: 'h1', label: 'Household' }], 'duplicate membership rows collapse');
  assert.deepEqual(adminHouseholdOptions([], [], null), []);
  assert.deepEqual(adminHouseholdOptions(null, null, null), []);
  assert.deepEqual(adminHouseholdOptions([{ household_id: 'h9' }], [{ id: 'h9', name: null }], null),
    [{ value: 'h9', label: 'Household' }], 'null name falls back');
});

test('NEW-R4-C2: live.js offers a household choice on 409 and retries with household_id', () => {
  assert.ok(liveJs.includes('if (out.status === 409)'), 'connect handler checks for the 409');
  assert.ok(liveJs.includes('async function pickAdminHousehold()'), 'picker helper exists');
  assert.ok(liveJs.includes('const picked = await pickAdminHousehold();'), '409 path calls the picker');
  assert.ok(liveJs.includes("out = await callFn('gmail-oauth-start', { household_id: picked });"), 'picker choice is retried with household_id');
  assert.ok(liveJs.includes("inputOptions: options,"), 'picker renders the households as a sheet select');
  assert.ok(liveJs.includes("title: 'Choose Household'"), 'picker sheet names the choice');
  assert.ok(liveJs.includes(".eq('role', 'admin')"), 'picker reads only the caller\'s own admin memberships');
  assert.ok(liveJs.includes('You administer more than one household'), 'a failed picker still shows a clear message');
  // Single-household path is untouched: first call still sends {}.
  assert.ok(liveJs.includes("let out = await callFn('gmail-oauth-start', {});"), 'first start call still sends no household_id');
});

// --- NEW-R4-C4: ingest dedupe precedes the nonce claim ---------------------
test('NEW-R4-C4: ingest checks messageId dedupe before claiming the nonce', () => {
  const dedupeCheck = ingest.indexOf(".eq('external_id', messageId)");
  const nonceClaim = ingest.indexOf("from('ingest_nonces').insert");
  const insert = ingest.indexOf(".from('transactions').insert");
  assert.ok(dedupeCheck !== -1 && nonceClaim !== -1 && insert !== -1);
  assert.ok(dedupeCheck < nonceClaim, 'dedupe check precedes the nonce claim');
  assert.ok(nonceClaim < insert, 'nonce still claimed before the insert');
  // The duplicate return is on the dedupe path, before any nonce is claimed.
  const dupReturn = ingest.indexOf("return json({ stored: true, duplicate: true, state: 'provisional' })");
  assert.ok(dupReturn !== -1 && dupReturn > dedupeCheck && dupReturn < nonceClaim,
    're-delivery returns duplicate:true without claiming a nonce');
  assert.ok(ingest.includes('NEW-R4-C4'), 'the ordering change is documented at the claim site');
  assert.ok(ingest.includes('cannot be presented'), 'the replay-safety reasoning is recorded');
  // P2-B8 invariants survive the reorder: one generic 401, nonce after quarantine.
  assert.equal((ingest.match(/error: AUTH_FAILED/g) ?? []).length, 4, 'all four auth failures still use the generic 401');
  assert.ok(nonceClaim > ingest.indexOf("!authResultsPass(authResults)"), 'nonce still claimed after auth-results quarantine');
  assert.ok(nonceClaim > ingest.indexOf("reason: 'unparseable alert'"), 'nonce still claimed after parse quarantine');
});
