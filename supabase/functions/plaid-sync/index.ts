// plaid-sync (S3 rewrite) — pulls Amex transactions via Plaid
// Deploy note (Nov 2, 2026): redeploying so this function picks up the current SERVICE_ROLE_SECRET value.
// /transactions/sync and writes them for S2's compute-week/week-close.
//
// What this function owns (audit items): P0-10b (card-payment kind),
// P0-13 (pending→posted linking), P1-3 (removed[]), P1-4 (canonical
// dedupe + coexistence), P1-15 (cursor load/persist, pagination),
// P1-16 function-side (see note below), plaid_accounts upsert,
// institution backfill, disconnected-item skip.
//
// Security / token handling (unchanged pattern from v2):
//   * The access token is never in the database in plaintext. It is
//     fetched (ciphertext only) via the get_plaid_ciphertext RPC, which
//     checks the caller's membership, then decrypted IN MEMORY with
//     PLAID_TOKEN_KEY (Edge Function secrets only). It is never logged
//     and never returned to the client. No client ever receives token
//     ciphertext: the plaid_items_public view concept is S1's vault
//     file — this function does not expose plaid_items rows.
//   * P1-16 RESIDUAL, resolved in repo (deep audit Nov 5):
//     supabase/07-service-rpc-access.sql restricts
//     get_plaid_ciphertext / update_plaid_sync to service_role only;
//     the old "still granted to authenticated" note above is stale.
//     This function does NOT widen them: it writes a cursor only with
//     the value Plaid itself returned for that item, only after a page
//     sequence completes without a Plaid error, and never from a
//     client-supplied value.
//   * Auth (server-sync build, Nov 2, 2026): verify_jwt=false in
//     config.toml + in-code auth (admin JWT for manual sync, or the
//     service-key bearer for server calls from plaid-webhook / pg_cron).
//     A bare call with neither credential 401s. Manual sync is
//     admin-only (owner decision 15).
//
// Plaid amounts: positive for outflows, negative for inflows. The app
// stores charges positive and inflows negative, so Plaid's sign maps
// directly (amount_cents = round(tx.amount * 100)).
//
// Kind classification (P0-10b): see _shared/canonical.ts. A transaction
// is kind='payment' if Plaid's personal_finance_category indicates a
// credit-card payment OR the merchant name matches
// /MOBILE PAYMENT|PAYMENT - THANK YOU|CARD PAYMENT/i. kind='cashback'
// for /CASH BACK|CASHBACK|REWARD/i. Real refunds (e.g. an Amazon return)
// match neither pattern and stay kind='refund'. Payments and cashback
// are NOT refunds and must never create refund credit — that exclusion
// is S2's week-math rule; this function only labels them correctly.
//
// State mapping (compute-week interface, S2 consumes these verbatim):
//   pending Plaid row  -> state='provisional'
//   posted Plaid row   -> state='verified'
//   removed Plaid row  -> state='reversed' AND excluded=true ONLY for a
//                         row with no replacement in this sync or in a
//                         recent window of household rows (never
//                         deleted; append-only, audit P1-3).
//                         Build 44 change 1 (Nov 18, 2026): a
//                         PROVISIONAL row in removed[] is left untouched
//                         when a replacement / re-issue signal exists
//                         — a pending tx disappearing is normal, it
//                         posted under a new id — and a verified row
//                         with a same-merchant+amount+date+card_suffix
//                         replacement is LINKED to the new id (kind
//                         kept, duplicate arrival row excluded), not
//                         trashed; a same-triple arrival on another
//                         card is still a re-issue, left untouched.
//                         Build 58 (owner, Nov 22, 2026): a
//                         PROVISIONAL row with NO replacement signal
//                         anywhere is now excluded too (auto-reverse:
//                         the pending transaction truly disappeared
//                         and will never post). See decideRemovedRow
//                         in canonical.ts. The removed[] matcher
//                         uses ONLY the row's live ids — never
//                         plaid_pending_transaction_id, which still
//                         holds the old pending id after a
//                         pending→posted link.
//                         Removed rows are decided AFTER the whole
//                         item's pages are read, so a replacement on a
//                         later page still counts. See decideRemovedRow
//                         in canonical.ts.
//   NOTE on provisional refunds: spec FINAL A4 says a pending refund
//   restores nothing until it posts. This function labels the row
//   provisional; S2 MUST exclude provisional refunds from week math
//   and restoration until state='verified' (audit P0-12, S2-owned).
//   Provisional CHARGES counting is the intended provisional behaviour.
//
// Dedupe / upsert order (P1-4, P0-13) — for every added/modified tx:
//   1. existing row with external_id = tx.transaction_id, else
//   2. existing row with external_id = tx.pending_transaction_id, or
//      plaid_pending_transaction_id = tx.pending_transaction_id, else
//   3. canonical-hash MATCH (same household + dedupe_hash) — used only
//      to update an existing cross-source row (e.g. an earlier Gmail
//      alert row, source in EMAIL_SOURCES), never as a uniqueness constraint,
//      never to overwrite an unrelated identical purchase, else
//   3b. suffix-0000 fallback: same merchant + date + amount, source in
//      EMAIL_SOURCES, card_suffix '0000' (the alert never knew the
//      card ending), earliest first, else
//   3c. Plaid hash fallback (build 44 change 1 expansion): a POSTED
//      tx with no pending_transaction_id claims the EARLIEST matching
//      provisional PLAID row by dedupe_hash — never a verified row,
//      so two identical real purchases still coexist, else
//   4. insert a new row.
// Merged-audit A14/A15/B6: a re-delivery never overwrites a trashed
// row's state/excluded, never overwrites an admin-set kind (kind is
// set at insert only; posting changes state, not kind), a hash match
// only ever claims a Gmail-alert row — except step 3c, which claims
// the earliest provisional Plaid row for a posted tx with no pending
// link (never a verified Plaid row) — and a full pull (cursor NULL)
// drops pre-2026-11-01 rows for the household afterwards, so a
// cursor reset cannot re-import September/October history.
//   A posted version therefore UPDATES its pending row (amount/state
//   corrected, e.g. $40 authorization -> $48 with tip) instead of
//   inserting a second row. Two identical real purchases coexist
//   because they have distinct external_ids / row ids; the hash alone
//   never blocks an insert.
//
// Refund linkage (P0-1, Nov 8, 2026): Plaid's /transactions/sync
// payload carries NO refund-to-original-purchase link field, so the
// link is made after insert by supabase/refund-linking.sql —
// auto_link_refund for a refund row (exact-amount, same card, same
// normalized merchant, 90-day window, exactly one candidate) and
// link_refunds_to_purchase for a charge row (reverse direction, so a
// refund that arrived first still gets linked). A null
// original_purchase_id refund is unlinked, never invented.
//
// Sync cursor (P1-15): loaded from plaid_items.sync_cursor at start,
// persisted via update_plaid_sync at end. Pagination runs until
// has_more is false, with a safety cap of 200 pages: hitting the cap
// LOGS a warning (console.warn) and returns truncated:true — it never
// silently truncates. A partial cursor IS persisted on cap (that is
// progress, not loss: the next run resumes from it). On a Plaid error
// mid-sequence the cursor is NOT persisted, so the next run re-pulls
// the same pages idempotently via the upsert order above.
//
// Overlap safety (build 44, item 3): overlapping sync runs ARE
// serialised — plaid-sync claims a per-household lock
// (try_claim_sync_lock, supabase/plaid-sync-lock.sql, TTL ~10 min)
// right after auth, before loading items; a run that finds the lock
// held returns 200 { sync_skipped: 'already_running' } and does
// nothing. Upserts stay idempotent (external_id / pending / hash
// matching updates instead of duplicating) and the cursor only moves
// forward, so a stale cursor just re-pulls idempotently — the lock
// covers the interleaving the upserts cannot: two runs sharing one
// cursor and interleaving page sequences. An insert that still loses
// a race under the same external_id (unique-violation 23505) is
// re-selected and updated instead of reported insert-failed.
//
// Institution backfill: when plaid_items.institution_name is null,
// call Plaid /item/get (for institution_id) then
// /institutions/get_by_id and store institution_name + institution_id.
// Uses the same client_id/secret Plaid pattern as the rest of this
// file; no new auth flow is invented.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { accrueCharityForIncomeTx, applyMerchantRuleToMerchant, canonicalHash, classifyKind, decideRemovedRow, EMAIL_SOURCES, flagLookalikes, loadMerchantRules, normalizeMerchant, pickPlaidHashClaim, type MerchantRule, type RemovedReplacement, type SyncArrivalLike } from './canonical.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const MAX_PAGES = 200;

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function decryptToken(keyB64: string, b64: string): Promise<string> {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const iv = bytes.slice(0, 12);
  const ct = bytes.slice(12);
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, ct);
  return new TextDecoder().decode(pt);
}

