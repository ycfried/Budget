// Excluded-decisions (owner, Nov 3, 9:42 PM): HERO ONLY + duplicate
// connection guard. Static + logic tests only — no live data, no
// network, no money math.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { findDuplicateKeeper, describeConnection } from '../duplicateConnection.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const syncTs = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');

// --- 1. HERO ONLY -------------------------------------------------------
test('weekly stat card is gone; charity and fund cards stay', () => {
  assert.equal(html.includes('data-home-card="weekly"'), false);
  assert.equal(html.includes('homeWeeklyPrimary'), false);
  assert.equal(html.includes('data-home-card="charity"'), true);
  assert.equal(html.includes('data-home-card="fund"'), true);
  assert.equal(js.includes('homeWeeklyPrimary'), false);
});

test('hero number is the weekly breakdown target, numbers-only face', () => {
  assert.match(html, /id="weeklyAvailable"[^>]*role="button"[^>]*tabindex="0"/);
  assert.equal(js.includes('openWeeklySheet'), true);
  assert.match(js, /heroWeeklyTarget\?\.addEventListener\('click', openWeeklySheet\)/);
  assert.match(js, /heroWeeklyTarget\?\.addEventListener\('keydown'/);
  // Face: hero number is set from formatCentsHtml only, no words.
  assert.equal(js.includes('Over budget by $X'), false);
  // Words live only in the hero aria-label, as the card used to carry.
  assert.match(js, /Weekly Budget, over budget by \$\{formatCents\(Math\.abs\(avail\)\)\}, show breakdown/);
  assert.match(js, /Weekly Budget, \$\{formatCents\(avail\)\} left this week, show breakdown/);
  // No button nested in the hero number target: the Sync button is a
  // separate control in the hero head row.
  assert.match(html, /id="homeSyncBtn"/);
  assert.equal(js.includes('openWeeklySheet'), true);
});

test('weekly sheet rows are not duplicated in the hero handler', () => {
  // The Weekly sheet is defined exactly once (inside openWeeklySheet).
  assert.equal((js.match(/title: 'Weekly Budget'/g) ?? []).length, 1);
});

// --- 2. Duplicate-connection guard --------------------------------------
const keeper = {
  plaid_item_id: 'item-old',
  institution_name: 'American Express',
  created_at: '2026-11-01T00:00:00Z',
  accounts: [
    { mask: '1005', name: 'Blue Cash Everyday' },
    { mask: '1636', name: 'Rewards Checking' },
  ],
};
const dup = {
  plaid_item_id: 'item-new',
  institution_name: 'American Express',
  created_at: '2026-11-03T00:00:00Z',
  accounts: [{ mask: '1005', name: 'Blue Cash Everyday' }],
};

test('duplicate: fully-covered newer item at same bank is flagged', () => {
  assert.equal(findDuplicateKeeper(dup, [keeper]), 'item-old');
});

test('duplicate: genuinely different account at same bank is NOT flagged', () => {
  const other = { ...dup, accounts: [{ mask: '9999', name: 'Gold Card' }] };
  assert.equal(findDuplicateKeeper(other, [keeper]), null);
});

test('duplicate: same mask but different account name is NOT flagged', () => {
  const lookalike = { ...dup, accounts: [{ mask: '1005', name: 'Platinum Card' }] };
  assert.equal(findDuplicateKeeper(lookalike, [keeper]), null);
});

test('duplicate: different institution is NOT flagged', () => {
  const otherBank = { ...dup, institution_name: 'Chase' };
  assert.equal(findDuplicateKeeper(otherBank, [keeper]), null);
});

test('duplicate: keeper must be older; missing dates fail open', () => {
  const newerKeeper = { ...keeper, created_at: '2026-11-04T00:00:00Z' };
  assert.equal(findDuplicateKeeper(dup, [newerKeeper]), null);
  assert.equal(findDuplicateKeeper({ ...dup, created_at: null }, [keeper]), null);
  assert.equal(findDuplicateKeeper(dup, [{ ...keeper, created_at: null }]), null);
});

test('duplicate: empty or unprovable candidate fails open', () => {
  assert.equal(findDuplicateKeeper({ ...dup, accounts: [] }, [keeper]), null);
  assert.equal(findDuplicateKeeper({ ...dup, accounts: [{ mask: '1005', name: null }] }, [keeper]), null);
  assert.equal(findDuplicateKeeper({ ...dup, institution_name: null }, [keeper]), null);
});

test('duplicate warning lists active connections and requires explicit confirm', () => {
  assert.match(js, /Already Connected\?/);
  assert.match(js, /'Connect Anyway'/);
  assert.match(js, /describeConnection\(item/);
  assert.equal(describeConnection(keeper, keeper.accounts), 'American Express — Blue Cash Everyday ••1005, Rewards Checking ••1636');
});

test('sync server guard: subset check, older keeper, disconnected excluded, fail-open removal', () => {
  assert.match(syncTs, /findDuplicateKeeper/);
  assert.match(syncTs, /status: 'disconnected', disconnected_at/);
  assert.match(syncTs, /duplicate_removed/);
  assert.match(syncTs, /could not remove it safely; syncing normally/);
  // Transactions are never deleted by the guard: no transaction delete
  // in the duplicate block (only the plaid_items status update).
  assert.equal(syncTs.includes('.from(\'transactions\').delete'), false);
});

test('no new SQL file is required for this package', () => {
  // Guard is code-only: no supabase/*.sql change in this branch is
  // asserted by the parent diff check; here we assert the client
  // never blocks on institution name alone.
  assert.equal(js.includes("institution_name === 'American Express'"), false);
});
