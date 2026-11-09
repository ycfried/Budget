// P0 fixes from the Nov 8, 2026 full audit (owner: "Do it", Nov 8, 2:14 PM).
// Four P0s, branch-only. No live data, no network.
//   P0-1 refund restoration unreachable — nothing wrote original_purchase_id.
//   P0-2 Transactions "Load more" dead — no handler, txLimit never raised.
//   P0-3 update_fund_shortfall caller/callee risk — live verified correct
//         Nov 8, 2:19 PM (alias version, household_id parameter); repo side
//         is quarantine of the p_ rename file + canonical file + caller test.
//   P0-4 auto-sync toggle fixed in repo, still broken live (deployed
//         plaid-webhook-register is the Nov 4 version, no disconnected
//         filter) — repo hardening + truthful toast; redeploy after merge.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { actionsForTxKind } from '../filterState.mjs';
import { isPostedRefund, computeWeek } from '../engine.mjs';
import { computeRestorationTotal, computeIncrementalRestoration } from '../restoration.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const linkSql = readFileSync(new URL('../supabase/refund-linking.sql', import.meta.url), 'utf8');
const shortfallSql = readFileSync(new URL('../supabase/update-fund-shortfall.sql', import.meta.url), 'utf8');
const quarantined = readFileSync(new URL('../supabase/DO-NOT-APPLY-deep-audit-update-fund-shortfall-fix.sql', import.meta.url), 'utf8');
const weekClose = readFileSync(new URL('../supabase/functions/week-close/index.ts', import.meta.url), 'utf8');
const plaidSync = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');
const ingestAlert = readFileSync(new URL('../supabase/functions/ingest-amex-alert/index.ts', import.meta.url), 'utf8');
const gmailPoll = readFileSync(new URL('../supabase/functions/gmail-poll/index.ts', import.meta.url), 'utf8');
const register = readFileSync(new URL('../supabase/functions/plaid-webhook-register/index.ts', import.meta.url), 'utf8');

test('pins are styles v52 / live.js v62', () => {
  assert.match(html, /styles\.css\?v=52/);
  assert.match(html, /live\.js\?v=62/);
});

// --- P0-1. Refund linking -----------------------------------------------
// Executable mirror of the matcher rules in supabase/refund-linking.sql
// (rule-for-rule: same normalization, exact amount, 90-day window,
// exactly-one candidate, not-already-fully-refunded). The shipped
// matcher is the SQL; this pins the intended semantics in executable
// form, the way classifyCsvKind mirrors canonical.ts.
function normMerchant(s) { return String(s ?? '').toUpperCase().trim().replace(/\s+/g, ' '); }
function matchRefundCandidates(refund, purchases) {
  if (!refund || refund.kind !== 'refund') return null;
  if (refund.excluded === true || refund.state === 'excluded' || refund.state === 'reversed') return null;
  if (refund.original_purchase_id) return null;
  const cands = purchases.filter((p) => {
    if (!['charge', 'fund_charge'].includes(p.kind)) return false;
    if (p.excluded === true || p.state === 'excluded' || p.state === 'reversed') return false;
    if (p.household_id !== refund.household_id) return false;
    if (p.card_suffix !== refund.card_suffix) return false;
    if (normMerchant(p.merchant) !== normMerchant(refund.merchant)) return false;
    if (p.amount_cents !== -refund.amount_cents) return false;
    if (p.date > refund.date) return false;
    const days = (new Date(`${refund.date}T12:00:00Z`) - new Date(`${p.date}T12:00:00Z`)) / 86400000;
    if (days > 90) return false;
    const already = purchases
      .filter((r) => r.original_purchase_id === p.id)
      .reduce((s, r) => s + Math.abs(r.amount_cents), 0);
    if (already >= p.amount_cents) return false;
    return true;
  });
  return cands.length === 1 ? cands[0].id : null;
}

