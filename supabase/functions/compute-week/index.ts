// compute-week — server-side week calculation for the Household Budget app.
// Deployed as a Supabase Edge Function (Deno). The client NEVER computes
// authoritative numbers; it only displays what this function returns.
//
// Auth: the caller sends their Supabase user JWT (Authorization: Bearer).
// The function verifies it, checks the user belongs to the requested
// household (household_members), and returns the week math from the single
// shared engine (../_shared/engine.mjs — same file as the PWA/server use).
// Role checks: any household member may READ their own week's numbers;
// this function performs no writes, so no admin check is needed here.
// FIN-REFUND-001 is still OPEN: outputs that depend on that case are
// flagged not_production_certified in the response, exactly as the PWA does.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { computeWeek, weekStartOf, nyTodayString } from '../_shared/engine.mjs';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) {
      return json({ error: 'missing authorization' }, 401);
    }
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: { user }, error: userErr } = await supabase.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const body = await req.json().catch(() => ({}));
    const householdId = String(body.household_id ?? '');
    const weekStart = String(body.week_start ?? weekStartOf(nyTodayString()));
    if (!householdId) return json({ error: 'household_id required' }, 400);

    // Membership check (RLS on household_members enforces this too).
    const { data: membership, error: memErr } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (memErr || !membership) return json({ error: 'not a household member' }, 403);

    // Household base allowance.
    const { data: household, error: hhErr } = await supabase
      .from('households')
      .select('base_allowance_cents')
      .eq('id', householdId)
      .single();
    if (hhErr || !household) return json({ error: 'household not found' }, 404);

    // This week's eligible charges, net of linked refunds, floored at 0.
    // Uses the same week window as the engine: [weekStart, weekStart+7).
    const weekEnd = addDaysStr(weekStart, 7);
    const { data: txns, error: txErr } = await supabase
      .from('transactions')
      .select('amount_cents, kind, excluded, state')
      .eq('household_id', householdId)
      .gte('date', weekStart)
      .lt('date', weekEnd)
      .eq('excluded', false)
      .neq('state', 'reversed');
    if (txErr) return json({ error: 'transaction read failed' }, 500);

    const charges = (txns ?? [])
      .filter((t) => t.kind === 'charge')
      .reduce((s, t) => s + t.amount_cents, 0);
    const refunds = (txns ?? [])
      .filter((t) => t.kind === 'refund')
      .reduce((s, t) => s + t.amount_cents, 0);
    const C = Math.max(0, charges - refunds);

    // Temporary increments and carried credit/debt are supplied by the
    // caller for now (they live in week-state rows once the week-close
    // function lands); default to 0 so a plain current-week read works.
    const result = computeWeek({
      B: household.base_allowance_cents,
      T: body.T ?? 0,
      R_in: body.R_in ?? 0,
      X: body.X ?? 0,
      D: body.D ?? 0,
      C,
    });

    // FIN-REFUND-001 flag: the deferred case is X > 0 with no debt and no
    // charges, where the engine reports both surplus and outgoing credit.
    const finRefund001Affected = (body.X ?? 0) > 0 && (body.D ?? 0) === 0 && C === 0;

    return json({
      household_id: householdId,
      week_start: weekStart,
      role: membership.role,
      inputs: { B: result.B, T: result.T, R_in: result.R_in, X: result.X, D: result.D, C: result.C },
      result,
      not_production_certified: finRefund001Affected,
      fin_refund_001: finRefund001Affected
        ? 'OPEN: owner has deferred the refund-credit/surplus policy; do not use for automatic fund release.'
        : null,
    });
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

function addDaysStr(dateStr: string, days: number) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const utc = new Date(Date.UTC(y, m - 1, d));
  utc.setUTCDate(utc.getUTCDate() + days);
  return utc.toISOString().slice(0, 10);
}
