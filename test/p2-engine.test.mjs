// P2 engine / test-drift fixes from the Nov 8, 2026 third re-audit
// (FULL_AUDIT_2026-11-08_R3.md §5). Branch-only, no live change.
// Run with: node --test test/p2-engine.test.mjs
// All amounts are integer cents. $1 = 100.
//
// Covered here:
//   P2-M1 engine.mjs copy drift — whole-file equality, not just the
//         N1/N2 block (the old copy test missed charityCommittedCents
//         + locale formatCents).
//   P2-M2 N2 Option A residual — NO-ACTION, owner-accepted (see the
//         note below; this file deliberately changes nothing for it).
//   P2-M3 stale fund-first flags — restoration.mjs header now records
//         the Nov 5 owner decision instead of asking for confirmation.
//   P2-M5 tautological unlinked-cap test — the real helper is tested
//         in test/refund-classification-fix.test.mjs; this file pins
//         that the helper exists in every engine copy.
//   P2-N5 tests assert a JS mirror, not the SQL — extra mirror/SQL
//         agreement pins here, plus the live-syntax check in
//         docs/APPLY_RUNBOOK.md (a synthetic-household live test is
//         still owed at apply time; it cannot run in-branch).
//   P2-N15 stale fixture $3,790.55 — fixed in
//         test/refund-classification-fix.test.mjs (gross $4,762.30,
//         net spent $4,603.33, surplus $396.67).
//   P2-B19 stale comments, test-file side — guards that the two
//         stale apply-state claims found in test files stay fixed.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import {
  applyUnlinkedRefundCap,
  charityCommittedCents,
  formatCents,
} from '../engine.mjs';

const rootEngine = readFileSync(new URL('../engine.mjs', import.meta.url), 'utf8');
const restoration = readFileSync(new URL('../restoration.mjs', import.meta.url), 'utf8');
const linkSql = readFileSync(new URL('../supabase/refund-linking.sql', import.meta.url), 'utf8');
const runbook = readFileSync(new URL('../docs/APPLY_RUNBOOK.md', import.meta.url), 'utf8');

// --- P2-M1: whole-file engine equality ------------------------------------
// Canonical direction: root engine.mjs is the single formula; the three
// deployed copies are synced FROM root, never the other way (see the
// comment at the top of the N1/N2 section in engine.mjs). This test
// reads the actual file bytes, so ANY drift — a new export, a changed
// format, a one-line fix applied to one copy only — fails the suite.
// It would have caught the Nov 8 drift (root md5 7353de36 vs copies
// e9933b34: charityCommittedCents + locale formatCents only in root).
test('P2-M1: all four engine.mjs copies are byte-identical to root', () => {
  for (const copy of ['compute-week', 'week-close', '_shared']) {
    const other = readFileSync(new URL(`../supabase/functions/${copy}/engine.mjs`, import.meta.url), 'utf8');
    assert.equal(other, rootEngine, `${copy}/engine.mjs must be byte-identical to root engine.mjs`);
  }
});

// --- MATH-NEW2 (R4): restoration.mjs copy drift --------------------------------
// Same whole-file rule as M1, extended to restoration.mjs: the deployed
// week-close copy missed the Nov 5 fund-first fix (comment drift) because
// no test covered it. Root restoration.mjs is canonical; the deployed
// copy is synced FROM root, never the other way.
test('MATH-NEW2 (R4): week-close restoration.mjs is byte-identical to root', () => {
  const deployed = readFileSync(new URL('../supabase/functions/week-close/restoration.mjs', import.meta.url), 'utf8');
  assert.equal(deployed, restoration, 'week-close/restoration.mjs must be byte-identical to root restoration.mjs');
  assert.equal(deployed.includes('needs an owner confirmation'), false,
    'the stale "needs an owner confirmation at integration" flag is gone from the deployed copy too');
  assert.ok(deployed.includes('owner-confirmed Nov 5,'),
    'the deployed copy records the Nov 5 owner confirmation');
});

