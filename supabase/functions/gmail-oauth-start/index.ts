// gmail-oauth-start — starts a per-user Gmail OAuth connection
// (UNVERIFIED mode: Google OAuth app in Testing mode, NOT submitted
// for verification — see HANDOFF checklist for what that implies).
//
// Contract:
//   Request (POST, caller JWT required): {} — no body fields are
//     trusted. The household comes from the caller's own membership:
//     the caller must be an ADMIN of exactly one household (the app
//     allows one household per user). A caller-supplied household_id
//     is IGNORED, never trusted.
//   Response: { auth_url } — the Google authorization URL. The client
//     redirects the browser there (full navigation, not a popup).
//   Scope is ONLY https://www.googleapis.com/auth/gmail.readonly.
//     NEVER gmail.modify, NEVER full mailbox access. Dedupe lives
//     server-side in processed_email_ids, so no label scope is needed.
//   access_type=offline + prompt=consent: Google only returns a
//     refresh token on a consent grant, so both are required; without
//     them the callback would have nothing to store.
//   State: a random nonce stored server-side in gmail_oauth_states
//     (service role only), single-use, 10-minute expiry enforced by
//     the callback. The state value itself carries no household data.
//   This function never sees, stores, or returns any token. It only
//     mints the authorization URL. GOOGLE_CLIENT_ID is a public
//     OAuth identifier (it appears in the URL by design); the client
//     SECRET is never used here — only the callback holds it.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const CALLBACK_URL =
  'https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/gmail-oauth-callback';
const GMAIL_READONLY_SCOPE = 'https://www.googleapis.com/auth/gmail.readonly';

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

    // Admin household DERIVED from the JWT identity, never from the body.
    const { data: membership } = await supabase
      .from('household_members')
      .select('household_id, role')
      .eq('user_id', user.id)
      .eq('role', 'admin')
      .maybeSingle();
    if (!membership) return json({ error: 'admin only' }, 403);

    const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
    if (!clientId) return json({ error: 'gmail oauth not configured' }, 503);

    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    const nonce = crypto.randomUUID();
    const { error: stateErr } = await supabaseAdmin.from('gmail_oauth_states').insert({
      nonce,
      household_id: membership.household_id,
    });
    if (stateErr) return json({ error: 'could not start oauth flow' }, 500);

    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: CALLBACK_URL,
      response_type: 'code',
      scope: GMAIL_READONLY_SCOPE,
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: 'false',
      state: nonce,
    });
    return json({ auth_url: `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}` });
  } catch (e) {
    console.error('gmail-oauth-start failed:', (e as Error)?.message ?? e);
    return json({ error: 'could not start email connection' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