const purchase = { id: 'p1', household_id: 'h1', kind: 'charge', state: 'verified', merchant: 'NORDSTROM', amount_cents: 15897, card_suffix: '1005', date: '2026-11-02', excluded: false };
const refund = { id: 'r1', household_id: 'h1', kind: 'refund', state: 'verified', merchant: 'Nordstrom', amount_cents: -15897, card_suffix: '1005', date: '2026-11-05', original_purchase_id: null, excluded: false };

test('P0-1: matcher links the one exact-amount, same-card, same-place purchase inside 90 days', () => {
  assert.equal(matchRefundCandidates(refund, [purchase]), 'p1');
});

test('P0-1: matcher links nothing when the match is ambiguous or inexact', () => {
  const twin = { ...purchase, id: 'p2', date: '2026-11-03' };
  assert.equal(matchRefundCandidates(refund, [purchase, twin]), null, 'two identical purchases: never guess');
  assert.equal(matchRefundCandidates({ ...refund, amount_cents: -10000 }, [purchase]), null, 'partial refund never auto-links');
  assert.equal(matchRefundCandidates({ ...refund, date: '2027-02-15' }, [purchase]), null, 'purchase more than 90 days before the refund');
  assert.equal(matchRefundCandidates({ ...refund, card_suffix: '1636' }, [purchase]), null, 'different card');
  assert.equal(matchRefundCandidates({ ...refund, merchant: 'MACYS' }, [purchase]), null, 'different merchant');
  assert.equal(matchRefundCandidates({ ...refund, household_id: 'h2' }, [purchase]), null, 'different household');
  const refunded = { ...purchase, id: 'p3' };
  const prior = { ...refund, id: 'r0', original_purchase_id: 'p3' };
  assert.equal(matchRefundCandidates(refund, [refunded, prior]), null, 'purchase already fully refunded');
  assert.equal(matchRefundCandidates({ ...refund, state: 'excluded' }, [purchase]), null, 'excluded refund');
  assert.equal(matchRefundCandidates({ ...refund, original_purchase_id: 'p1' }, [purchase]), null, 'already linked');
});

test('P0-1: refund-linking.sql states the same rules as the mirror', () => {
  assert.match(linkSql, /create or replace function public\.auto_link_refund\(p_refund_id uuid\)/, 'auto-link function exists');
  assert.match(linkSql, /create or replace function public\.link_refunds_to_purchase\(p_purchase_id uuid\)/, 'reverse-link function exists');
  assert.match(linkSql, /create or replace function public\.link_refund\(p_refund_id uuid, p_purchase_id uuid\)/, 'manual link RPC exists');
  assert.match(linkSql, /create or replace function public\.unlink_refund\(p_refund_id uuid\)/, 'manual unlink RPC exists');
  assert.match(linkSql, /c\.amount_cents = -v_ref\.amount_cents/, 'auto-link requires the exact full amount');
  assert.match(linkSql, /c\.date >= v_ref\.date - interval '90 days'/, '90-day window');
  assert.match(linkSql, /if v_cand_count <> 1 then return null; end if;/, 'exactly one candidate or nothing links');
  assert.match(linkSql, /_same_normalized_merchant\(c\.merchant, v_ref\.merchant\)/, 'normalized merchant equality, same as canonical.ts');
  assert.match(linkSql, /grant execute on function public\.auto_link_refund\(uuid\) to service_role;/, 'auto-link callable by the Edge Functions only');
  assert.match(linkSql, /grant execute on function public\.link_refund\(uuid, uuid\) to authenticated;/, 'manual link is an authenticated call (admin check inside)');
  assert.match(linkSql, /raise exception 'admin only'/, 'manual link enforces admin');
  assert.match(linkSql, /raise exception 'refund is more than the purchase has left to refund'/, 'manual link enforces the amount fit');
  assert.match(linkSql, /exists \(select 1 from restoration_entries where refund_transaction_id = p_refund_id\)/, 'unlink refuses after a restoration entry exists');
});

