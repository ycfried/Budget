// gmail-oauth-start — starts a per-user Gmail OAuth connection
// (UNVERIFIED mode: Google OAuth app in Testing mode, NOT submitted
// for verification — see HANDOFF checklist for what that implies).
//
// Contract:
//   Request (POST, caller JWT required): {} — no body fields are
//     trusted, EXCEPT household_id for a multi-household admin (see
//     below) and `client` (see below). The household comes from the
//     caller's own membership:
//     the caller must be an ADMIN of a household (the app allows one
//     household per user, but a user can admin more than one —
//     P2-C6, Nov 8, 2026: the old .maybeSingle() errored on two admin
//     rows and the caller got a bare 403). With exactly one admin
//     household it is used and any body household_id is IGNORED,
//     never trusted. With several, the caller must name one of their
//     own admin households in the body; anything else gets an honest
//     409 naming the problem, not a 403.
//   The `client` body field is NOT a trust decision — it only picks
//     where the callback redirects. The native iOS app sends
//     `client: "native"` (the web sends nothing); anything other
//     than exactly "native" behaves as the web.
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
//     For native flows the state is `native:<nonce>` — the `native:`
//     prefix is the client marker the callback reads to choose its
//     redirect (onbudget://gmail-callback vs live.html); the full
//     string is stored verbatim as the nonce, so the lookup needs
//     no parsing.
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
  'https://auth.getstag.us/functions/v1/gmail-oauth-callback';
// Branded redirect (Nov 22, 2026): the OAuth redirect goes through
// the Cloudflare Worker proxy auth.getstag.us so Google's sign-in
// screen shows getstag.us instead of the raw Supabase host. The
// Worker forwards /functions/v1/* to the Supabase Edge Function
// unchanged. This URI must be registered as an Authorized redirect
// URI in the Google OAuth client "STAGE" (the old supabase.co URI
// stays registered until the new one is verified working).
// Keep this identical to the CALLBACK_URL in gmail-oauth-callback —
// Google requires the redirect_uri in the token exchange to match
// the one in the authorization request exactly.
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
    // P2-C6 (Nov 8, 2026): the old .maybeSingle() errored (data null)
    // when a user admins two or more households, so a multi-household
    // admin got a bare 403. Read the whole list instead: one admin
    // household → use it (body ignored, as before); several → the
    // caller must name one of their own admin households in the body,
    // and anything else gets an honest 409, not a 403.
    const body = await req.json().catch(() => ({}));
    const { data: memberships } = await supabase
      .from('household_members')
      .select('household_id, role')
      .eq('user_id', user.id)
      .eq('role', 'admin');
    const adminHouseholds = (memberships ?? []).map((m: { household_id: string }) => m.household_id);
    if (adminHouseholds.length === 0) return json({ error: 'admin only' }, 403);
    let householdId: string;
    if (adminHouseholds.length === 1) {
      householdId = adminHouseholds[0];
    } else {
      const requested = String(body.household_id ?? '');
      if (requested && adminHouseholds.includes(requested)) {
        householdId = requested;
      } else {
        return json({ error: 'multiple admin households: pass household_id of the household to connect' }, 409);
      }
    }

    const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
    if (!clientId) return json({ error: 'gmail oauth not configured' }, 503);

    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    const nonce = crypto.randomUUID();
    // Native client marker: the iOS app sends `client: "native"`.
    // The marker rides in the OAuth state (`native:<nonce>`) so the
    // callback — which only ever sees Google's redirect — can tell
    // the native flow from the web flow and redirect accordingly.
    // Anything else (including no body at all, as the web sends)
    // keeps the bare nonce and the web redirect. The marker is not
    // a trust decision: the household still comes from the verified
    // state row, never from the request.
    const state = body.client === 'native' ? `native:${nonce}` : nonce;
    const { error: stateErr } = await supabaseAdmin.from('gmail_oauth_states').insert({
      nonce: state,
      household_id: householdId,
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
      state,
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
