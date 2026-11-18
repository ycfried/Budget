// Force-restore tests (build 44, change 2) — run with:
//   node --test test/restore-force-restore.test.mjs
// Source assertions in the existing audit-test style (see
// test/charity-auto-accrue.test.mjs). The SQL itself cannot run
// without a live database — the live pass (dashboard apply, then a
// throwaway row in a TEST household: force-restore refuses a row
// WITH a snapshot, restores a NULL-snapshot row as verified with
// source='restored', writes the audit row) is still owed after
// deploy. No Swift toolchain exists in this environment, so the
// Swift half is asserted on source text here; a build in Xcode
// (compile + the Trash tap-through on a test household) is owed.
//
// DECISIONS PINNED HERE:
// - Pre-check, not error-driven: the Trash row already carries
//   pre_exclusion_state (decoded from the `*` list load), so a NULL
//   snapshot is known BEFORE any RPC call — the popup shows
//   directly, with no wasted restore call and no failure alert
//   flashed first. The .cannotRestore error path in restore() is
//   only a stale-data fallback.
// - New RPC force_restore_transaction; restore_transaction is NOT
//   modified — the normal path keeps the original source and
//   restores the stored snapshot.
// - Force-restored rows come back state='verified', source='restored'
//   (owner label "Restored"), never provisional, never 'Bank'.
// - The $3,500 check row was already restored by a one-off
//   owner-approved SQL repair (Nov 18 ~11:05) — this file must
//   never re-restore it and no test here touches live data.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const sql = read('../supabase/restored-source.sql');
const n4 = read('../supabase/n4-pre-exclusion-state.sql');
const models = read('../ios-clone/OnBudgetKit/Sources/API/Models.swift');
const rpcs = read('../ios-clone/OnBudgetKit/Sources/API/RPCs.swift');
const formatting = read('../ios-clone/OnBudget/Transactions/TransactionFormatting.swift');
const fundsShared = read('../ios-clone/OnBudget/Funds/FundsShared.swift');
const viewModel = read('../ios-clone/OnBudget/Transactions/TransactionsViewModel.swift');
const trashView = read('../ios-clone/OnBudget/Transactions/TrashView.swift');

// --- SQL: source constraint ----------------------------------------------

test('source SQL: adds restored alongside the four existing values, drops none', () => {
  assert.match(sql, /check \(source in \('csv', 'amex_alert', 'plaid', 'manual', 'restored'\)\)/);
  assert.ok(sql.includes("add constraint transactions_source_check"));
});

test('source SQL: constraint found by definition lookup, never guessed', () => {
  // Same pattern as transfer-kind.sql: the schema.sql check is
  // anonymous, so the name comes from pg_constraint.
  assert.match(sql, /select conname into c\s+from pg_constraint/);
  assert.match(sql, /pg_get_constraintdef\(oid\) like '%''csv''%'/);
  assert.match(sql, /execute 'alter table transactions drop constraint ' \|\| quote_ident\(c\)/);
  // The lookup must match the live/schema definition, so a fresh
  // setup (schema.sql, 4-value list) is upgraded by this file.
  const schema = read('../supabase/schema.sql');
  assert.match(schema, /source text not null check \(source in \('csv', 'amex_alert', 'plaid', 'manual'\)\)/);
});

test('source SQL: dashboard-apply file, not applied live, with verification queries', () => {
  assert.match(sql, /DASHBOARD-APPLY FILE — NOT yet applied live/);
  assert.match(sql, /select conname, pg_get_constraintdef\(oid\) from pg_constraint/);
  assert.match(sql, /select proname from pg_proc where proname = 'force_restore_transaction'/);
});

// --- SQL: force_restore_transaction guards --------------------------------

test('force-restore SQL: new RPC, normal restore untouched', () => {
  assert.match(sql, /create or replace function public\.force_restore_transaction\(txn_id uuid\)/);
  assert.ok(!sql.includes('function public.restore_transaction'), 'this file must not redefine the normal restore RPC');
  assert.ok(n4.includes("raise exception 'cannot restore: no prior state recorded'"), 'normal restore still refuses NULL snapshots');
});

test('force-restore SQL: refuses rows WITH a snapshot', () => {
  assert.match(sql, /if v_row\.pre_exclusion_state is not null then/);
  assert.match(sql, /raise exception 'transaction has a prior state recorded: use restore_transaction'/);
});

test('force-restore SQL: NULL-snapshot rows come back verified, excluded=false, source=restored', () => {
  assert.match(sql, /set excluded = false, state = 'verified', exclude_reason = '',\s+pre_exclusion_state = null, source = 'restored'/);
});

test('force-restore SQL: audit row written', () => {
  assert.match(sql, /insert into audit_log \(household_id, actor, actor_name, action, detail\)/);
  assert.match(sql, /'Transaction force-restored'/);
  assert.match(sql, /source set to restored/);
});

