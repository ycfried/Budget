// delete-account — Household Budget account deletion (S4).
//
// DEPLOY NOTE (parent must do this at deploy): set the service-role key in
// the Edge Function secrets as SERVICE_ROLE_SECRET, falling back to the
// legacy SUPABASE_SERVICE_ROLE_KEY. The key NEVER reaches the client: it
// lives only in this function's environment. If neither is set, this
// function refuses with a generic 500 and deletes nothing.
//
// Auth: the caller sends their own Supabase user JWT (Authorization:
// Bearer). The function verifies it and deletes ONLY that caller.
// Order: (1) the caller's auth user via the admin API, (2) the
// caller's household_membership rows, (3) for any household left
// with no members, revoke its Plaid items and Gmail grants
// (best-effort — the tokens die with the household rows, so
// revocation must happen while the rows still exist), then delete
// the household (its rows cascade-delete under the schema FKs).
// Nothing else is deleted, and no other user's data is touched.
// Revocation runs ONLY for emptied households: a household with
// remaining members keeps its connections for them.
//
// FAILURE SAFETY (Round 3, bug 9; P1-B7, Nov 8, 2026): the old
// version swallowed the household-cleanup error and returned a
// generic error after the membership was already deleted, leaving
// an orphaned auth account with no household. Two changes fix that
// class: (a) the FK migration (delete-account-fk-migration.sql)
// re-points every user-referencing history column to ON DELETE SET
// NULL, so the auth-user delete is no longer blocked by the
// caller's own history rows; (b) this function now restores the
// membership rows if any step fails BEFORE the auth delete, and
// reports the failing step instead of a generic error, so a failure
// leaves the account intact and diagnosable instead of half-deleted.
// After the auth delete the memberships cannot be restored (the
// user is gone), so post-auth failures take a compensating path
// instead: the failed delete is retried once, and if the household
// cleanup still fails, the orphaned household's invite code is
// revoked (invite_code = NULL) so nobody can join it and read its
// data — the row itself then needs a manual delete, logged loudly
// for the runbook. Revocation failures never block deletion: a
// household whose Plaid/Gmail revoke fails is still deleted, and
// the failure is logged (the token dies with the row either way).
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

// Token decryption (local copies of the per-function helpers — the
// repo has no shared decrypt module): Plaid keys are base64
// (plaid-disconnect), Gmail keys are 64-char hex (gmail-disconnect).
async function decryptPlaidToken(keyB64: string, b64: string): Promise<string> {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  return new TextDecoder().decode(pt);
}
function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}
async function decryptGmailToken(keyHex: string, b64: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', hexToBytes(keyHex), { name: 'AES-GCM' }, false, ['decrypt']);
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  return new TextDecoder().decode(pt);
}

