// P2 fixes from the Nov 8, 2026 third re-audit (FULL_AUDIT_2026-11-08_R3.md
// §5) — Edge Function / connections items, branch p2-functions.
// The suite runs under node --test and never executes Deno Edge
// Functions, so these tests assert source markers plus pure-JS mirrors
// of the fixed logic (same class as the existing audit tests), and the
// .ts files are verified separately by strip-parsing (see /tmp/check-ts.mjs).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { weekStartOf } from '../supabase/functions/compute-week/engine.mjs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const stripLineComments = (s) => s.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

// --- P2-B1: gmail-parse copies byte-identical -----------------------------
test('P2-B1: gmail-parse copies are byte-identical (_shared vs gmail-poll)', () => {
  const shared = read('../supabase/functions/_shared/gmail-parse.ts');
  const poll = read('../supabase/functions/gmail-poll/gmail-parse.ts');
  assert.equal(shared, poll);
  assert.ok(shared.includes('Subject-phrase only: the bare whole-message phrase also matched'));
});

// --- P2-NEW3: gmail-poll generic last_error -------------------------------
test('P2-NEW3: gmail-poll stores a generic last_error, detail to console only', () => {
  const src = read('../supabase/functions/gmail-poll/index.ts');
  assert.ok(src.includes("last_error: 'poll failed'"));
  assert.ok(!src.includes('last_error: connError'), 'raw exception must not reach the column');
  assert.ok(src.includes("console.error('gmail-poll: connection failed:'"));
});

// --- P2-NEW5 / P2-N12: Plaid vendor errors stay server-side --------------
test('P2-NEW5: plaid-link returns a generic error, Plaid detail to console only', () => {
  const src = read('../supabase/functions/plaid-link/index.ts');
  assert.ok(!src.includes('detail: data?.error_message'), 'vendor error_message must not reach the client');
  assert.ok(src.includes("console.error('plaid-link: Plaid link/token/create failed:'"));
  assert.ok(src.includes("return json({ error: 'plaid link token failed' }, 502)"));
});

test('P2-NEW5/P2-N12: webhook-register per-item errors are generic on both paths', () => {
  const src = read('../supabase/functions/plaid-webhook-register/index.ts');
  assert.ok(src.includes("error: res.ok ? null : 'request failed'"));
  const pushLine = src.split('\n').find((l) => l.includes('results.push'));
  assert.ok(pushLine && !pushLine.includes('error_message'), 'results.push must not carry the vendor error_message');
  assert.ok(src.includes("console.error('plaid-webhook-register: item failed:'"));
  assert.ok(src.includes("'request failed' })"), 'catch branch stays generic too');
});

// --- P2-C1: gmail-poll pagination -----------------------------------------
test('P2-C1: gmail-poll paginates with pageToken (no 50-message cap)', () => {
  const src = read('../supabase/functions/gmail-poll/index.ts');
  assert.ok(src.includes('nextPageToken'), 'must read nextPageToken');
  assert.ok(src.includes('&pageToken='), 'must send pageToken');
  assert.ok(src.includes('MAX_PAGES_PER_POLL'), 'must cap pages');
  assert.ok(src.includes('filterNewMessageIds(allIds, processedIds)'), 'processed markers unchanged');
});

// --- P2-C5: cron staleness signal -----------------------------------------
// Mirror of the threshold logic in gmail-poll (60 min) / plaid-sync (180 min).
const isStale = (minutesSincePrevious, threshold) =>
  minutesSincePrevious !== null && minutesSincePrevious > threshold;

test('P2-C5: staleness mirrors — gaps over threshold flag stale, null never does', () => {
  assert.equal(isStale(61, 60), true);
  assert.equal(isStale(60, 60), false);
  assert.equal(isStale(5, 60), false);
  assert.equal(isStale(null, 60), false);
  assert.equal(isStale(181, 180), true);
  assert.equal(isStale(180, 180), false);
  assert.equal(isStale(null, 180), false);
});

test('P2-C5: gmail-poll + plaid-sync report previous-run gap and a stale flag', () => {
  const poll = read('../supabase/functions/gmail-poll/index.ts');
  assert.ok(poll.includes('minutes_since_previous_poll'));
  assert.ok(poll.includes('STALE_POLL_MINUTES = 60'));
  assert.ok(poll.includes('last_poll_at'), 'must read the previous poll time');
  const sync = read('../supabase/functions/plaid-sync/index.ts');
  assert.ok(sync.includes('minutes_since_previous_sync'));
  assert.ok(sync.includes('minutesSincePreviousSync > 180'));
  assert.ok(sync.includes('last_sync_at'), 'must read the previous sync time');
});

