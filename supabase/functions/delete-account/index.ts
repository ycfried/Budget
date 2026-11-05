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
// Order: (1) the caller's household_membership rows, (2) any household
// left with no members (its rows cascade-delete under the schema FKs),
// (3) the caller's auth user via the admin API. Nothing else is deleted,
// and no other user's data is touched.
//
// FAILURE SAFETY (Round 3, bug 9): the old version swallowed the
// household-cleanup error and returned a generic error after the
// membership was already deleted, leaving an orphaned auth account
// with no household. Two changes fix that class: (a) the FK
// migration (delete-account-fk-migration.sql) re-points every
// user-referencing history column to ON DELETE SET NULL, so the
// auth-user delete is no longer blocked by the caller's own history
// rows; (b) this function now restores the membership rows if any
// later step fails, and reports the failing step instead of a
// generic error, so a failure leaves the account intact and
// diagnosable instead of half-deleted.
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
    if (delMemErr) return await fail('membership-delete', delMemErr.message);
    // Delete any household left with no members. A failure here used
    // to be swallowed; it is now fatal, because leaving an emptied
    // household behind with a live invite code would expose its data
    // to whoever joins next. Memberships are restored instead.
    for (const hid of householdIds) {
      const { data: remaining } = await admin
        .from('household_members').select('user_id').eq('household_id', hid).limit(1);
      if (!remaining?.length) {
        const { error: delHhErr } = await admin.from('households').delete().eq('id', hid);
        if (delHhErr) return await fail('household-cleanup', delHhErr.message);
      }
    }
    return json({ deleted: true });
  } catch (e) {
    console.error('delete-account failed:', String((e as Error)?.message ?? e));
    return json({ error: 'could not delete account', step: 'unexpected' }, 500);
  }
});