test('P0-1: all three ingestion paths call the linker after insert, best-effort', () => {
  for (const [name, src] of [['plaid-sync', plaidSync], ['ingest-amex-alert', ingestAlert], ['gmail-poll', gmailPoll]]) {
    assert.match(src, /rpc\('auto_link_refund', \{ p_refund_id: inserted\.id \}\)/, `${name} auto-links a refund after insert`);
    assert.match(src, /rpc\('link_refunds_to_purchase', \{ p_purchase_id: inserted\.id \}\)/, `${name} reverse-links a charge after insert`);
    assert.match(src, /Best-effort: never fails/, `${name} never fails ingestion on linking`);
  }
  assert.match(plaidSync, /rpc\('auto_link_refund', \{ p_refund_id: existing\.id \}\)/, 'plaid-sync also links a refund re-delivered after the purchase');
});

test('P0-1: a linked posted refund is selected for restoration; an unlinked one is not', () => {
  const rows = [
    { ...purchase, date: '2026-10-04', amount_cents: 47500 },
    { id: 'r1', kind: 'refund', state: 'verified', amount_cents: -15000, date: '2026-11-08', original_purchase_id: 'p1', excluded: false },
    { id: 'r2', kind: 'refund', state: 'verified', amount_cents: -15000, date: '2026-11-08', original_purchase_id: null, excluded: false },
  ];
  const forRestoration = rows.filter((t) => isPostedRefund(t) && t.original_purchase_id);
  assert.deepEqual(forRestoration.map((t) => t.id), ['r1'], 'only the linked refund reaches restoration');
  const unlinked = rows.filter((t) => isPostedRefund(t) && !t.original_purchase_id);
  assert.deepEqual(unlinked.map((t) => t.id), ['r2'], 'the unlinked refund stays in the unlinked fallback');
  // The linked refund restores its locked week per the spec example:
  // $475 purchase, $150 refund, empty later weeks -> $150 surplus.
  const weeks = ['2026-10-04', '2026-10-11', '2026-10-18', '2026-10-25', '2026-11-01'].map((week_start) => ({
    week_start, B: 37500, T: 0, charges_cents: week_start === '2026-10-04' ? 47500 : 0,
  }));
  const total = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500, totalRefundedCents: 15000,
  });
  assert.equal(total.restoredSurplusCents, 15000);
  assert.equal(total.debtReductionCents, 0);
  assert.equal(total.heldCents, 0);
  // Incremental: a second $425 refund on the same purchase restores
  // nothing more than the purchase, and the excess is held.
  const over = computeRestorationTotal({
    weeks, purchaseWeekStart: '2026-10-04', purchaseAmountCents: 47500, totalRefundedCents: 47500 + 10000,
  });
  assert.equal(over.heldCents, 10000, 'refund beyond the purchase is held, never restored');
  const inc = computeIncrementalRestoration({ priorTotal: total, newTotal: over, newRefundCents: 42500 });
  assert.equal(inc.restoredSurplusCents, 32500, 'incremental surplus is the restorable remainder of the new refund');
  assert.equal(inc.heldCents, 10000, 'incremental held is the excess over the purchase');
  assert.ok(inc.restoredSurplusCents + inc.debtReductionCents + inc.fundCreditCents <= 42500, 'incremental credit never exceeds the new refund');
  // Unlinked refunds net in the current week, capped at charges
  // (compute-week floors C at 0) — the fallback is still there for
  // refunds no purchase could be found for.
  const cw = readFileSync(new URL('../supabase/functions/compute-week/index.ts', import.meta.url), 'utf8');
  // P1-M1 (Nov 8, 2026): the lock gates the netting — an open week
  // still caps at charges, a locked week nets nothing.
  assert.match(cw, /const unlinkedNetted = weekLocked \? 0 : Math\.min\(unlinkedRefundAbs, Math\.max\(0, chargesNet\)\);/, 'unlinked netting capped at charges in open weeks, zero in locked weeks');
  assert.equal(computeWeek({ B: 37500, T: 0, D: 0, C: 0 }).available, 37500, 'a week floored at zero charges keeps its full allowance');
});

