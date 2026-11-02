// gmail-oauth-callback — completes a per-user Gmail OAuth connection.
// This is a GET endpoint: Google redirects the browser here after the
// user consents (redirect URI registered in Google Cloud Console:
// https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/gmail-oauth-callback).
//
// Flow, in order:
//   1. If Google reports ?error= (user denied, etc.), show an error
//      page. Nothing is stored.
//   2. Verify the ?state= nonce against gmail_oauth_states (service
//      role only): it must exist and be under 10 minutes old. The row
//      is DELETED immediately, so a captured callback URL cannot be
//      replayed. The household comes from that verified row — never
//      from a query parameter the caller could forge.
//   3. Exchange the code for tokens at oauth2.googleapis.com. Only
//      the REFRESH token is kept; the access token is used once below
//      and then discarded. If Google returns no refresh token, show an
//      error page (re-consent required) and store nothing.
//   4. Read the connected address from the Gmail profile endpoint
//      (covered by the gmail.readonly scope) — the address is recorded
//      so the UI can show WHICH mailbox is connected.
//   5. Encrypt the refresh token with GMAIL_TOKEN_KEY (AES-GCM, same
//      iv+ciphertext base64 pattern as plaid-exchange) and upsert
//      email_connections. ONLY the ciphertext is stored.
//   6. Audit row + an HTML page telling the user the connection is
//      done, with a link back to the app. The page never prints a token.
// UNVERIFIED mode: the user will see Google's "unverified app" warning
// screen during consent. That is expected until the OAuth app is
// verified (a later owner decision, not this build).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CALLBACK_URL =
  'https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/gmail-oauth-callback';
const APP_URL = 'https://ycfried.github.io/Budget/live.html';
const STATE_TTL_MS = 10 * 60 * 1000;

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

function esc(s: string): string {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function page(title: string, body: string): Response {
  return new Response(
    `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title></head>` +
      `<body style="font-family:-apple-system,Helvetica,Arial,sans-serif;padding:32px 20px;color:#0f172a">` +
      `<h1 style="font-size:22px">${esc(title)}</h1><p>${body}</p>` +
      `<p><a href="${APP_URL}">Return to OnBudget</a></p></body></html>`,
    { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
  );
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const code = url.searchParams.get('code') ?? '';
    const state = url.searchParams.get('state') ?? '';
    const googleError = url.searchParams.get('error') ?? '';
    if (googleError) {
      return page('Email connection cancelled', `Google reported: ${esc(googleError)}. Nothing was connected. You can try again from the app.`);
    }
    if (!code || !state) return page('Email connection failed', 'Missing authorization code or state. Nothing was connected. Please try again from the app.');

    const serviceKey = Deno.env.get('SUPABASE_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return page('Email connection failed', 'Server is not configured. Nothing was connected.');
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    // Verify + consume the state nonce (single-use).
    const { data: stateRow } = await supabaseAdmin
      .from('gmail_oauth_states')
      .select('household_id, created_at')
      .eq('nonce', state)
      .maybeSingle();
    if (!stateRow) return page('Email connection failed', 'This authorization link is invalid or was already used. Nothing was connected. Please start again from the app.');
    await supabaseAdmin.from('gmail_oauth_states').delete().eq('nonce', state);
    const ageMs = Date.now() - new Date(stateRow.created_at).getTime();
    if (!Number.isFinite(ageMs) || ageMs > STATE_TTL_MS) {
      return page('Email connection failed', 'This authorization link expired. Nothing was connected. Please start again from the app.');
    }
    const householdId = stateRow.household_id as string;

    const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
    const clientSecret = Deno.env.get('GOOGLE_CLIENT_SECRET');
    const tokenKey = Deno.env.get('GMAIL_TOKEN_KEY');
    if (!clientId || !clientSecret) return page('Email connection failed', 'Server is not configured. Nothing was connected.');
    if (!tokenKey) return page('Email connection failed', 'Server is not configured. Nothing was connected.');

    // Exchange the code for tokens.
    const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        grant_type: 'authorization_code',
        redirect_uri: CALLBACK_URL,
      }),
    });
    const tokens = await tokenRes.json().catch(() => ({}));
    if (!tokenRes.ok || !tokens.refresh_token || !tokens.access_token) {
      return page(
        'Email connection failed',
        'Google did not return a reusable connection (no refresh token). This can happen if consent was granted before. Please disconnect any previous grant for this app in your Google account and try again from the app — nothing was connected.',
      );
    }

    // Connected address, via the Gmail profile endpoint (readonly scope).
    const profileRes = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/profile', {
      headers: { Authorization: `Bearer ${tokens.access_token}` },
    });
    const profile = await profileRes.json().catch(() => ({}));
    const emailAddress = String(profile.emailAddress ?? '').trim();
    if (!profileRes.ok || !emailAddress) {
      return page('Email connection failed', 'Could not read the connected mailbox address. Nothing was stored. Please try again from the app.');
    }

    const encrypted = await encryptToken(tokenKey, String(tokens.refresh_token));
    const { error: upsertErr } = await supabaseAdmin.from('email_connections').upsert({
      household_id: householdId,
      provider: 'gmail',
      email_address: emailAddress,
      refresh_token_encrypted: encrypted,
      status: 'active',
      last_error: null,
    }, { onConflict: 'household_id,provider,email_address' });
    if (upsertErr) return page('Email connection failed', 'Could not save the connection. Nothing was stored. Please try again from the app.');

    await supabaseAdmin.from('audit_log').insert({
      household_id: householdId,
      actor: 'system',
      actor_name: 'Gmail OAuth',
      action: 'gmail_connected',
      detail: `Connected ${emailAddress} for email alerts (read-only).`,
    });

    return page(
      'Email connected',
      `Connected <strong>${esc(emailAddress)}</strong> for read-only email alerts. The app will check it for Amex purchase alerts; purchases found there stay provisional until the bank confirms them. You can return to the app now.`,
    );
  } catch (e) {
    return page('Email connection failed', `Something went wrong: ${esc(String((e as Error)?.message ?? e))}. Nothing was stored unless the page above says connected.`);
  }
});
