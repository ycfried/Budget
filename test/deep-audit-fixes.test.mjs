import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { classifyCsvKind } from '../filterState.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const mergeSql = readFileSync(new URL('../supabase/dedupe-review-queue.sql', import.meta.url), 'utf8');
const shortfallFix = readFileSync(new URL('../supabase/DO-NOT-APPLY-deep-audit-update-fund-shortfall-fix.sql', import.meta.url), 'utf8');
const shortfallCanonical = readFileSync(new URL('../supabase/update-fund-shortfall.sql', import.meta.url), 'utf8');
const webhookRegister = readFileSync(new URL('../supabase/functions/plaid-webhook-register/index.ts', import.meta.url), 'utf8');
const plaidSync = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');
const gmailPoll = readFileSync(new URL('../supabase/functions/gmail-poll/index.ts', import.meta.url), 'utf8');

test('pins bumped to v52/v62', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=64/);
});

test('loadMembership failure uses setResultMsg soft red, not a direct blue box write', () => {
  assert.match(js, /setResultMsg\('householdMsg', `Could not load your household membership:/);
  assert.doesNotMatch(js, /el\.textContent = `Could not load your household membership/);
});

test('Activity screen has one Activity heading (page-head only)', () => {
  assert.match(html, /id="section-activity-head"/);
  const card = html.slice(html.indexOf('id="section-activity"'));
  assert.doesNotMatch(card, /<h2>Activity<\/h2>/);
});

test('Transactions From/To pair stacks at <=360px like the History pair', () => {
  assert.match(css, /@media \(max-width: 360px\) \{\s*body\.live \.tx-sheet-pair \{ grid-template-columns: 1fr; \}/);
});

test('reclassify offers payment and cashback (RPC already accepted them)', () => {
  assert.match(js, /value: 'payment', label: 'Payment'/);
  assert.match(js, /value: 'cashback', label: 'Cashback'/);
});

test('classifyCsvKind mirrors canonical: payment/cashback before sign fallback', () => {
  assert.equal(classifyCsvKind('PAYMENT - THANK YOU', -50000), 'payment');
  assert.equal(classifyCsvKind('CASH BACK', -2000), 'cashback');
  assert.equal(classifyCsvKind('INTERNAL TRANSFER DEBIT', 1000), 'transfer');
  assert.equal(classifyCsvKind('AMAZON REFUND', -1059), 'refund');
  assert.equal(classifyCsvKind('SOME TRANSFER TO A FRIEND', 5000), 'charge');
});

test('merge sets state=excluded so Trash restore can succeed', () => {
  assert.match(mergeSql, /update transactions set excluded = true, state = 'excluded' where id = v_cand\.duplicate_transaction_id/);
});

test('update_fund_shortfall: p_ rename file is quarantined DO-NOT-APPLY; canonical file keeps the household_id parameter with a table alias', () => {
  // P0-3 (Nov 8, 2026): the Nov 5 p_ rename would break week-close's
  // named RPC calls ({ household_id, shortfall_cents }). The file is
  // quarantined under a DO-NOT-APPLY name and the canonical version is
  // supabase/update-fund-shortfall.sql — verified live Nov 8, 2:19 PM.
  assert.match(shortfallFix, /DO NOT APPLY THIS FILE\. EVER\./, 'quarantined file carries the banner');
  assert.match(shortfallFix, /update_fund_shortfall\(p_household_id uuid/, 'quarantined file still holds the rejected rename, as a record');
  assert.match(shortfallFix, /supabase\/update-fund-shortfall\.sql/, 'quarantined file points at the canonical file');
  assert.match(shortfallCanonical, /create or replace function public\.update_fund_shortfall\(household_id uuid, shortfall_cents integer\)/, 'canonical file keeps the household_id parameter name');
  assert.match(shortfallCanonical, /from household_members hm\s*\n\s*where hm\.household_id = household_id/, 'ambiguity removed by qualifying the column with a table alias');
  const shortfallBody = shortfallCanonical.slice(shortfallCanonical.indexOf('create or replace function'));
  assert.doesNotMatch(shortfallBody, /where household_id = household_id/, 'no bare ambiguous comparison in the function body');
  assert.doesNotMatch(shortfallBody, /p_household_id/, 'function body never uses the p_ name');
  assert.match(shortfallCanonical, /for update/, 'row lock restored');
  assert.match(shortfallCanonical, /insert into audit_log/, 'audit row restored');
});

test('webhook-register skips disconnected items', () => {
  assert.match(webhookRegister, /filter\(\(i\) => \(i\.status \?\? 'active'\) !== 'disconnected'\)/);
});

test('plaid-sync full-pull pre-Nov delete is plaid-source only, and item failures continue', () => {
  assert.match(plaidSync, /\.delete\(\)\.eq\('household_id', householdId\)\.eq\('source', 'plaid'\)\.lt\('date', '2026-11-01'\)/);
  assert.match(plaidSync, /failedItems\.push\(item\.plaid_item_id\)/);
  assert.match(plaidSync, /failed_items: failedItems/);
});

test('gmail-poll bearer compare is timing-safe and synchronous', () => {
  assert.match(gmailPoll, /function timingSafeEqual\(a: string, b: string\): boolean \{/);
  assert.match(gmailPoll, /timingSafeEqual\(bearer, serviceKey\)/);
  assert.doesNotMatch(gmailPoll, /bearer !== serviceKey/);
});
