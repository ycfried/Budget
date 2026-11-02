# S2 — Refund restoration engine (workstream notes)

Scope: S2 owns the engine, the restoration module, `compute-week`,
`week-close`, and the migration in this file set. S2 does NOT own
`live.html` / `live.js` (UI workstream), the RLS hardening file, the
S1 RPCs, or the S3 kinds/linking work. Nothing in this set is
deployed or live; live behaviour is unverified until the parent
deploys and tests it.

## 1. What was retired

The old refund-credit model is gone from every S2 file: no
carried-in credit, no excess-credit, no credit-coverage step, no
outgoing credit balance, no deferred-refund flag, no
`not_production_certified` refund flag, and no `held` surplus-release
status is ever created. Legacy `week_closes.outgoing_credit_cents`
values and legacy `surplus_releases` rows with status `held` are left
untouched in the database (additive migration only); S2 code never
writes or reads them. A stale caller sending legacy credit fields to
`computeWeek` gets them ignored (tested).

## 2. compute-week response shape (EXACT — UI codes against this)

```
{
  "week_start": "YYYY-MM-DD",            // Sunday, normalized from the request
  "base_available_cents": <int>,         // max(0, B - D)
  "temp_cents": <int>,                   // T for the week
  "carried_debt_cents": <int>,           // D: debt carried INTO the week
  "charges_cents": <int>,                // C: floored net eligible charges
  "available_cents": <int>,              // base_available + temp - charges
  "week_locked": <bool>,                 // 28-day open window
  "pending_refund_excluded_cents": <int> // |provisional refunds| excluded
}
```

No other fields are returned. Mapping note (open confirmation item,
see §6): `carried_debt_cents` is D (incoming debt), NOT the engine's
`carriedDebt` output `max(0, D - B)`. The dashboard's "incoming debt"
is D, and B is not in the shape, so the UI cannot derive one
interpretation from the other — the UI workstream should confirm
this mapping before coding against it.

Server-side derivation (P1-5): `household_id` + optional `week_start`
are the only request fields read. D comes from the latest
`week_closes` row before the requested week, minus restoration debt
cuts posted after that close; T comes from `temp_increases` for the
week, or from the week's stored snapshot when one exists. Client
D/T/credit values are never read.

Counting (shared engine helpers, identical in week-close): charges
count net of fund allocations, including provisional charges. Posted
refunds linked to a purchase in an open week reduce C; linked refunds
for a locked week never touch C (restoration instead). Unlinked
posted refunds dated in the week net in that week (fallback). Never
counted: `excluded`, `state='reversed'`, `kind='payment'`,
`kind='cashback'`, provisional refunds. Cash-back reclassified by an
admin via `reclassify_transaction` (S1) counts under its CURRENT kind
automatically, because the filter is by current kind string.

Current-week late charges (P0-9): compute-week adds unposted
locked-week charges to the CURRENT week's C dynamically (total
locked-week charges with a close, minus late amounts already frozen
in snapshots). Week-close freezes them into the current week's
`late_adjustment_cents` when that week closes.

## 3. week-close response shape

```
{
  "weeks_closed": <int>, "releases": <int>, "held_legacy": <int>,
  "restorations": <int>, "held_refunds_created": <int>,
  "fund_available_cents": <int>, "shortfall_cents": <int>,
  "pending_late_adjustment_cents": <int>,
  "restorations_skipped": [ { "reason": ... } ]
}
```

`held_legacy` counts old-model `held` releases left untouched (never
auto-released, never rewritten). `pending_late_adjustment_cents` is
non-zero only when every completed week is already locked, so no
week could absorb newly arrived late charges this run; they freeze
on the next run that closes a week, and compute-week already shows
them in the current week meanwhile. On restoration failure the
function returns HTTP 500 with these fields plus `error`
(closes/releases above ARE persisted; restoration is re-runnable —
see §5).

Release rules: new releases get `release_date = actual close date +
7 days` (P1-6), never week-start + 14 for a late close. A surplus
increase after release releases the delta net of shortfall (P1-7).
A surplus decrease after release reduces the fund to at most zero,
remainder to shortfall (A4). Releases are claimed with a conditional
update (`status='pending'`, row count checked) before any fund
ledger insert (P1-9). Every write is checked; any failure throws
and the run returns 500 (P0-15). Shortfall persists ONLY via
`update_fund_shortfall(household_id, shortfall_cents)` (S1, exact
name/argument names), called only when the value changed.

## 4. Restoration contract

Pure math: `restoration.mjs` (`computeRestorationTotal`,
`computeIncrementalRestoration`, `simulateWeeks`,
`postedRefundTotalCents`). Horizon: purchase week through the LAST
COMPLETED week only — never the in-progress current week. (An empty
current week would absorb outstanding debt in the baseline run and
break the FINAL variant example: $50 surplus + $100 debt cut becomes
$150 surplus + $0 debt cut.) Simulation inputs: snapshot B/T for
closed weeks, current B/T otherwise; charges per the §2 rules, with
the target purchase's own linked refunds removed from its week's
baseline (the reduction models them). Initial debt: outgoing debt of
the latest close before the purchase week (steady state: the
immediately preceding week).

