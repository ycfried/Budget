// Settings bank buttons (owner, Nov 4, 2026): the three long bank
// buttons took up too much space. Connect becomes "Connect New
// Account", Sync becomes "Sync Transactions", both in one row, and
// "Enable automatic sync" becomes a real on/off switch backed by a
// stored flag and a Plaid webhook enable/disable — not a fake switch.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const fn = readFileSync(new URL('../supabase/functions/plaid-webhook-register/index.ts', import.meta.url), 'utf8');
const sql = readFileSync(new URL('../supabase/auto-sync-toggle.sql', import.meta.url), 'utf8');

test('bank buttons are shortened and fit one row', () => {
  assert.ok(html.includes('>Connect New Account</button>'), 'Connect New Account label');
  assert.ok(html.includes('>Sync Transactions</button>'), 'Sync Transactions label');
  assert.equal(html.includes('Connect another bank account'), false, 'old long Connect label gone');
  assert.equal(html.includes('Sync bank transactions now'), false, 'old long Sync label gone');
  assert.equal(html.includes('Enable automatic sync'), false, 'enable button label gone');
  // Two-button rule: primary blue first, grey tertiary second — pale
  // is only the middle of a three-button row.
  assert.match(html, /id="connectBankBtn" class="btn btn-primary"/);
  assert.match(html, /id="syncBankBtn" class="btn btn-tertiary"/);
  assert.match(css, /#section-bank \.btn-row \{ flex-wrap: nowrap;/);
  assert.match(css, /#section-bank \.btn-row \.btn \{ flex: 1 1 0; min-width: 0;/);
});

test('Automatic Sync is a switch, not a button', () => {
  assert.match(html, /id="autoSyncSwitch" class="auto-sync-switch"[^>]*role="switch" aria-checked="false"/);
  assert.match(html, /<label class="auto-sync-label" for="autoSyncSwitch">Automatic Sync<\/label>/);
  assert.equal(html.includes('id="registerWebhookBtn"'), false, 'old enable button removed');
  assert.match(css, /\.auto-sync-switch\[aria-checked="true"\] \{ background: #2f6bff;/);
  assert.match(css, /\.auto-sync-switch\[aria-checked="true"\] \.auto-sync-knob \{ transform: translateX\(22px\);/);
});

test('switch toggles for real: enable and disable via the edge function, state stored', () => {
  // Client sends the target state and reverts on failure.
  assert.match(js, /callFn\('plaid-webhook-register', \{ household_id: household\.household_id, enabled: target \}\)/);
  assert.match(js, /setAutoSyncSwitch\(target\)/);
  assert.match(js, /select\('auto_sync_enabled'\)\.eq\('id', household\.household_id\)/);
  // Edge function: enabled defaults to true for older clients, an
  // empty webhook clears it on disable, and the stored flag is only
  // written on a fully successful run.
  assert.match(fn, /const enabled = body\.enabled !== false;/);
  assert.match(fn, /const webhook = enabled \? WEBHOOK_URL : '';/);
  assert.match(fn, /update\(\{ auto_sync_enabled: enabled \}\)\.eq\('id', householdId\)/);
  assert.match(fn, /results\.every\(\(r\) => r\.ok\)/);
  // Migration file exists and adds the column (applied live Nov 4, 2026 (PR #44) — P2-B19: the old "(not applied live)" comment was stale; see supabase/auto-sync-toggle.sql).
  assert.match(sql, /alter table households add column if not exists auto_sync_enabled boolean not null default false;/);
  // Admin-only gating moved from the old button to the switch row.
  assert.match(js, /setBtn\('autoSyncRow', isAdmin\)/);
  assert.equal(js.includes("setBtn('registerWebhookBtn'"), false, 'old button gating gone');
});

test('pins bumped to v52/v62', () => {
  assert.ok(html.includes('styles.css\?v=53'));
  assert.ok(html.includes('live.js\?v=63'));
});

test('untouched copy: look-only sentence, last synced line, connected list', () => {
  assert.ok(html.includes('Look only — it never moves, sends, or changes anything.'));
  assert.ok(html.includes('id="bankSyncLine"'));
  assert.ok(html.includes('Connected Accounts'));
});
