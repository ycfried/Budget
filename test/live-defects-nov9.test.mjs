// Two live defects found by the Nov 9, 2026 synthetic live proofs
// (SYNTHETIC_PROOFS_2026-11-09.md, LIVE RUN section) — run with:
//   node --test test/live-defects-nov9.test.mjs
//
// DEFECT 1 — merged duplicates could never be restored from Trash
// (proof 3: MERGE PASS, RESTORE FAIL). resolve_duplicate_candidate
// excluded the duplicate without recording pre_exclusion_state, so
// restore_transaction raised 'cannot restore: no prior state
// recorded' — although the Resolved Duplicates row promises "the
// duplicate can be restored from Trash."
//
// DEFECT 2 — held refunds could never be released via the app
// (proof 8: FAIL). resolve_held_refund checked status='pending',
// but the live held_refunds CHECK allows only
// ('held','written_off','resolved'), so the function could never
// match a real row — and the UI labelled held rows "Resolved" with
// no Release button. The fix aligns function, writer, unlink guard
// and UI on 'held', the live constraint's vocabulary.
//
// The suite never executes SQL (the carried N5 gap), so these tests
// do two things: (a) assert the exact SQL/JS text that implements
// each fix, and (b) run a pure-JS mirror of the RPC state machines
// to prove the sequences (merge -> restore; release -> re-release
// refuses) behave as specified.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const dedupeSql = read('../supabase/dedupe-review-queue.sql');
const n4Sql = read('../supabase/n4-pre-exclusion-state.sql');
const atomicSql = read('../supabase/merged-audit-held-release-atomic.sql');
const snapshotsSql = read('../supabase/restoration-snapshots.sql');
const migrationSql = read('../supabase/restoration-columns-migration.sql');
const linkingSql = read('../supabase/refund-linking.sql');
const weekClose = read('../supabase/functions/week-close/index.ts');
const js = read('../live.js');
const html = read('../live.html');
const sw = read('../live-sw.js');

// --- DEFECT 1: merge records the snapshot ---------------------------

test('defect 1: merge records pre_exclusion_state from the duplicate row (mirrors exclude_transaction)', () => {
  // The merge UPDATE must carry the snapshot case — the exact bug
  // was an UPDATE that set excluded/state only.
  const merge = dedupeSql.slice(dedupeSql.indexOf("if p_action = 'merge'"), dedupeSql.indexOf("if p_action = 'separate'"));
  assert.match(merge, /pre_exclusion_state = case/);
  assert.match(merge, /when v_dup\.state <> 'excluded' then v_dup\.state/);
  assert.match(merge, /else v_dup\.pre_exclusion_state/);
  assert.match(merge, /set excluded = true, state = 'excluded'/);
});

test('defect 1: the canonical exclude still records the snapshot (guard against a shared regression)', () => {
  assert.match(n4Sql, /pre_exclusion_state = case/);
  assert.match(n4Sql, /when v_row\.state <> 'excluded' then v_row\.state/);
  assert.match(n4Sql, /else v_row\.pre_exclusion_state/);
});

test('defect 1: the UI promise the fix makes true is still there', () => {
  assert.ok(js.includes('the duplicate can be restored from Trash'), 'Resolved Duplicates row promises Trash restore');
});

// --- DEFECT 1: snapshot rule, mirrored in JS -------------------------
// Mirrors the case expression in both RPCs plus restore_transaction's
// NULL-snapshot refusal (n4). The SQL-text tests above tie this
// mirror to the real files.

function mergeSnapshot(dupState, dupSnapshot) {
  return dupState !== 'excluded' ? dupState : dupSnapshot;
}

function restoreTx(state, snapshot) {
  if (state !== 'excluded' && state !== 'reversed') throw new Error('transaction is not excluded or reversed');
  if (snapshot === null) throw new Error('cannot restore: no prior state recorded');
  return snapshot;
}

test('defect 1: merge of a posted row snapshots verified, restore returns it counted', () => {
  const snap = mergeSnapshot('verified', null);
  assert.equal(snap, 'verified');
  assert.equal(restoreTx('excluded', snap), 'verified');
});

test('defect 1: merge of a pending row snapshots provisional, restore returns it pending', () => {
  const snap = mergeSnapshot('provisional', null);
  assert.equal(snap, 'provisional');
  assert.equal(restoreTx('excluded', snap), 'provisional');
});

test('defect 1: re-merge of an already-excluded row preserves its snapshot', () => {
  assert.equal(mergeSnapshot('excluded', 'reversed'), 'reversed');
  assert.equal(restoreTx('excluded', mergeSnapshot('excluded', 'reversed')), 'reversed');
});

test('defect 1: NULL snapshot still refuses restore (the deliberate N4 rule — no invented state)', () => {
  const snap = mergeSnapshot('excluded', null);
  assert.equal(snap, null);
  assert.throws(() => restoreTx('excluded', snap), /cannot restore: no prior state recorded/);
});

// --- DEFECT 2: the function treats 'held' as releasable --------------

test('defect 2: atomic resolve_held_refund checks and updates status held, never pending', () => {
  assert.match(atomicSql, /if v_row\.status <> 'held' then raise exception 'held refund is not held';/);
  const conditional = atomicSql.match(/where id = p_held_id and status = 'held';/g) ?? [];
  assert.equal(conditional.length, 2, 'both resolving UPDATEs (release + write_off/resolve) are conditional on held');
  assert.ok(!atomicSql.includes("status = 'pending'"), 'no pending check remains in the atomic file');
  assert.ok(!atomicSql.includes("status <> 'pending'"), 'no pending guard remains in the atomic file');
});