Per refund, week-close posts ONE `restoration_entries` row
(unique on `refund_transaction_id`) with gross restored surplus,
debt reduction, and fund credit. Credits offset shortfall FIRST
(surplus first, then fund credit); the remainder posts to
`fund_ledger` as kind `restoration`. Debt cuts affect future weeks
through the D chain (compute-week and week-close both subtract cuts
posted after the latest close). Excess over the purchase posts to
`held_refunds` (status `pending`). Pending refunds are never
processed; a pending refund later removed leaves no trace because no
entry was ever created.

Tables/RPCs (in `supabase/restoration-snapshots.sql`):
`restoration_entries`, `held_refunds`,
`transactions.original_purchase_id`,
`transactions.plaid_pending_transaction_id`,
`transactions.plaid_transaction_id`,
`week_closes.base_allowance_cents / temp_increase_cents /
late_adjustment_cents`, `surplus_releases.closed_at`,
`resolve_held_refund(held_id uuid, action text, note text)`.

`resolve_held_refund` semantics (exact): `write_off` and `resolve`
both close the row with NO money movement (status `resolved`,
`resolved_at`, `resolution_note`, audit row). `release` is REJECTED
with an exception — see §6. Admin-only, SECURITY DEFINER.

## 5. Known limits of the Edge Function implementation (not hidden)

- True multi-table atomicity needs a DB transaction (S1 RPC). The
  conditional-claim + checked-write + loud-500 design prevents
  double-release and silent loss, but a failure midway through the
  restoration batch leaves earlier refunds posted with their
  shortfall offsets unpersisted until a later successful run. A
  re-run is conservative (fund may be under-credited by at most the
  lost offsets, never over-credited) and the 500 names the failure
  for manual reconciliation. Do not present week-close as atomic.
- Simulation initial debt uses the latest pre-purchase close. In
  steady state (regular closes) this is exact. In a backfill with
  unclosed intervening weeks, restoration cuts posted in those
  unclosed weeks are not separately adjusted; the effect is bounded
  by those cuts and disappears once closes are contiguous.
- First close after an allowance change stamps the CURRENT allowance
  onto every never-closed completed week (no snapshot exists to
  recover the old one). Operational rule: run week-close before
  changing the allowance. Weeks closed at least once are immune.
- `set_base_allowance` future-effective semantics are S1's; S2
  assumes "weeks already closed keep snapshots; weeks not yet closed
  use the current allowance at close time". If S1 implements
  strictly next-week-effective, the current-week allowance used at
  close time needs revisiting at integration.
- Household transaction fetches use `.limit(10000)` (household
  scale). A household approaching that many rows needs cursor
  pagination in both functions.
- The simulation horizon's open weeks use live B/T (no snapshot yet).
  An entry once posted never changes, even if a later temp grant for
  an open horizon week would change a re-run — entries are stable by
  design (idempotent by refund id).

## 6. Ambiguous rules flagged, NOT silently decided

1. `carried_debt_cents` mapping (§2): D vs engine `carriedDebt`.
   S2 chose D; UI workstream to confirm.
2. Held-refund `release` (money-posting): the FINAL spec says excess
   is "held for admin review and restores nothing until the admin
   resolves it" but never says where a released excess goes (fund?
   elsewhere?). S2 implements closure-only (`write_off`/`resolve`)
   and rejects `release`. Owner decision required before any
   money-posting release ships.
3. Split fund/normal purchase refund ordering: S2 applies the refund
   to the fund portion first, remainder to normal (tested). The
   FINAL acceptance cases cover only fully-fund purchases; the split
   ordering needs owner confirmation.
4. `update_fund_shortfall` argument names: S2 calls
   `rpc('update_fund_shortfall', { household_id, shortfall_cents })`
   per the brief's signature. If S1 defines different parameter
   names, the call must change at integration — verify before
   deploying week-close.
5. Restoration write path: S2 was told to grant NO direct member
   writes on the new tables. Week-close (caller JWT) therefore needs
   a write path from the RLS workstream (service role or RPCs).
   Until that lands, restoration inserts fail loudly (500, partial
   counts) while closes/releases still succeed. Sequence the RLS
   work before enabling restoration in production.
6. Simulation horizon (last completed week, not current week): S2
   chose this because it is the only reading under which the FINAL
   variant example ($50 + $100) holds. If the owner intended the
   in-progress week to be included, the variant example itself
   would need rewording.

## 7. Files changed (relative to repo root, in the S2 copy only)

- `engine.mjs` (rewritten: B/T/D/C only)
- `supabase/functions/_shared/engine.mjs` (identical copy)
- `supabase/functions/compute-week/engine.mjs` (identical copy)
- `supabase/functions/week-close/engine.mjs` (identical copy)
- `restoration.mjs` (new)
- `supabase/functions/week-close/restoration.mjs` (identical copy)
- `test/engine.test.mjs` (rewritten: old credit fixtures deleted)
- `supabase/functions/compute-week/index.ts` (rewritten)
- `supabase/functions/week-close/index.ts` (rewritten)
- `supabase/restoration-snapshots.sql` (new)
- `S2_NOTES.md` (new, this file)

NOT touched by S2: `live.html`, `live.js`, `app.js`, `server.mjs`,
`HANDOFF.md`, `AUDIT_FULL.md`, `supabase/fund-ledger.sql`,
`supabase/schema.sql`, and every other file. Demo/server consumers
of removed engine fields (`outgoingCredit` etc.) will now read
`undefined` for those fields; their owners should remove those
references (UI workstream for live.js, demo owner for app.js).
