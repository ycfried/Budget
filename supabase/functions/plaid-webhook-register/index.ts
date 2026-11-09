// Household Budget — plaid-webhook-register (new, Nov 1, 2026;
// toggle, Nov 4, 2026).
// Registers the webhook URL on each of the household's connected bank
// items via Plaid /item/webhook/update. Plaid's dashboard does NOT
// offer Transactions webhooks, so this per-item API call is the only
// way to turn them on for an existing connection.
// Toggle (Nov 4): the client sends { enabled: true | false }. Enabling
// registers WEBHOOK_URL; disabling clears the webhook by passing an
// empty string — Plaid's item webhook is an empty string when no
// webhook is set. After a fully successful run the function stores the
// result in households.auto_sync_enabled (see
// supabase/auto-sync-toggle.sql), which the client reads back as the
// switch state. A partial failure stores nothing, so the stored state
// never claims a state Plaid does not have. With no connected items
// there is nothing to register, so nothing is stored.
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
    // Toggle: enabled defaults to true, so older clients that call
    // without it still enable, exactly as before.
    const enabled = body.enabled !== false;
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

    const { data: allItems } = await supabaseAdmin.from('plaid_items')
      .select('plaid_item_id, institution_name, status')
      .eq('household_id', householdId);
    // Deep audit Nov 5: disconnected items still carry ciphertext, so
    // /item/webhook/update fails for them and results.every(ok) is
    // false forever — auto_sync_enabled is never stored and the
    // switch stays OFF even though active items were registered.
    // plaid-sync already filters status !== 'disconnected'; do the same.
    const items = (allItems ?? []).filter((i) => (i.status ?? 'active') !== 'disconnected');
    const webhook = enabled ? WEBHOOK_URL : '';
    const results = [];
    for (const item of items ?? []) {
      // P0-4 (Nov 8, 2026): one bad item must not 500 the whole toggle.
      // Each item is isolated — a decrypt/fetch failure yields ok:false
      // for that item only, with the institution named so the client
      // toast can say which connection failed and why.
      try {
        const { data: ct } = await supabaseAdmin.rpc('get_plaid_ciphertext', {
          p_household_id: householdId, p_item_id: item.plaid_item_id,
        });
        if (!ct) { results.push({ item: item.plaid_item_id, institution: item.institution_name ?? null, ok: false, error: 'no token' }); continue; }
        const accessToken = await decryptToken(tokenKey, ct);
        const res = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/item/webhook/update`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken, webhook }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) {
          // P2-NEW5 / P2-N12 (Nov 8, 2026): the per-item error reaches
          // the client (the toggle toast displays first.error), so it
          // must be generic; Plaid's error_message goes to the server
          // log only. (The catch branch below was already generic.)
          console.error('plaid-webhook-register: item failed:', item.plaid_item_id, data?.error_code ?? data?.error_message ?? 'unknown');
        }
        results.push({ item: item.plaid_item_id, institution: item.institution_name ?? null, ok: res.ok, error: res.ok ? null : 'request failed' });
      } catch (e) {
        // P1-B3 (Nov 8, 2026) + P2-NEW5/P2-N12: the per-item error is
        // shown in the auto-sync toast, so it must be generic — the
        // institution is named separately and the vendor detail goes
        // to the server log only (same rule as the non-ok response
        // path above). Log the detail here.
        console.error('plaid-webhook-register: item failed:', item.plaid_item_id, (e as Error)?.message ?? e);
        results.push({ item: item.plaid_item_id, institution: item.institution_name ?? null, ok: false, error: 'request failed' });
      }
    }
    // Store the switch state only on a fully successful run with at
    // least one item — a partial failure stores nothing, and with no
    // items there is nothing to store.
    if ((items ?? []).length && results.every((r) => r.ok)) {
      await supabaseAdmin.from('households').update({ auto_sync_enabled: enabled }).eq('id', householdId);
    }
    return json({ webhook_url: WEBHOOK_URL, enabled, results });
  } catch (e) {
    console.error('plaid-webhook-register failed:', e?.message ?? e);
    return json({ error: 'could not update automatic sync' }, 500);
  }
});

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
