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
    // No service-role client here on purpose: the legacy service role
    // key proved broken in this project (bootstrap-household, Nov 1).
    // The upsert runs with the caller's own JWT under the
    // "members insert own plaid items" policy; the ciphertext is
    // useless without PLAID_TOKEN_KEY, which only functions hold.
    const { error: upsertError } = await supabase.from('plaid_items').upsert({
      household_id: householdId,
      plaid_item_id: data.item_id,
      institution_name: body.institution_name ?? null,
      access_token_encrypted: encrypted,
    }, { onConflict: 'household_id,plaid_item_id' });
    // FIX (Nov 1, evening): the original code ignored the upsert result,
    // so the app reported "Connected" even when the item row never
    // landed — which is exactly why a later sync saw 0 items. A failed
    // store is a failed connection, and must be reported as such.
    if (upsertError) return json({ error: `could not store plaid item: ${upsertError.message}` }, 500);
    return json({ item_id: data.item_id, connected: true });
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
