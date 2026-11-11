// Admin remove-member (owner-found bug, Nov 8, 2026): the admin could
// not remove other household members — the Members page had no remove
// control at all. Fix: an admin sees a Remove button on every OTHER
// member's row (never their own, never for a non-admin viewer);
// tapping asks for confirmation, then calls the new
// remove_household_member RPC (admin-only, own household only,
// refuses self / last-admin / non-member) and refreshes the list.
// Static tests plus execution of the shipped memberRowHtml builder
// itself (sliced out of live.js, as the funds-expand-in-place test
// does), so the rows and buttons are tested as real code, not a copy.
// No live data, no network: the RPC's server-side guards are asserted
// from the SQL file's text; live behaviour is proven on apply in a
// synthetic household (see the SQL file's verification notes).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const sql = readFileSync(new URL('../supabase/remove-household-member.sql', import.meta.url), 'utf8');
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Slice the shipped row builder out of live.js and execute it.
const slice = (start, end) => js.slice(js.indexOf(start), js.indexOf(end));
const memberRowHtml = new Function('esc', `${slice('function memberRowHtml', 'async function removeMemberFlow')}; return memberRowHtml;`)(esc);

const other = { name: 'Chayas Friedman', role: 'Member', userId: 'u-member-1', isMe: false, isAdmin: true };
const meAdmin = { name: 'Shuki Friedman (you)', role: 'Admin', userId: 'u-admin-1', isMe: true, isAdmin: true };
const otherAsMember = { name: 'Chayas Friedman', role: 'Member', userId: 'u-member-1', isMe: false, isAdmin: false };
const otherAdmin = { name: 'Second Admin', role: 'Admin', userId: 'u-admin-2', isMe: false, isAdmin: true };

// --- Row builder: who sees Remove ---------------------------------------

test('admin sees Remove on another member row, with the member id + name on the button', () => {
  const row = memberRowHtml(other, esc);
  assert.match(row, /class="member-row"/);
  assert.ok(row.includes('<span class="member-name">Chayas Friedman</span>'));
  assert.ok(row.includes('<span class="role-pill">Member</span>'));
  assert.match(row, /<button class="btn btn-small btn-danger" data-remove-member="u-member-1" data-member-name="Chayas Friedman" type="button" aria-label="Remove Chayas Friedman from the household">Remove<\/button>/);
});

test('admin sees Remove on another ADMIN row too (the server refuses only the last admin)', () => {
  const row = memberRowHtml(otherAdmin, esc);
  assert.ok(row.includes('data-remove-member="u-admin-2"'));
  assert.ok(row.includes('<span class="role-pill">Admin</span>'));
});

test('admin sees NO Remove on their own row', () => {
  const row = memberRowHtml(meAdmin, esc);
  assert.ok(row.includes('Shuki Friedman (you)'));
  assert.equal(row.includes('data-remove-member'), false);
  assert.equal(row.includes('>Remove<'), false);
});

test('a non-admin viewer sees NO Remove on any row', () => {
  const row = memberRowHtml(otherAsMember, esc);
  assert.ok(row.includes('Chayas Friedman'));
  assert.equal(row.includes('data-remove-member'), false);
});

test('member name is escaped in the row text, button label, and data attribute', () => {
  const nasty = { name: '<script>alert(1)</script>', role: 'Member', userId: 'u-x', isMe: false, isAdmin: true };
  const row = memberRowHtml(nasty, esc);
  assert.equal(row.includes('<script>'), false);
  assert.ok(row.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
});

// --- Wiring in refresh(): buttons call removeMemberFlow -----------------

test('members list wires Remove buttons to removeMemberFlow with id + name', () => {
  assert.match(js, /ml\.querySelectorAll\('\[data-remove-member\]'\)\.forEach\(\(b\) => b\.addEventListener\('click', \(\) => removeMemberFlow\(b\.dataset\.removeMember, b\.dataset\.memberName\)\)\);/);
});

test('removeMemberFlow confirms first, then calls the RPC, toasts, and refreshes', () => {
  const fn = slice('async function removeMemberFlow', 'async function deleteAccountFlow');
  assert.match(fn, /showConfirm\('Remove Member', `Remove \$\{label\} from the household\? They will lose access to the household's data\.`, 'Remove'\)/);
  assert.match(fn, /supabase\.rpc\('remove_household_member', \{ p_user_id: userId \}\)/);
  assert.match(fn, /showToast\(`\$\{label\} was removed from the household\.`\)/);
  assert.match(fn, /await refresh\(\);/);
});

test('removeMemberFlow shows a soft-red alert (not a silent failure) when the RPC refuses', () => {
  const fn = slice('async function removeMemberFlow', 'async function deleteAccountFlow');
  assert.match(fn, /console\.warn\('remove_household_member failed:', error\.message\)/);
  assert.match(fn, /showAlert\('Could not remove member', 'Could not remove this member\. Try again\.'\)/);
});

// --- RPC: server-side guards (static — live proof is synthetic-only) ----

test('remove_household_member RPC: SECURITY DEFINER, admin-only, own household only', () => {
  assert.match(sql, /create or replace function public\.remove_household_member\(p_user_id uuid\)/);
  assert.match(sql, /security definer/);
  assert.match(sql, /raise exception 'not authenticated'/);
  assert.match(sql, /raise exception 'admin only'/);
  assert.match(sql, /where hm\.user_id = auth\.uid\(\)/);
});

test('RPC refuses self-removal, last-admin removal, and non-members', () => {
  assert.match(sql, /raise exception 'you cannot remove yourself'/);
  assert.match(sql, /raise exception 'cannot remove the last admin'/);
  assert.match(sql, /raise exception 'that person is not a member of your household'/);
  assert.match(sql, /where household_id = v_household_id and role = 'admin'/);
});

test('RPC deletes ONLY the membership row and writes a Member removed audit row', () => {
  assert.match(sql, /delete from household_members\s+where household_id = v_household_id and user_id = p_user_id;/);
  assert.match(sql, /insert into audit_log \(household_id, actor, actor_name, action, detail\)/);
  assert.match(sql, /'Member removed'/);
  // Nothing else is deleted: no auth account, no data rows.
  assert.equal(/delete from auth\.users/i.test(sql), false);
  assert.equal(/delete from transactions/i.test(sql), false);
  assert.equal(/delete from households/i.test(sql), false);
});

test('RPC grants: revoked from public, granted to authenticated only', () => {
  assert.match(sql, /revoke execute on function public\.remove_household_member\(uuid\) from public;/);
  assert.match(sql, /grant execute on function public\.remove_household_member\(uuid\) to authenticated;/);
});

// --- Layout + pins -------------------------------------------------------

test('Remove button sits at the right edge of the member row', () => {
  assert.match(css, /body\.live \.member-row \.btn-small \{ margin-left: auto; flex: 0 0 auto; \}/);
});

test('pins bumped to v53/v69', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=69/);
});