// --- P2-C6: gmail-oauth-start multi-household -----------------------------
test('P2-C6: gmail-oauth-start lists admin households; multi-household gets 409, not 403', () => {
  const src = read('../supabase/functions/gmail-oauth-start/index.ts');
  const code = stripLineComments(src);
  assert.ok(!code.includes('.maybeSingle()'), 'maybeSingle must not gate multi-household admins');
  assert.ok(src.includes('multiple admin households: pass household_id of the household to connect'));
  assert.ok(src.includes('}, 409)'));
  assert.ok(src.includes('adminHouseholds.includes(requested)'), 'body household_id must be verified against membership');
});

// --- P2-B12: callback catch logs ------------------------------------------
test('P2-B12: gmail-oauth-callback catch logs server-side and returns an honest failure', () => {
  const src = read('../supabase/functions/gmail-oauth-callback/index.ts');
  assert.ok(src.includes("console.error('gmail-oauth-callback failed:'"));
  assert.ok(!src.includes('Something went wrong: ${'), 'raw error text must not reach the user');
});

// --- P2-B7: plaid-sync silent skips ---------------------------------------
test('P2-B7: plaid-sync logs each skip with a reason and returns skipped_by_reason', () => {
  const src = read('../supabase/functions/plaid-sync/index.ts');
  assert.ok(src.includes('skipped_by_reason: skipReasons'));
  assert.ok(src.includes("console.warn(`plaid-sync: skipped (item ${itemId}): ${reason}`)"));
  for (const reason of ['missing-token', 'token-decrypt-failed', 'account-disconnected', 'removed-not-found', 'invalid-amount', 'invalid-date', 'update-failed', 'insert-failed']) {
    assert.ok(src.includes(`'${reason}'`), `skip reason ${reason} missing`);
  }
  assert.ok(!src.includes('void isModified'), 'dead void isModified line removed');
  // The old bare `skipped++` sites are gone; the only increment lives in logSkip.
  assert.ok(!src.includes('skipped++'), 'bare skipped++ must be replaced by logSkip');
});

// --- P2-N11: best-effort linking logs RPC errors --------------------------
test('P2-N11: all three ingestion sites check the link RPC result and log failures', () => {
  for (const f of ['plaid-sync', 'gmail-poll', 'ingest-amex-alert']) {
    const src = read(`../supabase/functions/${f}/index.ts`);
    assert.ok(src.includes('logLinkError'), `${f}: logLinkError helper missing`);
    assert.ok(src.includes('refund linking failed (best-effort):'), `${f}: link failure must be logged`);
    assert.ok(src.includes('const { error: linkErr } = await'), `${f}: rpc result must be checked, not just try/catch`);
    assert.ok(!src.includes('catch { /* linking is best-effort */ }'), `${f}: silent bare catch must be gone`);
  }
});

// --- P2-B8: ingest 401 oracle + nonce burn --------------------------------
test('P2-B8: ingest returns one generic 401 for every auth failure', () => {
  const src = read('../supabase/functions/ingest-amex-alert/index.ts');
  for (const leaked of [
    'unknown household or ingest not configured',
    "'bad signature'",
    "'nonce already used'",
    "'timestamp outside replay window'",
  ]) {
    assert.ok(!src.includes(leaked), `oracle message still present: ${leaked}`);
  }
  assert.ok(src.includes("const AUTH_FAILED = 'authentication failed'"));
  assert.equal((src.match(/error: AUTH_FAILED/g) ?? []).length, 4, 'all four auth failures must use the generic 401');
});

test('P2-B8: nonce is claimed only after the quarantine checks, before the insert', () => {
  const src = read('../supabase/functions/ingest-amex-alert/index.ts');
  const authResultsCheck = src.indexOf("!authResultsPass(authResults)");
  const unparseable = src.indexOf("reason: 'unparseable alert'");
  const nonceClaim = src.indexOf("from('ingest_nonces').insert");
  const insert = src.indexOf(".from('transactions').insert");
  assert.ok(authResultsCheck !== -1 && unparseable !== -1 && nonceClaim !== -1 && insert !== -1);
  assert.ok(nonceClaim > authResultsCheck, 'nonce claimed after auth-results quarantine');
  assert.ok(nonceClaim > unparseable, 'nonce claimed after parse quarantine');
  assert.ok(nonceClaim < insert, 'nonce still claimed before the insert');
});