test('P2-M1: the previously-drifted symbols exist in every copy', () => {
  for (const copy of ['compute-week', 'week-close', '_shared']) {
    const other = readFileSync(new URL(`../supabase/functions/${copy}/engine.mjs`, import.meta.url), 'utf8');
    assert.ok(other.includes('export function charityCommittedCents'),
      `${copy}/engine.mjs must export charityCommittedCents (was root-only)`);
    assert.ok(other.includes("toLocaleString('en-US')"),
      `${copy}/engine.mjs must use the locale formatCents (was float toFixed(2))`);
    assert.ok(other.includes('export function applyUnlinkedRefundCap'),
      `${copy}/engine.mjs must export the P2-M5 cap helper`);
  }
  // And the root exports behave as the deployed copies must:
  // thousands separators (the UX-audit fix), half-up charity math.
  assert.equal(formatCents(476230), '$4,762.30');
  assert.equal(formatCents(-15897), '-$158.97');
  assert.equal(charityCommittedCents(700000, 1000), 70000);
  assert.deepEqual(applyUnlinkedRefundCap(15897, 476230, false),
    { nettedCents: 15897, excessCents: 0, chargesAfterCents: 460333 });
});

// --- P2-M2: N2 Option A residual — NO ACTION -------------------------------
// Evidence (no code changed for this item, by the task's instruction):
// restoration.mjs simulateWeeks(weeks, initialDebtCents) takes only an
// entering-debt scalar — cuts posted inside the simulation horizon,
// after the purchase week, are not applied week-by-week inside the
// simulation. The owner picked Option A with this residual disclosed
// (MATH_DECISIONS_N1_N2.md, "Cons: a residual gap remains"; HANDOFF.md
// "Math fixes N1 + N2", N2: "Residual gap (brief Option B): cuts
// posted inside the simulation horizon, after the purchase week, are
// still not applied week-by-week inside the simulation — noted, not
// fixed here"; test/math-fixes-n1-n2.test.mjs header: "owner-approved,
// Option A each"). Fixing it would be Option B (pass cutsByWeek into
// the simulation) — a math change, explicitly out of scope here.
test('P2-M2: no-action — simulateWeeks still takes only initialDebtCents (Option A, owner-accepted)', () => {
  assert.match(restoration, /export function simulateWeeks\(weeks, initialDebtCents\)/,
    'the Option A signature is unchanged; Option B (cutsByWeek) was not smuggled in');
});

// --- P2-M3: stale fund-first flags -----------------------------------------
test('P2-M3: restoration.mjs no longer asks for owner confirmation of fund-first ordering', () => {
  assert.equal(restoration.includes('needs an owner confirmation'), false,
    'the stale "needs an owner confirmation at integration" flag is gone');
  assert.equal(restoration.includes('needs owner confirmation'), false,
    'no stale confirmation flag remains anywhere in the file');
  assert.ok(restoration.includes('owner-confirmed'),
    'the header records the owner confirmation');
  assert.ok(restoration.includes('(Nov 5, 2026 — N1 Option A, fund-first counted once;'),
    'the header names the Nov 5 decision (N1 Option A)');
  // The same stale flag lived in a test name (engine.test.mjs) — fixed
  // with the header; guard it here so it cannot come back.
  const engineTest = readFileSync(new URL('../test/engine.test.mjs', import.meta.url), 'utf8');
  assert.equal(engineTest.includes('flagged for owner confirmation'), false,
    'no test still calls fund-first "flagged for owner confirmation"');
  assert.ok(engineTest.includes('owner-confirmed Nov 5, 2026 — N1 Option A'),
    'the split-fund test name records the owner decision');
});