test('defect 2: second-release refusal is preserved (row lock + row-count guard)', () => {
  assert.match(atomicSql, /select \* into v_row from held_refunds where id = p_held_id for update;/);
  assert.match(atomicSql, /get diagnostics v_updated = row_count;/);
  assert.match(atomicSql, /raise exception 'held refund already resolved'/);
  assert.match(atomicSql, /select fund_shortfall_cents into v_shortfall from households where id = v_row\.household_id for update;/);
});

test('defect 2: table definitions match the live constraint (held / written_off / resolved)', () => {
  assert.match(snapshotsSql, /status text not null default 'held' check \(status in \('held', 'written_off', 'resolved'\)\)/);
  assert.match(migrationSql, /status text not null default 'held' check \(status in \('held', 'written_off', 'resolved'\)\)/);
  assert.ok(!snapshotsSql.includes("default 'pending' check (status in ('pending', 'resolved'))"), 'old pending constraint is gone from snapshots');
});

test('defect 2: week-close inserts held rows as held', () => {
  assert.match(weekClose, /held_cents: inc\.heldCents, status: 'held',/);
  assert.ok(!weekClose.includes("held_cents: inc.heldCents, status: 'pending'"), 'no pending insert remains in week-close');
});

test('defect 2: the UI offers Release for held rows and labels them Held, not Resolved', () => {
  assert.match(js, /reviewNeedsCount = \(heldRows2 \?\? \[\]\)\.filter\(\(h\) => h\.status === 'held'\)\.length;/);
  assert.match(js, /st\.textContent = h\.status === 'held' \? 'Held for review'/);
  assert.match(js, /if \(h\.status === 'held'\) \{\n\s+const btn = document\.createElement\('button'\); btn\.className = 'btn btn-small btn-primary'; btn\.type = 'button';\n\s+btn\.textContent = 'Release';/);
  assert.ok(js.includes("supabase.rpc('resolve_held_refund', { p_held_id: h.id, p_action: 'release', p_note: '' })"), 'Release still calls resolve_held_refund');
  assert.ok(!js.includes("h.status === 'pending'"), 'no pending check remains on held rows in live.js');
});

test('defect 2: the unlink guard matches held rows too (P2-N14 was dead under pending)', () => {
  assert.match(linkingSql, /if exists \(select 1 from held_refunds where refund_transaction_id = p_refund_id and status = 'held'\) then/);
  assert.match(linkingSql, /this refund has a held amount — resolve the held refund first/);
});

// --- DEFECT 2: held state machine, mirrored in JS --------------------
// Mirrors the atomic RPC: release is shortfall-first, remainder to
// the fund ledger; any second resolution attempt raises; write_off
// closes with no money moved. The SQL-text tests above tie this
// mirror to the real file.

function resolveHeld(row, action, shortfall) {
  if (row.status !== 'held') throw new Error(row.status === 'resolved' ? 'held refund already resolved' : 'held refund is not held');
  if (action === 'release') {
    const applied = Math.min(shortfall, row.held_cents);
    return { status: 'resolved', toFund: row.held_cents - applied, shortfallOffset: applied, shortfallLeft: shortfall - applied };
  }
  if (action === 'write_off' || action === 'resolve') {
    return { status: 'resolved', toFund: 0, shortfallOffset: 0, shortfallLeft: shortfall };
  }
  throw new Error(`unknown action: ${action}`);
}

test('defect 2: a held row releases once — shortfall first, remainder to spendable surplus', () => {
  const out = resolveHeld({ status: 'held', held_cents: 1000 }, 'release', 400);
  assert.equal(out.status, 'resolved');
  assert.equal(out.shortfallOffset, 400, 'shortfall covered first');
  assert.equal(out.toFund, 600, 'remainder reaches the fund');
  assert.equal(out.shortfallLeft, 0);
});

test('defect 2: a held row releases in full to the fund when there is no shortfall', () => {
  const out = resolveHeld({ status: 'held', held_cents: 1000 }, 'release', 0);
  assert.equal(out.toFund, 1000);
  assert.equal(out.shortfallOffset, 0);
});

test('defect 2: a second release raises and moves no money (the proof-8 re-release)', () => {
  const first = resolveHeld({ status: 'held', held_cents: 1000 }, 'release', 0);
  assert.equal(first.status, 'resolved');
  assert.throws(() => resolveHeld({ status: 'resolved', held_cents: 1000 }, 'release', 0), /held refund already resolved/);
});

test('defect 2: a resolved or written-off row cannot be released', () => {
  assert.throws(() => resolveHeld({ status: 'resolved', held_cents: 1000 }, 'release', 0), /held refund already resolved/);
  assert.throws(() => resolveHeld({ status: 'written_off', held_cents: 1000 }, 'release', 0), /held refund is not held/);
});

test('defect 2: write_off closes a held row with no money moved', () => {
  const out = resolveHeld({ status: 'held', held_cents: 1000 }, 'write_off', 400);
  assert.equal(out.status, 'resolved');
  assert.equal(out.toFund, 0);
  assert.equal(out.shortfallOffset, 0);
  assert.equal(out.shortfallLeft, 400, 'shortfall untouched by a write-off');
});

// --- Pins --------------------------------------------------------------

test('pins: live.js v67 / styles v53, service-worker cache tracks live.js', () => {
  assert.ok(html.includes('live.js?v=67'), 'live.html pins live.js v67');
  assert.ok(html.includes('styles.css?v=53'), 'live.html pins styles v53');
  assert.ok(sw.includes("CACHE = 'onbudget-live-v67'"), 'service-worker cache tracks the live.js pin');
  assert.ok(sw.includes('(v67)'), 'service-worker comment names the current pin');
});
