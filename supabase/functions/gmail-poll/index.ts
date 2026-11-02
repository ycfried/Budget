// gmail-poll — polls each connected Gmail mailbox for Amex Large
// Purchase alerts and stores them as PROVISIONAL transactions through
// the same contract as ingest-amex-alert.
//
// Contract:
//   Request (POST): { household_id }.
//   Auth, either of:
//     (a) a caller JWT: the caller must be an ADMIN of that household
//         (verified via the JWT + household_members lookup); members
//         get 403. This is the path the app's "Check email now" button
//         uses.
//     (b) a server bearer: the Authorization token equals the
//         SERVICE_ROLE_SECRET / SUPABASE_SERVICE_ROLE_KEY env value.
//         Anyone holding that key already has full database access, so
//         this grants nothing new; it exists so a future scheduled
//         trigger can call this function without a user session.
//         (Scheduled polling itself is NOT built here — see HANDOFF.)
//   Per active connection, in order:
//     1. Decrypt the refresh token IN MEMORY ONLY (GMAIL_TOKEN_KEY;
//        never logged, never returned) and exchange it for a short
//        access token. If Google rejects the refresh grant
//        (invalid_grant — user revoked access, or a Testing-mode token
//        expired), the connection flips to status='error' with
//        last_error='reauthorization required' and is skipped until
//        the admin reconnects. Transient failures leave the status
//        alone and only record last_error.
//     2. List messages matching buildAlertQuery() (first page, 50 max
//        — documented limitation; a household's alert volume fits this
//        for a manual/scheduled poll cadence).
//     3. Skip message ids already in processed_email_ids for this
//        connection. NO Gmail labels are read or written — dedupe is
//        server-side, so only the gmail.readonly scope is ever needed.
//     4. For each new message: fetch it (format=full) and fail closed.
//        Authentication-Results must pass the ingest rule
//        (americanexpress.com + dkim=pass + spf=pass) or the message
//        is recorded 'quarantined' and NEVER stored. An alert that does
//        not parse is recorded 'unparseable' and never guessed into a
//        transaction. A message already in transactions (same
//        external_id) is recorded 'duplicate', never double-stored.
//     5. A parsed alert inserts ONE provisional transaction, exactly
//        like ingest-amex-alert: source 'amex_alert', state
//        'provisional', kind from classifyMerchantOnly, external_id =
//        the Gmail message id, dedupe_hash = canonical hash (so a
//        later Plaid sync can MATCH this row instead of double
//        counting). Nothing here touches week math directly; pending
//        alerts restore nothing (spec FINAL: email is provisional,
//        Plaid is authoritative).
//   Response: aggregate counts { connections, checked, stored,
//     duplicates, quarantined, unparseable } plus errors[] with
//     connection ids and generic messages. No tokens, no addresses,
//     no message bodies are ever returned.
// DEPLOY NOTE (dashboard editor layout): this file imports
// './gmail-parse.ts' and './canonical.ts' — the copies sitting
// ALONGSIDE it in this directory (same pattern as compute-week's
// alongside engine.mjs). Paste all three files verbatim; do not
// rewrite the imports to ../_shared/... — that path does not exist
// in the dashboard file tree. Keep the alongside copies in sync with
// supabase/functions/_shared/gmail-parse.ts and canonical.ts.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  authResultsPass,
  buildAlertQuery,
  extractPlainText,
  filterNewMessageIds,
  gmailDateToNY,
  headerValue,
  parseAmexAlertText,
} from './gmail-parse.ts';
import { canonicalHash, classifyMerchantOnly, normalizeMerchant } from './canonical.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const MAX_MESSAGES_PER_POLL = 50;

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
    const bearer = auth.slice('Bearer '.length);
    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);

    const body = await req.json().catch(() => ({}));
    const householdId = String(body.household_id ?? '');
    if (!householdId) return json({ error: 'household_id required' }, 400);

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: { user } } = await supabase.auth.getUser();
    if (user) {
      // User path: admin of this household only.
      const { data: membership } = await supabase
        .from('household_members')
        .select('role')
        .eq('household_id', householdId)
        .eq('user_id', user.id)
        .maybeSingle();
      if (!membership) return json({ error: 'not a household member' }, 403);
      if (membership.role !== 'admin') return json({ error: 'admin only' }, 403);
    } else if (bearer !== serviceKey) {
      // Neither a valid user session nor the server key.
      return json({ error: 'unauthorized' }, 401);
    }
    // Server path (bearer === service key): trusted trigger, household
    // comes from the body. The service key already grants full DB
    // access, so this path adds no privilege.

    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);
    const clientId = Deno.env.get('GOOGLE_CLIENT_ID');
    const clientSecret = Deno.env.get('GOOGLE_CLIENT_SECRET');
    const tokenKey = Deno.env.get('GMAIL_TOKEN_KEY');
    if (!clientId || !clientSecret) return json({ error: 'gmail oauth not configured' }, 503);
    if (!tokenKey) return json({ error: 'gmail token key not configured' }, 503);

    const { data: connections, error: connErr } = await supabaseAdmin
      .from('email_connections')
      .select('id, email_address, refresh_token_encrypted, status')
      .eq('household_id', householdId)
      .eq('status', 'active');
    if (connErr) return json({ error: 'could not load email connections' }, 500);

    const totals = { connections: connections?.length ?? 0, checked: 0, stored: 0, duplicates: 0, quarantined: 0, unparseable: 0 };
    const errors: { connection_id: string; error: string }[] = [];

    for (const conn of connections ?? []) {
      let connError: string | null = null;
      try {
        const refreshToken = await decryptToken(tokenKey, conn.refresh_token_encrypted);
        // Exchange the refresh token for a short access token.
        const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: clientId,
            client_secret: clientSecret,
            refresh_token: refreshToken,
            grant_type: 'refresh_token',
          }),
        });
        const tokenData = await tokenRes.json().catch(() => ({}));
        if (!tokenRes.ok || !tokenData.access_token) {
          if (tokenData.error === 'invalid_grant') {
            await supabaseAdmin.from('email_connections').update({
              status: 'error',
              last_error: 'reauthorization required',
            }).eq('id', conn.id);
            errors.push({ connection_id: conn.id, error: 'reauthorization required' });
            continue;
          }
          throw new Error('token refresh failed');
        }
        const accessToken = String(tokenData.access_token);
        const gHeaders = { Authorization: `Bearer ${accessToken}` };

        const listRes = await fetch(
          `https://gmail.googleapis.com/gmail/v1/users/me/messages?q=${encodeURIComponent(buildAlertQuery())}&maxResults=${MAX_MESSAGES_PER_POLL}`,
          { headers: gHeaders },
        );
        const listData = await listRes.json().catch(() => ({}));
        if (!listRes.ok) throw new Error('message list failed');
        const allIds: string[] = (listData.messages ?? []).map((m: { id?: string }) => String(m?.id ?? '')).filter(Boolean);

        const { data: processed } = await supabaseAdmin
          .from('processed_email_ids')
          .select('message_id')
          .eq('connection_id', conn.id);
        const processedIds = (processed ?? []).map((r: { message_id: string }) => r.message_id);
        const newIds = filterNewMessageIds(allIds, processedIds);
        totals.checked += newIds.length;

        for (const messageId of newIds) {
          try {
            const msgRes = await fetch(
              `https://gmail.googleapis.com/gmail/v1/users/me/messages/${encodeURIComponent(messageId)}?format=full`,
              { headers: gHeaders },
            );
            const msg = await msgRes.json().catch(() => ({}));
            if (!msgRes.ok) continue; // transient: not marked processed, retried next poll
            const headers = (msg.payload?.headers ?? []) as { name: string; value: string }[];
            const authResults = headerValue(headers, 'Authentication-Results');
            const subject = headerValue(headers, 'Subject');
            if (!authResultsPass(authResults)) {
              await supabaseAdmin.from('processed_email_ids').insert({
                connection_id: conn.id, message_id: messageId, disposition: 'quarantined',
              });
              totals.quarantined += 1;
              continue;
            }
            const date = gmailDateToNY(msg.internalDate);
            const parsed = parseAmexAlertText({
              subject,
              body: extractPlainText(msg.payload),
              date,
            });
            if (!parsed) {
              await supabaseAdmin.from('processed_email_ids').insert({
                connection_id: conn.id, message_id: messageId, disposition: 'unparseable',
              });
              totals.unparseable += 1;
              continue;
            }
            // Dedupe by message identity, NOT by hash alone (same rule
            // as ingest-amex-alert: two real identical purchases have
            // different message ids and must both insert).
            const { data: existing } = await supabaseAdmin.from('transactions')
              .select('id').eq('household_id', householdId).eq('external_id', messageId)
              .limit(1).maybeSingle();
            if (existing) {
              await supabaseAdmin.from('processed_email_ids').insert({
                connection_id: conn.id, message_id: messageId, disposition: 'duplicate',
              });
              totals.duplicates += 1;
              continue;
            }
            const merchant = normalizeMerchant(parsed.merchant).slice(0, 80);
            const dedupeHash = await canonicalHash(merchant, parsed.date, parsed.amountCents, parsed.cardSuffix);
            const kind = classifyMerchantOnly(parsed.merchant, parsed.amountCents);
            const { error: insertErr } = await supabaseAdmin.from('transactions').insert({
              household_id: householdId,
              date: parsed.date,
              merchant,
              amount_cents: parsed.amountCents,
              card_suffix: parsed.cardSuffix,
              source: 'amex_alert',
              state: 'provisional',
              kind,
              external_id: messageId,
              dedupe_hash: dedupeHash,
            });
            if (insertErr) continue; // transient: not marked processed, retried next poll
            await supabaseAdmin.from('processed_email_ids').insert({
              connection_id: conn.id, message_id: messageId, disposition: 'stored',
            });
            totals.stored += 1;
          } catch {
            // Per-message failure: leave unprocessed so the next poll
            // retries it. Never partial-mark a message.
            continue;
          }
        }
        await supabaseAdmin.from('email_connections').update({
          last_poll_at: new Date().toISOString(),
          last_error: null,
        }).eq('id', conn.id);
      } catch (e) {
        connError = String((e as Error)?.message ?? e);
        errors.push({ connection_id: conn.id, error: 'poll failed' });
        await supabaseAdmin.from('email_connections').update({
          last_error: connError,
        }).eq('id', conn.id);
      }
    }

    return json({ ...totals, errors });
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
