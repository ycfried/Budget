// Plaid webhook overlap lock tests (build 44, item 3) — run with:
//   node --test test/plaid-sync-overlap.test.mjs
// Pure source assertions in the existing audit-test style: the lock
// SQL cannot run without a live database, and the Edge Functions
// never execute under Node, so these tests pin the markers the
// deploy relies on — the atomic claim, the 200 skip, the release on
// every exit path, the insert-conflict retry, and the webhook JWK
// cache. The live pass (dashboard apply + test-household sync) is
// still owed after deploy; these tests prove the code, not the DB.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const lockSql = read('../supabase/plaid-sync-lock.sql');
const plaidSync = read('../supabase/functions/plaid-sync/index.ts');
const webhook = read('../supabase/functions/plaid-webhook/index.ts');
const cronSql = read('../supabase/server-sync-cron.sql');

// --- Lock SQL: table + atomic claim --------------------------------------

test('lock SQL: plaid_sync_locks table is keyed by household, TTL column present', () => {
  assert.match(lockSql, /create table if not exists public\.plaid_sync_locks/);
  assert.match(lockSql, /household_id uuid primary key references public\.households\(id\) on delete cascade/);
  assert.match(lockSql, /locked_until timestamptz not null/);
  assert.match(lockSql, /locked_by text not null/);
});