test('force-restore SQL: mirrors restore_transaction security and guards', () => {
  // Same security pattern: SECURITY DEFINER, auth check, admin-only
  // membership check, authenticated-only EXECUTE.
  assert.match(sql, /security definer/);
  assert.match(sql, /if auth\.uid\(\) is null then raise exception 'not authenticated'/);
  assert.match(sql, /where household_id = v_row\.household_id and user_id = auth\.uid\(\) and role = 'admin'\) then\s+raise exception 'admin only'/);
  assert.ok(sql.includes('grant execute on function public.force_restore_transaction(uuid) to authenticated;'));
  assert.ok(sql.includes('revoke execute on function public.force_restore_transaction(uuid) from public;'));
  // Same guards: not-found, not-excluded-or-reversed, 35-day
  // locked-week check, linked-refund check, best-effort re-link.
  assert.match(sql, /raise exception 'transaction not found'/);
  assert.match(sql, /raise exception 'transaction is not excluded or reversed'/);
  assert.match(sql, /if v_cur_week > v_tx_week \+ 35 then/);
  assert.match(sql, /raise exception 'week is locked: a locked-week transaction cannot be changed here'/);
  assert.match(sql, /raise exception 'cannot restore refund: original transaction is missing'/);
  assert.match(sql, /perform public\.auto_link_refund\(txn_id\)/);
  assert.match(sql, /perform public\.link_refunds_to_purchase\(txn_id\)/);
});

// --- Swift: TransactionSource enum ----------------------------------------

test('Swift enum: restored case decodes source=restored', () => {
  assert.match(models, /case restored/);
  // Raw-value enum: `case restored` decodes the string "restored"
  // with no custom mapping, like `case csv` decodes "csv".
  assert.match(models, /public enum TransactionSource: String, Equatable, Codable \{/);
  assert.match(models, /case csv\n\s+case amexAlert = "amex_alert"\n\s+case plaid\n\s+case manual\n\s+case restored/);
});

test('Swift labels: restored displays as Restored in both source-label maps', () => {
  assert.match(formatting, /case \.restored: return "Restored"/);
  assert.match(fundsShared, /case \.restored: return "Restored"/);
});

test('Swift labels: no other source display changed', () => {
  for (const src of [formatting, fundsShared]) {
    assert.match(src, /case \.plaid: return "Bank"/);
    assert.match(src, /case \.manual: return "By hand"/);
    assert.match(src, /case \.csv: return "File"/);
    assert.match(src, /case \.amexAlert: return "Email"/);
  }
});

// --- Swift: force-restore RPC + Trash flow --------------------------------

test('Swift RPC: forceRestoreTransaction calls force_restore_transaction', () => {
  assert.match(rpcs, /public func forceRestoreTransaction\(txnId: UUID\) async throws \{/);
  assert.match(rpcs, /try await callVoid\(name: "force_restore_transaction", params: \[\s+"txn_id": txnId\.uuidString,\s+\]\)/);
  // Normal restore still calls restore_transaction, unchanged.
  assert.match(rpcs, /try await callVoid\(name: "restore_transaction", params: \[\s+"txn_id": txnId\.uuidString,\s+\]\)/);
});

test('Swift view model: pre-check on the decoded snapshot, no RPC first', () => {
  assert.match(viewModel, /public var pendingForceRestoreTransaction: Transaction\?/);
  assert.match(viewModel, /if transaction\.preExclusionState == nil \{\s+pendingForceRestoreTransaction = transaction\s+return false\s+\}/);
  // Stale-data fallback: a cannot-restore refusal also offers the popup.
  assert.match(viewModel, /if case \.cannotRestore = error \{\s+pendingForceRestoreTransaction = transaction\s+return false\s+\}/);
});

test('Swift view model: forceRestore calls the force RPC and reloads', () => {
  assert.match(viewModel, /public func forceRestore\(_ transaction: Transaction\) async -> Bool \{/);
  assert.match(viewModel, /try await client\.rpcs\.forceRestoreTransaction\(txnId: transaction\.id\)/);
  assert.match(viewModel, /await appendAudit\(\s+action: "Transaction force-restored",/);
  // The normal restore path still restores the snapshot and keeps
  // the original source (it never sets source itself — the slice
  // stops before forceRestore's doc comment, which does mention it).
  const restoreFn = viewModel.slice(viewModel.indexOf('public func restore(_ transaction: Transaction)'), viewModel.indexOf('/// Force-restore a bank-dropped'));
  assert.ok(restoreFn.includes('restoreTransaction(txnId: transaction.id)'));
  assert.ok(!restoreFn.includes('source'), 'normal restore must not touch source');
});

test('Swift Trash view: confirm popup has the exact owner-directed text', () => {
  assert.ok(trashView.includes('The bank dropped this transaction. Restore it anyway?'), 'exact popup message required');
  assert.match(trashView, /\.alert\(item: \$viewModel\.pendingForceRestoreTransaction\)/);
  assert.match(trashView, /Text\("Restore Anyway"\)/);
  assert.match(trashView, /_ = await viewModel\.forceRestore\(transaction\)/);
  // Centred .alert, not a confirmationDialog (on iPad a
  // confirmationDialog is a top-anchored popover). The word may
  // appear in comments explaining why; only an actual call counts.
  assert.ok(!trashView.includes('.confirmationDialog('), 'Trash confirm must be a centred alert, not a confirmationDialog');
});
