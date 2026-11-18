// plaid-link — creates a Plaid Link token for the Household Budget app.
// Deployed as a Supabase Edge Function (Deno).
//
// Security rules (from the spec, unchanged):
//   * The Plaid secret key lives ONLY in Edge Function secrets
//     (PLAID_SECRET). It is never in the repo, the browser, or chat.
//   * This function requests Transactions ONLY. Do NOT add Auth or
//     Transfer to the products list — Plaid's own docs say that excludes
//     credit-card accounts from the flow.
//   * The caller must be a household ADMIN (reaudit N1, Nov 2, 2026:
//     link/exchange are admin-only, matching sync/disconnect/register).
//   * The access token returned by plaid-exchange is never stored in the
//     database — only the Plaid item id and sync cursor go to plaid_items.
//   * No Plaid account, Item, or bank connection is created by this code
//     until the owner runs the Link flow in the app and signs in to Amex.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
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
    if (membership.role !== 'admin') return json({ error: 'bank linking is admin-only' }, 403);

    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret) {
      return json({ error: 'plaid not configured (server secrets missing)' }, 503);
    }

    const res = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/link/token/create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client_id: clientId,
        secret,
        user: { client_user_id: `${householdId}:${user.id}` },
        client_name: 'Household Budget',
        // Webhook URL at Link creation, so future connections get
        // transactions webhooks automatically (the dashboard does not
        // offer them; existing items use plaid-webhook-register).
        webhook: 'https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/plaid-webhook',
        products: ['transactions'],
        country_codes: ['US'],
        language: 'en',
      }),
    });
    const data = await res.json();
    if (!res.ok) {
      // P2-NEW5 (Nov 8, 2026): Plaid's error_message is vendor detail
      // for the server log only; the client gets a generic string.
      console.error('plaid-link: Plaid link/token/create failed:', data?.error_code ?? data?.error_message ?? 'unknown');
      return json({ error: 'plaid link token failed' }, 502);
    }
    return json({ link_token: data.link_token, expiration: data.expiration });
  } catch (e) {
    console.error('plaid-link failed:', e?.message ?? e);
    return json({ error: 'could not create bank link' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