// Duplicate-connection guard (excluded-decisions, owner Nov 3, 9:42 PM).
// Mirrors duplicateConnection.mjs on the client: a connection is a
// duplicate ONLY when every account it carries is already carried by
// ONE older, still-active connection at the SAME institution, matched
// on mask AND account name. Mask alone is not identity (two cards
// can share a last-4); anything unprovable fails OPEN (returns null)
// so a legitimate connection is never removed on a guess. The two
// implementations must stay in step — see duplicateConnection.mjs.
function normDup(v: unknown): string {
  return String(v ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
}
type DupAcct = { mask?: string | null; name?: string | null };
type DupItem = {
  plaid_item_id: string; institution_name?: string | null;
  created_at?: string | null; accounts: DupAcct[];
};
function findDuplicateKeeper(
  candidate: DupItem,
  keepers: DupItem[],
): string | null {
  if (!candidate.accounts || candidate.accounts.length === 0) return null;
  const candInst = normDup(candidate.institution_name);
  if (!candInst) return null;
  for (const acct of candidate.accounts) {
    if (!normDup(acct.mask) || !normDup(acct.name)) return null;
  }
  for (const keeper of keepers) {
    if (keeper.plaid_item_id === candidate.plaid_item_id) continue;
    if (normDup(keeper.institution_name) !== candInst) continue;
    if (!keeper.created_at || !candidate.created_at) continue;
    if (!(String(keeper.created_at) < String(candidate.created_at))) continue;
    const covered = candidate.accounts.every((acct) =>
      keeper.accounts.some((k) =>
        normDup(k.mask) === normDup(acct.mask) &&
        normDup(k.name) === normDup(acct.name)
      )
    );
    if (covered) return keeper.plaid_item_id;
  }
  return null;
}

function plaidBase(env: string): string {
  return `https://${env === 'production' ? 'production' : env}.plaid.com`;
}

async function plaidPost(
  base: string,
  path: string,
  clientId: string,
  secret: string,
  body: Record<string, unknown>,
): Promise<{ ok: boolean; data: Record<string, any> }> {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: clientId, secret, ...body }),
  });
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok, data };
}

