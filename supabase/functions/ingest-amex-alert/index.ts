// ingest-amex-alert — receives Amex Large Purchase alerts from the Gmail
// Apps Script (Plan B: personal Gmail, Amex-alerts-only search query).
// Security, in order:
//   1. Verify the HMAC-SHA256 signature (header x-budget-signature) over
//      the raw body, using INGEST_SECRET. Anything unverified is rejected.
//   2. Require the script's Authentication-Results claim (SPF/DKIM pass
//      for americanexpress.com). Anything else is quarantined, not stored.
//   3. Parse amount/merchant/date with the existing fail-closed rules;
//      unparseable alerts go to quarantine (a rejected response the
//      script logs), never into transactions.
//   4. Dedupe by stable hash (merchant + amount + date + card suffix).
//      Re-deliveries are no-ops.
// Alerts stored here are PROVISIONAL only — never verified — exactly as
// the spec requires for the Gmail source.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const raw = await req.text();
    const secret = Deno.env.get('INGEST_SECRET');
    if (!secret) return json({ error: 'ingest not configured' }, 503);
    const sig = req.headers.get('x-budget-signature') ?? '';
    const ok = await verifyHmac(secret, raw, sig);
    if (!ok) return json({ error: 'bad signature' }, 401);

    const body = JSON.parse(raw);
    if (body.auth_results !== 'pass') {
      return json({ quarantined: true, reason: 'authentication-results not pass' }, 202);
    }
    const amountCents = parseAmount(body.amount);
    const merchant = String(body.merchant ?? '').trim();
    const date = String(body.date ?? '');
    if (amountCents === null || !merchant || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return json({ quarantined: true, reason: 'unparseable alert' }, 202);
    }
    const householdId = String(body.household_id ?? '');
    if (!householdId) return json({ error: 'household_id required' }, 400);
    const dedupeHash = await sha256(`${merchant}|${amountCents}|${date}|${body.card_suffix ?? '0000'}`);

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { error } = await supabase.from('transactions').insert({
      household_id: householdId,
      date,
      merchant,
      amount_cents: amountCents,
      card_suffix: String(body.card_suffix ?? '0000').slice(-4),
      source: 'amex_alert',
      state: 'provisional',
      kind: amountCents < 0 ? 'refund' : 'charge',
      dedupe_hash: dedupeHash,
    });
    if (error && !String(error.message).includes('duplicate')) {
      return json({ error: 'insert failed' }, 500);
    }
    return json({ stored: !error, duplicate: !!error, state: 'provisional' });
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});

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

async function sha256(text: string) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function verifyHmac(secret: string, body: string, sigHex: string) {
  try {
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
    const sig = new Uint8Array(sigHex.match(/../g)!.map((h) => parseInt(h, 16)));
    const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
    return sig.length === mac.byteLength && sig.every((b, i) => b === new Uint8Array(mac)[i]);
  } catch { return false; }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
