// Household naming step (owner, Nov 4, 2026): creating a household
// is choice -> optional naming step -> RPC; joiners never see the
// naming step; the stored name shows in the Settings Account card.
// The new RPC SQL is built for owner review only and is NOT applied
// by any test here. Static tests only — no live data, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const sql = readFileSync(new URL('../supabase/create-household-name.sql', import.meta.url), 'utf8');

const householdCard = html.slice(html.indexOf('id="view-household"'), html.indexOf('id="view-app"'));
const choicePanel = html.slice(html.indexOf('id="householdChoicePanel"'), html.indexOf('id="householdNamePanel"'));
const namePanel = html.slice(html.indexOf('id="householdNamePanel"'), html.indexOf('id="view-app"'));
const createFn = js.slice(js.indexOf("$('householdNameCreateBtn').addEventListener('click'"), js.indexOf("$('joinHouseholdBtn').addEventListener('click'"));
const choiceFn = js.slice(js.indexOf("$('createHouseholdBtn').addEventListener('click'"), js.indexOf("$('householdNameBackBtn')"));
const backFn = js.slice(js.indexOf("$('householdNameBackBtn')"), js.indexOf("$('householdNameCreateBtn')"));
const joinFn = js.slice(js.indexOf("$('joinHouseholdBtn').addEventListener('click'"), js.indexOf('async function shareInviteCode'));
assert.ok(createFn.length > 0, 'household create handler found');
assert.ok(choiceFn.length > 0, 'household choice handler found');
assert.ok(backFn.length > 0, 'household Back handler found');
assert.ok(joinFn.length > 0, 'join handler found');

test('household page has a choice panel and a hidden optional naming step', () => {
  assert.ok(choicePanel.includes('id="createHouseholdBtn"'), 'choice panel keeps Create household');
  assert.ok(choicePanel.includes('id="joinHouseholdBtn"'), 'choice panel keeps Join');
  assert.ok(namePanel.includes('Name your household'), 'naming step is titled');
  assert.ok(namePanel.includes('Optional'), 'naming step says the name is optional');
  const input = namePanel.match(/<input id="householdNameInput"[^>]*>/);
  assert.ok(input, 'household name input present');
  assert.match(input[0], /maxlength="80"/);
  assert.ok(namePanel.includes('id="householdNameBackBtn"'), 'naming step has Back');
  assert.ok(namePanel.includes('id="householdNameCreateBtn"'), 'naming step has Create');
  assert.ok(householdCard.includes('id="householdNamePanel" class="hidden"'), 'naming step starts hidden');
});

test('choice Create button shows the naming step and calls no RPC', () => {
  assert.match(choiceFn, /showHouseholdPanel\('name'\)/);
  assert.equal(choiceFn.includes('supabase.rpc('), false, 'choice button never calls the RPC');
});

test('naming step: blank name passes no p_name, supplied name passes p_name', () => {
  // Blank -> empty args object, so both the old no-arg RPC and the
  // new defaulted RPC create the default 'Household'.
  assert.match(createFn, /const args = name \? \{ p_name: name \} : \{\};/);
  assert.match(createFn, /supabase\.rpc\('create_household', args\)/);
  assert.match(createFn, /rawName\.slice\(0, 80\)/, 'name capped at 80 client-side too');
  // Failure on the old RPC (unknown argument) surfaces the existing
  // message — never a silent fallback through another path.
  assert.match(createFn, /householdNameMsg'\)\.textContent = data/);
  assert.match(createFn, /Could not create household\. Try again\./);
  assert.equal(createFn.includes("supabase.rpc('create_household')") && !createFn.includes('args'), false);
});

test('naming step Back returns to the choice panel', () => {
  assert.match(backFn, /showHouseholdPanel\('choice'\)/);
});

test('join path has no naming step', () => {
  assert.equal(joinFn.includes('showHouseholdPanel'), false, 'join never touches the naming panels');
  assert.equal(joinFn.includes('householdName'), false, 'join never reads the household name input');
  assert.match(joinFn, /join_household_by_code/);
});

test('Settings Account card shows the stored household name (fail silent)', () => {
  assert.ok(html.includes('id="householdNameLine"'), 'Account card has the household name line');
  assert.ok(html.includes('Household: Household'), 'static fallback covers existing households');
  assert.match(js, /from\('households'\)\.select\('name'\)/);
  assert.ok(js.includes("getElementById('householdNameLine')"), 'name line element is read');
  assert.ok(js.includes('`Household: ${hrow.name.trim()}`'), 'stored name is rendered with the Household: prefix');
  assert.match(js, /household name read failed/);
});

test('replacement RPC SQL: same guards, name parameter, invite code preserved', () => {
  assert.match(sql, /NOT YET APPLIED/, 'SQL is marked not-applied for owner review');
  assert.match(sql, /create or replace function public\.create_household\(p_name text default 'Household'\)/);
  assert.match(sql, /drop function if exists public\.create_household\(\);/);
  assert.match(sql, /raise exception 'not authenticated'/);
  assert.match(sql, /raise exception 'already in a household'/);
  assert.match(sql, /coalesce\(nullif\(trim\(p_name\), ''\), 'Household'\)/);
  assert.match(sql, /left\(coalesce\(nullif\(trim\(p_name\), ''\), 'Household'\), 80\)/);
  assert.match(sql, /insert into households \(name, base_allowance_cents, invite_code\)/);
  assert.match(sql, /generate_invite_code\(\)/);
  assert.match(sql, /insert into household_members \(household_id, user_id, role\)/);
  assert.match(sql, /values \(new_id, auth\.uid\(\), 'admin'\)/);
  assert.match(sql, /grant execute on function public\.create_household\(text\) to authenticated/);
});
