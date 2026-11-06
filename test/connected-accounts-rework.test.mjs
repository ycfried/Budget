// Connected accounts rework (owner, Nov 4, 2026) — per-account rows
// with per-account Disconnect, classy bank icons, Previously
// connected removed, email status shortened to "Connected".
// Static tests only. No DOM, no network, no database, no live app.
// Run with: node --test test/connected-accounts-rework.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const plaidSync = readFileSync(new URL('../supabase/functions/plaid-sync/index.ts', import.meta.url), 'utf8');
const acctDisconnect = readFileSync(new URL('../supabase/functions/plaid-account-disconnect/index.ts', import.meta.url), 'utf8');
const itemDisconnect = readFileSync(new URL('../supabase/functions/plaid-disconnect/index.ts', import.meta.url), 'utf8');
const config = readFileSync(new URL('../supabase/config.toml', import.meta.url), 'utf8');
const acctSql = readFileSync(new URL('../supabase/plaid-account-disconnect.sql', import.meta.url), 'utf8');

test('pins bumped to v50/v60', () => {
  assert.match(html, /styles\.css\?v=50/);
  assert.match(html, /live\.js\?v=60/);
});

test('Previously connected is gone from the UI, no rows deleted', () => {
  assert.equal(html.includes('Previously connected'), false);
  assert.equal(html.includes('bankPreviouslyList'), false);
  assert.equal(html.includes('Disconnected accounts stay listed here.'), false);
  assert.equal(js.includes('bankPreviouslyList'), false);
  // "Previously connected" appears in live.js only in the comment
  // explaining that the section is gone — never as rendered text.
  assert.equal(js.includes('Previously connected'), js.includes('// "Previously connected" is GONE'));
  assert.equal(css.includes('bankPreviouslyList'), false);
  // No delete in the new SQL or the new function: rows are kept.
  // (Comment lines are stripped first — the SQL header itself says
  // "no rows are deleted".)
  const acctSqlCode = acctSql.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
  assert.doesNotMatch(acctSqlCode, /delete|drop table/i);
  assert.doesNotMatch(acctDisconnect, /\.delete\(\)/);
});

test('Connected accounts renders one row per account', () => {
  assert.ok(js.includes('renderConnectedAccounts'), 'per-account renderer present');
  assert.equal(js.includes('renderBankList'), false, 'old item-grouped renderer gone');
  // Only active items, only accounts whose disconnected_at is unset.
  assert.match(js, /itemRows\.filter\(\(i\) => i\.status === 'active'\)/);
  assert.match(js, /!x\.disconnected_at/);
  assert.match(js, /disconnected_at/);
  // The account query actually selects the flag.
  assert.match(js, /plaid_account_id, name, mask, type, subtype, disconnected_at/);
  // Row title is the account (nickname or Plaid name), bank is a meta line.
  assert.match(js, /bank-acct-name/);
  assert.match(js, /bank-acct-meta/);
  assert.match(js, /plainAccountType\(acct\.type, acct\.subtype\)/);
});

