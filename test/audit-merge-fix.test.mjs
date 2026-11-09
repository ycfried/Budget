// Audit-merge fix (Nov 3, 2026) tests — run with:
//   node --test test/audit-merge-fix.test.mjs
// Merges audit A (v29 audit, doc 2c7d0c3a) and review B (original full
// review, H1-H5/T1-T5/F1-F5/S1-S5/A1-A5) under the owner rule: only
// findings that make sense are fixed; judged-not-sensible findings
// are listed in the HANDOFF addendum, not built. No DOM, no network,
// no database; checks read the shipped files as static text, plus
// one structural check on the new SQL file (parameter renames only,
// column references untouched).

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const liveJs = readFileSync(path.join(root, 'live.js'), 'utf8');
const liveHtml = readFileSync(path.join(root, 'live.html'), 'utf8');
const stylesCss = readFileSync(path.join(root, 'styles.css'), 'utf8');
const sql = readFileSync(path.join(root, 'supabase/approve-ambiguity-fix.sql'), 'utf8');
// §1 is located by markers, not fixed line numbers (P1-B1, Nov 8,
// 2026: the never-reapply banners added header lines, which broke
// the old slice(109, 202) — the comparison itself is unchanged).
const s04 = readFileSync(path.join(root, 'supabase/04-admin-rpcs.sql'), 'utf8');
const section1 = s04.slice(
  s04.indexOf('drop function if exists public.approve_and_allocate'),
  s04.indexOf('grant execute on function public.approve_and_allocate(uuid, integer, text) to authenticated;')
    + 'grant execute on function public.approve_and_allocate(uuid, integer, text) to authenticated;'.length,
);

test('approve: RPC calls use the renamed p_ parameters, never the old names', () => {
  const calls = [...liveJs.matchAll(/supabase\.rpc\('approve_and_allocate', \{([^}]*)\}\)/g)];
  assert.equal(calls.length, 2);
  for (const [, args] of calls) {
    assert.match(args, /p_request_id/);
    assert.match(args, /p_amount_cents/);
    assert.match(args, /p_override_reason/);
    assert.doesNotMatch(args, /(?<!p_)request_id/);
  }
  assert.match(liveJs, /Could not approve this request\. Please try again in a moment\./);
});

test('approve SQL: drop + recreate with p_ params; column references untouched', () => {
  assert.match(sql, /drop function if exists public\.approve_and_allocate\(uuid, integer, text\);/);
  assert.match(sql, /create or replace function public\.approve_and_allocate\(p_request_id uuid, p_amount_cents integer, p_override_reason text\)/);
  assert.match(sql, /revoke execute on function public\.approve_and_allocate\(uuid, integer, text\) from public;/);
  assert.match(sql, /grant execute on function public\.approve_and_allocate\(uuid, integer, text\) to authenticated;/);
  // Column references keep their names: the fund_ledger sum, the
  // INSERT column list, and every v_req.amount_cents reference.
  assert.match(sql, /select coalesce\(sum\(amount_cents\), 0\) into v_available/);
  assert.match(sql, /insert into fund_ledger \(household_id, kind, amount_cents, week_start, request_id, note, created_by\)/);
  assert.match(sql, /v_req\.amount_cents/);
  assert.doesNotMatch(sql, /sum\(p_amount_cents\)/);
  assert.doesNotMatch(sql, /v_req\.p_amount_cents/);
  // Reverse-renaming the body must reproduce §1 exactly: the file is
  // §1 with parameter uses renamed and nothing else changed.
  const body = sql.slice(sql.indexOf('drop function'));
  const restored = body
    .replace(/\bp_request_id\b/g, 'request_id')
    .replace(/\bp_amount_cents\b/g, 'amount_cents')
    .replace(/\bp_override_reason\b/g, 'override_reason');
  assert.equal(restored.trimEnd(), section1.trimEnd());
});

test('week flag: apply handler always reads the checkbox, never forces it off for All', () => {
  const apply = liveJs.slice(liveJs.indexOf("$('txFiltersApplyBtn')"), liveJs.indexOf("$('txFiltersCancelBtn')"));
  assert.doesNotMatch(apply, /txWeekOnly = false/);
  assert.match(apply, /txWeekOnly = weekCheck\.checked/);
});

test('weekly sheet values: wrap at spaces, never mid-number', () => {
  const rule = stylesCss.match(/\.sheet-rows > div > span:last-child \{[^}]*\}/);
  assert.ok(rule);
  assert.doesNotMatch(rule[0], /overflow-wrap:\s*anywhere/);
  assert.match(rule[0], /overflow-wrap:\s*normal/);
  assert.doesNotMatch(rule[0], /white-space:\s*nowrap/);
});

test('stale hints point to Settings, not profile menu / Funds tab', () => {
  assert.match(liveJs, /Share the invite code from Settings/);
  assert.doesNotMatch(liveJs, /from your profile menu/);
  assert.match(liveHtml, /connect a bank account in Settings/);
  assert.doesNotMatch(liveHtml, /on the Funds tab/);
});

test('silent failures: create-account names the field; forms validate date inline', () => {
  assert.match(liveJs, /Enter an email address to create an account\./);
  assert.match(liveJs, /Password must be at least 8 characters\./);
  assert.match(liveJs, /Date: pick the date of this transaction\./);
  assert.match(liveJs, /Date: pick the date of the gift\./);
  assert.match(liveHtml, /<form id="manualForm" novalidate>/);
  assert.match(liveHtml, /<form id="charityGiftForm" novalidate>/);
  assert.match(liveHtml, /id="charityFormError"/);
});

test('search no-match: distinct from the new-household empty state', () => {
  assert.match(liveJs, /No matching transactions\. Try a different search, or clear the search and filters\./);
  assert.match(liveJs, /data-clear-search-filters/);
  assert.match(liveJs, /No transactions here yet — add one by hand above, or connect a bank account and sync\./);
});

test('profile email shown once: hidden when it duplicates the header', () => {
  assert.match(liveJs, /pe2\.classList\.toggle\('hidden', pn2\.textContent !== '—' && pn2\.textContent === pe2\.textContent\)/);
});

test('tap hints removed; row accessible names keep their words', () => {
  assert.doesNotMatch(liveHtml, /Tap a card for its breakdown/);
  assert.doesNotMatch(liveHtml, /id="section-hint"/);
  assert.doesNotMatch(liveJs, /Tap for detail<\/span>/);
  assert.match(liveJs, /show detail/);
});

test('admin fund wording is Available to use; member wording unchanged', () => {
  assert.match(liveJs, /household\.role === 'admin' \? 'Available to use' : 'Available to request'/);
  assert.doesNotMatch(liveJs, /'Spendable now'/);
});

test('generic sheets: Escape, focus trap, and focus return; filter sheet untouched', () => {
  assert.match(liveJs, /sheetKeyHandler/);
  assert.match(liveJs, /e\.key === 'Escape'/);
  assert.match(liveJs, /sheetOpener/);
  assert.match(liveJs, /document\.contains\(sheetOpener\)/);
  assert.match(liveJs, /if \(filtersOpen\) return;/);
  // The filter sheet keeps its own handler.
  assert.match(liveJs, /txFiltersSheet/);
});

test('verify-then-decide trivial fixes: history scope label, footer hidden off-app', () => {
  assert.match(liveHtml, /Load more activity/);
  assert.match(liveJs, /footer\.foot.*classList\.toggle\('hidden', view !== 'app'\)/);
});