// P2-N11 (Nov 8, 2026): refund linking is best-effort and must never
// fail the sync — but a missing-SQL deploy used to be swallowed
// silently (supabase-js returns { error }, it does not throw, so the
// old bare catch never even saw it). The rpc invocations stay inline
// at the call sites (the P0-1 test pins that shape); this helper only
// centralises the server-side log line, so a missed apply is
// observable in function logs.
function logLinkError(error: unknown): void {
  if (error) console.error('plaid-sync: refund linking failed (best-effort):', (error as { message?: unknown })?.message ?? error);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  // Build 44 (item 3): the lock releaser lives outside the try so
  // the catch below can release on the error path too. It is null
  // until the lock is claimed (after auth, below).
  let releaseLock: (() => Promise<void>) | null = null;
  try {
    // Auth (server-sync build, Nov 2, 2026): verify_jwt=false in
    // config.toml, so the platform check is OFF and this in-code check
    // is the only gate. Two paths, in order:
    //   1. Server path: Bearer == SERVICE_ROLE_SECRET (non-empty both,
    //      timing-safe compare). Used by plaid-webhook and the hourly
    //      pg_cron job. No member check: the server is trusted, and
    //      the household comes from the request body.
    //   2. Manual path: a user JWT. The caller must be an ADMIN member
    //      of the household (owner decision 15: manual sync is
    //      admin-only once server sync is live; previously any member
    //      could sync).
    // Anything else (no bearer, wrong key, invalid JWT, non-admin
    // member) is rejected. A bare call with neither credential 401s.
    const auth = req.headers.get('Authorization') ?? '';
    const token = auth.startsWith('Bearer ') ? auth.slice('Bearer '.length) : '';
    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const body = await req.json().catch(() => ({}));
    const householdId = String(body.household_id ?? '');
    if (!householdId) return json({ error: 'household_id required' }, 400);
    const isServerCall = token !== '' && serviceKey !== '' && timingSafeEqual(token, serviceKey);
    if (!isServerCall) {
      if (!token) return json({ error: 'missing authorization' }, 401);
      const supabase = createClient(
        Deno.env.get('SUPABASE_URL')!,
        Deno.env.get('SUPABASE_ANON_KEY')!,
        { global: { headers: { Authorization: auth } } },
      );
      const { data: { user }, error: userErr } = await supabase.auth.getUser();
      if (userErr || !user) return json({ error: 'unauthorized' }, 401);
      const { data: membership } = await supabase
        .from('household_members')
        .select('role')
        .eq('household_id', householdId)
        .eq('user_id', user.id)
        .maybeSingle();
      if (!membership || membership.role !== 'admin') return json({ error: 'manual sync is admin-only' }, 403);
    }
    // All DB access below uses the service-role key (server-side only,
    // never in the browser) because member JWTs lost direct table/RPC
    // access in the S1 RLS hardening.
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    // Build 44 (item 3): overlap lock — claim right after auth /
    // household validation, before loading items. A held lock is a
    // 200 skip, not an error; the other run does the work. Fail OPEN
    // when the lock SQL has not been applied yet (the RPC errors):
    // log it and sync normally, so a function deploy ahead of the
    // dashboard apply never blocks sync.
    const lockOwner = `plaid-sync:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    let lockHeld = false;
    try {
      const { data: claimed, error: lockErr } = await supabaseAdmin.rpc('try_claim_sync_lock', {
        p_household_id: householdId, p_owner: lockOwner, p_ttl_seconds: 600,
      });
      if (lockErr) {
        console.error('plaid-sync: lock claim failed (syncing without lock):', lockErr.message ?? lockErr);
      } else if (claimed === true) {
        lockHeld = true;
      } else {
        return json({ sync_skipped: 'already_running' });
      }
    } catch (e) {
      console.error('plaid-sync: lock claim threw (syncing without lock):', (e as Error)?.message ?? e);
    }
    releaseLock = async (): Promise<void> => {
      if (!lockHeld) return;
      lockHeld = false;
      try {
        await supabaseAdmin.rpc('release_sync_lock', { p_household_id: householdId, p_owner: lockOwner });
      } catch { /* the lock expires on its own; never fail the sync */ }
    };

    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret || !tokenKey) { await releaseLock?.(); return json({ error: 'plaid not configured' }, 503); }
    const base = plaidBase(env);

    const { data: items } = await supabaseAdmin.from('plaid_items')
      .select('plaid_item_id, institution_name, institution_id, sync_cursor, status, created_at, last_sync_at')
      .eq('household_id', householdId);
    // Build 30 (merchant rules): load the household's rules once
    // for the whole sync; upsertPlaidTx applies the best rule to
    // each merchant BEFORE the hash, so a bank row and its email
    // alert hash identically. Best-effort: no rules = old behaviour.
    const merchantRules = await loadMerchantRules(supabaseAdmin, householdId);
    const allItems = items ?? [];
    // Oldest first: the duplicate guard keeps the oldest connection
    // and removes a newer one that fully duplicates it.
    const activeItems = allItems
      .filter((i) => (i.status ?? 'active') !== 'disconnected')
      .sort((a, b) => String(a.created_at ?? '9999') < String(b.created_at ?? '9999') ? -1 : 1);
    // Keeper account map for the duplicate guard: plaid_accounts rows
    // grouped by item, for active items only. Disconnected items are
    // excluded, so reconnecting after a disconnect still works.
    // Connected-accounts-rework: per-account disconnected accounts
    // (disconnected_at set) are ALSO excluded — otherwise reconnecting
    // one account via Plaid Link would look like a full duplicate of
    // the old item (which still carries that account's row) and the
    // new item would be removed on a guess.
    const keeperAccounts = new Map<string, DupAcct[]>();
    // Per-account disconnect set (connected-accounts-rework): Plaid
    // account_ids whose transactions this sync must skip. Loaded once
    // for the household, checked per transaction below. Past
    // transactions are never deleted; only new/changed rows for these
    // accounts are ignored.
    const disconnectedAccounts = new Set<string>();
    try {
      const { data: keeperRows } = await supabaseAdmin.from('plaid_accounts')
        .select('plaid_item_id, plaid_account_id, name, mask, disconnected_at').eq('household_id', householdId);
      for (const row of keeperRows ?? []) {
        if (row.disconnected_at) { disconnectedAccounts.add(String(row.plaid_account_id)); continue; }
        if (!activeItems.some((i) => i.plaid_item_id === row.plaid_item_id)) continue;
        const list = keeperAccounts.get(row.plaid_item_id) ?? [];
        list.push({ mask: row.mask, name: row.name });
        keeperAccounts.set(row.plaid_item_id, list);
      }
    } catch { /* guard data unavailable: the guard below fails open */ }
    const duplicateRemoved: string[] = [];
    const skippedDisconnected = allItems.length - activeItems.length;

    let added = 0, updated = 0, reversed = 0, skipped = 0;
    // Build 44 change 1: removed[] rows deliberately left untouched,
    // by reason — counted in the response, not as skips (they are
    // not sync failures). Provisional rows disappearing is normal;
    // re-issues are the new row being the live one; other covers
    // already-excluded / non-verified rows.
    let removedLeftProvisional = 0, removedLeftReissue = 0, removedLeftOther = 0;
    let removedLinked = 0;
    let truncated = false;
    // P2-B7 (Nov 8, 2026): skipped rows are now visible — every skip
    // is logged server-side with its reason, and the response carries
    // a per-reason breakdown (skipped_by_reason) alongside the total,
    // so the client can show it. Which rows are skipped is unchanged.
    const skipReasons: Record<string, number> = {};
    const logSkip = (itemId: string, reason: string) => {
      skipped += 1;
      skipReasons[reason] = (skipReasons[reason] ?? 0) + 1;
      console.warn(`plaid-sync: skipped (item ${itemId}): ${reason}`);
    };
    // P2-C5 (Nov 8, 2026): staleness signal. The client already shows
    // "Last bank sync" from plaid_items_public.last_sync_at; this
    // response also reports how long it had been since the previous
    // successful sync, so a dead hourly cron is visible instead of
    // silent. The cron runs hourly; a gap over 180 minutes means
    // scheduled sync has not run recently. The client warning itself
    // is a live.js follow-up — these fields are the API half.
    // NEW-R4-C3 (Nov 9, 2026): report the STALEST gap, not the
    // freshest. The old code took Math.max over last_sync_at (the
    // most recently synced item), so one healthy item hid a dead
    // one. gmail-poll already reports the max gap; this mirrors it.
    // Only active (non-disconnected) items count: a disconnected
    // item never syncs again, so its frozen stamp would pin stale
    // true forever. A never-synced item (null stamp) contributes no
    // gap, same as gmail-poll.
    const syncStartedAt = Date.now();
    const minutesSinceSync = (iso: string | null): number | null => {
      if (!iso) return null;
      const t = new Date(iso).getTime();
      if (!Number.isFinite(t)) return null;
      return Math.max(0, Math.floor((syncStartedAt - t) / 60000));
    };
    const prevGaps = activeItems
      .map((i: any) => minutesSinceSync(i.last_sync_at ?? null))
      .filter((n: number | null): n is number => n !== null);
    const minutesSincePreviousSync = prevGaps.length ? Math.max(...prevGaps) : null;
    const stale = minutesSincePreviousSync !== null && minutesSincePreviousSync > 180;
    // Deep audit Nov 5: Plaid failures on one item used to return 502
    // immediately, aborting all remaining items and skipping the
    // full-pull cleanup. Collect failures and keep going; the
    // aggregated failure is reported after the cleanup below.
    const failedItems: string[] = [];
    // P1-C1 (Nov 8, 2026): institutions of failed items, so the
    // sync toast can name them instead of 'plaid sync failed'.
    const failedInstitutions: string[] = [];
    // Merged-audit B6: set when any item started with a NULL cursor
    // (a full pull). The pre-Nov drop runs once, after all items,
    // so a second item's pull cannot re-add rows the first item's
    // drop removed.
    let fullPullSeen = false;

    for (const item of activeItems) {
      if (!item.sync_cursor) fullPullSeen = true;
      const { data: ct } = await supabaseAdmin.rpc('get_plaid_ciphertext', {
        p_household_id: householdId, p_item_id: item.plaid_item_id,
      });
      if (!ct) { logSkip(item.plaid_item_id, 'missing-token'); continue; }
      let accessToken: string;
      try {
        accessToken = await decryptToken(tokenKey, ct);
      } catch {
        logSkip(item.plaid_item_id, 'token-decrypt-failed');
        continue;
      }

      // --- /accounts/get: card suffixes + plaid_accounts upsert ---
      // Suffixes come from account.mask (the card's real last 4), NOT
      // from account_id (a Plaid UUID). Mask lookup failure is
      // best-effort for suffixes only; sync still proceeds.
      // The upsert deliberately does NOT list disconnected_at, so a
      // sync never clears a per-account disconnect flag.
      const maskByAccount = new Map<string, string>();
      // Refund-classification fix (Nov 5, 2026): Plaid's acc.type
      // ('depository' | 'credit' | ...) so a checking-account inflow
      // is never classified like a credit-card inflow.
      const typeByAccount = new Map<string, string>();
      try {
        const { ok, data: accData } = await plaidPost(base, '/accounts/get', clientId, secret, {
          access_token: accessToken,
        });
        if (ok) {
          for (const acc of accData.accounts ?? []) {
            if (acc.account_id && acc.mask) maskByAccount.set(acc.account_id, String(acc.mask));
            if (acc.account_id && acc.type) typeByAccount.set(acc.account_id, String(acc.type));
            if (acc.account_id) {
              const { error: accErr } = await supabaseAdmin.from('plaid_accounts').upsert({
                household_id: householdId,
                plaid_item_id: item.plaid_item_id,
                plaid_account_id: String(acc.account_id),
                name: acc.name ? String(acc.name) : null,
                mask: acc.mask ? String(acc.mask) : null,
                type: acc.type ? String(acc.type) : null,
                subtype: acc.subtype ? String(acc.subtype) : null,
              }, { onConflict: 'household_id,plaid_account_id' });
              if (accErr) logSkip(item.plaid_item_id, 'account-upsert-failed');
            }
          }
        }
      } catch { /* best-effort; sync still proceeds */ }

      // --- Duplicate-connection guard (b): if this item's accounts
      // are entirely already carried by an older active connection
      // at the same institution (mask + name, see helper above),
      // remove this item at Plaid and mark it disconnected — the
      // same semantics as plaid-disconnect: past transactions stay,
      // and the item is no longer listed. Any failure fails
      // OPEN: the item syncs normally instead of being removed on
      // a guess, and a removal failure never blocks the sync.
      {
        const candidateAccts: DupAcct[] = [];
        try {
          const { ok: dupOk, data: dupData } = await plaidPost(base, '/accounts/get', clientId, secret, {
            access_token: accessToken,
          });
          if (dupOk) {
            for (const acc of dupData.accounts ?? []) {
              if (acc.account_id && acc.mask) candidateAccts.push({ mask: String(acc.mask), name: acc.name ? String(acc.name) : null });
            }
          }
        } catch { /* accounts unavailable: cannot prove a duplicate */ }
        const keepers: DupItem[] = activeItems
          .filter((o) => o.plaid_item_id !== item.plaid_item_id)
          .map((o) => ({
            plaid_item_id: o.plaid_item_id,
            institution_name: o.institution_name,
            created_at: o.created_at,
            accounts: keeperAccounts.get(o.plaid_item_id) ?? [],
          }));
        const keeperId = findDuplicateKeeper(
          { plaid_item_id: item.plaid_item_id, institution_name: item.institution_name, created_at: item.created_at, accounts: candidateAccts },
          keepers,
        );
        if (keeperId) {
          let removeOk = false;
          let removeAttempted = false;
          try {
            const { data: dupCt } = await supabaseAdmin.rpc('get_plaid_ciphertext', {
              p_household_id: householdId, p_item_id: item.plaid_item_id,
            });
            if (dupCt) {
              removeAttempted = true;
              let dupToken: string | null = null;
              try { dupToken = await decryptToken(tokenKey, dupCt); } catch { dupToken = null; }
              if (dupToken) {
                const rm = await plaidPost(base, '/item/remove', clientId, secret, { access_token: dupToken });
                removeOk = rm.ok || String(rm.data?.error_code ?? '') === 'ITEM_NOT_FOUND';
              } else {
                // Disconnect fallback: no retrievable token, but the
                // local row can still be marked disconnected so sync
                // stops (the Plaid-side item may linger).
                removeOk = true;
              }
            } else {
              removeOk = true;
            }
          } catch { removeOk = false; }
          if (removeOk || !removeAttempted) {
            const { error: markErr } = await supabaseAdmin.from('plaid_items')
              .update({ status: 'disconnected', disconnected_at: new Date().toISOString() })
              .eq('household_id', householdId).eq('plaid_item_id', item.plaid_item_id);
            if (!markErr) {
              console.warn(`plaid-sync: removed duplicate item ${item.plaid_item_id} (accounts already on ${keeperId}); past transactions kept`);
              duplicateRemoved.push(item.plaid_item_id);
              continue;
            }
          }
          console.warn(`plaid-sync: duplicate check for ${item.plaid_item_id} could not remove it safely; syncing normally`);
        }
      }

      // --- Institution backfill (only when institution_name is null) ---
      if (!item.institution_name) {
        try {
          const { ok: itemOk, data: itemData } = await plaidPost(base, '/item/get', clientId, secret, {
            access_token: accessToken,
          });
          const institutionId = itemData?.item?.institution_id
            ? String(itemData.item.institution_id)
            : (item.institution_id ? String(item.institution_id) : null);
          if (itemOk && institutionId) {
            const { ok: instOk, data: instData } = await plaidPost(
              base, '/institutions/get_by_id', clientId, secret,
              { institution_id: institutionId, country_codes: ['US'] },
            );
            const institutionName = instOk && instData?.institution?.name
              ? String(instData.institution.name)
              : null;
            if (institutionName || institutionId) {
              await supabaseAdmin.from('plaid_items').update({
                institution_name: institutionName,
                institution_id: institutionId,
              }).eq('household_id', householdId).eq('plaid_item_id', item.plaid_item_id);
            }
          }
        } catch { /* best-effort; sync still proceeds */ }
      }

      // --- /transactions/sync with a LOADED cursor ---
      // Build 44 change 1: removed[] is decided AFTER the whole
      // item's pages are read (deferred block below the cursor
      // persist). syncArrivals collects every added/modified tx of
      // this sync in stored-row form (ruled display merchant +
      // signed cents + date + card suffix from the account mask),
      // so a replacement arriving on any page — including a later
      // page than the removed[] entry — still counts.
      // removedIdsThisItem collects the removed[] ids in
      // arrival order, deduplicated.
      const syncArrivals: SyncArrivalLike[] = [];
      const removedIdsThisItem: string[] = [];
      const seenRemovedIds = new Set<string>();
      let cursor: string | null = item.sync_cursor ?? null;
      let plaidFailed = false;
      let plaidErrorCode: string | null = null;
      for (let page = 0; page < MAX_PAGES; page++) {
        const { ok, data } = await plaidPost(base, '/transactions/sync', clientId, secret, {
          access_token: accessToken, cursor,
        });
        if (!ok) { plaidFailed = true; plaidErrorCode = String(data?.error_code ?? ''); break; }
        cursor = data.next_cursor ?? null;

        for (const tx of [...(data.added ?? []), ...(data.modified ?? [])]) {
          // Per-account disconnect (connected-accounts-rework): a
          // disconnected account's new/changed transactions are
          // ignored entirely. Past transactions already in the
          // database are untouched.
          if (tx.account_id && disconnectedAccounts.has(String(tx.account_id))) { logSkip(item.plaid_item_id, 'account-disconnected'); continue; }
          const upsert = await upsertPlaidTx(supabaseAdmin, householdId, tx, maskByAccount, typeByAccount, merchantRules);
          if (upsert.result === 'added') added++;
          else if (upsert.result === 'updated') updated++;
          else logSkip(item.plaid_item_id, upsert.reason ?? 'upsert-skipped');
          // Build 44 change 1: record this sync's arrival for the
          // deferred removed[] decision below — same derivation as
          // upsertPlaidTx (ruled display merchant, signed cents,
          // date, card suffix from the account mask, pending link).
          // Invalid amount/date rows never become arrivals (upsert
          // skips them too), so they can never shield a removed row.
          // The upserted row id rides along so a replacement link
          // can exclude the duplicate arrival row instead of
          // leaving two live rows for the same money.
          const arrivalSigned = Math.round(Number(tx.amount) * 100);
          const arrivalDate = String(tx.date ?? '').slice(0, 10);
          if (Number.isFinite(arrivalSigned) && /^\d{4}-\d{2}-\d{2}$/.test(arrivalDate)) {
            const arrivalMerchant = normalizeMerchant(String(tx.merchant_name ?? tx.name ?? 'UNKNOWN')).slice(0, 80);
            syncArrivals.push({
              merchant: applyMerchantRuleToMerchant(merchantRules, arrivalMerchant, arrivalSigned).merchant,
              date: arrivalDate,
              amount_cents: arrivalSigned,
              card_suffix: maskByAccount.get(tx.account_id) ?? '0000',
              external_id: tx.transaction_id ? String(tx.transaction_id) : null,
              state: tx.pending ? 'provisional' : 'verified',
              rowId: upsert.id ?? null,
              pending_transaction_id: tx.pending_transaction_id ? String(tx.pending_transaction_id) : null,
            });
          }
        }

        // removed[] (P1-3, build 44 change 1): collect only — the
        // decision runs after the page loop, against the full sync's
        // arrivals (a re-issue may arrive on a later page).
        for (const removed of data.removed ?? []) {
          const removedId = typeof removed === 'string'
            ? removed
            : String(removed.transaction_id ?? removed.id ?? '');
          if (!removedId || seenRemovedIds.has(removedId)) continue;
          seenRemovedIds.add(removedId);
          removedIdsThisItem.push(removedId);
        }

        if (!data.has_more) break;
        if (page === MAX_PAGES - 1) {
          truncated = true;
          console.warn(
            `plaid-sync: safety cap of ${MAX_PAGES} pages hit for item ${item.plaid_item_id}; ` +
              'has_more was still true. Cursor persisted for resume; response flags truncated:true.',
          );
        }
      }
      // Persist the cursor only after a page sequence that did not hit
      // a Plaid error. On error, the next run re-pulls idempotently.
      // P1-C1 (Nov 8, 2026): the persist result MUST be checked — a
      // silent failure here used to make EVERY later sync a full pull
      // forever (the cursor never advanced). A failed persist fails
      // this item loudly instead: it lands in failed_items and the
      // toast names its institution.
      if (!plaidFailed && cursor) {
        const { error: cursorErr } = await supabaseAdmin.rpc('update_plaid_sync', {
          p_household_id: householdId, p_item_id: item.plaid_item_id, p_cursor: cursor,
        });
        if (cursorErr) {
          console.error('plaid-sync: cursor persist failed for item', item.plaid_item_id, cursorErr.message);
          failedItems.push(item.plaid_item_id);
          failedInstitutions.push(item.institution_name ?? item.plaid_item_id);
          continue;
        }
      } else if (plaidFailed) {
        failedItems.push(item.plaid_item_id);
        failedInstitutions.push(item.institution_name ?? item.plaid_item_id);
        // Notifications (push-notify, Nov 16, 2026): an auth error
        // code means the bank connection is broken (the bank needs
        // re-login) — tell the admins. Best-effort; push-notify
        // dedupes to once per day per item, so the hourly sync does
        // not spam. Transient failures (rate limit, server errors)
        // do NOT notify.
        if (['ITEM_LOGIN_REQUIRED', 'INVALID_ACCESS_TOKEN', 'ITEM_NOT_FOUND'].includes(plaidErrorCode ?? '')) {
          try {
            await fetch(`${Deno.env.get('SUPABASE_URL')!}/functions/v1/push-notify`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${serviceKey}` },
              body: JSON.stringify({ type: 'bank_broken', household_id: householdId, item_id: item.plaid_item_id }),
            });
          } catch {
            console.error('plaid-sync: push-notify call failed');
          }
        }
        continue;
      }

      // --- Deferred removed[] decision (build 44, change 1) ---
      // Runs only after a page sequence that completed without a
      // Plaid error: the plaidFailed / cursor-persist-failure paths
      // above `continue`, so a partial sync never decides removals
      // on incomplete arrivals — the next run re-pulls and decides
      // with the full payload. Per row (decideRemovedRow):
      //   * provisional + a replacement / re-issue signal in this
      //     sync -> left untouched (posted under a new id);
      //     provisional + NO signal -> excluded (build 58: the
      //     pending transaction truly disappeared, auto-reverse);
      //   * verified + a same-merchant+amount+date+card_suffix
      //     replacement in this sync -> LINKED to the new id
      //     (kind kept; the duplicate arrival row is excluded, so
      //     the same money is never live twice);
      //   * verified + a same-triple arrival on another card (or a
      //     pending_transaction_id link to a live id) -> left
      //     untouched (a re-issue, not a reversal);
      //   * verified + no replacement in this sync -> a recent
      //     window of household rows is searched for the same
      //     quadruple; found -> linked the same way; not found ->
      //     state='reversed' + excluded=true. Never deletes
      //     (append-only). The matcher uses ONLY the row's live ids
      //     (external_id / plaid_transaction_id) — never
      //     plaid_pending_transaction_id, which still holds the old
      //     pending id after a pending→posted link.
      //
      // Link a removed row to its replacement: the row takes the
      // replacement's live ids + verified state (kind is NEVER
      // touched — an admin reclassification survives), and the
      // duplicate row is excluded so the same money is never live
      // twice. Refund links pointing at the duplicate are re-pointed
      // at the surviving row. Best-effort on the duplicate cleanup:
      // a failure there still leaves exactly one live row (the
      // linked one) plus the duplicate, which the next sync's
      // decision can revisit — it never fails the sync.
      const linkRemovedRow = async (row: { id: string }, replacement: RemovedReplacement): Promise<boolean> => {
        const { error } = await supabaseAdmin.from('transactions')
          .update({
            external_id: replacement.external_id,
            plaid_transaction_id: replacement.plaid_transaction_id,
            plaid_pending_transaction_id: replacement.pending_transaction_id,
            state: replacement.state,
          })
          .eq('id', row.id).eq('household_id', householdId);
        if (error) return false;
        const dupId = replacement.rowId;
        if (dupId && dupId !== row.id) {
          const { error: dupErr } = await supabaseAdmin.from('transactions')
            .update({ state: 'excluded', excluded: true })
            .eq('id', dupId).eq('household_id', householdId);
          if (!dupErr) {
            await supabaseAdmin.from('transactions')
              .update({ original_purchase_id: row.id })
              .eq('household_id', householdId).eq('original_purchase_id', dupId);
          }
        }
        return true;
      };
      // Recent-window replacement search (fix 2): the replacement
      // may have landed in an EARLIER sync than the removed[] entry
      // (Plaid reports the removal a run later). Same merchant +
      // amount + date + card_suffix, posted Plaid row, live,
      // created in the last 90 days, not the removed row itself.
      // The money outcome matches excluding (one live row either
      // way); linking keeps the removed row's kind/history alive.
      const findRecentReplacement = async (row: { id: string; merchant: string; date: string; amount_cents: number; card_suffix?: string | null }): Promise<RemovedReplacement | null> => {
        const since = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString();
        const { data } = await supabaseAdmin.from('transactions')
          .select('id, external_id, plaid_transaction_id, plaid_pending_transaction_id')
          .eq('household_id', householdId)
          .eq('merchant', row.merchant).eq('date', row.date)
          .eq('amount_cents', row.amount_cents).eq('card_suffix', row.card_suffix ?? '0000')
          .eq('source', 'plaid').eq('state', 'verified').eq('excluded', false)
          .neq('id', row.id)
          .gte('created_at', since)
          .order('created_at', { ascending: false }).limit(1).maybeSingle();
        if (!data || !data.external_id) return null;
        return {
          external_id: data.external_id,
          plaid_transaction_id: data.plaid_transaction_id ?? data.external_id,
          pending_transaction_id: data.plaid_pending_transaction_id ?? null,
          state: 'verified',
          rowId: data.id,
        };
      };
      for (const removedId of removedIdsThisItem) {
        const { data: row } = await supabaseAdmin.from('transactions')
          .select('id, state, excluded, merchant, date, amount_cents, card_suffix, external_id, plaid_transaction_id')
          .eq('household_id', householdId)
          .or(`external_id.eq.${removedId},plaid_transaction_id.eq.${removedId}`)
          .maybeSingle();
        if (!row) { logSkip(item.plaid_item_id, 'removed-not-found'); continue; }
        const decision = decideRemovedRow(row, syncArrivals);
        if (decision.action === 'leave') {
          // Build 58: a provisional row leaves only via a re-issue
          // signal now (it posted); count it as provisional-left.
          if (row.state === 'provisional') removedLeftProvisional++;
          else if (decision.reason.startsWith('reissue-')) removedLeftReissue++;
          else removedLeftOther++;
          console.log(`plaid-sync: removed ${removedId} left untouched (${decision.reason})`);
          continue;
        }
        if (decision.action === 'link' && decision.replacement) {
          const ok = await linkRemovedRow(row, decision.replacement);
          if (ok) {
            removedLinked++;
            console.log(`plaid-sync: removed ${removedId} linked to replacement ${decision.replacement.external_id} (${decision.reason})`);
          } else logSkip(item.plaid_item_id, 'removed-link-failed');
          continue;
        }
        // 'exclude' — last chance: a replacement from an earlier
        // sync (recent window) links the same way; only with no
        // replacement anywhere is the row a genuine reversal.
        const recent = await findRecentReplacement(row);
        if (recent) {
          const ok = await linkRemovedRow(row, recent);
          if (ok) {
            removedLinked++;
            console.log(`plaid-sync: removed ${removedId} linked to recent replacement ${recent.external_id} (replacement-in-recent-window)`);
          } else logSkip(item.plaid_item_id, 'removed-link-failed');
          continue;
        }
        const { error } = await supabaseAdmin.from('transactions')
          .update({ state: 'reversed', excluded: true })
          .eq('id', row.id).eq('household_id', householdId);
        if (error) {
          logSkip(item.plaid_item_id, 'removed-update-failed');
        } else {
          reversed++;
          // Refund-link guard (Nov 20, 2026 — Walmart case): a
          // genuine bank reversal strands any refund linked to this
          // purchase. Unlink it (no surviving row here) so it can
          // re-link or fall to the unlinked fallback instead of
          // restoring nothing. Best-effort: never fails the sync.
          try {
            const { error: repointErr } = await supabaseAdmin.rpc('repoint_refund_links', { p_from_id: row.id, p_to_id: null });
            if (repointErr) console.error('plaid-sync: refund unlink on reversal failed (best-effort):', repointErr.message ?? repointErr);
          } catch (e) {
            console.error('plaid-sync: refund unlink on reversal failed (best-effort):', (e as Error)?.message ?? e);
          }
        }
      }

      // A successful sync consumes pending webhook events for this item.
      await supabaseAdmin.from('webhook_events')
        .update({ processed: true })
        .eq('plaid_item_id', item.plaid_item_id)
        .eq('processed', false);
    }

    // Merged-audit B6 date guard, second layer (the first is the
    // Nov 1 filter the app start implies): after a full pull, drop
    // any re-pulled BANK row dated before 2026-11-01 for this household.
    // Deep audit Nov 5: the old version had no source filter, yet the
    // manual form and CSV import accept any date — a hand/CSV row
    // dated Oct 2026 was deleted on the next cursor-reset full pull.
    // Only source='plaid' rows are bank history; manual/csv/amex_alert
    // rows are never deleted here.
    if (fullPullSeen) {
      await supabaseAdmin.from('transactions')
        .delete().eq('household_id', householdId).eq('source', 'plaid').lt('date', '2026-11-01');
    }

    if (failedItems.length) {
      await releaseLock?.();
      return json({ error: 'plaid sync failed', failed_items: failedItems, failed_institutions: failedInstitutions, added, updated, reversed, skipped, skipped_by_reason: skipReasons, removed_left_provisional: removedLeftProvisional, removed_left_reissue: removedLeftReissue, removed_left_other: removedLeftOther, removed_linked: removedLinked, minutes_since_previous_sync: minutesSincePreviousSync, stale }, 502);
    }
    // Notifications (push-notify, Nov 16, 2026): best-effort, never
    // fail the sync. push-notify re-reads the new charges / incomes /
    // charity gifts itself and dedupes by dedupe_hash, so a purchase
    // already notified via email is not re-notified here. The 502
    // partial path above does NOT notify — a later successful sync
    // catches the purchases.
    if (added > 0) {
      try {
        await fetch(`${Deno.env.get('SUPABASE_URL')!}/functions/v1/push-notify`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${serviceKey}` },
          body: JSON.stringify({ type: 'new_transaction', household_id: householdId, source: 'plaid' }),
        });
        // Review queue: a sync can create possible duplicates.
        await fetch(`${Deno.env.get('SUPABASE_URL')!}/functions/v1/push-notify`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${serviceKey}` },
          body: JSON.stringify({ type: 'needs_review', household_id: householdId }),
        });
      } catch {
        console.error('plaid-sync: push-notify call failed');
      }
    }
    // Dedupe backstop (Nov 20, 2026 - Royal Farms): catch any
    // Bank+Email pair the ingestion guards missed (stale deploy,
    // transient error) and any refund link stranded on an excluded
    // purchase. Runs once per successful hourly sync, so a missed
    // pair surfaces within a day, not only when the owner spots it.
    // Best-effort: a missing SQL apply must never fail the sync.
    try {
      const { error: backstopErr } = await supabaseAdmin.rpc('backstop_bank_email_pairs', { p_household_id: householdId });
      if (backstopErr) console.error('plaid-sync: dedupe backstop failed (best-effort):', backstopErr.message ?? backstopErr);
    } catch (e) {
      console.error('plaid-sync: dedupe backstop failed (best-effort):', (e as Error)?.message ?? e);
    }
    await releaseLock?.();
    return json({
      added, updated, reversed, skipped, skipped_by_reason: skipReasons,
      removed_left_provisional: removedLeftProvisional,
      removed_left_reissue: removedLeftReissue,
      removed_left_other: removedLeftOther,
      removed_linked: removedLinked,
      minutes_since_previous_sync: minutesSincePreviousSync, stale,
      duplicate_removed: duplicateRemoved,
      items: allItems.length,
      connected_items: activeItems.length,
      skipped_disconnected: skippedDisconnected,
      truncated,
      ...(allItems.length === 0 ? { no_bank_connected: true } : {}),
    });
  } catch (e) {
    console.error('plaid-sync failed:', (e as Error)?.message ?? e);
    try { await releaseLock?.(); } catch { /* never fail the error path */ }
    return json({ error: 'bank sync failed' }, 500);
  }
});