test('lock SQL: claim is a single atomic insert-on-conflict, expired locks only', () => {
  assert.match(lockSql, /create or replace function public\.try_claim_sync_lock\(/);
  assert.match(lockSql, /security definer/);
  assert.match(lockSql, /returns boolean/);
  assert.match(lockSql, /p_ttl_seconds integer default 600/);
  assert.match(lockSql, /insert into public\.plaid_sync_locks/);
  assert.match(lockSql, /on conflict \(household_id\) do update/);
  assert.match(lockSql, /where plaid_sync_locks\.locked_until < now\(\)/);
  assert.match(lockSql, /returning household_id into v_claimed/);
  assert.match(lockSql, /return v_claimed is not null/);
});

test('lock SQL: release deletes only the claiming owner\'s lock', () => {
  assert.match(lockSql, /create or replace function public\.release_sync_lock\(p_household_id uuid, p_owner text\)/);
  assert.match(lockSql, /delete from public\.plaid_sync_locks/);
  assert.match(lockSql, /where household_id = p_household_id/);
  assert.match(lockSql, /and locked_by = coalesce\(p_owner, ''\)/);
});

test('lock SQL: both RPCs are service_role-only, like 07-service-rpc-access.sql', () => {
  for (const fn of ['try_claim_sync_lock(uuid, text, integer)', 'release_sync_lock(uuid, text)']) {
    assert.match(lockSql, new RegExp(`if auth\\.role\\(\\) <> 'service_role' then raise exception 'service role only'`));
    assert.ok(lockSql.includes(`revoke execute on function public.${fn} from authenticated;`), `${fn} revoked from authenticated`);
    assert.ok(lockSql.includes(`grant execute on function public.${fn} to service_role;`), `${fn} granted to service_role`);
  }
  assert.match(lockSql, /revoke all on table public\.plaid_sync_locks from public, authenticated, anon;/);
});

// --- plaid-sync: claim, skip, release ------------------------------------

test('plaid-sync: lock claimed right after auth, before loading items', () => {
  const claimAt = plaidSync.indexOf("rpc('try_claim_sync_lock'");
  assert.notEqual(claimAt, -1, 'try_claim_sync_lock call missing');
  const itemsAt = plaidSync.indexOf(".from('plaid_items')");
  assert.notEqual(itemsAt, -1, 'plaid_items load missing');
  assert.ok(claimAt < itemsAt, 'lock must be claimed before items are loaded');
  assert.match(plaidSync, /p_household_id: householdId, p_owner: lockOwner, p_ttl_seconds: 600/);
});

test('plaid-sync: held lock returns 200 already_running, not an error', () => {
  assert.match(plaidSync, /return json\(\{ sync_skipped: 'already_running' \}\)/);
  assert.ok(!plaidSync.includes("sync_skipped: 'already_running' }, 4"), 'skip must be a 200, never a 4xx/5xx');
  assert.ok(!plaidSync.includes("sync_skipped: 'already_running' }, 5"), 'skip must be a 200, never a 4xx/5xx');
});

test('plaid-sync: lock released on every exit path (502, 503, success, catch)', () => {
  assert.match(plaidSync, /let releaseLock: \(\(\) => Promise<void>\) \| null = null;/);
  assert.match(plaidSync, /await supabaseAdmin\.rpc\('release_sync_lock', \{ p_household_id: householdId, p_owner: lockOwner \}\)/);
  const releaseCount = (plaidSync.match(/await releaseLock\?\.\(\)/g) ?? []).length;
  assert.ok(releaseCount >= 4, `expected release on 502 + 503 + success + catch, found ${releaseCount}`);
});

test('plaid-sync: lock claim fails OPEN when the SQL has not been applied yet', () => {
  assert.match(plaidSync, /plaid-sync: lock claim failed \(syncing without lock\)/);
  assert.match(plaidSync, /plaid-sync: lock claim threw \(syncing without lock\)/);
  // Fail-open means the claim error path does NOT return an error response.
  const claimBlock = plaidSync.slice(plaidSync.indexOf("rpc('try_claim_sync_lock'"), plaidSync.indexOf('releaseLock = async'));
  assert.ok(!claimBlock.includes('return json({ error:'), 'a failed claim must not error the sync');
});

test('plaid-sync: insert unique-violation re-selects by external_id and updates', () => {
  assert.match(plaidSync, /error\.code === '23505'/);
  assert.match(plaidSync, /duplicate key/i);
  const retryAt = plaidSync.indexOf("error.code === '23505'");
  assert.notEqual(retryAt, -1);
  const retryBlock = plaidSync.slice(retryAt, retryAt + 2500);
  assert.match(retryBlock, /\.eq\('external_id', txId\)\.maybeSingle\(\)/);
  assert.match(retryBlock, /\.update\(retryUpdate\)/);
  assert.match(retryBlock, /return \{ result: 'updated' \}/);
  assert.match(plaidSync, /return \{ result: 'skipped', reason: 'insert-failed' \}/);
});

// --- plaid-webhook: JWK cache + lock outcome ------------------------------

test('plaid-webhook: JWK cached per kid with ~1h TTL', () => {
  assert.match(webhook, /const jwkCache = new Map<string, \{ key: CryptoKey; fetchedAt: number \}>\(\)/);
  assert.match(webhook, /const JWK_CACHE_TTL_MS = 3600_000/);
  assert.match(webhook, /jwkCache\.get\(header\.kid\)/);
  assert.match(webhook, /Date\.now\(\) - cached\.fetchedAt < JWK_CACHE_TTL_MS/);
  assert.match(webhook, /jwkCache\.set\(header\.kid, \{ key, fetchedAt: Date\.now\(\) \}\)/);
});

test('plaid-webhook: verification logic unchanged (ES256, 5-min iat, body hash)', () => {
  assert.match(webhook, /header\.alg !== 'ES256' \|\| !header\.kid/);
  assert.match(webhook, /nowSec - payload\.iat > 300/);
  assert.match(webhook, /timingSafeEqual\(bodyHash, payload\.request_body_sha256\)/);
  assert.match(webhook, /crypto\.subtle\.verify\(\{ name: 'ECDSA', hash: 'SHA-256' \}/);
});

test('plaid-webhook: lock outcome surfaced in the 200 body', () => {
  assert.match(webhook, /let syncSkipped: string \| null = null;/);
  assert.match(webhook, /if \(syncBody\?\.sync_skipped\) syncSkipped = String\(syncBody\.sync_skipped\)/);
  assert.match(webhook, /\.\.\.\(syncSkipped \? \{ sync_skipped: syncSkipped \} : \{\}\)/);
});

// --- Cron backstop untouched ----------------------------------------------

test('server-sync-cron.sql: hourly cron unchanged, still the backstop', () => {
  assert.match(cronSql, /functions\/v1\/plaid-sync/);
  assert.ok(!cronSql.includes('try_claim_sync_lock'), 'the cron must not claim the lock itself — plaid-sync does');
  assert.ok(!cronSql.includes('plaid_sync_locks'), 'the cron must not touch the lock table');
});
