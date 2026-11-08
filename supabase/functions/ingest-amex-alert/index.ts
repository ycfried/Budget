// ingest-amex-alert (S3 rewrite) — receives Amex Large Purchase alerts
// from the Gmail Apps Script (Plan B: personal Gmail, Amex-alerts-only
// search query). ONE contract end to end with
// integrations/gmail-apps-script.gs — see integrations/INGEST_CONTRACT.md,
// which is the authoritative contract document. This file implements it.
//
// Security, in order:
//   1. Per-household HMAC-SHA256 signature (header 'x-budget-signature')
//      over the canonical string defined in INGEST_CONTRACT.md, using
//      that household's secret from household_ingest_secrets. Anything
//      unverified is rejected (401). Constant-time compare (no
//      early-exit .every()).
//   2. Replay protection: timestamp within 10 minutes + one-time nonce
//      recorded in ingest_nonces (unique(household_id, nonce)), claimed
//      BEFORE the transaction insert. A reused nonce is rejected (401).
//   3. Require the verbatim Authentication-Results header to show a
//      pass for americanexpress.com (see INGEST_CONTRACT.md for the
//      exact rule). Anything else is quarantined (202, stored:false),
//      never stored.
//   4. Parse amount/merchant/date with fail-closed rules; unparseable
//      alerts are quarantined (202), never guessed into transactions.
//   5. Dedupe by messageId (external_id), with the canonical hash
//      (see _shared/canonical.ts) stored for later Plaid matching.
//      Re-deliveries return stored:true + duplicate:true (the purchase
//      IS in transactions from the earlier delivery) so the script can
//      safely label the message processed. The hash alone never drops
//      an alert, so two real identical purchases can coexist.
// Alerts stored here are PROVISIONAL only — never verified — exactly as
// the spec requires for the Gmail source.
//
// Service key migration (audit P1-2): the dead legacy key is NOT used.
// The key is read from env with fallback order SERVICE_ROLE_SECRET
// then SUPABASE_SERVICE_ROLE_KEY. DEPLOY NOTE: the parent must set the
// CURRENT secret key in Edge Function secrets; do not claim the legacy
// key works. The service-role client is used ONLY for the secret/nonce
// tables (which have no authenticated grants by design) and the
// transaction insert; household_id is never trusted on its own — the
// HMAC must verify against that household's stored secret first.
//
// Residual risk (documented, not hidden): the function must verify the
// HMAC, so it needs the secret VALUE, not a hash. household_ingest_secrets
// therefore stores the secret value in a table readable only by the
// service role (RLS enabled, NO policy grants to authenticated/anon).
// Anyone holding the service-role key or SQL-editor access can read it.
// The parent must restrict that access, and rotation is provided via
// rotate_household_ingest_secret (supabase/ingest-secrets.sql).
// Moving the secret to a dedicated vault is out of scope for code-only
// work and is a parent follow-up, not a claim made here.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  canonicalHash,
  classifyMerchantOnly,
  flagLookalikes,
  hmacSha256Hex,
  normalizeMerchant,
  timingSafeEqualHex,
} from './canonical.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-budget-signature',
};

const REPLAY_WINDOW_SECONDS = 600; // 10 minutes

// Canonical string (exact — see INGEST_CONTRACT.md):
//   timestamp + '.' + nonce + '.' + household_id + '.' + messageId
//   + '.' + amount + '.' + merchant + '.' + date
// where amount is String(amount) exactly as sent in the body, merchant
// is the merchant string exactly as sent, and timestamp is epoch
// seconds as sent. Both sides must build this string from the same
// sent values, not from re-parsed/normalized ones.
function canonicalString(body: Record<string, unknown>): string {
  return [
    String(body.timestamp ?? ''),
    String(body.nonce ?? ''),
    String(body.household_id ?? ''),
    String(body.messageId ?? ''),
    String(body.amount ?? ''),
    String(body.merchant ?? ''),
    String(body.date ?? ''),
  ].join('.');
}

