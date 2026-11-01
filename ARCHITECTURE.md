# Household Budget — Architecture notes (Milestone A prototype)

## Stack (prototype)
- **Front end:** vanilla HTML/CSS/JS PWA (no build step, no dependencies, no
  external network calls). `index.html`, `styles.css`, `app.js`, `manifest.json`,
  `sw.js` (app-shell cache only), `icon.svg`.
- **Budget engine:** `engine.mjs` — pure ES module, integer cents only, no I/O.
  Imported by the browser PWA *and* by `server.mjs`, so there is one formula.
  Do not duplicate the formula in a second place.
- **Server (prototype):** `server.mjs` — zero-dependency Node HTTP server. Serves
  the PWA and `POST /api/compute` plus admin-only endpoints. State in this
  prototype is browser localStorage; the server does not yet own a database.
- **Tests:** `test/engine.test.mjs`, run with `node --test`.

## Data flow (prototype)
```
seeded demo transactions (localStorage)
        │
        ▼
app.js groups by week (America/New_York, Sunday start)
        │  locked-week transactions post to the current week (A4)
        ▼
engine.mjs computeWeek() chained week to week
  (debt and refund credit carried forward; temp increment per-week only)
        │
        ▼
Dashboard / Extra Fund / Savings views + audit log (append-only in UI)
```
CSV import and the synthetic-alert parser feed the same transaction list and
the same dedupe hash (`date|merchant|amount|suffix`). Re-imports add nothing.

## Households and roles
- One demo household (`household_id` concept: all records in this prototype
  belong to a single household; the production schema must carry `household_id`
  on every table from day one — see spec Part B5).
- Roles: `admin` (owner) and `member` (spouse). Role checks in the UI only hide
  controls; the server enforces them: `server.mjs` returns 403 for member calls
  to `/api/admin/*`. Production must replace the demo `x-demo-role` header with
  verified sessions and server-side role assignment. Never trust a client role.

## Week and fund mechanics implemented here
- Week: Sunday 00:00 → next Sunday 00:00, America/New_York (calendar-date math,
  so DST cannot move a purchase across weeks).
- Surplus pending 7 days after close, then released (release date = week start
  + 14 days). Releases are netted against any outstanding shortfall first.
- Open window 28 days after a week ends; older weeks are locked — charges dated
  there post to the current week as "late" adjustments and locked history is
  not recomputed in this prototype.
- Shortfall: a late reduction cuts the fund to at most $0; the remainder is a
  shortfall netted against the next release. No automatic clawback from the
  normal budget.
- Savings (spec A6): fund available, earned-not-yet-transferred
  (= fund available − confirmed net transfers, excluding interest), actual
  savings balance, interest tracked separately. Transfers are manual
  attestations in this prototype; the app never initiates a transfer.

## Production path (not built here)
Replace, in order: (1) localStorage → managed Postgres with the spec's tables
(households, memberships, budget_policies, financial_weeks, transactions,
ledger_entries, fund_allocations, fund_requests, surplus_releases, csv_imports,
audit_events, …); (2) demo header → real sessions + row-level household checks;
(3) local demo data → Gmail-alert ingestion (signed events, replay protection,
quarantine) and/or Plaid Sync with cursor + verified webhooks, CSV as fallback;
(4) scheduled week-close and nightly backup export with a restore test.
Secrets stay server-side only (see `.env.example` — placeholders, never values).

## Security boundaries (prototype and production)
- Read-only against all financial accounts. No charge, transfer, payment, or
  account-change endpoint or button exists anywhere in this code.
- No passwords, tokens, or full card numbers in code, logs, or screenshots.
  Card suffixes (last 4 digits) only.
- No external network calls from the PWA; no analytics.
- FIN-REFUND-001 is unresolved — see OPEN_QUESTIONS.md. Do not deploy automatic
  fund release using an unreviewed interpretation of that case.
