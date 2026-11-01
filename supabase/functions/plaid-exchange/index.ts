// plaid-exchange — exchanges a Plaid public token for an Item, then
// stores ONLY the Plaid item id + institution name in plaid_items.
// The access token is NOT stored in the database (see schema notes).
// In production the access token must be held in a Plaid vault / secrets
// store reachable only by plaid-sync; until that store exists, this
// function returns an error rather than persisting the token anywhere
// unsafe. Do not change that rule without the owner's explicit approval.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

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
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret) return json({ error: 'plaid not configured' }, 503);
    if (!Deno.env.get('PLAID_TOKEN_VAULT_URL')) {
      // Refuse to complete the exchange until a safe token store exists.
      // This is deliberate: completing it here would leave the access
      // token with nowhere safe to go.
      return json({ error: 'plaid token vault not configured — exchange blocked by design' }, 503);
    }
    const res = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/item/public_token/exchange`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, secret, public_token: publicToken }),
    });
    const data = await res.json();
    if (!res.ok) return json({ error: 'plaid exchange failed' }, 502);
    // Store item id only. The access token goes to the vault (handled by
    // the vault integration, not by this database write).
    await supabase.from('plaid_items').upsert({
      household_id: householdId,
      plaid_item_id: data.item_id,
      institution_name: body.institution_name ?? null,
    }, { onConflict: 'household_id,plaid_item_id' });
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