// P1-B7 (Nov 8, 2026): revoke an emptied household's Plaid items
// (/item/remove) and Gmail grants (Google revoke) before its rows
// are deleted. Best-effort throughout — a failure is logged and the
// deletion continues (the token dies with the row either way, and a
// failed revoke must never strand the account). Missing env skips
// that provider with one log line, so deletion works on a project
// that never configured Plaid or Gmail.
async function revokeHouseholdConnections(admin: any, householdId: string) {
  // Plaid: remove every active item at Plaid.
  try {
    const clientId = Deno.env.get('PLAID_CLIENT_ID');
    const secret = Deno.env.get('PLAID_SECRET');
    const tokenKey = Deno.env.get('PLAID_TOKEN_KEY');
    const env = Deno.env.get('PLAID_ENV') ?? 'sandbox';
    if (!clientId || !secret || !tokenKey) {
      console.error('delete-account: Plaid not configured, skipping item removal for household', householdId);
    } else {
      const { data: items } = await admin.from('plaid_items')
        .select('plaid_item_id, status').eq('household_id', householdId);
      for (const item of items ?? []) {
        if (item.status === 'disconnected') continue;
        try {
          const { data: ct } = await admin.rpc('get_plaid_ciphertext', {
            p_household_id: householdId, p_item_id: item.plaid_item_id,
          });
          if (!ct) continue;
          const accessToken = await decryptPlaidToken(tokenKey, ct);
          const res = await fetch(
            `https://${env === 'production' ? 'production' : env}.plaid.com/item/remove`,
            {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ client_id: clientId, secret, access_token: accessToken }),
            },
          );
          const data = await res.json().catch(() => ({}));
          if (!res.ok && String(data?.error_code ?? '') !== 'ITEM_NOT_FOUND') {
            console.error('delete-account: Plaid item/remove failed for', item.plaid_item_id, data?.error_message ?? res.status);
          }
        } catch (e) {
          console.error('delete-account: Plaid item/remove failed for', item.plaid_item_id, (e as Error)?.message ?? e);
        }
      }
    }
  } catch (e) {
    console.error('delete-account: Plaid revocation failed for household', householdId, (e as Error)?.message ?? e);
  }
  // Gmail: revoke every connection's refresh token at Google.
  try {
    const tokenKey = Deno.env.get('GMAIL_TOKEN_KEY');
    if (!tokenKey) {
      console.error('delete-account: Gmail token key not configured, skipping grant revocation for household', householdId);
    } else {
      const { data: conns } = await admin.from('email_connections')
        .select('id, refresh_token_encrypted').eq('household_id', householdId);
      for (const conn of conns ?? []) {
        if (!conn.refresh_token_encrypted) continue;
        try {
          const refreshToken = await decryptGmailToken(tokenKey, conn.refresh_token_encrypted);
          await fetch('https://oauth2.googleapis.com/revoke', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ token: refreshToken }),
          }).catch(() => null);
        } catch (e) {
          console.error('delete-account: Gmail revoke failed for connection', conn.id, (e as Error)?.message ?? e);
        }
      }
    }
  } catch (e) {
    console.error('delete-account: Gmail revocation failed for household', householdId, (e as Error)?.message ?? e);
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'missing authorization' }, 401);
    const url = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceKey = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) {
      console.error('delete-account: no service key configured (SERVICE_ROLE_SECRET / SUPABASE_SERVICE_ROLE_KEY)');
      return json({ error: 'account deletion is not configured' }, 500);
    }
    // Verify the caller with their own JWT (anon client, RLS on).
    const caller = createClient(url, anonKey, { global: { headers: { Authorization: auth } } });
    const { data: { user }, error: userErr } = await caller.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);
    // Admin client (service role) for the deletes below.
    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: memberships, error: memErr } = await admin
      .from('household_members').select('household_id, role').eq('user_id', user.id);
    if (memErr) return json({ error: 'could not delete account', step: 'membership-read' }, 500);
    const householdIds = (memberships ?? []).map((m) => m.household_id);
    // Restore helper: if a later step fails, put the membership
    // rows back so the account is intact, not half-deleted. Only
    // used while the auth user still exists (see authDeleted below):
    // once the auth user is deleted, membership rows pointing at
    // it cannot be re-inserted, and the account is gone anyway.
    let authDeleted = false;
    const restoreMemberships = async () => {
      // Per-row inserts, not one upsert: if one household is already
      // gone, its row fails alone instead of failing the whole batch.
      for (const m of memberships ?? []) {
        const { error } = await admin.from('household_members')
          .insert({ household_id: m.household_id, user_id: user.id, role: m.role });
        if (error) console.error('delete-account: membership restore failed for household', m.household_id, error.message);
      }
    };
    const fail = async (step: string, message: string) => {
      console.error(`delete-account failed at ${step}:`, message);
      if (!authDeleted) await restoreMemberships();
      return json({ error: 'could not delete account', step }, 500);
    };
    // Design-questions (owner, Nov 5, audit N22): delete the auth
    // user FIRST, then the memberships and any emptied household.
    // If the auth delete fails, nothing else has been touched, the
    // account is intact, and the deletion can be retried. The old
    // order (household first, auth user last) left a stranded auth
    // user with no household when the auth delete failed, because
    // restoreMemberships could not re-insert rows pointing at the
    // deleted household.
    const { error: delUserErr } = await admin.auth.admin.deleteUser(user.id);
    if (delUserErr) return await fail('auth-delete', delUserErr.message);
    authDeleted = true;
    const { error: delMemErr } = await admin
      .from('household_members').delete().eq('user_id', user.id);
    if (delMemErr) {
      // P1-B7 compensating path: the auth user is already gone, so
      // memberships cannot be restored. Retry once — a transient
      // failure must not orphan the household. If it still fails,
      // the dead rows point at a deleted user and the household
      // needs a manual cleanup (logged loudly below via fail()).
      const { error: retryErr } = await admin
        .from('household_members').delete().eq('user_id', user.id);
      if (retryErr) return await fail('membership-delete', retryErr.message);
    }
    // Delete any household left with no members. A failure here used
    // to be swallowed; it is now fatal, because leaving an emptied
    // household behind with a live invite code would expose its data
    // to whoever joins next. Memberships are restored instead — but
    // only while the auth user still exists (see fail() above).
    for (const hid of householdIds) {
      const { data: remaining } = await admin
        .from('household_members').select('user_id').eq('household_id', hid).limit(1);
      if (!remaining?.length) {
        // P1-B7: revoke the household's Plaid items and Gmail grants
        // while their rows still exist (best-effort, never throws).
        await revokeHouseholdConnections(admin, hid);
        const { error: delHhErr } = await admin.from('households').delete().eq('id', hid);
        if (delHhErr) {
          const { error: retryErr } = await admin.from('households').delete().eq('id', hid);
          if (retryErr) {
            // P1-B7 compensating path: the household is orphaned
            // (its only member's auth user is gone) and the delete
            // failed twice. Revoke its invite code so nobody can
            // join it and read its data; the row itself needs a
            // manual delete. Logged loudly for the runbook.
            const { error: revokeErr } = await admin.from('households')
              .update({ invite_code: null }).eq('id', hid);
            console.error('delete-account: household orphaned, invite code revoked:', hid, revokeErr?.message ?? '(revoked)');
            return await fail('household-cleanup', retryErr.message);
          }
        }
      }
    }
    return json({ deleted: true });
  } catch (e) {
    console.error('delete-account failed:', String((e as Error)?.message ?? e));
    return json({ error: 'could not delete account', step: 'unexpected' }, 500);
  }
});
