// bootstrap-household — creates a household + the creator's admin
// membership, server-side, with the service role.
//
// Why this exists: the client must NOT be able to insert its own admin
// membership — a client granted that could make itself admin of any
// household whose ID it guesses. So household creation is an Edge
// Function that:
//   1. Verifies the caller's JWT.
//   2. Refuses if the caller already belongs to any household
//      (one household per user in this app; the spouse joins by ID).
//   3. Creates one household (base allowance $375) and one membership
//      row (creator = admin), and returns the household ID to share
//      with the spouse for joining.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'missing authorization' }, 401);
    const anon = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: { user }, error: userErr } = await anon.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: existing } = await admin.from('household_members')
      .select('household_id').eq('user_id', user.id).limit(1).maybeSingle();
    if (existing) return json({ error: 'already in a household', household_id: existing.household_id }, 409);

    const { data: hh, error: hhErr } = await admin.from('households')
      .insert({ name: 'Household', base_allowance_cents: 37500 }).select('id').single();
    // Detailed errors are returned on purpose (no secret is ever included):
    // the first version hid the real cause behind a generic message, which
    // made a real failure undebuggable from the app.
    if (hhErr) return json({ error: 'household create failed', step: 'households insert', detail: hhErr.message }, 500);
    const { error: memErr } = await admin.from('household_members')
      .insert({ household_id: hh.id, user_id: user.id, role: 'admin' });
    if (memErr) return json({ error: 'membership create failed', step: 'household_members insert', detail: memErr.message, household_id: hh.id }, 500);
    const { error: auditErr } = await admin.from('audit_log').insert({
      household_id: hh.id, actor: user.id, actor_name: 'admin',
      action: 'Household created', detail: 'Created via bootstrap-household; creator is admin.',
    });
    if (auditErr) console.warn('bootstrap audit insert failed (household still created):', auditErr.message);
    return json({ household_id: hh.id, role: 'admin' });
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
