// check-email-exists — does an auth account exist for this email?
//
// WHY THIS EXISTS (owner decision, Nov 11, 2026): a failed sign-in
// must say WHICH field is wrong — "Username is incorrect" vs
// "Password is incorrect" — but Supabase Auth's signInWithPassword
// returns one generic `invalid_credentials` error for both cases, by
// design. The native client therefore asks this function after an
// invalid-credentials failure: if the email has an account, the
// password was wrong; if not, the username (email) was wrong.
//
// ENUMERATION TRADE-OFF — ACCEPTED BY THE OWNER (Nov 11, ~7:41 PM:
// "It's just a budgeting app."): this endpoint lets anyone with the
// public anon key learn whether an email has an account, one email
// per call. That is inherent to the feature the owner asked for.
// Mitigations in place: the caller must supply a well-formed email
// (no bulk/list API — one email per call, one boolean back, no user
// data returned); the service-role key never leaves the server.
// NOT in place, owed as a follow-up if this is ever abused: a
// per-IP/per-caller rate limit (the function has no rate-limit store
// today) and an audit log of checks.
//
// DEPLOY NOTE: set the service-role key in the Edge Function secrets
// as SERVICE_ROLE_SECRET, falling back to the legacy
// SUPABASE_SERVICE_ROLE_KEY (same as delete-account). The key NEVER
// reaches the client. If neither is set, the function refuses with a
// generic 500 and the client falls back to "Username or password is
// incorrect." — the per-field wording degrades to the generic
// message, never to a wrong per-field message.
//
// Auth: NO caller JWT is required — at sign-in failure there is no
// session to attach. The request carries only the public anon key
// (apikey header). Do NOT add a JWT requirement: the client cannot
// satisfy it in the one flow that uses this function.
//
// Contract: POST { "email": "user@example.com" } ->
//   200 { "exists": true | false }
//   400 { "error": "a valid email is required" } (bad / missing email)
//   500 { "error": "could not check that email" } (no service key, or
//   the admin API failed for a reason other than "user not found")
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  let email = '';
  try {
    const body = await req.json();
    email = typeof body?.email === 'string' ? body.email.trim().toLowerCase() : '';
  } catch {
    return json({ error: 'a valid email is required' }, 400);
  }
  if (!EMAIL_RE.test(email) || email.length > 254) {
    return json({ error: 'a valid email is required' }, 400);
  }

  const url = Deno.env.get('SUPABASE_URL')!;
  const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!serviceKey) {
    console.error('check-email-exists: no service key configured (SERVICE_ROLE_SECRET / SUPABASE_SERVICE_ROLE_KEY)');
    return json({ error: 'could not check that email' }, 500);
  }

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // getUserByEmail does NOT exist on supabase-js v2's admin client
  // (runtime TypeError, Nov 12, 2026 — the call 500s on every
  // request). Use listUsers and match the email locally instead.
  // The user base is small (tens of accounts), so one page of 1000
  // covers it; paginate if that ever stops being true.
  const { data, error } = await admin.auth.admin.listUsers({ perPage: 1000 });
  if (error) {
    console.error('check-email-exists: admin lookup failed', error.message);
    return json({ error: 'could not check that email' }, 500);
  }
  const exists = (data?.users ?? []).some(
    (u) => (u.email ?? '').toLowerCase() === email,
  );
  return json({ exists });
});
