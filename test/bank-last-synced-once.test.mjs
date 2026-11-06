// "Last synced" once (owner, Nov 6, 2026, on the Settings Bank
// Connection screenshot): it appeared three times — once under
// Automatic Sync and once on each account row, all the same time.
// The accounts sync together in one run, so a per-account time adds
// nothing. Now it shows ONCE, at the top level under Automatic Sync
// (bankSyncLine); each account row keeps only its Connected date.
// Exception: an item that missed the latest run while the others
// succeeded shows a red "Sync failed" on that account row only —
// routine success is silent per account. No live data, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');

// Execute the shipped helper (sliced out of live.js, as the
// fund-expansion tests do with their builders).
const helperSrc = js.slice(js.indexOf('function accountSyncFailed'), js.indexOf('const renderConnectedAccounts'));
const accountSyncFailed = new Function(`${helperSrc}; return accountSyncFailed;`)();

test('accountSyncFailed: a stale stamp while the others advanced is a failure', () => {
  assert.equal(accountSyncFailed('2026-11-06T13:00:00Z', '2026-11-06T14:36:00Z'), true);
  assert.equal(accountSyncFailed('2026-11-06T14:36:00Z', '2026-11-06T14:36:00Z'), false, 'same time as the latest run is not a failure');
  assert.equal(accountSyncFailed('2026-11-06T15:00:00Z', '2026-11-06T14:36:00Z'), false, 'newer than the latest run is not a failure');
  assert.equal(accountSyncFailed(null, '2026-11-06T14:36:00Z'), false, 'never synced is not flagged — a just-connected account');
  assert.equal(accountSyncFailed('2026-11-06T13:00:00Z', null), false, 'no household sync yet, nothing to compare against');
  assert.equal(accountSyncFailed(null, null), false);
});

test('account rows show the Connected date only — no per-account Last synced', () => {
  assert.match(js, /sub\.textContent = item\.created_at \? `Connected \$\{fmtLong\(String\(item\.created_at\)\.slice\(0, 10\)\)\}` : '';/);
  const render = js.slice(js.indexOf('const renderConnectedAccounts'), js.indexOf('renderConnectedAccounts();'));
  const renderCode = render.replace(/\/\/[^\n]*/g, '');
  assert.equal(renderCode.includes('Last synced'), false, 'no Last synced survives in the account-row builder (comments aside)');
});

test('top-level Last synced under Automatic Sync is unchanged', () => {
  assert.ok(html.includes('id="bankSyncLine"'), 'the one Last synced line lives in the Settings bank section');
  assert.match(js, /syncLine\.textContent = bankLastSyncAt \? `Last synced \$\{fmtDateTime\(bankLastSyncAt\)\}` : 'Not synced yet\.';/);
});

test('Sync failed line is red, shown only on a failed item', () => {
  const render = js.slice(js.indexOf('const renderConnectedAccounts'), js.indexOf('renderConnectedAccounts();'));
  assert.match(render, /if \(accountSyncFailed\(item\.last_sync_at, bankLastSyncAt\)\) \{/);
  assert.match(render, /fail\.className = 'bank-acct-fail'/);
  assert.match(render, /fail\.textContent = 'Sync failed'/);
  assert.match(css, /body\.live \.bank-acct-fail \{ font-size: 13px; color: #dc2626; font-weight: 600;/);
});

test('exactly one Last synced line in the Settings bank section', () => {
  // bankSyncLine is the single "Last synced" in Settings; the Home
  // footer keeps its own "Last bank sync" line (different element,
  // different wording) and the account rows have none.
  assert.equal((html.match(/id="bankSyncLine"/g) ?? []).length, 1);
  assert.equal((js.match(/`Last synced \$\{fmtDateTime\(bankLastSyncAt\)\}`/g) ?? []).length, 1);
});
