// compute-week — server-side week calculation for the Household Budget app.
// Deployed as a Supabase Edge Function (Deno). The client NEVER computes
// authoritative numbers; it only displays what this function returns.
//
// Auth: the caller sends their Supabase user JWT (Authorization: Bearer).
// The function verifies it, checks the user belongs to the requested
// household (household_members), and returns the week math from the single
// shared engine (engine.mjs alongside this file).
// Role checks: any household member may READ their own week's numbers;
// this function performs no writes, so no admin check is needed here.
//
// FINAL (A2/A4) contract — read before changing the response:
// - Client-supplied D, T, and any legacy credit fields are IGNORED
//   entirely (audit P1-5). D is derived server-side from the latest
//   week_closes row before the requested week, minus restoration debt
//   cuts posted after that close (see below). T is derived server-side
//   from temp_increases for the requested week, unless the week already
//   has a close with a stored snapshot, in which case the snapshot's
//   B/T win (a later allowance change never rewrites a closed week).
// - Weekly allowance override (send-live-bundle): if a
//   weekly_allowance_overrides row exists for the requested week,
//   B is that override and T is 0 (debt still comes off the top).
//   A stored close snapshot still wins over a later override.
// - Week math counts: charges (including provisional charges) net of
//   fund allocations; posted refunds linked to a purchase in this week
//   (open weeks only — a locked week's refunds go through restoration,
//   never through this week's C); unlinked posted refunds dated in this
//   week (fallback until the S3 linking workstream links everything);
//   and, for the CURRENT week only, unposted late charges from locked
//   weeks (audit P0-9 — see week-close for how they freeze into a
//   snapshot when the current week closes).
// - Excluded from math (engine.isExcludedFromMath): excluded rows,
//   state 'reversed', kind 'payment', kind 'cashback', and provisional
//   REFUNDS (pending restores nothing, audit P0-12). Provisional
//   charges still count. Cash-back reclassified by an admin via the
//   reclassify_transaction RPC counts under its CURRENT kind.
// - C is floored at 0 (FINAL A2). A negative net in an open week (a
//   refund larger than the week's charges) floors here; any amount
//   beyond the original purchase is captured by week-close's held
//   queue, not by this function.
//
// RESPONSE SHAPE (exact — the UI workstream codes against these 8
// fields and no others; do not add fields without coordinating):
// {
//   week_start: "YYYY-MM-DD" (Sunday, normalized from the request),
//   base_available_cents: base capacity left after incoming debt,
//   temp_cents: active temporary increment for the week,
//   carried_debt_cents: incoming debt D carried INTO the week
//     (NOT the engine's carriedDebt output, which is max(0, D - B);
//     the UI asked for "carried debt" and the dashboard's "incoming
//     debt" is D — see S2_NOTES.md for the mapping and the open
//     confirmation item),
//   charges_cents: C (floored net eligible charges),
//   available_cents: base_available + temp - charges (may be negative),
//   week_locked: boolean (28-day open window, FINAL A4),
//   pending_refund_excluded_cents: absolute total of provisional
//     refunds excluded from this week's math (display only)
// }
// Pre-migration fallbacks: if the restoration-snapshots migration has
// not been applied yet (no snapshot columns, no restoration_entries
// table, no original_purchase_id column), this function still works
// on the old columns and treats linked-refund attribution and
// restoration debt cuts as zero, rather than failing the dashboard.
// Those fallbacks are marked FALLBACK below and disappear once the
// migration is applied.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  computeWeek, weekStartOf, nyTodayString, addDays, isWeekLocked,
  isExcludedFromMath, pendingRefundExcludedCents, chargeContribution,
} from './engine.mjs';

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
    const rawWeek = String(body.week_start ?? '');
    const today = nyTodayString();
    const currentWeekStart = weekStartOf(today);
    const weekStart = rawWeek ? weekStartOf(rawWeek) : currentWeekStart;
    // NOTE: body.D, body.T, and any legacy credit fields are
    // deliberately never read here. Server-side derivation only.

    const { data: membership, error: memErr } = await supabase
      .from('household_members')
      .select('role')
      .eq('household_id', householdId)
      .eq('user_id', user.id)
      .maybeSingle();
    if (memErr || !membership) return json({ error: 'not a household member' }, 403);

    const { data: household, error: hhErr } = await supabase
      .from('households')
      .select('base_allowance_cents')
      .eq('id', householdId)
      .single();
    if (hhErr || !household) return json({ error: 'household not found' }, 404);

    // Week closes, with snapshot columns when the migration exists.
    // FALLBACK: without the migration, snapshot fields are null and
    // the live allowance / temp sums below are used instead.
    let closes: any[] = [];
    const closesRes = await supabase
      .from('week_closes')
      .select('week_start, surplus_cents, outgoing_debt_cents, late_adjustment_cents, base_allowance_cents, temp_increase_cents, created_at')
      .eq('household_id', householdId);
    if (closesRes.error) {
      const retry = await supabase
        .from('week_closes')
        .select('week_start, surplus_cents, outgoing_debt_cents, created_at')
        .eq('household_id', householdId);
      if (retry.error) return json({ error: 'week close read failed' }, 500);
      closes = (retry.data ?? []).map((c: any) => ({ ...c, late_adjustment_cents: 0, base_allowance_cents: null, temp_increase_cents: null }));
    } else {
      closes = closesRes.data ?? [];
    }
    const closeByWeek = new Map(closes.map((c: any) => [c.week_start, c]));
    const thisClose = closeByWeek.get(weekStart);

    // Temporary increases for the requested week (server-side).
    const { data: temps, error: tempErr } = await supabase
      .from('temp_increases')
      .select('week_start, amount_cents')
      .eq('household_id', householdId);
    if (tempErr) return json({ error: 'temp increase read failed' }, 500);
    const tempSum = (temps ?? [])
      .filter((t: any) => t.week_start === weekStart)
      .reduce((s: number, t: any) => s + (t.amount_cents ?? 0), 0);

    // Weekly allowance overrides (send-live-bundle; SQL in
    // supabase/weekly-allowance-override.sql, owner review only).
    // A row for the requested week replaces base + temp with
    // B = override, T = 0. If the table does not exist yet (the
    // SQL has not been applied), the read fails and the override
    // is treated as absent — old behaviour, no error.
    let overrideCents: number | null = null;
    const ovRes = await supabase
      .from('weekly_allowance_overrides')
      .select('week_start, allowance_cents')
      .eq('household_id', householdId);
    if (!ovRes.error) {
      const row = (ovRes.data ?? []).find((o: any) => o.week_start === weekStart);
      if (row && row.allowance_cents != null) overrideCents = row.allowance_cents;
    }

    // Restoration debt cuts posted after the latest close (FALLBACK:
    // no table yet -> no cuts). These reduce the debt carried into
    // later weeks; cuts are never subtracted twice because only
    // entries after the latest close week are counted.
    let restorationCuts = 0;
    const latestCloseBefore = closes
      .filter((c: any) => c.week_start < weekStart)
      .sort((a: any, b: any) => (a.week_start < b.week_start ? 1 : -1))[0];
    if (latestCloseBefore) {
      const restRes = await supabase
        .from('restoration_entries')
        .select('week_start, debt_reduction_cents')
        .eq('household_id', householdId);
      if (!restRes.error) {
        restorationCuts = (restRes.data ?? [])
          .filter((r: any) => r.week_start > latestCloseBefore.week_start && r.week_start <= weekStart)
          .reduce((s: number, r: any) => s + (r.debt_reduction_cents ?? 0), 0);
      }
    }

    // Transactions for the household (household-scale; see S2_NOTES.md
    // for the pagination note). FALLBACK: without the migration's
    // linkage column, refunds net by date in their own week.
    let txns: any[] = [];
    let hasLinkage = true;
    const txRes = await supabase
      .from('transactions')
      .select('id, date, amount_cents, kind, state, excluded, fund_allocation_cents, original_purchase_id, created_at')
      .eq('household_id', householdId)
      .limit(10000);
    if (txRes.error) {
      const retry = await supabase
        .from('transactions')
        .select('id, date, amount_cents, kind, state, excluded, fund_allocation_cents, created_at')
        .eq('household_id', householdId)
        .limit(10000);
      if (retry.error) return json({ error: 'transaction read failed' }, 500);
      txns = (retry.data ?? []).map((t: any) => ({ ...t, original_purchase_id: null }));
      hasLinkage = false;
    } else {
      txns = txRes.data ?? [];
    }

    const weekEnd = addDays(weekStart, 7);
    const inWindow = (t: any) => t.date >= weekStart && t.date < weekEnd;
    const windowRows = txns.filter(inWindow);
    const weekLocked = isWeekLocked(weekStart, currentWeekStart);

    // Charges in the window (charge/fund_charge net of fund allocation;
    // provisional charges count; refunds/payments/cash-back do not
    // contribute here — see chargeContribution).
    let chargesNet = windowRows.reduce((s: number, t: any) => s + chargeContribution(t), 0);

    // Posted refunds: linked to a purchase in this week (open weeks
    // only), plus unlinked posted refunds dated in this week.
    const purchaseIdsInWindow = new Set(
      windowRows.filter((t: any) => t.kind === 'charge' || t.kind === 'fund_charge').map((t: any) => t.id),
    );
    const postedRefund = (t: any) =>
      t.kind === 'refund' && t.state === 'verified' && t.excluded !== true && t.state !== 'reversed';
    if (!weekLocked) {
      for (const t of txns) {
        if (postedRefund(t) && t.original_purchase_id && purchaseIdsInWindow.has(t.original_purchase_id)) {
          chargesNet += t.amount_cents ?? 0; // negative: reduces C
        }
      }
    }
    for (const t of windowRows) {
      if (postedRefund(t) && (!hasLinkage || !t.original_purchase_id)) {
        // Unlinked (or pre-migration) posted refund dated in this week.
        // Pre-migration fallback: every posted refund in the window
        // nets here, since linkage cannot be checked.
        // Locked-week reconstruction guard: a refund that arrived
        // AFTER this week's close was recorded does not rewrite it.
        if (thisClose && t.created_at && thisClose.created_at && t.created_at > thisClose.created_at) continue;
        chargesNet += t.amount_cents ?? 0;
      }
    }

    // Late charges (P0-9): for the CURRENT week, add locked-week
    // charges not yet frozen into any close snapshot. For a week
    // that already has a close, use its stored late adjustment so a
    // recompute reproduces the close; other past weeks get 0 here
    // (late charges belong to the current week until they freeze).
    let latePart = 0;
    if (weekStart === currentWeekStart) {
      const lockedTotal = txns
        .filter((t: any) => {
          const w = weekStartOf(t.date);
          return isWeekLocked(w, currentWeekStart) && closeByWeek.has(w)
            && (t.kind === 'charge' || t.kind === 'fund_charge')
            && t.excluded !== true && t.state !== 'reversed';
        })
        .reduce((s: number, t: any) => s + (t.amount_cents ?? 0) - (t.fund_allocation_cents ?? 0), 0);
      const alreadyPosted = closes.reduce((s: number, c: any) => s + (c.late_adjustment_cents ?? 0), 0);
      latePart = Math.max(0, lockedTotal - alreadyPosted);
      chargesNet += latePart;
    } else if (thisClose) {
      latePart = thisClose.late_adjustment_cents ?? 0;
      chargesNet += latePart;
    }

    // Pending refunds excluded from math (display only). Window-dated
    // provisional refunds plus provisional refunds linked to a
    // purchase in this week but dated elsewhere, de-duplicated by id.
    const pendingById = new Map<string, any>();
    for (const t of windowRows) {
      if (t.kind === 'refund' && t.state === 'provisional' && t.excluded !== true && t.state !== 'reversed') {
        pendingById.set(t.id, t);
      }
    }
    for (const t of txns) {
      if (t.kind === 'refund' && t.state === 'provisional' && t.excluded !== true && t.state !== 'reversed'
        && t.original_purchase_id && purchaseIdsInWindow.has(t.original_purchase_id)) {
        pendingById.set(t.id, t);
      }
    }
    const pendingExcluded = [...pendingById.values()]
      .reduce((s: number, t: any) => s + Math.abs(t.amount_cents ?? 0), 0);
    void pendingRefundExcludedCents;
    void isExcludedFromMath;

    // Snapshot precedence: a closed week's stored B/T win over any
    // later override (a later change never rewrites a closed week).
    // An override set after a week closed therefore does not change
    // that week; it applies to open and future weeks, and week-close
    // stores the override as the snapshot when it closes the week.
    const B = thisClose && thisClose.base_allowance_cents != null
      ? thisClose.base_allowance_cents
      : overrideCents != null
      ? overrideCents
      : household.base_allowance_cents;
    const T = thisClose && thisClose.temp_increase_cents != null
      ? thisClose.temp_increase_cents
      : overrideCents != null
      ? 0
      : tempSum;
    const D = latestCloseBefore
      ? Math.max(0, (latestCloseBefore.outgoing_debt_cents ?? 0) - restorationCuts)
      : 0;
    const C = Math.max(0, chargesNet);

    const result = computeWeek({ B, T, D, C });

    // EXACT response shape — no extra fields.
    return json({
      week_start: weekStart,
      base_available_cents: result.baseAvailable,
      temp_cents: result.T,
      carried_debt_cents: result.D,
      charges_cents: result.C,
      available_cents: result.available,
      week_locked: weekLocked,
      pending_refund_excluded_cents: pendingExcluded,
    });
  } catch (e) {
    return json({ error: String((e as any)?.message ?? e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
