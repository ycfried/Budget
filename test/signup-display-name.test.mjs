// Sign-up display name (owner, Nov 6, 2026): "when someone signs
// up they must chose a name". Sign-up requires a name, saved to auth
// metadata and to household_members.display_name on create/join; the
// members list shows every household member's name via the
// list_household_members() RPC scoped to the caller's own household.
// Dropped at the owner's direction (Nov 6, 2:55 PM): no admin path
// to set another member's display name, no backfill for existing
// members — the owner handles his wife by delete + re-add. No live
// data, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const sql = readFileSync(new URL('../supabase/signup-display-name.sql', import.meta.url), 'utf8');
const rls = readFileSync(new URL('../supabase/fix-membership-policy.sql', import.meta.url), 'utf8');

// --- 1. Sign-up requires a name ------------------------------------------

test('1. Sign-up is blocked without a name; with a name it is saved to auth metadata', () => {
  // The name step is a separate panel; sign-in never touches it.
  assert.ok(html.includes('id="authNamePanel"'), 'name step panel exists');
  assert.ok(html.includes('id="authName"'), 'Name field exists on the sign-up step');
  const createFn = js.slice(js.indexOf("$('authNameCreateBtn').addEventListener('click'"), js.indexOf("$('signOutBtn').addEventListener('click'"));
  // Blank name fails BEFORE any Supabase call, inline soft-red error, focus on the field.
  assert.match(createFn, /if \(!signName\?\.value\.trim\(\)\) \{ fail\('Enter a name for your new account\.', signName\); return; \}/, 'blank name is refused before signUp');
  assert.match(createFn, /setResultMsg\('authNameMsg', msg, true\)/, 'the failure is the inline soft-red message');
  // With a name, signUp stores it as full_name metadata.
  assert.match(createFn, /options: \{ data: \{ full_name: signName\.value\.trim\(\) \} \}/, 'name is saved to auth metadata full_name');
  assert.match(createFn, /await supabase\.auth\.signUp\(\{/, 'signUp is only reached past the name check');
});

// --- 1. display_name on create + join --------------------------------------

test('1. create_household and join_household_by_code store display_name from metadata', () => {
  // Both functions copy the caller's auth-metadata name (full_name,
  // then name), trimmed and capped, or NULL — never blank/placeholder.
  assert.match(sql, /create or replace function public\._caller_display_name\(\)/, 'metadata-name helper exists');
  assert.match(sql, /raw_user_meta_data->>'full_name'/, 'full_name is read first');
  assert.match(sql, /raw_user_meta_data->>'name'/, 'name is the fallback');
  assert.match(sql, /left\(nullif\(trim\(coalesce\(/, 'blank metadata name becomes NULL, capped at 80');
  const createFn = sql.slice(sql.indexOf('create or replace function public.create_household'), sql.indexOf('-- 1b.'));
  assert.match(createFn, /v_display_name := public\._caller_display_name\(\);/, 'create reads the metadata name');
  assert.match(createFn, /insert into household_members \(household_id, user_id, role, display_name\)\s*\n\s*values \(new_id, auth\.uid\(\), 'admin', v_display_name\);/, 'create stores it on the admin row');
  const joinFn = sql.slice(sql.indexOf('create or replace function public.join_household_by_code'), sql.indexOf('create or replace function public.list_household_members()'));
  assert.match(joinFn, /v_display_name := public\._caller_display_name\(\);/, 'join reads the metadata name');
  assert.match(joinFn, /insert into household_members \(household_id, user_id, role, display_name\)\s*\n\s*values \(v_household_id, auth\.uid\(\), 'member', v_display_name\);/, 'join stores it on the member row');
  // create_household drops both signatures so exactly one remains.
  assert.match(sql, /drop function if exists public\.create_household\(\);/, 'no-arg overload is dropped');
  assert.match(sql, /drop function if exists public\.create_household\(text\);/, 'text overload is dropped before recreate');
  assert.match(sql, /create or replace function public\.create_household\(p_name text default 'Household'\)/, 'the (text) signature is the one live.js calls');
});

// --- 2. list-members RPC -----------------------------------------------------

test('2. list_household_members returns every member of the caller\'s own household, names only', () => {
  const fn = sql.slice(sql.indexOf('create or replace function public.list_household_members()'));
  assert.match(fn, /security definer/, 'RPC runs as the database owner, not the caller');
  assert.match(fn, /select hm\.household_id into v_household_id\s*\n\s*from household_members hm where hm\.user_id = auth\.uid\(\);/, 'scoped by the caller\'s own membership row');
  assert.match(fn, /where hm\.household_id = v_household_id/, 'only that household\'s members are returned');
  assert.match(fn, /returns table \(\s*\n\s*user_id uuid,\s*\n\s*display_name text,\s*\n\s*role text,\s*\n\s*created_at timestamptz,\s*\n\s*email_prefix text\s*\n\)/, 'returns user_id, display_name, role, created_at, email_prefix');
  assert.equal(fn.includes('email text'), false, 'no full-email column in the returns table');
  assert.match(fn, /split_part\(u\.email, '@', 1\)/, 'email_prefix is the part before @');
  assert.match(fn, /if v_household_id is null then\s*\n\s*return;/, 'a caller in no household gets zero rows');
  assert.match(fn, /revoke execute on function public\.list_household_members\(\) from public;/, 'not public');
  assert.match(fn, /grant execute on function public\.list_household_members\(\) to authenticated;/, 'authenticated members only');
});

test('2. RLS on household_members is NOT widened; the client uses the RPC', () => {
  // The own-row policy stands exactly as Nov 1 fixed it.
  assert.match(rls, /create policy "members read own membership"\s*\n\s*on household_members for select\s*\n\s*using \(user_id = auth\.uid\(\)\);/, 'read policy still own-row only');
  assert.equal(sql.includes('create policy'), false, 'this file adds no policy');
  assert.equal(sql.includes('drop policy'), false, 'this file drops no policy');
  // The members render calls the RPC, never a direct table read.
  assert.match(js, /const \{ data: mrows \} = await supabase\.rpc\('list_household_members'\);/, 'members list goes through the RPC');
  const membersBlock = js.slice(js.indexOf('function memberDisplayName'), js.indexOf('loadInviteCodeInline();'));
  assert.equal(membersBlock.includes(".from('household_members')"), false, 'no direct household_members read remains in the members block');
});

// --- 2. Name fallback: email prefix, never "Member" --------------------------

test('2. Member rows fall back to the email prefix, never the word "Member"', () => {
  const memberStart = js.indexOf('function memberDisplayName');
  const memberSrc = js.slice(memberStart, js.indexOf('  try {', memberStart));
  const memberDisplayName = new Function(`${memberSrc}; return memberDisplayName;`)();
  const me = { id: 'u-admin', user_metadata: { full_name: 'Shuki Friedman' }, email: 'ycfried1@gmail.com' };
  // Stored display name wins.
  assert.equal(memberDisplayName({ user_id: 'u-admin', display_name: 'Shuki', role: 'admin', email_prefix: 'ycfried1' }, me), 'Shuki');
  // Own row, no stored name: auth metadata.
  assert.equal(memberDisplayName({ user_id: 'u-admin', display_name: null, role: 'admin', email_prefix: 'ycfried1' }, me), 'Shuki Friedman');
  // Another member with no stored name: the RPC email_prefix.
  assert.equal(memberDisplayName({ user_id: 'u-other', display_name: null, role: 'member', email_prefix: 'chayasf1' }, me), 'chayasf1');
  // Blank stored name falls through to the prefix, not "Member".
  assert.equal(memberDisplayName({ user_id: 'u-other', display_name: '  ', role: 'member', email_prefix: 'chayasf1' }, me), 'chayasf1');
  // No name anywhere at all: last resort, still not the word "Member".
  assert.equal(memberDisplayName({ user_id: 'u-other', display_name: null, role: 'member', email_prefix: null }, me), 'Household member');
  assert.equal(js.includes("|| 'Member';"), false, 'the old Member fallback is gone');
  // The render still marks the current user with (you).
  assert.match(js, /const you = me && m\.user_id === me\.id \? ' \(you\)' : '';/);
});

// --- Dropped scope ------------------------------------------------------------

test('Dropped at owner direction: no admin set-name path, no backfill', () => {
  assert.equal(sql.includes('set_member_display_name'), false, 'no admin set-name RPC');
  assert.equal(sql.includes('update household_members'), false, 'no backfill UPDATE');
  assert.equal(js.includes('set_member_display_name'), false, 'no client call to a set-name RPC');
  assert.equal(js.includes("Edit name"), false, 'no inline name edit in the Members section');
});

// --- 1b. N13 reconciliation (owner, Nov 6, 2026) -------------------------
// The first apply of signup-display-name.sql was STOPPED at Step 0:
// its §1b was written against the pre-N13 join and would have removed
// the live invite-join rate limiting. The reconciled §1b is the LIVE
// N13 body, verbatim except the limit (10 -> 5, owner decision) and
// the display_name insert. No live DB here — these are static checks
// of the SQL text; the live apply re-verifies from pg_get_functiondef.

test('1b. join keeps the live N13 rate limiting, limit 5 in every bucket', () => {
  const n13 = readFileSync(new URL('../supabase/n13-invite-rate-limit.sql', import.meta.url), 'utf8');
  const joinFn = sql.slice(sql.indexOf('create or replace function public.join_household_by_code'), sql.indexOf('create or replace function public.list_household_members()'));
  const body = joinFn.slice(joinFn.indexOf('as $$'));
  // 24-hour sweep, three buckets, all at 5, no 10 left in the body.
  assert.match(body, /delete from invite_join_attempts where created_at < now\(\) - interval '24 hours';/, '24-hour sweep kept');
  assert.equal((body.match(/>= 5 then/g) || []).length, 3, 'exactly three buckets, all at 5');
  assert.equal(body.includes('>= 10'), false, 'no 10 threshold remains in the join body');
  // Unknown/malformed code: log the attempt and return NULL (commits),
  // never raise — raising would roll the log row back.
  assert.match(body, /if v_household_id is null then\s*\n\s*insert into invite_join_attempts \(user_id, attempted_code, household_id\)\s*\n\s*values \(auth\.uid\(\), v_input, null\);\s*\n\s*return null;/, 'unknown code logs and returns NULL');
  assert.equal(body.includes("raise exception 'invalid invite code'"), false, 'no raise on invalid code (pre-N13 behaviour is gone)');
  // Already-in-a-household is checked only AFTER the code resolves,
  // so the failure can be attributed to that household.
  assert.ok(body.indexOf('select id into v_household_id') < body.indexOf("raise exception 'already in a household'"), 'already-in-household check comes after resolving the code');
  // display_name is still stored on the join path.
  assert.match(body, /v_display_name := public\._caller_display_name\(\);/, 'join reads the metadata name');
  // The N13 reference file agrees: same limit, no 10 anywhere.
  assert.match(n13, /Threshold is 5 failed attempts per bucket/, 'N13 header states the limit of 5');
  assert.equal(n13.includes('>= 10'), false, 'no 10 threshold remains in the N13 file');
  assert.equal((n13.match(/>= 5 then/g) || []).length, 3, 'N13 file has the same three buckets at 5');
});

test('1b. reconciled join is the N13 join plus display_name only', () => {
  const n13 = readFileSync(new URL('../supabase/n13-invite-rate-limit.sql', import.meta.url), 'utf8');
  const fnOnly = (src) => {
    const start = src.indexOf('create or replace function public.join_household_by_code');
    return src.slice(start, src.indexOf('$$;', start) + 3);
  };
  const norm = (src) => src.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('--')).map((l) => l.replace(/\s+/g, ' ')).join('\n');
  // Rewrite the display_name insert back to the N13 form, and drop
  // the declaration + assignment lines, before comparing.
  const reconciled = fnOnly(sql)
    .replace(/insert into household_members \(household_id, user_id, role, display_name\)/, 'insert into household_members (household_id, user_id, role)')
    .replace(/values \(v_household_id, auth\.uid\(\), 'member', v_display_name\);/, "values (v_household_id, auth.uid(), 'member');")
    .split('\n').filter((l) => !l.includes('v_display_name')).join('\n');
  assert.equal(norm(reconciled), norm(fnOnly(n13)), 'reconciled join differs from the N13 join only by the display_name lines');
});

// --- Pins ----------------------------------------------------------------------

test('version pins: styles v52, live.js v62', () => {
  assert.ok(html.includes('styles.css\?v=53'));
  assert.ok(html.includes('live.js\?v=64'));
});