test('per-account Disconnect: own button, own confirmation, own function', () => {
  assert.match(js, /callFn\('plaid-account-disconnect', \{ household_id: household\.household_id, plaid_item_id: item\.plaid_item_id, plaid_account_id: acct\.plaid_account_id \}\)/);
  assert.match(js, /Disconnect Account/);
  assert.match(js, /This stops syncing this account only/);
  assert.match(js, /Other accounts on the same bank connection keep syncing/);
  assert.match(js, /Past transactions stay in the list/);
  assert.match(js, /reconnect the bank from the Bank Connection card/);
  // Admin-only, like the old item Disconnect: the button is only
  // built when household.role is admin.
  const row = js.slice(js.indexOf('renderConnectedAccounts'), js.indexOf('renderConnectedAccounts();'));
  assert.match(row, /acct && household\.role === 'admin'/);
  // No whole-item disconnect call remains in the per-account path:
  // plaid-disconnect appears only in the no-accounts escape hatch
  // (an item with zero account rows has no account to disconnect).
  const plaidDisconnectCalls = js.match(/callFn\('plaid-disconnect'/g) ?? [];
  assert.equal(plaidDisconnectCalls.length, 1);
  assert.match(js, /No account rows at all for this item/);
});

test('plaid-account-disconnect: admin-only, last-account item removal, idempotent', () => {
  assert.ok(existsSync(new URL('../supabase/functions/plaid-account-disconnect/index.ts', import.meta.url)));
  assert.match(acctDisconnect, /membership\.role !== 'admin'/);
  assert.match(acctDisconnect, /plaid_account_id.*required/);
  // Last active account on the item triggers /item/remove.
  assert.match(acctDisconnect, /isLastActive/);
  assert.match(acctDisconnect, /\/item\/remove/);
  assert.match(acctDisconnect, /ITEM_NOT_FOUND/);
  // The flag is set, never a delete; the item is marked only in the
  // last-account case.
  assert.match(acctDisconnect, /disconnected_at: new Date\(\)\.toISOString\(\)/);
  assert.doesNotMatch(acctDisconnect, /\.delete\(\)/);
  assert.match(acctDisconnect, /already_disconnected/);
  // Deployed like the other app-called functions.
  assert.match(config, /\[functions\.plaid-account-disconnect\]\nverify_jwt = true/);
});

test('SQL migration: one nullable column, nothing else, applied live Nov 4 (PR #45)', () => {
  assert.match(acctSql, /alter table plaid_accounts\s+add column if not exists disconnected_at timestamptz/i);
  assert.doesNotMatch(acctSql, /update plaid_accounts|delete from|drop/i);
  assert.match(acctSql, /APPLIED live Nov 4, 2026 \(PR #45/);
});

test('plaid-sync skips disconnected accounts and keeps the reconnect path open', () => {
  // Disconnected account ids are loaded once and their added/modified
  // transactions are skipped, not upserted.
  assert.match(plaidSync, /disconnectedAccounts = new Set<string>\(\)/);
  assert.match(plaidSync, /disconnectedAccounts\.has\(String\(tx\.account_id\)\)/);
  // The duplicate guard ignores app-disconnected accounts, so a
  // reconnected account via Plaid Link is not killed as a duplicate.
  assert.match(plaidSync, /if \(row\.disconnected_at\) \{ disconnectedAccounts\.add/);
  // The /accounts/get upsert never clears the flag (it does not list
  // the column).
  const upsert = plaidSync.slice(plaidSync.indexOf('/accounts/get: card suffixes'), plaidSync.indexOf('Duplicate-connection guard'));
  assert.equal(upsert.includes('disconnected_at'), false);
});

test('bank logo: Clearbit gone, Google favicon first, brand-coloured fallback', () => {
  // The old dead source must not appear in the bank logo helper.
  const logoFn = js.slice(js.indexOf('function bankLogoHtml'), js.indexOf('// Plain-language account type'));
  assert.equal(logoFn.includes('logo.clearbit.com'), false);
  assert.match(logoFn, /www\.google\.com\/s2\/favicons\?domain=/);
  assert.match(logoFn, /sz=128/);
  // Fallback is a brand colour, never the flat grey box alone.
  assert.match(js, /BANK_BRAND_COLORS/);
  assert.match(js, /\['american express', '#2e77bc'\]/);
  assert.match(logoFn, /bankBrandColorFor\(name\)/);
  assert.match(logoFn, /p\.style\.background='\$\{brand\}'/);
  // The shared .bank-row base rule is untouched (other lists/tests
  // rely on it); the account row gets its own class.
  const row = css.match(/body\.live \.bank-row \{[^}]*\}/);
  assert.ok(row, '.bank-row rule found');
  assert.match(row[0], /align-items: center/);
  assert.match(css, /body\.live \.bank-row\.bank-acct-row \{[^}]*align-items: flex-start/);
  assert.match(css, /body\.live \.bank-acct-name \{[^}]*font-weight: 700/);
  assert.match(css, /body\.live \.bank-actions \{/);
});

test('email status has no standalone Connected line, error text unchanged', () => {
  // Owner, Nov 6, 2026: under a "Connected Email" heading the word
  // "Connected" repeats the heading, so the status line is gone —
  // only the reconnect error text survives.
  assert.equal(js.includes('Connected (read-only)'), false);
  assert.equal(js.includes(": 'Connected';"), false, 'no standalone Connected status is rendered');
  assert.match(js, /Needs reconnect — access was revoked or expired\./);
});

test('bank buttons (now Connect New Account / Sync Transactions / Automatic Sync switch) and Look only sentence untouched', () => {
  const bank = html.slice(html.indexOf('id="section-bank"'), html.indexOf('id="section-email"'));
  assert.ok(bank.includes('Connect New Account'));
  assert.ok(bank.includes('Sync Transactions'));
  assert.ok(bank.includes('Automatic Sync'));
  assert.ok(bank.includes('Look only — it never moves, sends, or changes anything.'));
});