// --- P2-M4: released_cents decremented on late surplus reduction ---------
// Mirror of the fixed branch: newReleased = max(0, oldReleased - applied),
// where applied = min(reduction, fundAvailable) is what left the fund.
const newReleasedCents = (oldReleased, applied) => Math.max(0, (oldReleased ?? 0) - applied);

test('P2-M4: late surplus reduction decrements released_cents by the amount debited', () => {
  assert.equal(newReleasedCents(50000, 20000), 30000);
  assert.equal(newReleasedCents(10000, 25000), 0, 'floored at zero, never negative');
  assert.equal(newReleasedCents(40000, 0), 40000, 'no debit, no change');
  assert.equal(newReleasedCents(null, 5000), 0, 'null released defaults to 0');
});

test('P2-M4: week-close source decrements released_cents on reduction', () => {
  const src = read('../supabase/functions/week-close/index.ts');
  assert.ok(src.includes('Math.max(0, (existingRelease.released_cents ?? 0) - applied)'));
  assert.ok(src.includes('released_cents: newReleasedCents'));
});

// --- P2-M6: dead void lines removed ---------------------------------------
test('P2-M6: compute-week dead void lines and unused imports are gone', () => {
  const src = read('../supabase/functions/compute-week/index.ts');
  assert.ok(!src.includes('void pendingRefundExcludedCents'));
  assert.ok(!src.includes('void isExcludedFromMath'));
  assert.ok(!src.includes('pendingRefundExcludedCents,'));
  assert.ok(!src.includes('isExcludedFromMath,'));
});

// --- P2-B13: compute-week week_start validation ---------------------------
// Mirror of isValidWeekStart in compute-week/index.ts (regex + round-trip
// + weekStartOf equality), using the real shared weekStartOf.
const isValidWeekStart = (s) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) return false;
  const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return false;
  return weekStartOf(s) === s;
};

test('P2-B13: week_start mirror — Sundays pass, Mondays and malformed dates fail', () => {
  assert.equal(isValidWeekStart('2026-11-08'), true, '2026-11-08 is a Sunday');
  assert.equal(isValidWeekStart('2026-11-01'), true, '2026-11-01 is a Sunday');
  assert.equal(isValidWeekStart('2026-11-09'), false, 'Monday is not a week start');
  assert.equal(isValidWeekStart('2026-11-07'), false, 'Saturday is not a week start');
  assert.equal(isValidWeekStart('2026-13-45'), false, 'month 13 rolls over in weekStartOf, must be rejected');
  assert.equal(isValidWeekStart('2026-02-30'), false, 'Feb 30 does not exist');
  assert.equal(isValidWeekStart('garbage'), false);
  assert.equal(isValidWeekStart('2026-11-8'), false, 'regex requires zero-padded day');
  assert.equal(isValidWeekStart(''), false);
});

test('P2-B13: compute-week rejects a non-Sunday/malformed week_start with 400', () => {
  const src = read('../supabase/functions/compute-week/index.ts');
  assert.ok(src.includes('isValidWeekStart(rawWeek)'));
  assert.ok(src.includes("error: 'week_start must be a Sunday date (YYYY-MM-DD)' }, 400"));
});

// --- P2-N10: restoration-loop purchase guard ------------------------------
// Mirror of the guard added to the week-close restoration loop.
const isRestorablePurchase = (p) =>
  !!p && p.excluded !== true && p.state !== 'excluded' && p.state !== 'reversed'
  && (p.kind === 'charge' || p.kind === 'fund_charge');

test('P2-N10: restoration skips missing/excluded/reversed/non-charge purchases', () => {
  assert.equal(isRestorablePurchase({ kind: 'charge', state: 'verified' }), true);
  assert.equal(isRestorablePurchase({ kind: 'fund_charge', state: 'provisional' }), true);
  assert.equal(isRestorablePurchase(null), false, 'missing purchase');
  assert.equal(isRestorablePurchase({ kind: 'charge', state: 'verified', excluded: true }), false);
  assert.equal(isRestorablePurchase({ kind: 'charge', state: 'excluded' }), false);
  assert.equal(isRestorablePurchase({ kind: 'charge', state: 'reversed' }), false);
  assert.equal(isRestorablePurchase({ kind: 'payment', state: 'verified' }), false, 'reclassified to payment');
  assert.equal(isRestorablePurchase({ kind: 'refund', state: 'verified' }), false);
  assert.equal(isRestorablePurchase({ kind: 'charity', state: 'verified' }), false);
});