// --- P2-N5: mirror/SQL agreement, strengthened where possible -------------
// The suite cannot execute SQL, so these pins are still not a live
// test — the live-syntax check + synthetic-household smoke test in
// docs/APPLY_RUNBOOK.md is what closes the loop at apply time. What
// IS strengthened here: every rule the JS mirror in
// test/p0-fixes-audit-2026-11-08.test.mjs implements must have a
// matching fragment in the shipped SQL. A SQL edit that drops a rule
// while keeping the old regexes now fails here.
// NOTE (P2-N6, fixed Nov 9, 2026 by the SQL workstream): the auto-link
// fully-refunded subquery now filters excluded/reversed linked refunds
// (refund-linking.sql:146-147), as do the reverse-link and manual totals.
// The mirror below pins the filtered form, not the old unfiltered one.
test('P2-N5: every mirror rule has a matching fragment in refund-linking.sql', () => {
  assert.match(linkSql, /c\.household_id = v_ref\.household_id/, 'auto-link: same household');
  assert.match(linkSql, /c\.card_suffix = v_ref\.card_suffix/, 'auto-link: same card suffix');
  assert.match(linkSql, /c\.amount_cents = -v_ref\.amount_cents/, 'auto-link: exact full amount');
  assert.match(linkSql, /c\.date <= v_ref\.date/, 'auto-link: purchase on or before the refund');
  assert.match(linkSql, /c\.date >= v_ref\.date - interval '90 days'/, 'auto-link: 90-day window');
  assert.match(linkSql, /where r\.original_purchase_id = c\.id[\s\S]{0,200}?\) < c\.amount_cents/,
    'auto-link: purchase not already fully refunded');
  assert.match(linkSql, /where r\.original_purchase_id = c\.id\s+and r\.kind = 'refund'\s+and r\.excluded is not true and r\.state not in \('excluded', 'reversed'\)/,
    'auto-link: fully-refunded total counts live linked refunds only (P2-N6, kind filter R4-BE-3)');
  assert.match(linkSql, /r\.original_purchase_id is null/, 'reverse-link: only unlinked refunds');
  assert.match(linkSql, /r\.date >= v_pur\.date/, 'reverse-link: refund on or after the purchase');
  assert.match(linkSql, /r\.date <= v_pur\.date \+ interval '90 days'/, 'reverse-link: 90-day window');
  assert.match(linkSql, /r\.state not in \('excluded', 'reversed'\)/, 'reverse-link: refund not excluded/reversed');
});

test('P2-N5: the apply runbook carries the live-syntax check', () => {
  assert.ok(existsSync(new URL('../docs/APPLY_RUNBOOK.md', import.meta.url)), 'docs/APPLY_RUNBOOK.md exists');
  assert.match(runbook, /P2-N5/, 'runbook names the P2-N5 gap');
  assert.match(runbook, /refund-linking\.sql/, 'runbook covers refund-linking.sql');
  assert.match(runbook, /rollback/i, 'runbook includes a rollback dry-run syntax check');
  assert.match(runbook, /auto_link_refund/, 'runbook includes the synthetic-household smoke test');
  assert.match(runbook, /synthetic/i, 'smoke test runs on a synthetic household, never the live one');
});

// --- P2-B19: test-file side guards -----------------------------------------
// Found by sweeping test/*.test.mjs for stale apply-state claims:
// 1. test/settings-bank-buttons.test.mjs:50 claimed the auto-sync
//    migration was "(not applied live)" — but its own SQL file
//    (supabase/auto-sync-toggle.sql) records "APPLIED live Nov 4,
//    2026 (PR #44, verified via information_schema)", and the
//    toggle was verified live Nov 8. Fixed to say so.
// 2. test/send-live-bundle.test.mjs:164 pinned "NOT YET APPLIED" on
//    supabase/weekly-allowance-override.sql — but the table is live:
//    supabase/delete-account-fk-migration.sql does an UNGUARDED
//    `alter table weekly_allowance_overrides ...` inside a transaction
//    and was applied live Nov 8 with no errors and a 9-row FK
//    verification (R3 §2), which is impossible if the table did not
//    exist. The test pin is removed; the SQL file's own stale header
//    belongs to the SQL workstream (supabase/ untouched here).
// Checked and NOT stale (left alone): household-name-step.test.mjs:80
// (create-household-name.sql was never run as-is — the live
// create_household came via the reconciled signup-display-name.sql);
// feedback-bundle.test.mjs:77 (feedback-allowance-set.sql is still
// prepared-only per HANDOFF, owner approval required); the
// signup-display-name.sql:7 "(branch only, NOT applied live)" header
// itself is SQL-side, not test-side.
test('P2-B19: no test file still claims the auto-sync column is unapplied', () => {
  const settingsTest = readFileSync(new URL('../test/settings-bank-buttons.test.mjs', import.meta.url), 'utf8');
  assert.equal(settingsTest.includes('// Migration file exists and adds the column (not applied live).'), false,
    'the stale auto-sync "(not applied live)" comment line is gone');
  assert.match(settingsTest, /applied live Nov 4, 2026 \(PR #44\)/,
    'the comment now records the live apply');
});

test('P2-B19: no test file still pins NOT YET APPLIED on the allowance-override SQL', () => {
  const bundleTest = readFileSync(new URL('../test/send-live-bundle.test.mjs', import.meta.url), 'utf8');
  assert.equal(bundleTest.includes("assert.match(sql, /NOT YET APPLIED/);"), false,
    'the stale NOT YET APPLIED pin on weekly-allowance-override.sql is gone');
});
