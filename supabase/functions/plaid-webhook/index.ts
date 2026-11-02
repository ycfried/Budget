// Household Budget — plaid-webhook (new, Nov 1, 2026).
// Receives Plaid webhooks, verifies them, and records sync-needed events.
// WHY THIS DESIGN: Plaid webhooks say "new data is available" — they do
// not carry the transactions themselves, and the actual sync still needs
// a household member's identity (plaid-sync verifies the caller's JWT
// and membership, and this project deliberately has no working
// service-role identity — the legacy key is deprecated). So the webhook
// does the spec-required part — verified receipt with replay protection
// — and the live app auto-syncs on its next refresh when it sees an
// unprocessed event for its household. That is real auto-sync from the
// user's point of view (open the app, transactions are already there
// or arrive on refresh) without inventing a service identity.
// Verification: Plaid signs webhooks with HMAC-SHA256 over the raw body
// using the webhook secret from the Plaid dashboard (PLAID_WEBHOOK_SECRET
// edge secret). Replay protection: the event's dedupe hash is stored via
// the log_webhook_event RPC, which rejects duplicates.
// Never logs tokens, secrets, or card numbers. Only the event type,
// item id, and webhook code are recorded.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const WEBHOOK_SECRET = Deno.env.get('PLAID_WEBHOOK_SECRET') ?? '';

async function hmacHex(secret, body) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
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
  if (!WEBHOOK_SECRET) {
    console.warn('plaid-webhook: PLAID_WEBHOOK_SECRET not set; refusing unverified webhook');
    return new Response(JSON.stringify({ error: 'webhook secret not configured' }), { status: 503, headers: { 'Content-Type': 'application/json' } });
  }
  // Plaid sends the signature as "v1=<hex>" in the Plaid-Signature header.
  const header = req.headers.get('plaid-signature') ?? '';
  const sent = header.split(',').map((p) => p.trim()).find((p) => p.startsWith('v1='))?.slice(3) ?? '';
  const expected = await hmacHex(WEBHOOK_SECRET, raw);
  if (!sent || !timingSafeEqual(sent, expected)) {
    return new Response(JSON.stringify({ error: 'invalid signature' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  let body;
  try { body = JSON.parse(raw); } catch {
    return new Response(JSON.stringify({ error: 'invalid json' }), { status: 400, headers: { 'Content-Type': 'application/json' } });
  }
  // Only transactions-sync events mean "sync now". Anything else is
  // acknowledged and ignored (e.g. ITEM webhook codes).
  const code = body.webhook_code ?? '';
  const isSyncEvent = body.webhook_type === 'TRANSACTIONS' &&
    (code === 'SYNC_UPDATES_AVAILABLE' || code === 'INITIAL_UPDATE' || code === 'HISTORICAL_UPDATE' || code === 'DEFAULT_UPDATE');
  if (!isSyncEvent) {
    return new Response(JSON.stringify({ ignored: true, webhook_code: code }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const dedupe = await (async () => {
    const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${body.item_id}|${code}|${body.new_transactions ?? ''}`));
    return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
  })();
  const { error } = await supabase.rpc('log_webhook_event', {
    p_item_id: body.item_id ?? null,
    p_webhook_code: code,
    p_dedupe_hash: dedupe,
  });
  if (error) {
    // Duplicate events are expected on Plaid retries — treat a unique
    // violation as already-recorded, not a failure.
    if (/duplicate|unique/i.test(error.message)) {
      return new Response(JSON.stringify({ duplicate: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    console.warn('plaid-webhook: log failed:', error.message);
    return new Response(JSON.stringify({ error: 'could not record event' }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
  return new Response(JSON.stringify({ recorded: true, webhook_code: code }), { status: 200, headers: { 'Content-Type': 'application/json' } });
});
