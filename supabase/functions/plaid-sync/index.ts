// plaid-sync — pulls new Amex transactions via Plaid /transactions/sync
// and writes them as VERIFIED (Plaid is the authoritative source).
// Security:
//   * The access token is never in the database in plaintext. It is
//     fetched (ciphertext only) via the get_plaid_ciphertext RPC, which
//     checks the caller's membership, then decrypted IN MEMORY with
//     PLAID_TOKEN_KEY (Edge Function secrets only). It is never logged
//     and never returned to the client.
//   * No legacy service-role key is used anywhere here (that key proved
//     broken in this project). Writes use the caller's JWT under the
//     existing member insert policies; the sync cursor is updated via
//     the update_plaid_sync RPC.
//   * Dedupe: Plaid transaction_id goes to external_id, and the stable
//     hash (merchant|amount|date|suffix) goes to dedupe_hash, so
//     re-syncs, pending→posted transitions, and re-deliveries are
//     no-ops or updates, never duplicates. Pending transactions are
//     stored as provisional; posted ones as verified.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function decryptToken(keyB64: string, b64: string): Promise<string> {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const iv = bytes.slice(0, 12);
  const ct = bytes.slice(12);
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, ct);
  return new TextDecoder().decode(pt);
}

async function sha256(text: string) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
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
    if (!householdId) return json({ error: 'household_id required' }, 400);
    const { data: membership } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (!membership) return json({ error: 'not a household member' }, 403);

    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret || !tokenKey) return json({ error: 'plaid not configured' }, 503);

    const { data: items } = await supabase.from('plaid_items')
      .select('plaid_item_id, institution_name')
      .eq('household_id', householdId);
    let added = 0, updated = 0, skipped = 0;
    for (const item of items ?? []) {
      const { data: ct } = await supabase.rpc('get_plaid_ciphertext', {
        p_household_id: householdId, p_item_id: item.plaid_item_id,
      });
      if (!ct) continue;
      const accessToken = await decryptToken(tokenKey, ct);
      // Card suffixes come from /accounts/get (account.mask), NOT from
      // account_id (a Plaid UUID — deriving a suffix from it gives
      // meaningless digits). Mask is the card's real last 4.
      const maskByAccount = new Map<string, string>();
      try {
        const accRes = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/accounts/get`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken }),
        });
        const accData = await accRes.json();
        for (const acc of accData.accounts ?? []) {
          if (acc.account_id && acc.mask) maskByAccount.set(acc.account_id, String(acc.mask));
        }
      } catch { /* mask lookup is best-effort; sync still proceeds */ }
      let cursor: string | null = null;
      // Paginate through /transactions/sync until has_more is false.
      for (let page = 0; page < 20; page++) {
        const res = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/transactions/sync`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken, cursor }),
        });
        const data = await res.json();
        if (!res.ok) return json({ error: 'plaid sync failed' }, 502);
        cursor = data.next_cursor ?? null;
        for (const tx of [...(data.added ?? []), ...(data.modified ?? [])]) {
          // Plaid amounts are positive for outflows and negative for
          // inflows; the app stores charges positive and refunds
          // negative, so Plaid's sign maps directly.
          const signed = Math.round(tx.amount * 100);
          const merchant = String(tx.merchant_name ?? tx.name ?? 'UNKNOWN').toUpperCase().slice(0, 80);
          const date = String(tx.date ?? '').slice(0, 10);
          const suffix = maskByAccount.get(tx.account_id) ?? '0000';
          const hash = await sha256(`${date}|${merchant}|${signed}|${suffix}`);
          const row = {
            household_id: householdId, date, merchant,
            amount_cents: signed, card_suffix: suffix, source: 'plaid',
            state: tx.pending ? 'provisional' : 'verified',
            kind: signed < 0 ? 'refund' : 'charge',
            external_id: tx.transaction_id, dedupe_hash: hash,
          };
          const { error } = await supabase.from('transactions').upsert(row, { onConflict: 'household_id,dedupe_hash' });
          if (error) { skipped++; continue; }
          if (data.modified?.includes(tx)) updated++; else added++;
        }
        if (!data.has_more) break;
      }
      if (cursor) {
        await supabase.rpc('update_plaid_sync', {
          p_household_id: householdId, p_item_id: item.plaid_item_id, p_cursor: cursor,
        });
      }
    }
    return json({ added, updated, skipped, items: (items ?? []).length });
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
