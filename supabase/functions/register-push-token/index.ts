// register-push-token — upserts (or deletes) the caller's device token
// in push_tokens.
//
// Contract:
//   Request (POST): { household_id, device_token, environment?, unregister? }.
//     environment: 'sandbox' | 'production' (default 'production').
//     unregister: true deletes the row instead of upserting it.
//   Auth: the signed-in user's JWT (verify_jwt = true in config.toml).
//   The caller must be a member of the household. A user can only ever
//   touch their own token rows (user_id = auth.uid()).
//   Response: { ok: true }.
//   Called from the native app when APNs issues a token, when the app
//   launches and permission is already granted, and best-effort on
//   sign-out / account deletion. Failures are silent to the user.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'missing authorization' }, 401);
    if (!SUPABASE_URL || !SERVICE_KEY) return json({ error: 'service key not configured' }, 503);

    const body = await req.json().catch(() => ({}));
    const householdId = String(body.household_id ?? '');
    const deviceToken = String(body.device_token ?? '');
    const environment = String(body.environment ?? 'production');
    const unregister = body.unregister === true;
    if (!householdId) return json({ error: 'household_id required' }, 400);
    if (!deviceToken) return json({ error: 'device_token required' }, 400);
    if (environment !== 'sandbox' && environment !== 'production') {
      return json({ error: 'environment must be sandbox or production' }, 400);
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: auth } },
    });
    const { data: { user }, error: userErr } = await supabase.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);
    const { data: membership } = await supabase
      .from('household_members')
      .select('user_id')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (!membership) return json({ error: 'not a household member' }, 403);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    if (unregister) {
      const { error } = await admin
        .from('push_tokens')
        .delete()
        .eq('household_id', householdId)
        .eq('user_id', user.id)
        .eq('device_token', deviceToken);
      if (error) return json({ error: 'could not unregister token' }, 500);
      return json({ ok: true });
    }

    const { error } = await admin
      .from('push_tokens')
      .upsert(
        {
          household_id: householdId,
          user_id: user.id,
          device_token: deviceToken,
          platform: 'ios',
          environment,
          last_seen_at: new Date().toISOString(),
        },
        { onConflict: 'user_id,device_token' },
      );
    if (error) return json({ error: 'could not register token' }, 500);
    return json({ ok: true });
  } catch (e) {
    console.error('register-push-token failed:', (e as Error)?.message ?? e);
    return json({ error: 'could not register token' }, 500);
  }
});