test('P2-N10: week-close restoration loop contains the purchase-state guard', () => {
  const src = read('../supabase/functions/week-close/index.ts');
  assert.ok(src.includes("purchase not restorable (excluded, reversed, or not a charge)"));
  assert.ok(src.includes("purchase.kind !== 'charge' && purchase.kind !== 'fund_charge'"));
});

// --- P2-B11: one-run lag is by design (no code change) --------------------
test('P2-B11: restoration runs after the walk, and compute-week applies cuts live (lag is by design)', () => {
  const wc = read('../supabase/functions/week-close/index.ts');
  assert.ok(wc.indexOf('// ---- Restoration phase') > wc.indexOf('// ---- Walk ----'),
    'restoration needs the walk closes, so its cuts land in the next run');
  const cw = read('../supabase/functions/compute-week/index.ts');
  assert.ok(cw.includes('restorationDebtCutsAfterClose'),
    'compute-week reads restoration cuts live, so displayed figures are correct immediately');
});

// --- P2-C7: view still exposes sync_cursor (SQL workstream owns the fix) --
// No Edge Function reads the public view (they use plaid_items directly),
// and live.js never selects sync_cursor — dropping the column is safe.
// The view itself lives in supabase/03-plaid-vault.sql (root SQL, outside
// the functions workstream): prepared SQL is in the branch report.
test('P2-C7: no function or client select reads sync_cursor from the public view', () => {
  for (const f of ['plaid-sync', 'plaid-link', 'plaid-webhook-register', 'plaid-webhook']) {
    const src = read(`../supabase/functions/${f}/index.ts`);
    assert.ok(!src.includes(".from('plaid_items_public')"), `${f} must not query the public view`);
  }
  const live = read('../live.js');
  assert.ok(!/\.select\([^)]*sync_cursor/.test(live), 'live.js must not select sync_cursor');
  const vault = read('../supabase/03-plaid-vault.sql');
  assert.ok(vault.includes('sync_cursor,'), 'view still exposes sync_cursor — prepared SQL, not yet applied');
});

// --- P2-B14: charity int overflow (prepared SQL, SQL workstream owns it) --
// record_charity_income / correct_charity_income compute
// (amount_cents * rate_bp + 5000) / 10000 in int4. At $214k income
// (21,400,000 cents) and the 10% default rate the intermediate product
// is 21,400,000,000 — far past the int4 max 2,147,483,647. The fix is a
// ::bigint cast in r13-charity.sql (root SQL, outside this workstream):
// prepared SQL is in the branch report. This test pins the arithmetic.
test('P2-B14: charity committed-cents product overflows int4 above ~$21k at 10% (bigint is exact)', () => {
  const amountCents = 21400000; // $214,000 income
  const rateBp = 1000; // 10% default
  const int32Max = 2147483647;
  assert.ok(amountCents * rateBp > int32Max, 'intermediate product exceeds int4');
  const exact = (BigInt(amountCents) * BigInt(rateBp) + 5000n) / 10000n;
  assert.equal(exact, 2140000n, 'bigint committed cents are exact');
  const sql = read('../supabase/r13-charity.sql');
  assert.equal((sql.match(/\(p_amount_cents \* v_rate \+ 5000\) \/ 10000/g) ?? []).length, 2,
    'both RPCs still use int arithmetic — prepared ::bigint SQL, not yet applied');
});

// --- P2-B15: cron service key is placeholders only, no real secret --------
test('P2-B15: server-sync-cron.sql holds placeholders only, never a real key', () => {
  const src = read('../supabase/server-sync-cron.sql');
  assert.equal((src.match(/PASTE_SERVICE_KEY_HERE/g) ?? []).length, 3,
    'comment + two job placeholders, nothing else');
  assert.ok(!/eyJ[A-Za-z0-9_-]{10,}/.test(src), 'no JWT-shaped secret present');
  assert.ok(src.includes('NEVER\n-- commit a filled-in copy of this file to the repo.')
    || src.includes('NEVER commit a filled-in copy'), 'never-commit note is present');
});