// Upsert order: external_id -> pending_transaction_id -> canonical-hash
// match (email rows) -> suffix-0000 email fallback -> Plaid hash
// fallback (earliest provisional Plaid row, posted tx only) -> insert.
// Returns the upserted row id so the caller can record arrivals.
async function upsertPlaidTx(
  // deno-lint-ignore no-explicit-any
  supabaseAdmin: any,
  householdId: string,
  tx: Record<string, any>,
  maskByAccount: Map<string, string>,
  typeByAccount?: Map<string, string>,
  rules: MerchantRule[] = [],
): Promise<{ result: 'added' | 'updated' | 'skipped'; reason?: string; id?: string }> {
  const signed = Math.round(Number(tx.amount) * 100);
  if (!Number.isFinite(signed)) return { result: 'skipped', reason: 'invalid-amount' };
  const merchantRaw = String(tx.merchant_name ?? tx.name ?? 'UNKNOWN');
  const merchant = normalizeMerchant(merchantRaw).slice(0, 80);
  // Build 30 (merchant rules): the rule's display name is what is
  // stored AND hashed, so the bank row and its email alert (ruled
  // the same way) hash identically. A rule's fixed kind overrides
  // the classifier (sign-guarded inside); otherwise classify on the
  // ORIGINAL name, so name patterns (PAYMENT, INTERNAL TRANSFER,
  // CHARITY, ...) still match as before.
  const ruled = applyMerchantRuleToMerchant(rules, merchant, signed);
  const displayMerchant = ruled.merchant;
  const date = String(tx.date ?? '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return { result: 'skipped', reason: 'invalid-date' };
  const suffix = maskByAccount.get(tx.account_id) ?? '0000';
  const hash = await canonicalHash(displayMerchant, date, signed, suffix);
  const kind = ruled.kindOverride
    ? (ruled.kindOverride as ReturnType<typeof classifyKind>)
    : classifyKind(tx, merchantRaw, signed, typeByAccount?.get(tx.account_id));
  const state = tx.pending ? 'provisional' : 'verified';
  const txId = tx.transaction_id ? String(tx.transaction_id) : null;
  const pendingTxId = tx.pending_transaction_id ? String(tx.pending_transaction_id) : null;

  const row = {
    household_id: householdId, date, merchant: displayMerchant,
    amount_cents: signed, card_suffix: suffix, source: 'plaid',
    state, kind,
    external_id: txId, dedupe_hash: hash,
    plaid_transaction_id: txId,
    plaid_pending_transaction_id: pendingTxId,
    // original_purchase_id starts null; the link is made just after
    // insert by auto_link_refund / link_refunds_to_purchase (P0-1).
    original_purchase_id: null,
  };

  // 1. external_id (this transaction's own id).
  let existing: { id: string; state?: string | null; excluded?: boolean | null; source?: string | null; kind?: string | null } | null = null;
  if (txId) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source,kind')
      .eq('household_id', householdId).eq('external_id', txId).maybeSingle();
    existing = data;
  }
  // 2. pending_transaction_id linkage (pending -> posted transition).
  if (!existing && pendingTxId) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source,kind')
      .eq('household_id', householdId)
      .or(`external_id.eq.${pendingTxId},plaid_pending_transaction_id.eq.${pendingTxId}`)
      .maybeSingle();
    existing = data;
  }
  // 3. canonical-hash MATCH ONLY (cross-source, e.g. Gmail alert row).
  //    Merged-audit A15: never a uniqueness constraint, and never a
  //    claim on an unrelated identical purchase — only a row whose
  //    source is in EMAIL_SOURCES (the email alert the hash was built
  //    to link) may be claimed here. Two identical real purchases keep
  //    coexisting, and the earliest matching alert row is the claim.
  if (!existing) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source,kind')
      .eq('household_id', householdId).eq('dedupe_hash', hash)
      .in('source', [...EMAIL_SOURCES])
      .order('created_at', { ascending: true }).limit(1).maybeSingle();
    existing = data;
  }
  // 3b. Suffix-unknown fallback (Nov 12, 2026 — provisional-merge
  //     miss, owner-reported doubles): an Amex alert whose email
  //     carried no card ending is stored with card_suffix '0000', so
  //     its dedupe_hash can NEVER equal the bank row's hash (real
  //     suffix) and the exact match above misses — the purchase then
  //     shows twice (email row + bank row). When the exact match
  //     misses, also claim the earliest alert row with the same
  //     normalized merchant + date + signed amount whose suffix is
  //     '0000' (the suffix was never known, not a different card).
  //     Same guards as the exact match: source in EMAIL_SOURCES only,
  //     earliest first. Two identical real purchases still coexist
  //     — the claim consumes one alert row; a second bank row finds
  //     no alert row left and inserts its own. The TOIREMORG $2
  //     pair is unaffected (merchant strings differ). LIMIT: this
  //     does not close a merchant-string gap — if Plaid's merchant
  //     carries a store number the alert lacks (e.g. "ROYAL FARMS
  //     #123" vs "ROYAL FARMS"), neither the hash nor this match
  //     fires; that gap is now closed one merchant at a time by
  //     merchant_rules (build 30): both sides are ruled to the same
  //     display name before hashing, so the hash matches. The
  //     remaining gap is only for merchants nobody has taught yet,
  //     and those fall through to the auto-merge / review path below.
  if (!existing) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source,kind')
      .eq('household_id', householdId)
      .eq('merchant', displayMerchant).eq('date', date).eq('amount_cents', signed)
      .in('source', [...EMAIL_SOURCES]).eq('card_suffix', '0000')
      .order('created_at', { ascending: true }).limit(1).maybeSingle();
    existing = data;
  }

  // 3c. Plaid hash fallback (build 44 change 1 expansion, fix 3):
  //     a POSTED tx with NO pending_transaction_id misses the
  //     pending lookup above, and the hash match (step 3) only claims
  //     EMAIL_SOURCES rows — so the posted tx used to insert a second
  //     row next to its own provisional predecessor. Claim the
  //     EARLIEST matching provisional PLAID row by dedupe_hash.
  //     Guards (pickPlaidHashClaim, re-checked on the fetched row):
  //     provisional only, never a verified row — two identical real
  //     purchases still coexist — and never an excluded row.
  //     Gated on the incoming tx being posted: a pending tx must not
  //     consume a provisional predecessor.
  if (!existing && state === 'verified') {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source,kind')
      .eq('household_id', householdId).eq('dedupe_hash', hash)
      .eq('source', 'plaid').eq('state', 'provisional').eq('excluded', false)
      .order('created_at', { ascending: true }).limit(1).maybeSingle();
    existing = pickPlaidHashClaim(data ? [data] : []);
  }

  if (existing) {
    // Merged-audit A14: a re-delivery never overwrites Trash state
    // (state='excluded', excluded=true) and never overwrites kind —
    // kind is set at insert only, so an admin reclassification
    // survives the next sync. A trashed row gets only the bank
    // facts refreshed (date/merchant/amount/suffix/ids); a live row
    // also gets its pending->posted state transition.
    const trashed = existing.excluded === true || existing.state === 'excluded';
    const update: Record<string, unknown> = {
      date, merchant: displayMerchant, amount_cents: signed, card_suffix: suffix,
      external_id: txId, dedupe_hash: hash,
      plaid_transaction_id: txId, plaid_pending_transaction_id: pendingTxId,
    };
    if (!trashed) update.state = state;
    const { error } = await supabaseAdmin.from('transactions').update(update)
      .eq('id', existing.id).eq('household_id', householdId);
    if (error) return { result: 'skipped', reason: 'update-failed' };
    // P0-1 (Nov 8, 2026): a refund re-delivered after the purchase (or
    // after refund-linking.sql went live) gets its link now. Idempotent
    // — auto_link_refund returns null when already linked. Best-effort:
    // never fails the sync (P2-N11: the rpc result is checked and
    // logged via logLinkError, so a missed SQL apply is observable
    // instead of silent).
    if (kind === 'refund') {
      try {
        const { error: linkErr } = await supabaseAdmin.rpc('auto_link_refund', { p_refund_id: existing.id });
        logLinkError(linkErr);
      } catch (e) {
        logLinkError(e);
      }
    }
    // Build 44 (item 5): pending→posted transition of an income row
    // accrues charity at the household default rate. VERIFIED-only:
    // a row that was already verified accrued at insert (or on an
    // earlier transition). The stored kind governs (kind is set at
    // insert only, never overwritten — merged-audit A14), and the
    // helper skips rows already linked. Best-effort, never fails sync.
    if (!trashed && state === 'verified' && existing.state !== 'verified') {
      await accrueCharityForIncomeTx(supabaseAdmin, householdId, existing.id, existing.kind ?? kind, state);
    }
    return { result: 'updated', id: existing.id };
  }
  const { data: inserted, error } = await supabaseAdmin.from('transactions').insert(row).select('id, created_at').single();
  if (error || !inserted) {
    // Build 44 (item 3): a concurrent sync (or a re-delivery racing
    // this one) can win the insert under the same external_id — the
    // partial unique index from supabase/dedupe-fix.sql rejects the
    // second insert with 23505. Re-select by external_id and update
    // the row that won instead of reporting insert-failed.
    if (error && txId && (error.code === '23505' || /duplicate key/i.test(error.message ?? ''))) {
      const { data: raced } = await supabaseAdmin.from('transactions').select('id,state,excluded,source,kind')
        .eq('household_id', householdId).eq('external_id', txId).maybeSingle();
      if (raced) {
        const racedTrashed = raced.excluded === true || raced.state === 'excluded';
        const retryUpdate: Record<string, unknown> = {
          date, merchant: displayMerchant, amount_cents: signed, card_suffix: suffix,
          external_id: txId, dedupe_hash: hash,
          plaid_transaction_id: txId, plaid_pending_transaction_id: pendingTxId,
        };
        if (!racedTrashed) retryUpdate.state = state;
        const { error: retryErr } = await supabaseAdmin.from('transactions').update(retryUpdate)
          .eq('id', raced.id).eq('household_id', householdId);
        if (!retryErr) {
          if (kind === 'refund') {
            try {
              const { error: linkErr } = await supabaseAdmin.rpc('auto_link_refund', { p_refund_id: raced.id });
              logLinkError(linkErr);
            } catch (e) {
              logLinkError(e);
            }
          }
          if (!racedTrashed && state === 'verified' && raced.state !== 'verified') {
            await accrueCharityForIncomeTx(supabaseAdmin, householdId, raced.id, raced.kind ?? kind, state);
          }
          return { result: 'updated', id: raced.id };
        }
      }
    }
    return { result: 'skipped', reason: 'insert-failed' };
  }
  // P0-1 (Nov 8, 2026): link this row to its purchase/refund so
  // restoration can reach it (supabase/refund-linking.sql). A refund
  // auto-links to its one exact-amount purchase; a charge links any
  // earlier unlinked refund to itself. Best-effort: never fails sync
  // (P2-N11: the rpc result is checked and logged via logLinkError,
  // so a missed SQL apply is observable instead of silent).
  try {
    if (kind === 'refund') {
      const { error: linkErr } = await supabaseAdmin.rpc('auto_link_refund', { p_refund_id: inserted.id });
      logLinkError(linkErr);
    } else if (kind === 'charge' || kind === 'fund_charge') {
      const { error: linkErr } = await supabaseAdmin.rpc('link_refunds_to_purchase', { p_purchase_id: inserted.id });
      logLinkError(linkErr);
    }
  } catch (e) {
    logLinkError(e);
  }
  // Build 30 auto-merge (task I): a new bank row may complete a
  // Bank+Email pair the exact-hash / suffix-0000 claims above did
  // not catch (different spellings, dates up to 2 days apart).
  // try_auto_merge_bank_email merges it server-side (bank row kept,
  // email row excluded) or refuses — TOIREMORG pairs, already
  // resolved pairs, ambiguous pairs and two-bank pairs never merge.
  // Best-effort: never fails the sync; a missing SQL apply is
  // logged, not swallowed.
  try {
    const { data: mergeResult, error: mergeErr } = await supabaseAdmin.rpc('try_auto_merge_bank_email', { p_bank_txn_id: inserted.id });
    if (mergeErr) console.error('plaid-sync: auto-merge RPC failed (best-effort):', mergeErr.message ?? mergeErr);
    else if (mergeResult && String(mergeResult).startsWith('merged')) {
      console.log(`plaid-sync: auto-merged email row into bank row ${inserted.id} (${mergeResult})`);
    }
  } catch (e) {
    console.error('plaid-sync: auto-merge RPC failed (best-effort):', (e as Error)?.message ?? e);
  }
  // Lookalike review (Nov 3 Amazon case): a same-date/amount/suffix
  // row with a related merchant name is flagged for admin review,
  // never auto-merged. Best-effort: never fails the sync.
  await flagLookalikes(supabaseAdmin, householdId, {
    id: inserted.id, merchant: displayMerchant, date, amount_cents: signed,
    card_suffix: suffix, source: 'plaid', created_at: inserted.created_at,
  });
  // Build 44 (item 5): a newly inserted VERIFIED income row accrues
  // charity now; a provisional one accrues on its pending→posted
  // transition above. Best-effort, never fails the sync.
  await accrueCharityForIncomeTx(supabaseAdmin, householdId, inserted.id, kind, state);
  return { result: 'added', id: inserted.id };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
