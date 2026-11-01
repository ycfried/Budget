# Household Budget — Milestone A Prototype (PWA, first useful slice)

**DEMO ONLY.** Fake transactions, local demo sign-in, no live Gmail, Plaid, or
bank connection, no production security, no App Store readiness. Nothing here
moves money, changes any account, or costs anything. No deployment was made.

## What this is
A mobile-first installable PWA for a two-person household sharing one $375
Sunday–Saturday allowance (America/New_York), with rollover debt, a pending →
released Extra Spending Fund, refund credit, savings reconciliation, and an
audit log both users can read. The budget engine is a single shared pure
module (`engine.mjs`) used by the browser and the server — balances cannot
diverge between clients.

## How to run locally
```sh
cd household-budget
node server.mjs
# open http://localhost:8080/
```
No dependencies, no build step. Requires Node 18+ (tested on Node 24).
Run the engine tests:
```sh
node --test test/engine.test.mjs
```

## How to open on an iPhone
1. Connect the iPhone to the **same Wi-Fi** as the computer running the server.
2. Find the computer's local IP (macOS: System Settings → Wi-Fi → Details;
   Windows: `ipconfig`; Linux: `ip addr`).
3. On the iPhone, open Safari and go to `http://<computer-IP>:8080/`.
   (Local preview only — this is not a public URL and is not reachable
   outside your Wi-Fi.)
4. **Add to Home Screen:** in Safari tap Share → **Add to Home Screen** →
   Add. The app opens standalone with its icon and name.
   Note: a PWA cannot provide native iOS Home Screen widgets; that needs the
   later native app (Milestone B). Web push and background updates are not
   guaranteed on iOS and are not relied on here — use the in-app Refresh
   button and the visible last-sync timestamp.

## Owner walkthrough
1. **Sign in:** tap "Continue as Owner (Admin) — DEMO" (or Spouse/Member).
   A yellow DEMO DATA banner is always visible. Use "Switch user" in the
   header to change roles.
2. **Inspect the week (Dashboard):** available this week, $375 allowance,
   weekly spent, incoming debt, Extra Fund available/pending, refund credit,
   and sync status with last-sync time. Seeded fake data spans weeks
   2026-10-11 → 2026-11-01, so the dashboard is meaningful on first open:
   fund available $130.00 (releases of $75 + $55), pending $92.35 (releases
   2026-11-08), current-week net charges $118.05.
3. **Add a sample purchase (Transactions):** fill the manual form (merchant,
   amount, date, card suffix — last 4 digits only) and submit. It appears
   marked PROVISIONAL and the dashboard updates immediately.
4. **Request / approve fund use (Extra Fund):** as Member, use "Request fund"
   on a transaction or the request form. As Admin, approve (full or split),
   decline, or watch the insufficient-fund block: an allocation above the
   available fund is refused with an explanation.
5. **Import CSV (Transactions):** use "Load sample CSV" — it adds one row and
   skips the identical duplicate. Re-running it adds 0 rows. Or choose your
   own Amex-style CSV file (Date, Description, Amount, Card Ending).
6. **Try the synthetic alert ingest (Transactions):** "Load sample alert",
   then "Parse as provisional". A garbled alert goes to quarantine and
   creates nothing. This is a SYNTHETIC SAMPLE — not a live Gmail connection.
7. **Check role enforcement:** as Member, the Settings tab is hidden. On the
   server, a member calling an admin endpoint gets a 403 (try it):
   ```sh
   curl -X POST localhost:8080/api/admin/allocate \
     -H 'x-demo-role: member' -H 'Content-Type: application/json' \
     -d '{"txId":"x","amountCents":1000}'
   # -> 403 {"error":"admin only", ...}
   curl -X POST localhost:8080/api/compute \
     -H 'Content-Type: application/json' \
     -d '{"B":37500,"C":40000}'
   # -> {"outgoingDebt":2500, ...}
   ```

## Known limits (honest, not hidden)
- **Demo auth only:** role switching is a local demo stand-in. Production
  needs real sessions, server-side roles, and a database.
- **No live Gmail / Plaid:** alerts are synthetic samples; CSV is the working
  import path. Plaid Trial eligibility and Amex coverage are unverified.
- **No native widgets, no guaranteed push:** PWA limitations on iOS.
- **State is browser-local:** clearing site data resets the demo. A production
  server must own the ledger (append-only, household-scoped).
- **FIN-REFUND-001 unresolved:** the refund-credit/surplus ambiguity is
  tracked in OPEN_QUESTIONS.md and flagged in the app. Its test is skipped,
  not passed. Do not use refund-credit/surplus outputs in production until
  the owner chooses the rule.
- **No deployment:** nothing was published, no external account was created,
  no account setting was changed, no money was spent.

## PASS / FAIL / BLOCKED (evidence from this build's own test run)
| Item | Result | Evidence |
|---|---|---|
| Engine tests (15 cases incl. all spec worked examples, refund-credit cases, week-close, 28-day window, shortfall) | PASS | `node --test test/engine.test.mjs` → 15 pass, 0 fail (2026-11-01 run) |
| FIN-REFUND-001 test | SKIPPED (pending, not passed) | Same run → 1 skipped, with the deferral reason printed |
| Server role enforcement (member → admin endpoint) | PASS | `curl` member → 403; admin → 200 (2026-11-01 run) |
| Server compute endpoint uses shared engine | PASS | `curl /api/compute` B=37500, C=40000 → outgoingDebt 2500 |
| PWA serves over local HTTP + manifest/service worker present | PASS | `node server.mjs` serves index/manifest/sw; install files present |
| Public HTTPS deployment / iPhone Home Screen install on a real device | BLOCKED (not attempted) | No deployment authorized; requires owner approval + a hosting account |
| Live Gmail forwarding / Plaid connection | BLOCKED (not attempted) | Requires owner approval + Phase 0 verification; CSV fallback works |
| Native iOS app / WidgetKit | NOT STARTED | Milestone B, after the PWA is reliable |

## File list
- `index.html`, `styles.css`, `app.js` — PWA (all screens/tabs)
- `engine.mjs` — shared budget engine (browser + server)
- `server.mjs` — zero-dependency static server + JSON API with role checks
- `manifest.json`, `sw.js`, `icon.svg` — installability
- `test/engine.test.mjs` — engine tests
- `TASKBOARD.md`, `ARCHITECTURE.md`, `OPEN_QUESTIONS.md`, `.env.example`, `README.md`
