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
//   removed Plaid row  -> state='reversed' AND excluded=true (never
//                         deleted; append-only, audit P1-3)
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
//      alert row, source='amex_alert'), never as a uniqueness constraint,
//      never to overwrite an unrelated identical purchase, else
//   4. insert a new row.
// Merged-audit A14/A15/B6: a re-delivery never overwrites a trashed
// row's state/excluded, never overwrites an admin-set kind (kind is
// set at insert only; posting changes state, not kind), a hash match
// only ever claims a Gmail-alert row, and a full pull (cursor NULL)
// drops pre-2026-11-01 rows for the household afterwards, so a
// cursor reset cannot re-import September/October history.
//   A posted version therefore UPDATES its pending row (amount/state
//   corrected, e.g. $40 authorization -> $48 with tip) instead of
//   inserting a second row. Two identical real purchases coexist
//   because they have distinct external_ids / row ids; the hash alone
//   never blocks an insert.
//
// Refund linkage (best-effort, documented limit): Plaid's
// /transactions/sync payload carries NO refund-to-original-purchase
// link field, so original_purchase_id is left NULL for Plaid refunds
// in this function. Setting it by merchant+amount window matching is
// NOT reliable and is deliberately not done here; a real matcher is
// S2/future work. S2 must treat a null original_purchase_id refund as
// unlinked, never invent a link.
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
// Overlap safety (server-sync build): overlapping sync runs need no
// lock — upserts are idempotent (external_id / pending / hash
// matching updates instead of duplicating) and the cursor only moves
// forward, so a stale cursor just re-pulls idempotently.
//
// Institution backfill: when plaid_items.institution_name is null,
// call Plaid /item/get (for institution_id) then
// /institutions/get_by_id and store institution_name + institution_id.
// Uses the same client_id/secret Plaid pattern as the rest of this
// file; no new auth flow is invented.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { canonicalHash, classifyKind, flagLookalikes, normalizeMerchant } from './canonical.ts';

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
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

    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret || !tokenKey) return json({ error: 'plaid not configured' }, 503);
    const base = plaidBase(env);

    const { data: items } = await supabaseAdmin.from('plaid_items')
      .select('plaid_item_id, institution_name, institution_id, sync_cursor, status, created_at')
      .eq('household_id', householdId);
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
    let truncated = false;
    // Deep audit Nov 5: Plaid failures on one item used to return 502
    // immediately, aborting all remaining items and skipping the
    // full-pull cleanup. Collect failures and keep going; the
    // aggregated failure is reported after the cleanup below.
    const failedItems: string[] = [];
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
      if (!ct) { skipped++; continue; }
      let accessToken: string;
      try {
        accessToken = await decryptToken(tokenKey, ct);
      } catch {
        skipped++;
        continue;
      }

      // --- /accounts/get: card suffixes + plaid_accounts upsert ---
      // Suffixes come from account.mask (the card's real last 4), NOT
      // from account_id (a Plaid UUID). Mask lookup failure is
      // best-effort for suffixes only; sync still proceeds.
      // The upsert deliberately does NOT list disconnected_at, so a
      // sync never clears a per-account disconnect flag.
      const maskByAccount = new Map<string, string>();
      try {
        const { ok, data: accData } = await plaidPost(base, '/accounts/get', clientId, secret, {
          access_token: accessToken,
        });
        if (ok) {
          for (const acc of accData.accounts ?? []) {
            if (acc.account_id && acc.mask) maskByAccount.set(acc.account_id, String(acc.mask));
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
              if (accErr) skipped++;
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
access_token: <redacted>
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
      let cursor: string | null = item.sync_cursor ?? null;
      let plaidFailed = false;
      for (let page = 0; page < MAX_PAGES; page++) {
        const { ok, data } = await plaidPost(base, '/transactions/sync', clientId, secret, {
          access_token: accessToken, cursor,
        });
        if (!ok) { plaidFailed = true; break; }
        cursor = data.next_cursor ?? null;

        for (const tx of [...(data.added ?? []), ...(data.modified ?? [])]) {
          // Per-account disconnect (connected-accounts-rework): a
          // disconnected account's new/changed transactions are
          // ignored entirely. Past transactions already in the
          // database are untouched.
          if (tx.account_id && disconnectedAccounts.has(String(tx.account_id))) { skipped++; continue; }
          const isModified = (data.modified ?? []).includes(tx);
          const result = await upsertPlaidTx(supabaseAdmin, householdId, tx, maskByAccount);
          if (result === 'added') added++;
          else if (result === 'updated') updated++;
          else skipped++;
          void isModified;
        }

        // removed[] (P1-3): mark reversed + excluded, never delete.
        for (const removed of data.removed ?? []) {
          const removedId = typeof removed === 'string'
            ? removed
            : String(removed.transaction_id ?? removed.id ?? '');
          if (!removedId) continue;
          const { data: row } = await supabaseAdmin.from('transactions')
            .select('id')
            .eq('household_id', householdId)
            .or(`external_id.eq.${removedId},plaid_transaction_id.eq.${removedId},plaid_pending_transaction_id.eq.${removedId}`)
            .maybeSingle();
          if (!row) { skipped++; continue; }
          const { error } = await supabaseAdmin.from('transactions')
            .update({ state: 'reversed', excluded: true })
            .eq('id', row.id).eq('household_id', householdId);
          if (error) skipped++; else reversed++;
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
      if (!plaidFailed && cursor) {
        await supabaseAdmin.rpc('update_plaid_sync', {
          p_household_id: householdId, p_item_id: item.plaid_item_id, p_cursor: cursor,
        });
      } else if (plaidFailed) {
        failedItems.push(item.plaid_item_id);
        continue;
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
      return json({ error: 'plaid sync failed', failed_items: failedItems, added, updated, reversed, skipped }, 502);
    }
    return json({
      added, updated, reversed, skipped,
      duplicate_removed: duplicateRemoved,
      items: allItems.length,
      connected_items: activeItems.length,
      skipped_disconnected: skippedDisconnected,
      truncated,
      ...(allItems.length === 0 ? { no_bank_connected: true } : {}),
    });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

// Upsert order: external_id -> pending_transaction_id -> canonical-hash
// match -> insert. Returns 'added' | 'updated' | 'skipped'.
async function upsertPlaidTx(
  // deno-lint-ignore no-explicit-any
  supabaseAdmin: any,
  householdId: string,
  tx: Record<string, any>,
  maskByAccount: Map<string, string>,
): Promise<'added' | 'updated' | 'skipped'> {
  const signed = Math.round(Number(tx.amount) * 100);
  if (!Number.isFinite(signed)) return 'skipped';
  const merchantRaw = String(tx.merchant_name ?? tx.name ?? 'UNKNOWN');
  const merchant = normalizeMerchant(merchantRaw).slice(0, 80);
  const date = String(tx.date ?? '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return 'skipped';
  const suffix = maskByAccount.get(tx.account_id) ?? '0000';
  const hash = await canonicalHash(merchant, date, signed, suffix);
  const kind = classifyKind(tx, merchantRaw, signed);
  const state = tx.pending ? 'provisional' : 'verified';
  const txId = tx.transaction_id ? String(tx.transaction_id) : null;
  const pendingTxId = tx.pending_transaction_id ? String(tx.pending_transaction_id) : null;

  const row = {
    household_id: householdId, date, merchant,
    amount_cents: signed, card_suffix: suffix, source: 'plaid',
    state, kind,
    external_id: txId, dedupe_hash: hash,
    plaid_transaction_id: txId,
    plaid_pending_transaction_id: pendingTxId,
    // original_purchase_id: intentionally left null — Plaid's sync
    // payload carries no refund-to-purchase link (see header).
    original_purchase_id: null,
  };

  // 1. external_id (this transaction's own id).
  let existing: { id: string; state?: string | null; excluded?: boolean | null; source?: string | null } | null = null;
  if (txId) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source')
      .eq('household_id', householdId).eq('external_id', txId).maybeSingle();
    existing = data;
  }
  // 2. pending_transaction_id linkage (pending -> posted transition).
  if (!existing && pendingTxId) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source')
      .eq('household_id', householdId)
      .or(`external_id.eq.${pendingTxId},plaid_pending_transaction_id.eq.${pendingTxId}`)
      .maybeSingle();
    existing = data;
  }
  // 3. canonical-hash MATCH ONLY (cross-source, e.g. Gmail alert row).
  //    Merged-audit A15: never a uniqueness constraint, and never a
  //    claim on an unrelated identical purchase — only a row whose
  //    source is 'amex_alert' (the Gmail alert the hash was built to
  //    link) may be claimed here. Two identical real purchases keep
  //    coexisting, and the earliest matching alert row is the claim.
  if (!existing) {
    const { data } = await supabaseAdmin.from('transactions').select('id,state,excluded,source')
      .eq('household_id', householdId).eq('dedupe_hash', hash)
      .eq('source', 'amex_alert')
      .order('created_at', { ascending: true }).limit(1).maybeSingle();
    existing = data;
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
      date, merchant, amount_cents: signed, card_suffix: suffix,
      external_id: txId, dedupe_hash: hash,
      plaid_transaction_id: txId, plaid_pending_transaction_id: pendingTxId,
    };
    if (!trashed) update.state = state;
    const { error } = await supabaseAdmin.from('transactions').update(update)
      .eq('id', existing.id).eq('household_id', householdId);
    return error ? 'skipped' : 'updated';
  }
  const { data: inserted, error } = await supabaseAdmin.from('transactions').insert(row).select('id, created_at').single();
  if (error || !inserted) return 'skipped';
  // Lookalike review (Nov 3 Amazon case): a same-date/amount/suffix
  // row with a related merchant name is flagged for admin review,
  // never auto-merged. Best-effort: never fails the sync.
  await flagLookalikes(supabaseAdmin, householdId, {
    id: inserted.id, merchant, date, amount_cents: signed,
    card_suffix: suffix, source: 'plaid', created_at: inserted.created_at,
  });
  return 'added';
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
