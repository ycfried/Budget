// P2 SQL/RPC fixes from the Nov 8, 2026 third re-audit
// (FULL_AUDIT_2026-11-08_R3.md §5). Branch-only tests; live SQL/RPC
// behaviour is verified by the parent's live probes, not by these
// node tests (the suite never executes SQL — these are SQL-text
// assertions plus small JS mirrors of the SQL rules, same pattern
// as the P1/P0 audit test files).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = (p) => readFileSync(new URL(`../supabase/${p}`, import.meta.url), 'utf8');
const liveJs = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

const n4 = sql('n4-pre-exclusion-state.sql');
const linking = sql('refund-linking.sql');
const reclassify = sql('refund-classification-income-kind.sql');
const dedupe = sql('dedupe-review-queue.sql');
const shortfall = sql('update-fund-shortfall.sql');
const vault = sql('03-plaid-vault.sql');
const sundayChecks = sql('p2-sunday-week-start-checks.sql');
const nov1Floor = sql('p2-transactions-nov1-floor.sql');
const revokeDead = sql('p2-revoke-dead-rpcs.sql');

// ---- P2-NEW1: restore_transaction locked-week check ----

test('P2-NEW1: restore_transaction has the same 35-day lock check as exclude/reclassify', () => {
  // One raise in exclude_transaction, one in restore_transaction.
  const raises = n4.match(/raise exception 'week is locked: a locked-week transaction cannot be changed here'/g) || [];
  assert.equal(raises.length, 2, 'expected the lock raise in both exclude and restore');
  // The restore raise is computed from the row date, like exclude.
  assert.match(n4, /v_tx_week := v_row\.date - extract\(dow from v_row\.date\)::int;\n  if v_cur_week > v_tx_week \+ 35 then\n    raise exception 'week is locked/);
});

test('P2-NEW1: the locked-week escape hatch is a documented one-off owner-approved repair, not a bypass RPC', () => {
  assert.match(n4, /ONE-OFF OWNER-APPROVED SQL REPAIR/);
  assert.match(n4, /NOT a second bypass RPC/);
  assert.match(n4, /update transactions set excluded = false,\n--       state = pre_exclusion_state/);
  // The NULL-snapshot refusal is untouched: the 23 unrestorable
  // rows stay unrestorable, no backfill, no silent repair.
  assert.match(n4, /if v_row\.pre_exclusion_state is null then\n    raise exception 'cannot restore: no prior state recorded'/);
});

// ---- P2-NEW2: n4 header matches its body on NULL snapshots ----

test('P2-NEW2: n4 header no longer promises a date fallback, and names the real remedy', () => {
  assert.doesNotMatch(n4, /keep the old date rule as a fallback/);
  assert.doesNotMatch(n4, /needs re-exclude\/re-restore, or a one-off/);
  assert.match(n4, /Re-exclude\/re-restore CANNOT fix/);
  assert.match(n4, /one-off owner-approved repair/);
  assert.match(n4, /accepting the row as unrestorable/);
  assert.match(n4, /23 rows live with NULL snapshots \(recorded Nov 8, 2026\)/);
});

// ---- P2-N6: "fully refunded" totals ignore trashed linked refunds ----

test('P2-N6: all three linked-total counts filter out excluded/reversed refunds', () => {
  // Auto-link subquery (was :106-108, unfiltered).
  assert.match(linking, /where r\.original_purchase_id = c\.id\n\s+and r\.excluded is not true and r\.state not in \('excluded', 'reversed'\)/);
  // Reverse-link subquery (R3 claimed it filtered; at this base it did not).
  assert.match(linking, /where x\.original_purchase_id = v_pur\.id\n\s+and x\.excluded is not true and x\.state not in \('excluded', 'reversed'\)/);
  // Manual link_refund total — same bug class, same fix.
  assert.match(linking, /where original_purchase_id = p_purchase_id\n\s+and excluded is not true and state not in \('excluded', 'reversed'\)/);
  // The auto-link re-check after the row lock uses the same filter.
  assert.match(linking, /where r\.original_purchase_id = v_cand_id\n\s+and r\.excluded is not true and r\.state not in \('excluded', 'reversed'\)/);
});

// ---- P2-N7: auto-link runs on restore / reclassify ----

test('P2-N7: restore_transaction offers the restored row to the linker best-effort', () => {
  assert.match(n4, /perform public\.auto_link_refund\(txn_id\);/);
  assert.match(n4, /perform public\.link_refunds_to_purchase\(txn_id\);/);
  assert.match(n4, /Linking never fails the restore/);
  assert.match(n4, /exception when others then\n    null;/);
});

test('P2-N7: reclassify_transaction offers the reclassified row to the linker best-effort', () => {
  assert.match(reclassify, /perform public\.auto_link_refund\(txn_id\);/);
  assert.match(reclassify, /perform public\.link_refunds_to_purchase\(txn_id\);/);
  assert.match(reclassify, /Linking never fails the\s*\n\s*--\s*reclassify/);
});

// ---- P2-N8: NULL card_suffix in manual link ----

test('P2-N8: manual link fails on a NULL card suffix on either side', () => {
  assert.match(linking, /if v_ref\.card_suffix is null or v_pur\.card_suffix is null\n\s+or v_ref\.card_suffix <> v_pur\.card_suffix then/);
  // Auto-link stays strict the other way: plain `=` never matches NULL.
  assert.match(linking, /and c\.card_suffix = v_ref\.card_suffix/);
  assert.match(linking, /and r\.card_suffix = v_pur\.card_suffix/);
  assert.match(linking, /a NULL suffix is never a\s*\n--\s*match/);
});

// JS mirror of the P2-N8 rule: suffixes match only when both are
// present and equal. NULL on either side is a mismatch.
function suffixesMatch(a, b) {
  return a !== null && b !== null && a === b;
}

test('P2-N8 mirror: suffix match rule (NULL is never a match)', () => {
  assert.equal(suffixesMatch('1234', '1234'), true);
  assert.equal(suffixesMatch('1234', '5678'), false);
  assert.equal(suffixesMatch(null, '1234'), false);
  assert.equal(suffixesMatch('1234', null), false);
  assert.equal(suffixesMatch(null, null), false);
});

// ---- P2-N9: auto-link row locks ----

test('P2-N9: auto_link_refund locks the candidate purchase and re-checks the total after the lock', () => {
  assert.match(linking, /select amount_cents into v_cand_amount from transactions where id = v_cand_id for update;/);
  assert.match(linking, /if v_linked_total >= v_cand_amount then return null; end if;/);
  assert.match(linking, /P2-N9: lock the candidate purchase row before trusting the/);
});

test('P2-N9: reverse-link locks the purchase row before counting', () => {
  assert.match(linking, /select \* into v_pur from transactions where id = p_purchase_id for update;/);
});

test('P2-N9: manual link locks the purchase row before reading the linked total', () => {
  assert.match(linking, /perform 1 from transactions where id = p_purchase_id for update;/);
});

// ---- P2-N14: unlink refuses on a pending held row ----

test('P2-N14: unlink_refund refuses when a pending held_refunds row exists for the refund', () => {
  assert.match(linking, /if exists \(select 1 from held_refunds where refund_transaction_id = p_refund_id and status = 'pending'\) then/);
  assert.match(linking, /this refund has a pending held amount — resolve the held refund first/);
  // The restoration-entry refusal is still there too.
  assert.match(linking, /this refund already restored a week — it cannot be unlinked/);
});

// ---- P2-B4: non-Sunday week_start ----

test('P2-B4: both week RPCs raise on a non-Sunday week_start', () => {
  for (const [name, src] of [['set_weekly_allowance_override', sql('weekly-allowance-override.sql')], ['add_temp_increase', sql('live-temp-increases.sql')]]) {
    assert.match(src, /if p_week_start is null or extract\(dow from p_week_start\) <> 0 then\n\s+raise exception 'week_start must be a Sunday';/, `${name} has the Sunday raise`);
  }
});

test('P2-B4: Sunday CHECKs exist for week_closes, temp_increases, and weekly_allowance_overrides', () => {
  for (const name of ['week_closes_week_start_sunday', 'temp_increases_week_start_sunday', 'weekly_allowance_overrides_week_start_sunday']) {
    assert.match(sundayChecks, new RegExp(`conname = '${name}'`), `CHECK ${name} present`);
  }
  assert.match(sundayChecks, /check \(extract\(dow from week_start\) = 0\)/);
  // The file gates itself on a live pre-check, like the other
  // prepared files.
  assert.match(sundayChecks, /select count\(\*\) from week_closes where extract\(dow from week_start\) <> 0;/);
});

// JS mirror of the P2-B4 rule: a week_start is valid only on a Sunday.
function isSunday(dateStr) {
  return new Date(`${dateStr}T00:00:00Z`).getUTCDay() === 0;
}

test('P2-B4 mirror: Sunday rule', () => {
  assert.equal(isSunday('2026-11-01'), true); // a Sunday
  assert.equal(isSunday('2026-11-02'), false); // a Monday
  assert.equal(isSunday('2026-11-08'), true);
});

// ---- P2-B5: restore of reversed snapshots — judged NOT a bug ----

test('P2-B5 (judged not a bug): a reversed snapshot restores to reversed, and reversed rows never count in math', () => {
  // The restore still returns the stored snapshot verbatim.
  assert.match(n4, /v_state := v_row\.pre_exclusion_state;/);
  // Evidence it is harmless: every math path filters reversed rows
  // out (compute-week, week-close, and the client list math).
  const computeWeek = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
  const weekClose = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
  assert.match(computeWeek, /t\.state !== 'reversed'/);
  assert.match(weekClose, /t\.state !== 'reversed'/);
  assert.match(liveJs, /t\.state === 'reversed' \? 'Reversed; does not count\.' /);
});

// ---- P2-B9: resolve_duplicate_candidate row lock ----

test('P2-B9: resolve_duplicate_candidate locks the candidate row', () => {
  assert.match(dedupe, /select \* into v_cand from duplicate_candidates where id = p_candidate_id for update;/);
});

// ---- P2-B10: shortfall lock — already fixed, no action ----

test('P2-B10 (already fixed): update_fund_shortfall holds the households row lock and writes the audit row', () => {
  assert.match(shortfall, /select fund_shortfall_cents into v_old from households where id = household_id for update;/);
  assert.match(shortfall, /insert into audit_log \(household_id, actor, actor_name, action, detail\)/);
});

// ---- P2-B17: views expose internals ----

test('P2-B17: plaid_items_public no longer selects sync_cursor', () => {
  const view = vault.match(/create or replace view public\.plaid_items_public as\n([\s\S]*?)\n  from plaid_items/);
  assert.ok(view, 'view definition found');
  assert.doesNotMatch(view[1], /sync_cursor/);
  // The display columns the client actually selects are still there.
  for (const col of ['plaid_item_id', 'institution_name', 'institution_id', 'status', 'last_sync_at']) {
    assert.match(view[1], new RegExp(`^    ${col},$`, 'm'), `view still selects ${col}`);
  }
  // No client code reads sync_cursor from the view at all.
  assert.doesNotMatch(liveJs, /sync_cursor/);
  // The email view keeps last_error: the client renders it as the
  // reconnect warning, so it is display data, not an internal.
  const gmailView = sql('gmail-connected-at.sql');
  assert.match(gmailView, /last_error,/);
});

// ---- P2-B19 / P2-NEW4: stale comments ----

test('P2-B19: signup-display-name header records the Nov 8 live apply', () => {
  const signup = sql('signup-display-name.sql');
  assert.match(signup, /APPLIED LIVE Nov 8, 2026/);
  // The old standalone claim line is gone (the phrase survives only
  // inside the correction note that names it as stale).
  assert.doesNotMatch(signup, /WHAT THIS FILE DOES \(branch only, NOT applied live\):/);
});

test('P2-NEW4: the two merged-audit headers record the Nov 8 live state', () => {
  assert.match(sql('merged-audit-held-release-atomic.sql'), /APPLIED LIVE Nov 8, 2026, 6:52–7:31 PM/);
  assert.match(sql('merged-audit-fund-request-kind-guard.sql'), /the live\n-- trigger body CONTAINS the kind guard/);
  assert.match(sql('merged-audit-fund-request-kind-guard.sql'), /do NOT\n-- re-apply this file without that probe/);
});

test('P2-B19: create-household-name is marked superseded, never apply', () => {
  assert.match(sql('create-household-name.sql'), /SUPERSEDED, NEVER\n-- APPLY/);
  assert.match(sql('create-household-name.sql'), /Applying THIS file would DROP that/);
});

test('P2-B19: reclassify STEP 0 no longer calls the allow-list 6-kind', () => {
  assert.doesNotMatch(reclassify, /the 6-kind list \(no 'charity'/);
  assert.match(reclassify, /allow-list = the 8-kind list incl\. 'income' and\n-- 'charity'/);
});

// ---- P2-N13: update-fund-shortfall "safe no-op" claim ----

test('P2-N13: the "safe no-op" claim is gone; the fatal-audit decision is documented', () => {
  assert.doesNotMatch(shortfall, /re-applying it is a safe no-op/);
  assert.match(shortfall, /the audit_log insert\n-- stays FATAL/);
  assert.match(shortfall, /Making the insert non-fatal \(swallowing its error\)\n-- was considered and rejected/);
});

// ---- P2-B2: audit_log member INSERT — judged deliberate ----

test('P2-B2 (judged deliberate): the audit_log INSERT doc names the real dependent writer and the residual risk', () => {
  const hardening = sql('02-rls-hardening.sql');
  assert.match(hardening, /direct INSERT is KEPT \(membership-scoped\)/);
  assert.match(hardening, /the live\.js audit\(\) helper\n--    \(live\.js:381 inserts audit rows directly\)/);
  assert.match(hardening, /Week-close also\n--    writes audit rows, but via the service-role client/);
  assert.match(hardening, /a\n--    member can still insert an audit row with arbitrary action/);
});

// ---- P2-B3: dead-but-granted RPCs ----

test('P2-B3: the revoke file revokes EXECUTE on exactly the four dead RPCs', () => {
  for (const sig of [
    'add_temp_increase\\(uuid, date, integer, text\\)',
    'attest_savings\\(uuid, integer, text\\)',
    'record_savings_entry\\(uuid, text, integer, text\\)',
    'approve_fund_request\\(uuid\\)',
  ]) {
    assert.match(revokeDead, new RegExp(`revoke execute on function public\\.${sig} from authenticated;`), `revokes ${sig}`);
  }
  // The functions themselves are NOT dropped — revoke only.
  assert.doesNotMatch(revokeDead, /drop function/i);
  // Nothing in the live app calls any of the four.
  assert.doesNotMatch(liveJs, /supabase\.rpc\('(add_temp_increase|attest_savings|record_savings_entry|approve_fund_request)'/);
  // ...and the defining files still hold the functions (revoke, not delete).
  assert.match(sql('live-temp-increases.sql'), /create or replace function public\.add_temp_increase/);
  assert.match(sql('live-savings-rpc.sql'), /create or replace function public\.attest_savings/);
  assert.match(sql('savings-movements.sql'), /create or replace function public\.record_savings_entry/);
  assert.match(sql('04-admin-rpcs.sql'), /create or replace function public\.approve_fund_request/);
});

// ---- P2-C8: manual/CSV Nov 1 floor is now a DB CHECK ----

test('P2-C8: the Nov 1 floor CHECK exists, gated on a live pre-check', () => {
  assert.match(nov1Floor, /conname = 'transactions_date_nov1_floor'/);
  assert.match(nov1Floor, /check \(date >= date '2026-11-01'\)/);
  assert.match(nov1Floor, /select count\(\*\) from transactions where date < '2026-11-01';/);
  // The client-side floor it makes structural is still in place.
  assert.match(liveJs, /\.gte\('date', '2026-11-01'\)/);
});

// JS mirror of the P2-C8 rule: no transaction date may precede Nov 1, 2026.
function isOnOrAfterNov1(dateStr) {
  return /^\d{4}-\d{2}-\d{2}$/.test(dateStr) && dateStr >= '2026-11-01';
}

test('P2-C8 mirror: Nov 1 floor', () => {
  assert.equal(isOnOrAfterNov1('2026-11-01'), true);
  assert.equal(isOnOrAfterNov1('2026-10-31'), false);
  assert.equal(isOnOrAfterNov1('2026-11-08'), true);
  assert.equal(isOnOrAfterNov1('not-a-date'), false);
});

// ---- P2-B14: charity int overflow ----
test('P2-B14: both charity RPCs compute committed cents with a bigint product', () => {
  const charity = sql('r13-charity.sql');
  assert.equal((charity.match(/\(p_amount_cents::bigint \* v_rate \+ 5000\) \/ 10000/g) ?? []).length, 2, 'both RPCs cast the product to bigint');
  assert.doesNotMatch(charity, /\(p_amount_cents \* v_rate \+ 5000\) \/ 10000/);
  assert.equal((charity.match(/v_committed bigint;/g) ?? []).length, 2);
  assert.match(charity, /overflows above ~\$21\.5k of income at the 10% default rate/);
});

// No stored column can overflow: charity_income has no committed_cents column.
test('P2-B14: no bigint column migration is needed — committed cents are never stored', () => {
  const charity = sql('r13-charity.sql');
  const table = charity.match(/create table if not exists public\.charity_income \(([\s\S]*?)\n\);/);
  assert.ok(table, 'charity_income table found');
  assert.doesNotMatch(table[1], /committed/);
});

// JS mirror of the half-up formula, exact via BigInt (the SQL now does the same).
function committedCentsBigint(amountCents, rateBp) {
  return (BigInt(amountCents) * BigInt(rateBp) + 5000n) / 10000n;
}

test('P2-B14 mirror: half-up committed cents, exact past the int4 boundary', () => {
  // $214,000 at 10%: the functions workstream's example.
  assert.equal(committedCentsBigint(21400000, 1000), 2140000n);
  // Just past the int4 boundary at 10%: $21,474.84 income.
  // int4 product 2,147,484,000 exceeds int4 max 2,147,483,647.
  assert.ok(2147484 * 1000 > 2147483647, 'int4 product overflows here');
  assert.equal(committedCentsBigint(2147484, 1000), 214748n);
  // Rounding still half-up: $10.05 at 10% commits $1.01 (100.5 -> 101).
  assert.equal(committedCentsBigint(1005, 1000), 101n);
  // Result never exceeds the income: 100% rate commits exactly the amount.
  assert.equal(committedCentsBigint(2147484, 10000), 2147484n);
});

// ---- P2-B13: compute-week unvalidated week_start — functions workstream ----

test('P2-B13 (functions workstream, not fixed here): compute-week still takes week_start without a format check', () => {
  const computeWeek = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
  assert.match(computeWeek, /const rawWeek = String\(body\.week_start \?\? ''\);/);
  assert.match(computeWeek, /const weekStart = rawWeek \? weekStartOf\(rawWeek\) : currentWeekStart;/);
  // The SQL side covers only the week_closes WRITE side (see B4 test).
  assert.match(sundayChecks, /compute-week's unvalidated week_start INPUT/);
});
