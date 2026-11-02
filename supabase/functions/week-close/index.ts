// week-close — close completed weeks into the Extra Fund (FINAL A4/A5).
// Admin-only, caller JWT, idempotent: running it twice changes nothing
// the second time (locked weeks are never recomputed, released weeks
// are never re-released, restoration entries are unique per refund).
//
// What changed from the old implementation (audit §0, P0-8–P0-15,
// P1-5–P1-9):
// - NO refund-credit chain. Debt chains alone (outgoing debt of one
//   week is the next week's incoming debt). No credit is persisted,
//   read, or returned anywhere.
// - Per-week policy snapshots (P0-11): week_closes stores the
//   effective base_allowance_cents and temp_increase_cents used for
//   that week. A recompute of a week that already has a snapshot uses
//   the SNAPSHOT, never the household's current allowance. Weeks
//   closed for the first time stamp the current allowance (backfill
//   limitation — see S2_NOTES.md: run week-close before changing the
//   allowance, because a never-closed completed week has no snapshot
//   to recover its old allowance from). set_base_allowance is
//   future-effective only (S1 RPC); this function never applies the
//   current allowance to a snapshotted week.
// - Pending window anchored to the ACTUAL close date (P1-6): a new
//   release gets release_date = close date + 7 days, not weekStart +
//   14. Legacy pending releases without a closed_at get one derived
//   from their close row's created_at on recompute.
// - Surplus INCREASE after release releases the delta net of
//   shortfall (P1-7); surplus decrease still reduces the fund to at
//   most zero with the remainder as shortfall (A4).
// - Locked-week late charges (P0-9) post as current-week adjustments:
//   compute-week shows them dynamically in the current week, and when
//   that current week itself closes, its week_closes row freezes them
//   in late_adjustment_cents. The rule is total-minus-stored (see
//   below), so a late charge is frozen exactly once, never twice.
// - Refund restoration (P0-8, FINAL A4): verified refunds linked to
//   a purchase get ONE restoration_entry each (see restoration.mjs
//   for the pure math). Surplus + fund credits offset any recorded
//   shortfall FIRST; the remainder reaches the fund ledger as kind
//   'restoration'. Debt cuts do not move ledger money — they reduce
//   the debt carried into the week the entry was posted in (and into
//   later closes through the chain; compute-week applies the same
//   rule). Excess over the original charge goes to held_refunds.
//   Pending refunds are never processed here.
// - EVERY write is checked (P0-15): any write error throws and the
//   run returns 500 instead of success counts. Shortfall is persisted
//   ONLY via the update_fund_shortfall RPC (S1 workstream, exact
//   name, arguments { household_id, shortfall_cents }); it is called
//   only when the shortfall value actually changed.
// - Concurrency guard (P1-9): a release is claimed with a conditional
//   update (… where status = 'pending', row count checked) BEFORE
//   the fund ledger row is inserted, so two concurrent runs cannot
//   both release the same surplus. True multi-table atomicity still
//   needs a DB transaction (S1 RPC); this is the conditional-claim
//   mitigation the audit prescribes for Edge Functions, plus loud
//   failure and a best-effort revert if the ledger insert then fails.
//
// Deployment order: apply supabase/restoration-snapshots.sql BEFORE
// deploying this function. Pre-migration fallbacks below keep closes
// and releases working on old columns, but restoration posting needs
// the new tables and the fund_ledger 'restoration' kind; without them
// restoration is skipped (reported, not silent) or fails loudly.
// Write path dependency: restoration_entries / held_refunds have NO
// direct member write grants by design (RLS hardening is another
// workstream's file). Until that workstream provides a write path
// for this function, restoration inserts will fail loudly — see
// S2_NOTES.md. Closes/releases already persisted before the
// restoration phase are NOT rolled back; the 500 response reports
// exactly what succeeded so a re-run is safe.
//
// Late-charge freezing rule (total-minus-stored, idempotent):
//   lockedAlreadyClosed = sum of charges dated in weeks that are
//     locked AND already have a close row (a charge is "late" only
//     once its week is closed; a first-ever close counts the charge
//     as its own week's charge, not as late).
//   alreadyPosted = sum of late_adjustment_cents over all close rows.
//   unposted = max(0, lockedAlreadyClosed - alreadyPosted).
//   The most recent completed week being (re)computed in this run
//   absorbs `unposted` on top of its stored late value; every other
//   week keeps its stored late value. A re-run then computes
//   unposted = 0. If no week is (re)computed this run (all locked),
//   `unposted` is reported as pending_late_adjustment_cents and
//   freezes on the next run that closes a week.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  computeWeek, weekStartOf, nyTodayString, addDays, isWeekLocked,
  chargeContribution,
} from './engine.mjs';
import {
  computeRestorationTotal, computeIncrementalRestoration,
} from './restoration.mjs';

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
    // Coordinator integration: membership/admin already verified above via the
    // caller JWT. All DB access below uses the service-role key (server-side
    // only, never in the browser) because member JWTs lost direct table/RPC
    // access in the S1 RLS hardening.
    const serviceKey = Deno.env.get('SUPABASE_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serviceKey) return json({ error: 'service key not configured' }, 503);
    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

    // ---- Loads (with pre-migration fallbacks; every read checked
    // except the explicitly optional restoration tables). ----
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
    const { data: temps, error: tempErr } = await supabase
      .from('temp_increases')
      .select('week_start, amount_cents')
      .eq('household_id', householdId);
    if (tempErr) return json({ error: 'temp increase read failed' }, 500);

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
    let releases: any[] = [];
    const relRes = await supabase
      .from('surplus_releases')
      .select('week_start, surplus_cents, release_date, status, released_cents, closed_at')
      .eq('household_id', householdId);
    if (relRes.error) {
      const retry = await supabase
        .from('surplus_releases')
        .select('week_start, surplus_cents, release_date, status, released_cents')
        .eq('household_id', householdId);
      if (retry.error) return json({ error: 'surplus release read failed' }, 500);
      releases = (retry.data ?? []).map((r: any) => ({ ...r, closed_at: null }));
    } else {
      releases = relRes.data ?? [];
    }
    const { data: ledger, error: ledgerErr } = await supabase
      .from('fund_ledger')
      .select('amount_cents')
      .eq('household_id', householdId);
    if (ledgerErr) return json({ error: 'fund ledger read failed' }, 500);

    // Optional restoration tables: a read failure here means the
    // migration has not been applied; restoration is skipped and
    // reported (not silent), while closes/releases still run.
    let restorationEntries: any[] = [];
    let heldRows: any[] = [];
    let restorationTablesMissing = false;
    const restRes = await supabase
      .from('restoration_entries')
      .select('week_start, purchase_transaction_id, refund_transaction_id, restored_surplus_cents, debt_reduction_cents, fund_credit_cents')
      .eq('household_id', householdId);
    if (restRes.error) {
      restorationTablesMissing = true;
    } else {
      restorationEntries = restRes.data ?? [];
      const heldRes = await supabase
        .from('held_refunds')
        .select('refund_transaction_id, held_cents, status')
        .eq('household_id', householdId);
      if (!heldRes.error) heldRows = heldRes.data ?? [];
    }

    const today = nyTodayString();
    const currentWeekStart = weekStartOf(today);
    const lastCompleted = addDays(currentWeekStart, -7);

    const closeByWeek = new Map(closes.map((c: any) => [c.week_start, c]));
    const releaseByWeek = new Map(releases.map((r: any) => [r.week_start, r]));
    const tempSum = (ws: string) => (temps ?? [])
      .filter((t: any) => t.week_start === ws)
      .reduce((s: number, t: any) => s + (t.amount_cents ?? 0), 0);
    const postedRefund = (t: any) =>
      t.kind === 'refund' && t.state === 'verified' && t.excluded !== true && t.state !== 'reversed';
    const inWeek = (t: any, ws: string) => t.date >= ws && t.date < addDays(ws, 7);
    const ownCharges = (ws: string) =>
      txns.filter((t: any) => inWeek(t, ws)).reduce((s: number, t: any) => s + chargeContribution(t), 0);
    const linkedPostedToWeek = (ws: string) => {
      const purchaseIds = new Set(
        txns.filter((t: any) => inWeek(t, ws) && (t.kind === 'charge' || t.kind === 'fund_charge')).map((t: any) => t.id),
      );
      return txns
        .filter((t: any) => postedRefund(t) && t.original_purchase_id && purchaseIds.has(t.original_purchase_id))
        .reduce((s: number, t: any) => s + (t.amount_cents ?? 0), 0);
    };
    const unlinkedPostedInWeek = (ws: string) =>
      txns.filter((t: any) => inWeek(t, ws) && postedRefund(t) && !t.original_purchase_id)
        .reduce((s: number, t: any) => s + (t.amount_cents ?? 0), 0);
    // Charges for a week as the walk/simulation reconstruct them.
    // Open weeks net linked refunds (recompute); locked weeks never
    // net linked refunds (restoration instead). Unlinked posted
    // refunds dated in the week net in that week whenever it is
    // (re)computed. Stored late adjustments are part of the week.
    const weekCharges = (ws: string) => {
      const locked = isWeekLocked(ws, currentWeekStart);
      const storedLate = closeByWeek.get(ws)?.late_adjustment_cents ?? 0;
      return ownCharges(ws)
        + (locked ? 0 : linkedPostedToWeek(ws))
        + unlinkedPostedInWeek(ws)
        + storedLate;
    };
    const weekPolicy = (ws: string) => {
      const snap = closeByWeek.get(ws);
      return {
        B: snap && snap.base_allowance_cents != null ? snap.base_allowance_cents : household.base_allowance_cents,
        T: snap && snap.temp_increase_cents != null ? snap.temp_increase_cents : tempSum(ws),
      };
    };

    let fundAvailable = (ledger ?? []).reduce((s: number, r: any) => s + (r.amount_cents ?? 0), 0);
    let shortfall = household.fund_shortfall_cents ?? 0;
    const shortfallAtStart = shortfall;

    // ---- Walk range ----
    const candidateWeeks: string[] = [];
    for (const t of txns) candidateWeeks.push(weekStartOf(t.date));
    for (const c of closes) candidateWeeks.push(c.week_start);
    for (const r of releases) candidateWeeks.push(r.week_start);
    if (candidateWeeks.length === 0) {
      return json({ weeks_closed: 0, releases: 0, held_legacy: 0, restorations: 0, held_refunds_created: 0, fund_available_cents: fundAvailable, shortfall_cents: shortfall, pending_late_adjustment_cents: 0, restorations_skipped: [] });
    }
    const earliest = candidateWeeks.sort()[0];

    // ---- Late-charge precompute (total-minus-stored) ----
    const lockedAlreadyClosedTotal = txns
      .filter((t: any) => {
        const w = weekStartOf(t.date);
        return isWeekLocked(w, currentWeekStart) && closeByWeek.has(w)
          && (t.kind === 'charge' || t.kind === 'fund_charge')
          && t.excluded !== true && t.state !== 'reversed';
      })
      .reduce((s: number, t: any) => s + (t.amount_cents ?? 0) - (t.fund_allocation_cents ?? 0), 0);
    const alreadyPostedLate = closes.reduce((s: number, c: any) => s + (c.late_adjustment_cents ?? 0), 0);
    const unpostedLate = Math.max(0, lockedAlreadyClosedTotal - alreadyPostedLate);

    // Restoration debt cuts by posting week (for the walk's D input).
    const cutsByWeek = new Map<string, number>();
    for (const r of restorationEntries) {
      cutsByWeek.set(r.week_start, (cutsByWeek.get(r.week_start) ?? 0) + (r.debt_reduction_cents ?? 0));
    }

    // Write helpers: every write checked; a failure throws (P0-15).
    const check = (res: any, label: string) => {
      if (res?.error) throw new Error(`${label} failed: ${res.error.message ?? res.error}`);
      return res;
    };
    const upsertClose = async (row: any) => {
      const variants = [
        row,
        { household_id: row.household_id, week_start: row.week_start, surplus_cents: row.surplus_cents, outgoing_debt_cents: row.outgoing_debt_cents, late_adjustment_cents: row.late_adjustment_cents },
        { household_id: row.household_id, week_start: row.week_start, surplus_cents: row.surplus_cents, outgoing_debt_cents: row.outgoing_debt_cents },
      ];
      let lastErr: any = null;
      for (const payload of variants) {
        const res = await supabaseAdmin.from('week_closes').upsert(payload, { onConflict: 'household_id,week_start' });
        if (!res.error) return;
        lastErr = res.error;
      }
      throw new Error(`week_closes upsert failed: ${lastErr?.message ?? lastErr}`);
    };
    const upsertRelease = async (row: any) => {
      const variants = [row, (({ closed_at: _c, ...rest }: any) => rest)(row)];
      let lastErr: any = null;
      for (const payload of variants) {
        const res = await supabaseAdmin.from('surplus_releases').upsert(payload, { onConflict: 'household_id,week_start' });
        if (!res.error) return;
        lastErr = res.error;
      }
      throw new Error(`surplus_releases upsert failed: ${lastErr?.message ?? lastErr}`);
    };
    const insertRelease = async (row: any) => {
      const res = await supabaseAdmin.from('surplus_releases').insert(row);
      if (res.error) {
        const { closed_at: _c, ...rest } = row;
        const retry = await supabaseAdmin.from('surplus_releases').insert(rest);
        check(retry, 'surplus_releases insert');
      }
    };

    // Claim a pending release (conditional update, P1-9). Returns true
    // when this run won the claim, false when another run won.
    const claimRelease = async (ws: string, releasedCents: number) => {
      const res = await supabaseAdmin.from('surplus_releases')
        .update({ status: 'released', released_cents: releasedCents })
        .eq('household_id', householdId)
        .eq('week_start', ws)
        .eq('status', 'pending')
        .select('week_start');
      check(res, 'surplus_releases release claim');
      return (res.data ?? []).length > 0;
    };
    const releaseDue = async (ws: string, surplusCents: number) => {
      // Computes the shortfall offset from CURRENT in-memory shortfall,
      // claims, then inserts the ledger row. On ledger failure the
      // claim is best-effort reverted and the error propagates.
      const applied = Math.min(shortfall, surplusCents);
      const toFund = surplusCents - applied;
      const won = await claimRelease(ws, toFund);
      if (!won) return false;
      try {
        if (toFund > 0) {
          check(await supabaseAdmin.from('fund_ledger').insert({
            household_id: householdId, kind: 'release', amount_cents: toFund,
            week_start: ws, note: `Surplus released for week ${ws}`, created_by: user.id,
          }), 'fund_ledger release insert');
          fundAvailable += toFund;
        }
        shortfall -= applied;
      } catch (e) {
        await supabaseAdmin.from('surplus_releases')
          .update({ status: 'pending', released_cents: 0 })
          .eq('household_id', householdId)
          .eq('week_start', ws)
          .eq('status', 'released');
        throw e;
      }
      check(await supabaseAdmin.from('audit_log').insert({
        household_id: householdId, actor: user.id, actor_name: 'admin',
        action: 'Surplus released',
        detail: `Surplus ${surplusCents} cents for week ${ws} released to the Extra Fund.`,
      }), 'audit_log insert');
      return true;
    };

    // ---- Walk ----
    let Dchain = 0;
    {
      const before = closes.filter((c: any) => c.week_start < earliest).sort((a: any, b: any) => (a.week_start < b.week_start ? 1 : -1))[0];
      Dchain = before ? (before.outgoing_debt_cents ?? 0) : 0;
    }
    // Determine the absorbing week for unposted late charges: the
    // most recent completed week that will be (re)computed.
    let absorbingWeek: string | null = null;
    for (let ws = earliest; ws < currentWeekStart; ws = addDays(ws, 7)) {
      const locked = isWeekLocked(ws, currentWeekStart);
      if (!(locked && closeByWeek.has(ws))) absorbingWeek = ws;
    }
    const pendingLateAfterRun = absorbingWeek ? 0 : unpostedLate;

    let weeksClosed = 0, releasesDone = 0, heldLegacy = 0;
    const handledReleaseWeeks = new Set<string>();
    for (let ws = earliest; ws < currentWeekStart; ws = addDays(ws, 7)) {
      const locked = isWeekLocked(ws, currentWeekStart);
      const existingClose = closeByWeek.get(ws);
      if (locked && existingClose) {
        // Locked history never changes: chain from recorded values.
        Dchain = existingClose.outgoing_debt_cents ?? 0;
        continue;
      }
      const { B, T } = weekPolicy(ws);
      const storedLate = existingClose?.late_adjustment_cents ?? 0;
      const lateWs = ws === absorbingWeek ? storedLate + unpostedLate : storedLate;
      // C for this week: own + open-week linked refunds + unlinked
      // refunds + late. (weekCharges adds the STORED late; replace it
      // with lateWs for the absorbing week.)
      const lockedNow = isWeekLocked(ws, currentWeekStart);
      const Cnet = ownCharges(ws)
        + (lockedNow ? 0 : linkedPostedToWeek(ws))
        + unlinkedPostedInWeek(ws)
        + lateWs;
      const Dws = Math.max(0, Dchain - (cutsByWeek.get(ws) ?? 0));
      const result = computeWeek({ B, T, D: Dws, C: Math.max(0, Cnet) });

      await upsertClose({
        household_id: householdId, week_start: ws,
        surplus_cents: result.earnedSurplus,
        outgoing_debt_cents: result.outgoingDebt,
        base_allowance_cents: B,
        temp_increase_cents: T,
        late_adjustment_cents: lateWs,
      });
      closeByWeek.set(ws, {
        week_start: ws, surplus_cents: result.earnedSurplus,
        outgoing_debt_cents: result.outgoingDebt, late_adjustment_cents: lateWs,
        base_allowance_cents: B, temp_increase_cents: T,
        created_at: existingClose?.created_at ?? new Date().toISOString(),
      });
      weeksClosed += 1;

      const existingRelease = releaseByWeek.get(ws);
      if (existingRelease) {
        if (existingRelease.status === 'held') {
          // Legacy old-model held release: left untouched, never
          // auto-released (see S2_NOTES.md). Counted, not changed.
          heldLegacy += 1;
        } else if (existingRelease.status === 'released') {
          const oldSurplus = existingRelease.surplus_cents ?? 0;
          if (result.earnedSurplus < oldSurplus) {
            // Reduction after release (A4): fund to at most zero,
            // remainder becomes shortfall.
            const reduction = oldSurplus - result.earnedSurplus;
            const applied = Math.min(reduction, fundAvailable);
            if (applied > 0) {
              check(await supabaseAdmin.from('fund_ledger').insert({
                household_id: householdId, kind: 'adjustment', amount_cents: -applied,
                week_start: ws, note: `Late reduction for week ${ws}`, created_by: user.id,
              }), 'fund_ledger adjustment insert');
              fundAvailable -= applied;
            }
            shortfall += reduction - applied;
            await upsertRelease({
              household_id: householdId, week_start: ws,
              surplus_cents: result.earnedSurplus,
              release_date: existingRelease.release_date,
              status: 'released',
              released_cents: existingRelease.released_cents ?? 0,
            });
            releaseByWeek.set(ws, { ...existingRelease, surplus_cents: result.earnedSurplus });
          } else if (result.earnedSurplus > oldSurplus) {
            // Increase after release (P1-7): release the delta net
            // of shortfall. Claim first (optimistic on old surplus)
            // so a concurrent run cannot double-release the delta.
            const delta = result.earnedSurplus - oldSurplus;
            const claim = await supabaseAdmin.from('surplus_releases')
              .update({
                surplus_cents: result.earnedSurplus,
                released_cents: (existingRelease.released_cents ?? 0) + Math.max(0, delta - shortfall),
              })
              .eq('household_id', householdId)
              .eq('week_start', ws)
              .eq('status', 'released')
              .eq('surplus_cents', oldSurplus)
              .select('week_start');
            check(claim, 'surplus_releases delta claim');
            if ((claim.data ?? []).length > 0) {
              const offset = Math.min(shortfall, delta);
              const toFund = delta - offset;
              shortfall -= offset;
              try {
                if (toFund > 0) {
                  check(await supabaseAdmin.from('fund_ledger').insert({
                    household_id: householdId, kind: 'release', amount_cents: toFund,
                    week_start: ws, note: `Surplus increase released for week ${ws}`, created_by: user.id,
                  }), 'fund_ledger delta release insert');
                  fundAvailable += toFund;
                }
              } catch (e) {
                await supabaseAdmin.from('surplus_releases')
                  .update({ surplus_cents: oldSurplus, released_cents: existingRelease.released_cents ?? 0 })
                  .eq('household_id', householdId)
                  .eq('week_start', ws)
                  .eq('status', 'released');
                throw e;
              }
              releaseByWeek.set(ws, {
                ...existingRelease, surplus_cents: result.earnedSurplus,
                released_cents: (existingRelease.released_cents ?? 0) + toFund,
              });
              releasesDone += 1;
            }
          }
          // Equal surplus: nothing to change.
        } else if (existingRelease.status === 'pending') {
          // P1-6 for legacy rows: derive closed_at from the close
          // row when missing so the pending window anchors to the
          // actual close, then keep release_date = closed_at + 7.
          let closedAt = existingRelease.closed_at ?? null;
          let releaseDate = existingRelease.release_date;
          if (!closedAt && existingClose?.created_at) {
            closedAt = existingClose.created_at;
            const d = new Date(closedAt);
            const parts = new Intl.DateTimeFormat('en-US', {
              timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit',
            }).formatToParts(d);
            const get = (t: string) => parts.find((p: any) => p.type === t).value;
            releaseDate = addDays(`${get('year')}-${get('month')}-${get('day')}`, 7);
          }
          await upsertRelease({
            household_id: householdId, week_start: ws,
            surplus_cents: result.earnedSurplus,
            release_date: releaseDate,
            status: 'pending',
            released_cents: existingRelease.released_cents ?? 0,
            closed_at: closedAt,
          });
          releaseByWeek.set(ws, {
            ...existingRelease, surplus_cents: result.earnedSurplus,
            release_date: releaseDate, closed_at: closedAt,
          });
        }
      } else {
        // New release: pending 7 days from the ACTUAL close (today).
        const rel = {
          household_id: householdId, week_start: ws,
          surplus_cents: result.earnedSurplus,
          release_date: addDays(today, 7),
          status: 'pending',
          released_cents: 0,
          closed_at: new Date().toISOString(),
        };
        await insertRelease(rel);
        releaseByWeek.set(ws, { ...rel, closed_at: rel.closed_at });
      }

      // Due release for this week.
      const rel = releaseByWeek.get(ws);
      handledReleaseWeeks.add(ws);
      if (rel && rel.status === 'pending' && rel.release_date <= today) {
        if (await releaseDue(ws, rel.surplus_cents ?? 0)) releasesDone += 1;
      }
      Dchain = result.outgoingDebt;
    }

    // Second pass: due releases for weeks not walked (locked +
    // existing closes whose releases are still pending).
    for (const [ws, rel] of releaseByWeek) {
      if (handledReleaseWeeks.has(ws)) continue;
      if (rel.status === 'pending' && rel.release_date <= today) {
        if (await releaseDue(ws, rel.surplus_cents ?? 0)) releasesDone += 1;
      } else if (rel.status === 'held') {
        heldLegacy += 1;
      }
    }

    // Persist release-driven shortfall before restoration, so a
    // restoration failure never loses the release shortfall.
    if (shortfall !== shortfallAtStart) {
      const rpc = await supabase.rpc('update_fund_shortfall', { household_id: householdId, shortfall_cents: shortfall });
      check(rpc, 'update_fund_shortfall RPC');
    }

    // ---- Restoration phase (post-walk; see header on failure) ----
    let restorations = 0, heldCreated = 0;
    const restorationsSkipped: any[] = [];
    let restorationError: string | null = null;
    if (restorationTablesMissing) {
      restorationsSkipped.push({ reason: 'restoration tables not yet migrated (apply restoration-snapshots.sql)' });
    } else {
      try {
        const existingEntryByRefund = new Map(
          restorationEntries.map((r: any) => [r.refund_transaction_id, r]),
        );
        const txnById = new Map(txns.map((t: any) => [t.id, t]));
        // Group verified linked refunds by purchase, in date order.
        const refundsByPurchase = new Map<string, any[]>();
        for (const t of txns) {
          if (postedRefund(t) && t.original_purchase_id) {
            const arr = refundsByPurchase.get(t.original_purchase_id) ?? [];
            arr.push(t);
            refundsByPurchase.set(t.original_purchase_id, arr);
          }
        }
        for (const [purchaseId, refundList] of refundsByPurchase) {
          const purchase: any = txnById.get(purchaseId);
          if (!purchase) {
            restorationsSkipped.push({ purchase_transaction_id: purchaseId, reason: 'purchase row not found' });
            continue;
          }
          const purchaseWeek = weekStartOf(purchase.date);
          const purchaseAmount = purchase.amount_cents ?? 0;
          const fundAllocation = purchase.fund_allocation_cents ?? 0;
          if (purchaseAmount <= 0 || fundAllocation < 0 || fundAllocation > purchaseAmount) {
            restorationsSkipped.push({ purchase_transaction_id: purchaseId, reason: 'invalid purchase amount/fund allocation' });
            continue;
          }
          const purchaseLocked = isWeekLocked(purchaseWeek, currentWeekStart);
          // Horizon: purchase week through the LAST COMPLETED week
          // only (never the in-progress current week — see
          // restoration.mjs horizon rule).
          if (purchaseWeek > lastCompleted) {
            restorationsSkipped.push({ purchase_transaction_id: purchaseId, reason: 'purchase week not yet completed' });
            continue;
          }
          // Simulation weeks: snapshot policy for closed weeks,
          // current policy otherwise; charges per weekCharges rule
          // EXCEPT the purchase week's own linked refunds are not
          // netted (the reduction models them) and other purchases'
          // linked refunds follow the same open/locked rule.
          const simWeeks: any[] = [];
          for (let ws = purchaseWeek; ws <= lastCompleted; ws = addDays(ws, 7)) {
            const { B, T } = weekPolicy(ws);
            // Reconstruct charges excluding ALL refunds for THIS
            // purchase (they are modeled by the reduction), but
            // including other weeks' booked inputs as weekCharges
            // does — then subtract this purchase's linked refunds
            // that weekCharges would have added for open weeks.
            let charges = weekCharges(ws);
            // weekCharges already includes linked refunds for open
            // weeks via linkedPostedToWeek, which includes this
            // purchase's refunds when the purchase week is open.
            // Remove them: baseline must carry the FULL purchase
            // charge, with refunds modeled only by the reduction.
            if (!isWeekLocked(ws, currentWeekStart) && ws === purchaseWeek) {
              // linkedPostedToWeek(purchaseWeek) includes this
              // purchase's posted refunds; they must not be in the
              // baseline charges. (Other purchases' refunds linked
              // to this week stay, as booked.)
              const thisPurchaseLinked = txns
                .filter((r: any) => postedRefund(r) && r.original_purchase_id === purchaseId)
                .reduce((s: number, r: any) => s + (r.amount_cents ?? 0), 0);
              charges -= thisPurchaseLinked; // amounts are negative, so this ADDS them back
            }
            simWeeks.push({ week_start: ws, B, T, charges_cents: Math.max(0, charges) });
          }
          // Initial debt into the purchase week: latest close
          // before it (steady state: the immediately preceding
          // week). See S2_NOTES.md for the backfill approximation.
          const priorClose = [...closeByWeek.values()]
            .filter((c: any) => c.week_start < purchaseWeek)
            .sort((a: any, b: any) => (a.week_start < b.week_start ? 1 : -1))[0];
          const initialDebt = priorClose ? (priorClose.outgoing_debt_cents ?? 0) : 0;

          const sortedRefunds = [...refundList].sort((a: any, b: any) =>
            (a.date < b.date ? -1 : a.date > b.date ? 1 : (a.id < b.id ? -1 : 1)));
          let cumulative = 0;
          const totalFor = (n: number) => computeRestorationTotal({
            weeks: simWeeks, purchaseWeekStart: purchaseWeek,
            purchaseAmountCents: purchaseAmount, fundAllocationCents: fundAllocation,
            totalRefundedCents: n, initialDebtCents: initialDebt,
          });
          for (const refund of sortedRefunds) {
            const refundAmount = Math.abs(refund.amount_cents ?? 0);
            const priorTotal = totalFor(cumulative);
            cumulative += refundAmount;
            const newTotal = totalFor(cumulative);
            if (existingEntryByRefund.has(refund.id)) {
              continue; // idempotent: this refund event already posted
            }
            const inc = computeIncrementalRestoration({
              priorTotal, newTotal, newRefundCents: refundAmount,
            });
            const postedSurplus = purchaseLocked ? inc.restoredSurplusCents : 0;
            const postedDebt = purchaseLocked ? inc.debtReductionCents : 0;
            const postedFund = inc.fundCreditCents;
            // Shortfall-first for all restoration credits (surplus
            // first, then fund credit), remainder to the fund ledger.
            const credits = postedSurplus + postedFund;
            const offset = Math.min(shortfall, credits);
            const surplusOffset = Math.min(offset, postedSurplus);
            const fundOffset = offset - surplusOffset;
            const toFundSurplus = postedSurplus - surplusOffset;
            const toFundFund = postedFund - fundOffset;
            shortfall -= offset;
            check(await supabaseAdmin.from('restoration_entries').insert({
              household_id: householdId, week_start: currentWeekStart,
              purchase_transaction_id: purchaseId, refund_transaction_id: refund.id,
              restored_surplus_cents: postedSurplus,
              debt_reduction_cents: postedDebt,
              fund_credit_cents: postedFund,
            }), 'restoration_entries insert');
            if (toFundSurplus > 0) {
              check(await supabaseAdmin.from('fund_ledger').insert({
                household_id: householdId, kind: 'restoration', amount_cents: toFundSurplus,
                week_start: currentWeekStart,
                note: `Refund restoration surplus for purchase week ${purchaseWeek}`,
                created_by: user.id,
              }), 'fund_ledger restoration insert');
              fundAvailable += toFundSurplus;
            }
            if (toFundFund > 0) {
              check(await supabaseAdmin.from('fund_ledger').insert({
                household_id: householdId, kind: 'restoration', amount_cents: toFundFund,
                week_start: currentWeekStart,
                note: `Refund restoration fund credit for purchase week ${purchaseWeek}`,
                created_by: user.id,
              }), 'fund_ledger restoration fund insert');
              fundAvailable += toFundFund;
            }
            if (inc.heldCents > 0) {
              check(await supabaseAdmin.from('held_refunds').insert({
                household_id: householdId, refund_transaction_id: refund.id,
                purchase_transaction_id: purchaseId, held_cents: inc.heldCents, status: 'pending',
              }), 'held_refunds insert');
              heldCreated += 1;
            }
            check(await supabaseAdmin.from('audit_log').insert({
              household_id: householdId, actor: user.id, actor_name: 'admin',
              action: 'Refund restoration',
              detail: `Refund ${refund.id} for purchase week ${purchaseWeek}: surplus ${postedSurplus}, debt reduction ${postedDebt}, fund ${postedFund}, held ${inc.heldCents}.`,
            }), 'audit_log restoration insert');
            restorations += 1;
            existingEntryByRefund.set(refund.id, true);
          }
        }
        // Unlinked verified refunds are noted for the S3 linking gap
        // (they net by date in open weeks; a locked-week unlinked
        // refund has no purchase to restore against).
        const unlinkedCount = txns.filter((t: any) => postedRefund(t) && !t.original_purchase_id).length;
        if (unlinkedCount > 0) {
          restorationsSkipped.push({ reason: `${unlinkedCount} unlinked posted refund(s) noted (S3 linking gap; they net by date in open weeks only)` });
        }
        if (shortfall !== shortfallAtStart) {
          const rpc = await supabase.rpc('update_fund_shortfall', { household_id: householdId, shortfall_cents: shortfall });
          check(rpc, 'update_fund_shortfall RPC');
        }
      } catch (e) {
        restorationError = String((e as any)?.message ?? e);
      }
    }

    check(await supabaseAdmin.from('audit_log').insert({
      household_id: householdId, actor: user.id, actor_name: 'admin',
      action: 'Weeks processed',
      detail: `${weeksClosed} week(s) closed, ${releasesDone} release(s), ${restorations} restoration(s), ${heldCreated} held refund(s).`,
    }), 'audit_log insert');

    const payload = {
      weeks_closed: weeksClosed, releases: releasesDone, held_legacy: heldLegacy,
      restorations, held_refunds_created: heldCreated,
      fund_available_cents: fundAvailable, shortfall_cents: shortfall,
      pending_late_adjustment_cents: pendingLateAfterRun,
      restorations_skipped: restorationsSkipped,
    };
    if (restorationError) {
      // Loud partial failure: closes/releases above ARE persisted;
      // restoration stopped at the error and is re-runnable (entries
      // are unique per refund). Never report this as success.
      return json({ ...payload, error: `restoration failed partway: ${restorationError}` }, 500);
    }
    return json(payload);
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
