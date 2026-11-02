// Household Budget — plaid-webhook-register (new, Nov 1, 2026).
// Registers the webhook URL on each of the household's connected bank
// items via Plaid /item/webhook/update. Plaid's dashboard does NOT
// offer Transactions webhooks, so this per-item API call is the only
// way to turn them on for an existing connection.
// Security: admin-only (checked via household membership + role).
// The bank access token is fetched as ciphertext via the
// get_plaid_ciphertext RPC, decrypted IN MEMORY with PLAID_TOKEN_KEY,
// used for this one Plaid call, and never logged, stored, or returned.
// No bank username or password is involved at any point — the token
// is the read-only credential Plaid issued at Link time.
// After this runs, Plaid sends SYNC_UPDATES_AVAILABLE webhooks to
// plaid-webhook whenever new transactions appear, and the live app
// auto-syncs on its next refresh.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const WEBHOOK_URL = 'https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/plaid-webhook';

async function decryptToken(keyB64, b64) {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  return new TextDecoder().decode(pt);
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
    if (membership.role !== 'admin') return json({ error: 'admin only' }, 403);
    // Coordinator integration: membership/admin already verified above via the
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
    if (!clientId || !secret || !tokenKey) return json({ error: 'plaid not configured' }, 503);

    const { data: items } = await supabaseAdmin.from('plaid_items')
      .select('plaid_item_id, institution_name')
      .eq('household_id', householdId);
    const results = [];
    for (const item of items ?? []) {
      const { data: ct } = await supabaseAdmin.rpc('get_plaid_ciphertext', {
        p_household_id: householdId, p_item_id: item.plaid_item_id,
      });
      if (!ct) { results.push({ item: item.plaid_item_id, ok: false, error: 'no token' }); continue; }
      const accessToken = await decryptToken(tokenKey, ct);
      const res = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/item/webhook/update`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken, webhook: WEBHOOK_URL }),
      });
      const data = await res.json();
      results.push({ item: item.plaid_item_id, ok: res.ok, error: res.ok ? null : (data?.error_message ?? 'unknown') });
    }
    return json({ webhook_url: WEBHOOK_URL, results });
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