// Authentication-Results acceptance rule (exact — see contract):
// the verbatim header must mention americanexpress.com AND contain
// dkim=pass AND spf=pass. FLAGGED AMBIGUITY (see final report): this
// requires both DKIM and SPF to pass. If Amex (or an intermediate)
// fails SPF on some legitimate path, real alerts will quarantine
// (202, stored:false, nothing lost, nothing mis-stored) until the
// parent relaxes the rule deliberately. Fail-closed was chosen over
// guessing.
function authResultsPass(authResults: string): boolean {
  const h = String(authResults ?? '').toLowerCase();
  return h.includes('americanexpress.com') && h.includes('dkim=pass') && h.includes('spf=pass');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const raw = await req.text();
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(raw);
    } catch {
      return json({ error: 'invalid json' }, 400);
    }

    const householdId = String(body.household_id ?? '');
    const nonce = String(body.nonce ?? '');
    const timestampRaw = body.timestamp;
    if (!householdId || !nonce || timestampRaw === undefined || timestampRaw === null) {
      return json({ error: 'household_id, nonce and timestamp required' }, 400);
    }
    const timestamp = Number(timestampRaw);
    if (!Number.isInteger(timestamp)) return json({ error: 'timestamp must be epoch seconds' }, 400);
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (Math.abs(nowSeconds - timestamp) > REPLAY_WINDOW_SECONDS) {
      return json({ error: 'timestamp outside replay window' }, 401);
    }

    // Service key with the documented fallback order. No legacy-key
    // assumption: if neither env var is set, this is a 503, not a
    // silent fallback to a broken key.
    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET')
      ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!serviceKey) return json({ error: 'ingest not configured' }, 503);
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    // Per-household secret lookup (service role only; no client read).
    const { data: secretRow } = await supabase
      .from('household_ingest_secrets')
      .select('secret')
      .eq('household_id', householdId)
      .maybeSingle();
    if (!secretRow?.secret) return json({ error: 'unknown household or ingest not configured' }, 401);

    // 1. Signature verify (constant-time).
    const sig = (req.headers.get('x-budget-signature') ?? '').toLowerCase();
    const expected = await hmacSha256Hex(String(secretRow.secret), canonicalString(body));
    if (!timingSafeEqualHex(sig, expected)) return json({ error: 'bad signature' }, 401);

    // 2. Replay: claim the nonce before any insert. A unique-violation
    //    here means this exact signed delivery was already processed.
    const { error: nonceError } = await supabase.from('ingest_nonces').insert({
      household_id: householdId, nonce,
    });
    if (nonceError) return json({ error: 'nonce already used' }, 401);

    // 3. Authentication-Results (verbatim header value, as sent).
    const authResults = String(body.auth_results ?? '');
    if (!authResults || !authResultsPass(authResults)) {
      return json({ quarantined: true, stored: false, reason: 'authentication-results not pass' }, 202);
    }

    // 4. Fail-closed parse.
    const amountCents = parseAmount(body.amount);
    const merchantRaw = String(body.merchant ?? '').trim();
    const date = String(body.date ?? '');
    const cardSuffix = String(body.card_suffix ?? '0000').slice(-4);
    if (amountCents === null || !merchantRaw || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return json({ quarantined: true, stored: false, reason: 'unparseable alert' }, 202);
    }
    const merchant = normalizeMerchant(merchantRaw).slice(0, 80);
    const dedupeHash = await canonicalHash(merchant, date, amountCents, cardSuffix);

    // 5. Dedupe by message identity, NOT by hash alone. Two deliveries
    //    of the same Gmail message share messageId, so a row with
    //    external_id = messageId means this alert is already stored
    //    (stored:true + duplicate:true — the purchase IS in
    //    transactions from the earlier delivery — so the script can
    //    safely label the message processed). Two REAL identical
    //    purchases have different messageIds and MUST both insert
    //    (spec test 20); the canonical hash is stored on the row so
    //    plaid-sync can later MATCH the Plaid version to this row
    //    (its step-3 hash match) instead of double-counting. The hash
    //    is never, on its own, a reason to drop a Gmail alert.
    const messageId = String(body.messageId ?? '');
    if (messageId) {
      const { data: existing } = await supabase.from('transactions')
        .select('id').eq('household_id', householdId).eq('external_id', messageId)
        .limit(1).maybeSingle();
      if (existing) return json({ stored: true, duplicate: true, state: 'provisional' });
    }

    const kind = classifyMerchantOnly(merchantRaw, amountCents);
    const { data: inserted, error } = await supabase.from('transactions').insert({
      household_id: householdId,
      date,
      merchant,
      amount_cents: amountCents,
      card_suffix: cardSuffix,
      source: 'amex_alert',
      state: 'provisional',
      kind,
      external_id: messageId || null,
      dedupe_hash: dedupeHash,
    }).select('id, created_at').single();
    if (error) return json({ error: 'insert failed' }, 500);
    if (inserted) {
      // Lookalike review (Nov 3 Amazon case): flagged for admin
      // review, never auto-merged. Best-effort: never fails ingest.
      await flagLookalikes(supabase, householdId, {
        id: inserted.id, merchant, date, amount_cents: amountCents,
        card_suffix: cardSuffix, source: 'amex_alert', created_at: inserted.created_at,
      });
      // P0-1 (Nov 8, 2026): link this row to its purchase/refund so
      // restoration can reach it (supabase/refund-linking.sql).
      // Best-effort: never fails ingest.
      try {
        if (kind === 'refund') await supabase.rpc('auto_link_refund', { p_refund_id: inserted.id });
        else if (kind === 'charge' || kind === 'fund_charge') await supabase.rpc('link_refunds_to_purchase', { p_purchase_id: inserted.id });
      } catch { /* linking is best-effort */ }
    }
    // stored:true ONLY after a successful insert (or a proven
    // duplicate above). Never on 401/202/500.
    return json({ stored: true, duplicate: false, state: 'provisional' });
  } catch (e) {
    console.error('ingest-amex-alert failed:', (e as Error)?.message ?? e);
    return json({ error: 'could not save email alert' }, 500);
  }
});

// Amount contract: the script sends integer cents (number). A decimal
// dollar string ("48.00") is also accepted, for robustness. Anything
// else fails closed (null -> quarantine).
function parseAmount(v: unknown): number | null {
  if (typeof v === 'number' && Number.isInteger(v)) return v;
  if (typeof v === 'string') {
    const m = v.replace(/[$,\s]/g, '').match(/^(-?\(?\d+(\.\d{1,2})?\)?)$/);
    if (!m) return null;
    const neg = v.includes('(') || v.trim().startsWith('-');
    const cents = Math.round(parseFloat(m[1].replace(/[()]/g, '')) * 100);
    return neg ? -cents : cents;
  }
  return null;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
