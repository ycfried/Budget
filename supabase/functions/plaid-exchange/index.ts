// plaid-exchange v2 — exchanges a Plaid public token, encrypts the
// access token, and stores ONLY the ciphertext + item id.
// Security (updated Nov 1, 2026 — see AUDIT_LIVE.md "Plaid today"):
//   * The access token is encrypted with AES-GCM using PLAID_TOKEN_KEY,
//     a key held ONLY in Edge Function secrets. The key is never in
//     the repo, chat, logs, or database.
//   * The plaintext token is never written anywhere. The ciphertext
//     goes to plaid_items.access_token_encrypted, a column with NO
//     client read policy — only service-role functions read it, and
//     plaid-sync decrypts it in memory only.
//   * The client receives only { item_id, connected: true }.
//   * Transactions only: this function never requests Auth/Transfer.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function encryptToken(keyB64: string, plaintext: string): Promise<string> {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(plaintext));
  const out = new Uint8Array(iv.length + ct.byteLength);
  out.set(iv, 0);
  out.set(new Uint8Array(ct), iv.length);
  return btoa(String.fromCharCode(...out));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'missing authorization' }, 401);
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: { user }, error: userErr } = await supabase.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);
    const body = await req.json().catch(() => ({}));
    const householdId = String(body.household_id ?? '');
    const publicToken = String(body.public_token ?? '');
    if (!householdId || !publicToken) return json({ error: 'household_id and public_token required' }, 400);
    const { data: membership } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (!membership) return json({ error: 'not a household member' }, 403);
    if (membership.role !== 'admin') return json({ error: 'bank linking is admin-only' }, 403);
    // Coordinator integration: admin membership verified above via the
    // caller JWT. All DB access below uses the service-role key (server-side
    // only, never in the browser) because member JWTs lost direct table/RPC
    // access in the S1 RLS hardening.
    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret) return json({ error: 'plaid not configured' }, 503);
    if (!tokenKey) return json({ error: 'plaid token key not configured' }, 503);

    const res = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/item/public_token/exchange`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, secret, public_token: publicToken }),
    });
    const data = await res.json();
    if (!res.ok) return json({ error: 'plaid exchange failed' }, 502);
    const encrypted = await encryptToken(tokenKey, data.access_token);
    // Deep audit Nov 5: the old comment claimed this upsert ran
    // with the caller's own JWT — it does not. It runs with the
    // service-role client (supabaseAdmin, above); the ciphertext is
    // useless without PLAID_TOKEN_KEY, which only functions hold.
    const { error: upsertError } = await supabaseAdmin.from('plaid_items').upsert({
      household_id: householdId,
      plaid_item_id: data.item_id,
      institution_name: body.institution_name ?? null,
      access_token_encrypted: encrypted,
    }, { onConflict: 'household_id,plaid_item_id' });
    // FIX (Nov 1, evening): the original code ignored the upsert result,
    // so the app reported "Connected" even when the item row never
    // landed — which is exactly why a later sync saw 0 items. A failed
    // store is a failed connection, and must be reported as such.
    if (upsertError) { console.error('plaid-exchange: could not store plaid item:', upsertError.message); return json({ error: 'could not store plaid item' }, 500); }
    // P1-C2 (Nov 8, 2026): duplicate guard AT CONNECT, not only at
    // sync. Re-linking a bank whose accounts are already carried by
    // an older ACTIVE connection at the same institution (mask + name)
    // used to return { connected: true } and leave a duplicate item
    // until the next sync removed it. The check mirrors plaid-sync's
    // findDuplicateKeeper (same rule: every candidate account covered
    // by an older keeper at the same institution). Any failure fails
    // OPEN — the item stays connected and the sync-path guard catches
    // a real duplicate on the next sync. A confirmed duplicate is
    // removed at Plaid, marked disconnected, and reported as
    // { connected: false, duplicate: true } so the client never says
    // "Connected" for it.
    const dup = await checkDuplicateAtConnect(supabaseAdmin, householdId, data.item_id, body.institution_name ?? null, data.access_token, clientId, secret, env);
    if (dup) return json({ item_id: data.item_id, connected: false, duplicate: true, duplicate_of: dup });
    return json({ item_id: data.item_id, connected: true });
  } catch (e) {
    console.error('plaid-exchange failed:', e?.message ?? e);
    return json({ error: 'could not complete bank connection' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Duplicate-connection check at connect time (P1-C2). Same rule as
// plaid-sync's findDuplicateKeeper — keep the two in step (see
// duplicateConnection.mjs): a candidate is a duplicate when every
// one of its accounts (mask + name) is already carried by an older
// ACTIVE item at the same institution. Returns the keeper's item id,
// or null when the item is not a duplicate (or the check could not
// run — fail open). Removes a confirmed duplicate at Plaid and marks
// the stored row disconnected before returning the keeper id.
function normDup(v: unknown): string {
  return String(v ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
}
async function checkDuplicateAtConnect(
  admin: any, householdId: string, itemId: string, institutionName: string | null,
  accessToken: string, clientId: string, secret: string, env: string,
): Promise<string | null> {
  try {
    const base = `https://${env === 'production' ? 'production' : env}.plaid.com`;
    const accRes = await fetch(`${base}/accounts/get`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken }),
    });
    if (!accRes.ok) return null;
    const accData = await accRes.json().catch(() => ({}));
    const candAccts: { mask?: string | null; name?: string | null }[] = [];
    for (const acc of accData.accounts ?? []) {
      if (acc.account_id && acc.mask) candAccts.push({ mask: String(acc.mask), name: acc.name ? String(acc.name) : null });
    }
    if (!candAccts.length || !normDup(institutionName)) return null;
    for (const a of candAccts) if (!normDup(a.mask) || !normDup(a.name)) return null;
    const { data: items } = await admin.from('plaid_items')
      .select('plaid_item_id, institution_name, created_at, status').eq('household_id', householdId);
    const keepers = (items ?? []).filter((i: any) => i.plaid_item_id !== itemId && i.status !== 'disconnected');
    if (!keepers.length) return null;
    const { data: acctRows } = await admin.from('plaid_accounts')
      .select('plaid_item_id, name, mask, disconnected_at').eq('household_id', householdId);
    const byItem = new Map<string, { mask?: string | null; name?: string | null }[]>();
    for (const row of acctRows ?? []) {
      if (row.disconnected_at) continue;
      const list = byItem.get(row.plaid_item_id) ?? [];
      list.push({ mask: row.mask, name: row.name });
      byItem.set(row.plaid_item_id, list);
    }
    const candidateCreated = new Date().toISOString();
    for (const keeper of keepers) {
      if (normDup(keeper.institution_name) !== normDup(institutionName)) continue;
      if (!keeper.created_at || !(String(keeper.created_at) < candidateCreated)) continue;
      const kAccts = byItem.get(keeper.plaid_item_id) ?? [];
      const covered = candAccts.every((acct) =>
        kAccts.some((k) => normDup(k.mask) === normDup(acct.mask) && normDup(k.name) === normDup(acct.name)));
      if (!covered) continue;
      // Confirmed duplicate: remove at Plaid, mark disconnected.
      try {
        const rm = await fetch(`${base}/item/remove`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken }),
        });
        const rmData = await rm.json().catch(() => ({}));
        if (!rm.ok && String(rmData?.error_code ?? '') !== 'ITEM_NOT_FOUND') return null;
      } catch {
        return null;
      }
      const { error: markErr } = await admin.from('plaid_items')
        .update({ status: 'disconnected', disconnected_at: new Date().toISOString() })
        .eq('household_id', householdId).eq('plaid_item_id', itemId);
      if (markErr) return null;
      console.warn(`plaid-exchange: removed duplicate item ${itemId} at connect (accounts already on ${keeper.plaid_item_id}); past transactions kept`);
      return keeper.plaid_item_id;
    }
    return null;
  } catch (e) {
    console.warn('plaid-exchange: duplicate check failed open:', (e as Error)?.message ?? e);
    return null;
  }
}
