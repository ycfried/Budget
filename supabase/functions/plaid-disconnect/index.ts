// plaid-disconnect (S3, NEW) — disconnects a Plaid item on purpose
// (spec FINAL Phase 3 demo: "You disconnect Plaid on purpose and the
// app shows a sync warning while email transactions keep arriving").
//
// Contract:
//   Request (JSON, caller JWT required): { household_id, plaid_item_id }
//   Caller must be an ADMIN of the item's household (verified via the
//   JWT + a household_members lookup). Members get 403.
//   Effect: calls Plaid /item/remove with the item's access token
//     (decrypted in memory only, same pattern as plaid-sync; never
//     logged, never returned), then marks the plaid_items row
//     status='disconnected' + disconnected_at=now().
//   The row and its plaid_accounts rows are KEPT, so the app can show
//   a "Previously connected" list. No row is deleted. No transaction
//   row is touched: past transactions stay in history.
//   Response: { disconnected: true, plaid_item_id }.
//   Failure semantics: if the Plaid /item/remove call fails for a
//   reason OTHER than ITEM_NOT_FOUND, the row is NOT marked
//   disconnected (HTTP 502) so the disconnect can be retried. An
//   already-removed item (ITEM_NOT_FOUND) is treated as disconnected
//   (idempotent) and the row is still marked.
//   After disconnect, plaid-sync SKIPS the item (status check), so
//   email ingestion is unaffected and keeps working.
//
// Token ciphertext is never returned to any client. This function does
// not read or expose the plaid_items_public view; that view concept is
// S1's vault file — if it does not exist yet, nothing here depends on
// it (this function uses the same get_plaid_ciphertext RPC as
// plaid-sync). See S3_INTERFACE_NOTES.md for the dependency.

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
    const plaidItemId = String(body.plaid_item_id ?? '');
    if (!householdId || !plaidItemId) {
      return json({ error: 'household_id and plaid_item_id required' }, 400);
    }
    // Admin-only: role check via the JWT identity, not a client claim.
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
    const serviceKey = Deno.env.get('SUPABASE_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    // The item must belong to this household.
    const { data: item } = await supabaseAdmin.from('plaid_items')
      .select('plaid_item_id, status')
      .eq('household_id', householdId)
      .eq('plaid_item_id', plaidItemId)
      .maybeSingle();
    if (!item) return json({ error: 'plaid item not found' }, 404);
    if (item.status === 'disconnected') {
      return json({ disconnected: true, plaid_item_id: plaidItemId, already_disconnected: true });
    }

    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret || !tokenKey) return json({ error: 'plaid not configured' }, 503);

    // Best-effort Plaid removal: if there is no retrievable token the
    // item cannot be removed at Plaid, but the local row can still be
    // marked disconnected so sync stops (documented fallback — the
    // Plaid-side item may linger until removed in the Plaid dashboard).
    const { data: ct } = await supabaseAdmin.rpc('get_plaid_ciphertext', {
      p_household_id: householdId, p_item_id: plaidItemId,
    });
    if (ct) {
      let accessToken: string | null = null;
      try {
        accessToken = await decryptToken(tokenKey, ct);
      } catch {
        accessToken = null;
      }
      if (accessToken) {
        const res = await fetch(
          `https://${env === 'production' ? 'production' : env}.plaid.com/item/remove`,
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken }),
          },
        );
        const data = await res.json().catch(() => ({}));
        const errorCode = String(data?.error_code ?? '');
        if (!res.ok && errorCode !== 'ITEM_NOT_FOUND') {
          return json({ error: 'plaid item/remove failed' }, 502);
        }
      }
    }

    const { error: markError } = await supabaseAdmin.from('plaid_items')
      .update({ status: 'disconnected', disconnected_at: new Date().toISOString() })
      .eq('household_id', householdId)
      .eq('plaid_item_id', plaidItemId);
    if (markError) return json({ error: 'could not mark disconnected' }, 500);
    return json({ disconnected: true, plaid_item_id: plaidItemId });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
