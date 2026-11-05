// plaid-account-disconnect (connected-accounts-rework, Nov 4, 2026) —
// disconnects ONE Plaid account on purpose, not the whole bank
// connection. Owner, Nov 4, 2026: one American Express item groups
// two accounts (Blue Cash Everyday ••1005 + Rewards Checking ••1636)
// under a single Disconnect, all or nothing; each account must be
// disconnectable on its own.
//
// Plaid FACT: Plaid has no per-account removal. /item/remove removes
// the WHOLE item (every account on that bank connection). So this is
// app-level, in two cases:
//   (a) Other accounts on the same item stay active: ONLY the account
//       is flagged — plaid_accounts.disconnected_at=now(). plaid-sync
//       skips that account's transactions from then on. No Plaid call
//       is made, so the other accounts keep syncing untouched.
//   (b) It was the LAST active account on the item: the Plaid item is
//       also removed via /item/remove (same pattern as
//       plaid-disconnect, including the ITEM_NOT_FOUND idempotent case
//       and the no-token fallback), and plaid_items is marked
//       disconnected, so the Plaid token does not linger.
// In both cases NO row is deleted and NO transaction row is touched:
// past transactions stay in history. The account simply stops
// appearing in Connected accounts (the "Previously connected" list
// was removed from the UI in the same change). Reconnect is via
// Connect New Account (Plaid Link); plaid-sync's duplicate guard
// ignores app-disconnected accounts, so the reconnected account is
// not mistaken for a duplicate of the old item.
//
// Contract:
//   Request (JSON, caller JWT required):
//     { household_id, plaid_item_id, plaid_account_id }
//   Caller must be an ADMIN of the item's household (verified via the
//   JWT + a household_members lookup). Members get 403.
//   Response: { disconnected: true, plaid_account_id,
//               item_disconnected: boolean }.
//   Failure semantics: if the account is already flagged, the call is
//   idempotent ({ disconnected: true, already_disconnected: true }).
//   In case (b), if /item/remove fails for a reason OTHER than
//   ITEM_NOT_FOUND, nothing is flagged (HTTP 502) so the disconnect
//   can be retried.
//
// Token ciphertext is never returned to any client. The access token
// is decrypted in memory only, used for this one Plaid call, and
// never logged, stored, or returned.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function decryptToken(keyB64: string, b64: string): Promise<string> {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
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
    const plaidItemId = String(body.plaid_item_id ?? '');
    const plaidAccountId = String(body.plaid_account_id ?? '');
    if (!householdId || !plaidItemId || !plaidAccountId) {
      return json({ error: 'household_id, plaid_item_id and plaid_account_id required' }, 400);
    }
    // Admin-only: role check via the JWT identity, not a client claim.
    const { data: membership } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (!membership) return json({ error: 'not a household member' }, 403);
    if (membership.role !== 'admin') return json({ error: 'admin only' }, 403);
    // All DB access below uses the service-role key (server-side only,
    // never in the browser) because member JWTs lost direct table/RPC
    // access in the S1 RLS hardening.
    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    // The account must belong to this household on this item.
    const { data: account } = await supabaseAdmin.from('plaid_accounts')
      .select('plaid_account_id, disconnected_at')
      .eq('household_id', householdId)
      .eq('plaid_item_id', plaidItemId)
      .eq('plaid_account_id', plaidAccountId)
      .maybeSingle();
    if (!account) return json({ error: 'plaid account not found' }, 404);
    if (account.disconnected_at) {
      return json({ disconnected: true, plaid_account_id: plaidAccountId, already_disconnected: true, item_disconnected: false });
    }

    // Last active account on the item? Only then is the Plaid item
    // itself removed; otherwise this stays a local flag only.
    const { data: siblings } = await supabaseAdmin.from('plaid_accounts')
      .select('plaid_account_id')
      .eq('household_id', householdId)
      .eq('plaid_item_id', plaidItemId)
      .is('disconnected_at', null)
      .neq('plaid_account_id', plaidAccountId);
    const isLastActive = !(siblings ?? []).length;

    if (isLastActive) {
      const clientId = Deno.env.get('PLAID_CLIENT_ID');
      const secret = Deno.env.get('PLAID_SECRET');
      const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
      const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
      if (!clientId || !secret || !tokenKey) return json({ error: 'plaid not configured' }, 503);
      // Best-effort Plaid removal (same pattern as plaid-disconnect):
      // no retrievable token means the local rows can still be marked
      // so sync stops (the Plaid-side item may linger until removed
      // in the Plaid dashboard).
      const { data: ct } = await supabaseAdmin.rpc('get_plaid_ciphertext', {
        p_household_id: householdId, p_item_id: plaidItemId,
      });
      if (ct) {
        let accessToken: string | null = null;
        try {
          accessToken = await decryptToken(tokenKey, ct);
        } catch {
          accessToken = null;
        }
        if (accessToken) {
          const res = await fetch(
            `https://${env === 'production' ? 'production' : env}.plaid.com/item/remove`,
            {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken }),
            },
          );
          const data = await res.json().catch(() => ({}));
          const errorCode = String(data?.error_code ?? '');
          if (!res.ok && errorCode !== 'ITEM_NOT_FOUND') {
            return json({ error: 'plaid item/remove failed' }, 502);
          }
        }
      }
      const { error: itemError } = await supabaseAdmin.from('plaid_items')
        .update({ status: 'disconnected', disconnected_at: new Date().toISOString() })
        .eq('household_id', householdId)
        .eq('plaid_item_id', plaidItemId);
      if (itemError) return json({ error: 'could not mark item disconnected' }, 500);
    }

    const { error: flagError } = await supabaseAdmin.from('plaid_accounts')
      .update({ disconnected_at: new Date().toISOString() })
      .eq('household_id', householdId)
      .eq('plaid_item_id', plaidItemId)
      .eq('plaid_account_id', plaidAccountId);
    if (flagError) return json({ error: 'could not mark account disconnected' }, 500);
    return json({ disconnected: true, plaid_account_id: plaidAccountId, item_disconnected: isLastActive });
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