test('P0-1: no <redacted> placeholder survives in any Edge Function source (plaid-sync duplicate guard)', () => {
  // Found while wiring P0-1: supabase/functions/plaid-sync/index.ts
  // carried a literal `access_token: <redacted>` in the duplicate-
  // connection guard (since ad368bf, Nov 4) — a syntax error, so the
  // repo file could not parse or deploy at all. The guard needs this
  // item's decrypted token, the same variable the identical call
  // thirty lines above uses.
  const fnFiles = readdirSync(new URL('../supabase/functions/', import.meta.url), { withFileTypes: true })
    .filter((e) => e.isDirectory() && e.name !== '_shared')
    .map((e) => e.name);
  for (const f of fnFiles) {
    const src = readFileSync(new URL(`../supabase/functions/${f}/index.ts`, import.meta.url), 'utf8');
    assert.doesNotMatch(src, /<redacted>/, `${f} contains no redaction placeholder`);
  }
  assert.match(plaidSync, /const \{ ok: dupOk, data: dupData \} = await plaidPost\(base, '\/accounts\/get', clientId, secret, \{\s*\n\s*access_token: accessToken,\s*\n\s*\}\);/, 'duplicate guard (b) passes this item’s access token');
});

test('P0-1: the merge/re-delivery path preserves an existing link (never overwrites original_purchase_id)', () => {
  const updateBlock = plaidSync.slice(plaidSync.indexOf('const update: Record<string, unknown>'), plaidSync.indexOf("if (!trashed) update.state = state;"));
  assert.doesNotMatch(updateBlock, /original_purchase_id/, 're-delivery update never touches the link');
  const mergeSql = readFileSync(new URL('../supabase/dedupe-review-queue.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(mergeSql, /original_purchase_id\s*=/, 'dedupe merge never writes the link');
});

test('P0-1: refund rows offer Link to purchase (admin only); detail shows the link state', () => {
  assert.deepEqual(actionsForTxKind('refund', true, true), ['linkRefund', 'other', 'delete']);
  assert.deepEqual(actionsForTxKind('refund', false, true), [], 'members get no refund actions');
  assert.match(js, /id === 'linkRefund'\s*\n\s*\? \{ id, label: 'Link to purchase'/, 'Actions sheet lists Link to purchase');
  assert.match(js, /else if \(id === 'linkRefund'\) await doTxLinkRefund\(row\);/, 'Link to purchase dispatches to doTxLinkRefund');
  assert.match(js, /async function doTxLinkRefund\(row\) \{/, 'doTxLinkRefund exists');
  assert.match(js, /supabase\.rpc\('link_refund', \{ p_refund_id: row\.id, p_purchase_id: picked \}\)/, 'manual link calls link_refund');
  assert.match(js, /supabase\.rpc\('unlink_refund', \{ p_refund_id: row\.id \}\)/, 'unlink calls unlink_refund');
  assert.match(js, /t\.kind === 'refund' \? `<div><span>Refund link<\/span><span>\$\{t\.original_purchase_id \? 'Linked to a purchase' : 'Not linked to a purchase yet'\}<\/span><\/div>` : ''/, 'detail shows the link state on refund rows');
});

// --- P0-2. Load more ------------------------------------------------------

test('P0-2: Transactions Load more raises the limit and reloads', () => {
  assert.match(js, /if \(loadMore && !loadMore\.dataset\.bound\) \{/, 'handler is bound once, not stacked by refresh');
  assert.match(js, /loadMore\.addEventListener\('click', async \(\) => \{ txLimit \+= 100; await refresh\(\); \}\);/, 'tap raises txLimit by 100 and reloads');
  assert.match(js, /loadMore\.classList\.toggle\('hidden', all\.length < txLimit\)/, 'button still hides when everything is loaded');
  assert.match(js, /tap Load more for older ones/, 'count line still points at Load more');
});

// --- P0-3. update_fund_shortfall ------------------------------------------

test('P0-3: week-close calls update_fund_shortfall by the live parameter name, and no caller uses p_household_id', () => {
  assert.match(weekClose, /supabase\.rpc\('update_fund_shortfall', \{ household_id: householdId, shortfall_cents: target \}\)/, 'week-close calls with { household_id, shortfall_cents }');
  assert.doesNotMatch(weekClose, /p_household_id/, 'no week-close call site uses the p_ name');
  assert.match(shortfallSql, /create or replace function public\.update_fund_shortfall\(household_id uuid, shortfall_cents integer\)/, 'canonical file keeps the household_id parameter');
  assert.match(shortfallSql, /where hm\.household_id = household_id/, 'canonical file qualifies the column with a table alias');
  assert.doesNotMatch(shortfallSql, /where household_id = household_id/, 'canonical file has no bare ambiguous comparison');
  assert.match(shortfallSql, /VERIFIED Nov 8, 2026, 2:19 PM/, 'canonical file records the live verification');
});

test('P0-3: the p_ rename exists only in the quarantined file', () => {
  const sqlFiles = readdirSync(new URL('../supabase/', import.meta.url)).filter((f) => f.endsWith('.sql'));
  const definers = sqlFiles.filter((f) => {
    const src = readFileSync(new URL(`../supabase/${f}`, import.meta.url), 'utf8');
    return /function public\.update_fund_shortfall\(p_household_id/.test(src);
  });
  assert.deepEqual(definers, ['DO-NOT-APPLY-deep-audit-update-fund-shortfall-fix.sql'], 'only the quarantined file defines the p_ version');
  assert.match(quarantined, /DO NOT APPLY THIS FILE\. EVER\./, 'quarantined file carries the banner');
  assert.match(quarantined, /supabase\/update-fund-shortfall\.sql/, 'quarantined file points at the canonical file');
});

// --- P0-4. Auto-sync toggle -------------------------------------------------

test('P0-4: plaid-webhook-register skips disconnected items and isolates per-item failures', () => {
  assert.match(register, /filter\(\(i\) => \(i\.status \?\? 'active'\) !== 'disconnected'\)/, 'disconnected items are skipped');
  assert.match(register, /try \{\s*\n\s*const \{ data: ct \} = await supabaseAdmin\.rpc\('get_plaid_ciphertext'/, 'per-item work is inside try/catch');
  // P1-B3 (Nov 8, 2026): the per-item error is the generic string
  // 'request failed' — the raw exception text is logged server-side
  // only, because the toast displays this error.
  assert.match(register, /catch \(e\) \{[\s\S]*?results\.push\(\{ item: item\.plaid_item_id, institution: item\.institution_name \?\? null, ok: false, error: 'request failed' \}\)/, 'a failed item yields ok:false instead of a 500');
  assert.match(register, /institution: item\.institution_name \?\? null, ok: res\.ok/, 'every result names its institution');
  assert.match(register, /if \(\(items \?\? \[\]\)\.length && results\.every\(\(r\) => r\.ok\)\) \{/, 'switch state is stored only on a fully successful run');
});

test('P0-4: the auto-sync failure toast names the connection and the error, and never says partly enabled', () => {
  assert.doesNotMatch(js, /partly enabled|partly turned off/, 'the misleading "partly" wording is gone');
  assert.match(js, /Automatic sync could not be \$\{target \? 'turned on' : 'turned off'\} — \$\{name\} failed\$\{why\}\$\{more\}\. Nothing was changed; the switch stays \$\{target \? 'off' : 'on'\}\./, 'toast names the failing connection, its error, and that nothing changed');
  assert.match(js, /const name = first\.institution \? first\.institution : 'A bank connection';/, 'institution comes from the function result, with a fallback');
});
