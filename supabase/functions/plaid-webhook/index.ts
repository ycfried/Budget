// Household Budget — plaid-webhook (corrected Nov 1, 2026).
// Receives Plaid webhooks and verifies them the way Plaid actually
// documents: the Plaid-Verification header carries a JWT signed ES256
// with a Plaid key. Verification steps (Plaid docs, webhook verification):
//   1. Decode the JWT header; require alg ES256, take kid.
//   2. Fetch the public JWK via /webhook_verification_key/get
//      (client_id + secret, both Edge Function secrets only).
//   3. Verify the JWT signature with that JWK (WebCrypto ECDSA P-256).
//   4. Require iat within the last 5 minutes (replay protection).
//   5. Require SHA-256(raw body) == request_body_sha256 in the payload.
// There is NO shared webhook secret to set — an earlier version of this
// function wrongly expected an HMAC Plaid-Signature secret, which Plaid
// does not issue for this flow, and it would have rejected every real
// webhook. That version is superseded by this one.
// Only transactions-sync events are recorded, via the
// log_webhook_event RPC (dedupe hash rejects Plaid retries). The live
// app auto-syncs on refresh when it sees an unprocessed event, because
// the actual sync still needs a household member's identity and this
// project deliberately has no working service-role identity.
// Never logs tokens, secrets, or card numbers.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

function b64urlToBytes(s) {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '=');
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}
function b64urlJson(s) {
  return JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));
}
async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const raw = await req.text();
  const jwt = req.headers.get('plaid-verification') ?? '';
  const parts = jwt.split('.');
  if (parts.length !== 3) {
    return new Response(JSON.stringify({ error: 'missing or invalid verification header' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  let header, payload;
  try {
    header = b64urlJson(parts[0]);
    payload = b64urlJson(parts[1]);
  } catch {
    return new Response(JSON.stringify({ error: 'unreadable verification token' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  if (header.alg !== 'ES256' || !header.kid) {
    return new Response(JSON.stringify({ error: 'unsupported verification algorithm' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  // iat within the last 5 minutes (Plaid's replay window).
  const nowSec = Math.floor(Date.now() / 1000);
  if (!payload.iat || nowSec - payload.iat > 300 || payload.iat > nowSec + 60) {
    return new Response(JSON.stringify({ error: 'stale verification token' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  // Fetch Plaid's public key for this kid and verify the signature.
  const clientId = Deno.env.get('PLAID_CLIENT_ID');
  const secret = Deno.env.get('PLAID_SECRET');
  const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
  if (!clientId || !secret) {
    return new Response(JSON.stringify({ error: 'plaid not configured' }), { status: 503, headers: { 'Content-Type': 'application/json' } });
  }
  try {
    const keyRes = await fetch(`https://${env === 'production' ? 'production' : env}.plaid.com/webhook_verification_key/get`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, secret, key_id: header.kid }),
    });
    const keyData = await keyRes.json();
    if (!keyRes.ok || !keyData.key) throw new Error('key fetch failed');
    const key = await crypto.subtle.importKey('jwk', keyData.key, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    const signature = b64urlToBytes(parts[2]);
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, signature, signed);
    if (!valid) throw new Error('bad signature');
  } catch {
    return new Response(JSON.stringify({ error: 'verification failed' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  // Body integrity: SHA-256(raw body) must match the JWT payload claim.
  const bodyHash = await sha256Hex(raw);
  if (!payload.request_body_sha256 || !timingSafeEqual(bodyHash, payload.request_body_sha256)) {
    return new Response(JSON.stringify({ error: 'body hash mismatch' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  let body;
  try { body = JSON.parse(raw); } catch {
    return new Response(JSON.stringify({ error: 'invalid json' }), { status: 400, headers: { 'Content-Type': 'application/json' } });
  }
  const code = body.webhook_code ?? '';
  const isSyncEvent = body.webhook_type === 'TRANSACTIONS' &&
    (code === 'SYNC_UPDATES_AVAILABLE' || code === 'INITIAL_UPDATE' || code === 'HISTORICAL_UPDATE' || code === 'DEFAULT_UPDATE');
  if (!isSyncEvent) {
    return new Response(JSON.stringify({ ignored: true, webhook_code: code }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (!SUPABASE_SERVICE_KEY) return new Response(JSON.stringify({ error: 'service key not configured' }), { status: 503, headers: { 'Content-Type': 'application/json' } });
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const dedupe = await sha256Hex(`${body.item_id}|${code}|${body.new_transactions ?? ''}`);
  const { error } = await supabase.rpc('log_webhook_event', {
    p_item_id: body.item_id ?? null,
    p_webhook_code: code,
    p_dedupe_hash: dedupe,
  });
  if (error) {
    if (/duplicate|unique/i.test(error.message)) {
      return new Response(JSON.stringify({ duplicate: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    console.warn('plaid-webhook: log failed:', error.message);
    return new Response(JSON.stringify({ error: 'could not record event' }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
  return new Response(JSON.stringify({ recorded: true, webhook_code: code }), { status: 200, headers: { 'Content-Type': 'application/json' } });
});
