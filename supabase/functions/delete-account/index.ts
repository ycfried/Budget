// delete-account — Household Budget account deletion (S4).
//
// DEPLOY NOTE (parent must do this at deploy): set the service-role key in
// the Edge Function secrets as SUPABASE_SECRET_KEY, falling back to the
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
    const serviceKey = Deno.env.get('SUPABASE_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) {
      console.error('delete-account: no service key configured (SUPABASE_SECRET_KEY / SUPABASE_SERVICE_ROLE_KEY)');
      return json({ error: 'account deletion is not configured' }, 500);
    }
    // Verify the caller with their own JWT (anon client, RLS on).
    const caller = createClient(url, anonKey, { global: { headers: { Authorization: auth } } });
    const { data: { user }, error: userErr } = await caller.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);
    // Admin client (service role) for the deletes below.
    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: memberships, error: memErr } = await admin
      .from('household_members').select('household_id').eq('user_id', user.id);
    if (memErr) return json({ error: 'could not delete account' }, 500);
    const householdIds = (memberships ?? []).map((m) => m.household_id);
    const { error: delMemErr } = await admin
      .from('household_members').delete().eq('user_id', user.id);
    if (delMemErr) return json({ error: 'could not delete account' }, 500);
    // Delete any household left with no members.
    for (const hid of householdIds) {
      const { data: remaining } = await admin
        .from('household_members').select('user_id').eq('household_id', hid).limit(1);
      if (!remaining?.length) {
        await admin.from('households').delete().eq('id', hid);
      }
    }
    const { error: delUserErr } = await admin.auth.admin.deleteUser(user.id);
    if (delUserErr) return json({ error: 'could not delete account' }, 500);
    return json({ deleted: true });
  } catch (e) {
    console.error('delete-account failed:', String((e as Error)?.message ?? e));
    return json({ error: 'could not delete account' }, 500);
  }
});
