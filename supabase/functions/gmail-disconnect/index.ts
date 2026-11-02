// gmail-disconnect — disconnects a per-user Gmail mailbox on purpose.
//
// Contract:
//   Request (POST, caller JWT required): { household_id, connection_id }.
//   Caller must be an ADMIN of the connection's household (verified via
//     the JWT + household_members lookup). Members get 403.
//   Effect: revokes the refresh token at Google
//     (oauth2.googleapis.com/revoke), then DELETES the email_connections
//     row. processed_email_ids rows cascade away with it. An audit row
//     is written. No transaction row is touched: past purchases stay
//     in history, exactly like plaid-disconnect.
//   Idempotency: if Google says the token is already invalid (400),
//     the row is still deleted — a dead token is a disconnected
//     mailbox, and disconnect must be retryable. If the revoke call
//     fails for another reason, the row is still deleted: keeping a
//     row whose token the owner asked to revoke would be worse than
//     deleting it, and re-connecting is a fresh OAuth flow.
//     (Contrast with plaid-disconnect, which keeps the row as
//     "Previously connected": email connections carry no account list
//     worth preserving, and the brief specifies deletion.)
//   Response: { disconnected: true, connection_id }.
//   Token ciphertext is never returned to any client.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Hex key decoding (see gmail-oauth-callback): GMAIL_TOKEN_KEY is
// 64-char hex, not base64 — atob() on it yields 48 bytes and AES-GCM
// importKey throws "Invalid key length".
function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

async function decryptToken(keyHex: string, b64: string): Promise<string> {
  const raw = hexToBytes(keyHex);
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
    const connectionId = String(body.connection_id ?? '');
    if (!householdId || !connectionId) return json({ error: 'household_id and connection_id required' }, 400);

    // Admin-only: role check via the JWT identity, not a client claim.
    const { data: membership } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (!membership) return json({ error: 'not a household member' }, 403);
    if (membership.role !== 'admin') return json({ error: 'admin only' }, 403);

    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    const { data: conn } = await supabaseAdmin
      .from('email_connections')
      .select('id, email_address, refresh_token_encrypted')
      .eq('id', connectionId)
      .eq('household_id', householdId)
      .maybeSingle();
    if (!conn) return json({ disconnected: true, connection_id: connectionId });

    // Revoke at Google (best effort — a dead token still disconnects).
    try {
      const tokenKey = Deno.env.get('GMAIL_TOKEN_KEY');
      if (tokenKey && conn.refresh_token_encrypted) {
        const refreshToken = await decryptToken(tokenKey, conn.refresh_token_encrypted);
        await fetch('https://oauth2.googleapis.com/revoke', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ token: refreshToken }),
        }).catch(() => null);
      }
    } catch {
      // Revoke failure never blocks the delete below.
    }

    const { error: delErr } = await supabaseAdmin
      .from('email_connections')
      .delete()
      .eq('id', connectionId)
      .eq('household_id', householdId);
    if (delErr) return json({ error: 'could not disconnect' }, 500);

    await supabaseAdmin.from('audit_log').insert({
      household_id: householdId,
      actor: user.id,
      actor_name: 'admin',
      action: 'gmail_disconnected',
      detail: `Disconnected ${conn.email_address ?? 'email'} from email alerts.`,
    });

    return json({ disconnected: true, connection_id: connectionId });
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
