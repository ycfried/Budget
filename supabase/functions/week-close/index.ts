// week-close — close completed weeks into the Extra Fund (spec A4/A5).
// Admin-only, caller JWT, idempotent: running it twice changes nothing
// the second time (locked weeks are never recomputed, released weeks
// are never re-released).
//
// Chain: weeks run from the earliest week containing a transaction
// through the last completed week (weekStart < current week start).
// Debt and refund credit chain from each week's outgoing values into
// the next week's inputs. The chain starts at D=0, R_in=0 in the
// earliest week — stated honestly, since no earlier state exists.
//
// FIN-REFUND-001 (still OPEN, owner-deferred): a week with excess
// refunds, no incoming debt, and no charges gets status 'held' and
// NEVER auto-releases. It stays held until the owner rules.
//
// Late reductions (spec A4): if an already-released week's surplus
// shrinks on recompute, the reduction comes out of the current fund
// ledger (adjustment entry, floored at $0) and any remainder becomes
// a shortfall on the household, netted against the next release.
// There is no clawback from the normal weekly budget.
//
// Deploy: paste this file AND the shared engine.mjs into the
// function's folder in the Supabase dashboard (Via Editor), exactly
// like compute-week. The function reads no service-role key.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  computeWeek, weekStartOf, nyTodayString, addDays,
  surplusReleaseDate, isWeekLocked,
} from '../_shared/engine.mjs';

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
    if (!householdId) return json({ error: 'household_id required' }, 400);

    const { data: membership, error: memErr } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (memErr || !membership) return json({ error: 'not a household member' }, 403);
    if (membership.role !== 'admin') return json({ error: 'admin only' }, 403);

    const { data: household, error: hhErr } = await supabase
      .from('households')
      .select('base_allowance_cents, fund_shortfall_cents')
      .eq('id', householdId)
      .single();
    if (hhErr || !household) return json({ error: 'household not found' }, 404);

    const { data: txns } = await supabase
      .from('transactions')
      .select('date, amount_cents, fund_allocation_cents')
      .eq('household_id', householdId)
      .eq('excluded', false)
      .neq('state', 'reversed');
    const { data: temps } = await supabase
      .from('temp_increases')
      .select('week_start, amount_cents')
      .eq('household_id', householdId);
    const { data: closes } = await supabase
      .from('week_closes')
      .select('week_start, surplus_cents, outgoing_debt_cents, outgoing_credit_cents')
      .eq('household_id', householdId);
    const { data: releases } = await supabase
      .from('surplus_releases')
      .select('week_start, surplus_cents, release_date, status, released_cents')
      .eq('household_id', householdId);
    const { data: ledger } = await supabase
      .from('fund_ledger')
      .select('amount_cents')
      .eq('household_id', householdId);

    const today = nyTodayString();
    const currentWeekStart = weekStartOf(today);
    const allTxns = txns ?? [];
    if (allTxns.length === 0) {
      return json({ weeks_closed: 0, releases: 0, held: 0, fund_available_cents: 0, shortfall_cents: household.fund_shortfall_cents ?? 0 });
    }
    const earliest = allTxns.map((t) => weekStartOf(t.date)).sort()[0];

    const closeByWeek = new Map((closes ?? []).map((c) => [c.week_start, c]));
    const releaseByWeek = new Map((releases ?? []).map((r) => [r.week_start, r]));
    let fundAvailable = (ledger ?? []).reduce((s, r) => s + r.amount_cents, 0);
    let shortfall = household.fund_shortfall_cents ?? 0;

    let D = 0, R_in = 0;
    let weeksClosed = 0, releasesDone = 0, held = 0;
    // Walk weeks from the earliest transaction week to the last
    // completed week (a week is completed when its start is before
    // the current week's start).
    for (let ws = earliest; ws < currentWeekStart; ws = addDays(ws, 7)) {
      const weekTxns = allTxns.filter((t) => weekStartOf(t.date) === ws);
      const net = weekTxns.reduce((s, t) => s + t.amount_cents - (t.fund_allocation_cents ?? 0), 0);
      const C = net >= 0 ? net : 0;
      const X = net < 0 ? -net : 0;
      const T = (temps ?? []).filter((t) => t.week_start === ws).reduce((s, t) => s + t.amount_cents, 0);
      const locked = isWeekLocked(ws, currentWeekStart);
      const existingClose = closeByWeek.get(ws);

      if (locked && existingClose) {
        // Locked history never changes: chain from the recorded values.
        D = existingClose.outgoing_debt_cents ?? 0;
        R_in = existingClose.outgoing_credit_cents ?? 0;
        continue;
      }
      const result = computeWeek({ B: household.base_allowance_cents, T, R_in, X, D, C });
      const finHeld = X > 0 && D === 0 && C === 0;

      await supabase.from('week_closes').upsert({
        household_id: householdId, week_start: ws,
        surplus_cents: result.earnedSurplus,
        outgoing_debt_cents: result.outgoingDebt,
        outgoing_credit_cents: result.outgoingCredit,
      }, { onConflict: 'household_id,week_start' });
      weeksClosed += 1;

      const existingRelease = releaseByWeek.get(ws);
      if (existingRelease) {
        // Recompute-reduction on an already-released week (spec A4).
        if (existingRelease.status === 'released' && result.earnedSurplus < (existingRelease.surplus_cents ?? 0)) {
          const reduction = (existingRelease.surplus_cents ?? 0) - result.earnedSurplus;
          const applied = Math.min(reduction, fundAvailable);
          if (applied > 0) {
            await supabase.from('fund_ledger').insert({
              household_id: householdId, kind: 'adjustment', amount_cents: -applied,
              week_start: ws, note: `Late reduction for week ${ws}`, created_by: user.id,
            });
            fundAvailable -= applied;
          }
          shortfall += reduction - applied;
        }
        const nextStatus = existingRelease.status === 'held' && !finHeld ? 'pending' : existingRelease.status;
        await supabase.from('surplus_releases').upsert({
          household_id: householdId, week_start: ws,
          surplus_cents: result.earnedSurplus,
          release_date: existingRelease.release_date,
          status: nextStatus,
          released_cents: existingRelease.released_cents ?? 0,
        }, { onConflict: 'household_id,week_start' });
        releaseByWeek.set(ws, { ...existingRelease, surplus_cents: result.earnedSurplus, status: nextStatus });
      } else {
        const rel = {
          household_id: householdId, week_start: ws,
          surplus_cents: result.earnedSurplus,
          release_date: surplusReleaseDate(ws),
          status: finHeld ? 'held' : 'pending',
          released_cents: 0,
        };
        await supabase.from('surplus_releases').insert(rel);
        releaseByWeek.set(ws, rel);
      }

      // Due releases: release_date reached and still pending.
      const rel = releaseByWeek.get(ws);
      if (rel && rel.status === 'pending' && rel.release_date <= today) {
        const applied = Math.min(shortfall, rel.surplus_cents);
        const releasedToFund = rel.surplus_cents - applied;
        shortfall -= applied;
        await supabase.from('fund_ledger').insert({
          household_id: householdId, kind: 'release', amount_cents: releasedToFund,
          week_start: ws, note: `Surplus released for week ${ws}`, created_by: user.id,
        });
        fundAvailable += releasedToFund;
        await supabase.from('surplus_releases').upsert({
          household_id: householdId, week_start: ws,
          surplus_cents: rel.surplus_cents,
          release_date: rel.release_date,
          status: 'released',
          released_cents: releasedToFund,
        }, { onConflict: 'household_id,week_start' });
        releasesDone += 1;
        await supabase.from('audit_log').insert({
          household_id: householdId, actor: user.id, actor_name: 'admin',
          action: 'Surplus released',
          detail: `Surplus ${rel.surplus_cents} cents for week ${ws} released to the Extra Fund.`,
        });
      }
      if (finHeld) held += 1;
      D = result.outgoingDebt;
      R_in = result.outgoingCredit;
    }

    if (shortfall !== (household.fund_shortfall_cents ?? 0)) {
      await supabase.from('households').update({ fund_shortfall_cents: shortfall }).eq('id', householdId);
    }
    await supabase.from('audit_log').insert({
      household_id: householdId, actor: user.id, actor_name: 'admin',
      action: 'Weeks processed',
      detail: `${weeksClosed} week(s) closed, ${releasesDone} release(s).`,
    });

    return json({
      weeks_closed: weeksClosed, releases: releasesDone, held,
      fund_available_cents: fundAvailable, shortfall_cents: shortfall,
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
