# Household Budget — Review: What Stands Between the Private PWA and a Public App Store App

> Written Nov 1, 2026, evening, from a read-only pass over the spec
> (Revised iOS Spec v2, 19 pages), HANDOFF.md, the live app
> (live.html/live.js), the demo PWA, all Supabase SQL and Edge
> Functions, and the open-questions file. Nothing was changed live
> for this review. Where the review could not verify something from
> files alone, it says so.

## Owner direction (Nov 1, 2026, evening)

The goal is an app anyone can use, published on the App Store, with
onboarding as simple as possible. Scale later means paid tiers
(Plaid beyond trial, Supabase Pro, Apple Developer), but nothing
paid before scale actually demands it. For the current two users,
everything runs at $0 except the eventual Apple fee.

## Already in flight (not gaps)

- Fund allocations per spec A5/A4 (week close → 7-day pending →
  release → allocation). Approve/decline today is a decision record
  only; the allocation work makes the fund balance move.
- Transaction sort + month/card filters (just shipped).

## Stale documents (do not use as current gap lists)

- HANDOFF.md §3 still calls the live slice "just built — needs its
  first real test" and says settings/savings are "not wired yet."
  Both are stale: settings, temp increases, savings attestation,
  approvals, and Plaid sync were wired and proven Nov 1 evening.
- AUDIT_LIVE.md is an early-evening snapshot; its items on approvals,
  settings, savings, transaction depth, and role gating have since
  been built.
- TASKBOARD.md and ARCHITECTURE.md describe the localStorage demo
  prototype only, not the Supabase live app.

## 1. Spec gaps in the live app

**A1 People and roles — partial.** Admin controls are hidden from
members in the UI and the RPCs check admin server-side. But the RLS
"members update own transactions" policy lets ANY household member
directly update any transaction row (amount, state, excluded flag)
via API — the spec requires only the admin to change history.
Missing: member flag-for-review, member "Use Extra Fund" on a
transaction row, invite/remove-member/role management, and any
leave-household path (creating a household refuses if you already
belong to one, with no way out).

**A2 Weekly engine — built in the engine, broken in the live
dashboard.** `engine.mjs` + `compute-week` implement the formula and
15 engine tests pass. But `live.js` calls `compute-week` passing
only T — incoming debt D, carried credit R_in, and excess credit X
all default to 0. So in the live app, debt and refund credit do NOT
carry from week to week: after an over-budget week, the next week
wrongly shows the full $375 available. The demo chains weeks
correctly; the live app does not. The in-flight week-close work is
the vehicle that fixes this (it produces the chain state).
**Also verify urgently:** the repo copy of `compute-week`
computes C = charges − refunds while refunds are stored as
NEGATIVE amounts (Plaid sign, demo seed data, and the displayed
−$10.70 refund all confirm negative). If the deployed function
matches the repo, refund weeks overstate spending by twice the
refund amount. Check one refund week's numbers by hand before
trusting them.

**A3 Worked examples — partial.** Engine fixtures pass (except the
skipped FIN-REFUND-001 case). They have never been verified against
live data.

**A4 Week close, surplus, late/locked weeks — not built in live
(partly in flight).** No week_closes, surplus_releases, or
financial_weeks tables; no Sunday 00:00 close; no 28-day open
window; no locked-week "late" posting; no shortfall tracking. The
in-flight allocation work covers close → pending → release, but
late/locked/shortfall-recompute rules and the scheduled (vs.
manual) close are still open. The demo simulates pending/release
in localStorage only.

**A5 Extra Fund — in flight.** See above.

**A6 Savings — partial.** Only the fourth number exists in live:
admin attestation of the actual balance. Missing: fund available,
earned-not-yet-transferred, interest/outside movements tracked
separately, transfer states (initiated/pending/posted/reversed/
unmatched), and the suggested manual transfer amount. The demo has
all four numbers; live shows one.

**A7 Special transactions — partial.** Exclude-with-reason exists
(UI only enforces admin; see A1). Missing: split a purchase
between normal and fund (admin only), and reclassification. Hard
delete of manual transactions (recently added) contradicts the
spec's append-only ledger rule — a documented, deliberate choice,
but a spec deviation to own, not hide.

**B1/B5 Architecture and data model — partial.** Week math is
server-side, good. But most live writes are direct client table
writes under household-level RLS (manual entries, excludes, fund
requests, audit rows), not server-moved state transitions. Missing
tables vs. the spec's B5 list: budget_policies, financial_weeks,
source_events, transaction_matches, ledger_entries,
fund_allocations, bank_accounts, savings_reconciliation,
alerts_and_sync_status, transaction_state_history,
week_close_runs, surplus_releases, csv_imports,
quarantine_items, merchant_rules, devices,
notification_preferences, backup_runs. Existing: households,
members, transactions, fund requests, savings ledger, audit log,
plaid items, temp increases, webhook events.

**B2 Sources — mixed.**
- Plaid: built and proven for one Amex connection (Link, encrypted
  token, Sync with cursor, verified JWT webhooks, auto-sync on
  refresh). Missing: `removed` transaction handling,
  pending→posted linking via `pending_transaction_id` (today
  dedupe is hash-only, so a tip-changed amount can double-count),
  reconciliation against the matcher, and a disconnect warning.
- Gmail: Apps Script installed in personal Gmail (Plan B),
  10-minute trigger, one clean manual run. Unproven: the first real
  alert end-to-end, and the spec's Phase 2 gate — inspecting a real
  alert's full headers to prove sender authentication — has not
  been done. Risk: `ingest-amex-alert` still reads the deprecated
  legacy SUPABASE_SERVICE_ROLE_KEY, the same key proven broken for
  `bootstrap-household`; if it is dead here too, the first real
  alert will fail.
- CSV: demo only. No live CSV import, so the spec's fallback path
  does not exist in the shared app.
- Manual: built, with a duplicate warning.

**B3 Matching — not built.** No matcher exists anywhere in live:
no amount/date-window/merchant normalization, no confidence
thresholds, no review queue for ambiguous matches, no 7-day
unconfirmed flag, no tip-correction display, no `date_uncertain`
marking. Dedupe is by stable hash only, weaker than the spec in
every case the spec names (tips, holds, partial refunds, two
identical purchases).

**B4 Transaction states — partial.** Schema has
provisional/verified/excluded/reversed, but no quarantined/voided
states, no `transaction_state_history` table, and state changes
are client writes, not server-only transitions. Audit entries for
those changes are best-effort client inserts that can fail
silently (console only).

**B6 Security and backups — partial, with two live risks.** Good:
no money-movement endpoint anywhere, secrets in Edge Function
secrets, suffixes only, Plaid products Transactions-only. Gaps:
(1) the dead `bootstrap-household` function is still deployed and
still reads the deprecated legacy key — remove it; (2) **no
backups at all** — no nightly export, no restore test, despite
the spec requiring both (Free tier has no point-in-time restore).
Also the repo is public on GitHub while the app is described as
private: the publishable key in `config.js` is by design, but the
public repo + open sign-ups combination (see §2) is what makes
the RLS gaps above matter.

**B7 Screens — partial.** Home shows
available/allowance/spent/debt/credit but no days-left, no
per-source last-updated times, and no stale-feed warning (the
"last sync" line is just the page refresh time, and the bank
status resets every reload). Transactions now have
filters/sort/month/card, but no classification filter, no
review-needed filter, and detail lacks match provenance and
history. Missing entirely: weekly history, fund ledger display,
CSV export, roles/source-health management, widgets, push.

**Phases:** Phase 0 partial (only the Plaid trial banner verified;
no written matrix, no alert-header inspection). Phase 1 partial
(engine done; close/fund/releases in flight; role tests missing).
Phase 2 partial (script installed; no quarantine UI/table, no
matcher, no live CSV). Phase 3 mostly built for one bank (minus
removed/pending-link/disconnect warning). Phase 4 not started —
**no Swift/Xcode code exists anywhere in the workspace**. Phase 5
not started — no shadow run, no reconciliation report, no backup
restore, no runbooks.

## 2. Onboarding gaps for a public app

A brand-new user's first 2 minutes today:
1. Lands on a sign-in screen whose copy is written for the two
   existing users ("Private household — two users only") and even
   tells them to disable sign-ups — internal instructions leaked
   into the product.
2. Signs up, then hits a household screen asking them to paste a
   UUID. No invite link, no invite email, no explanation of what
   the app does, no tour, no sample week. The second user must
   receive a UUID out of band and paste it exactly.
3. First bank connection is three separate steps: Connect → manual
   Sync → Enable automatic sync. It should be one flow (connect,
   then sync and register automatically).
4. First week shows $0s until a sync happens, with no guidance on
   what to do next. No empty states that teach the $375 rule, the
   fund, or the week.
5. Email alerts are not set up in-app at all — a public user
   cannot complete the Apps Script install themselves, so that
   entire source is owner-only today.

Security items fine for two people, unacceptable for public:
- **Email confirmation OFF + sign-ups ON.** Anyone can create an
  account right now, and the join policy lets any signed-in user
  join ANY household as a member if they learn its UUID. For a
  public app this must flip to: confirmation on, sign-ups gated by
  invite, and join via unguessable invite tokens (not raw
  household IDs) with expiry.
- **No password reset flow** in the app (Supabase can send reset
  emails, but no UI or flow exists).
- **No account deletion** — Apple requires in-app account
  deletion for any app that creates accounts (App Store Guideline
  5.1.1). This is a hard rejection risk, not polish.
- **No landing/explainer page.** `index.html` is the demo with
  fake data and fake sign-in buttons; a stranger landing there
  cannot tell what is real, what is demo, or how to start. The
  demo and the live app sharing one public Pages site is
  confusing and, for a public launch, actively misleading.

## 3. Design / class polish gaps

The design language itself is good and consistent (warm white
#faf9f7, deep green #20392f, brass #b08d57, serif headings, soft
status tints). Where it still feels plain or unpolished:
- **Browser `prompt()`/`confirm()`/`alert()` dialogs** for exclude
  reasons, deletes, and duplicate warnings — these look cheap,
  block the whole page, and are the single least classy thing in
  the app. Replace with in-app sheets/modals.
- **No loading states.** Refresh shows stale numbers while
  loading; a failed `compute-week` call only logs to console,
  leaving $0.00s on screen with no error shown.
- **No charts or visual summaries** — no week bar, no
  spend-by-source or by-card visual, no trend. Everything is lists
  and numbers.
- **Transaction list is capped at 100 rows with no "load more"
  and no notice** — the month filter only covers the loaded 100,
  so older months silently vanish.
- **Inconsistent button hierarchy** on the Bank card (three
  same-weight buttons) and fund buttons buried inside expandable
  detail rows.
- **iOS PWA gaps:** the only icon is an SVG; iOS largely ignores
  SVG `apple-touch-icon`s, so home-screen icons and splash
  behavior will look wrong. `manifest-live.json` has no PNG icons
  in multiple sizes, no screenshots, no `description` fit for a
  store listing.
- **Copy leaks internals:** "compute-week," "Supabase Budget
  project," household UUIDs on the dashboard, and the
  FIN-REFUND-001 banner are all fine for the owner but read as
  unfinished to a stranger.

## 4. App Store readiness checklist

**Milestone B (native SwiftUI + WidgetKit): NOT STARTED.** No
Xcode project, no Swift code, no App Group, no Keychain usage, no
WidgetKit extension. The PWA cannot be submitted to the App Store
— this is a full rebuild of the front end against the existing
Supabase backend, not a packaging step. What transfers directly:
the engine rules, the RPCs, the Edge Functions, and the schema.
What must be built new: onboarding, dashboard, transactions, fund
flows, settings, audit, widgets (small = available + freshness
timestamp; medium = + fund; never transaction details or bank
identifiers), and push (optional, post-MVP).

**Accounts and distribution (from the spec, still true):**
- Apple Developer Program, ~$99/year. Owner's own account is the
  clean path; the friend's account works but TestFlight builds
  expire after 90 days, so the friend must ship a fresh build at
  least quarterly, and the app identifier's ownership must be
  written down before anything is signed.
- A Mac with Xcode is required by whoever builds — confirm who
  has one before Phase 4 starts.
- TestFlight first (internal, then external testers), then App
  Review. Finance apps draw extra scrutiny: the listing must not
  imply Amex/Plaid endorsement, must show real screenshots of the
  real app (not the demo with fake data), and must include a
  privacy policy URL, a support URL, and in-app account deletion.

**What can be done before any of that (no Apple account needed):**
privacy policy + terms pages, support contact page, App Store
screenshots from the live PWA, the account-deletion flow, the
invite-based onboarding, and the public landing page. All of
these are also needed for the PWA itself, so none of it is wasted
if native slips.

## 5. Scale / cost triggers — none of this bites the current two users

- **Supabase Free:** pauses after 1 week of inactivity (dashboard
  click restores, no data loss); 500 MB database; 50k monthly
  active users; 5 GB egress; 2 active projects. Breaks at: any
  real user base with daily use (pause risk disappears with use,
  but storage/egress grow), or a third project. Paid step: Pro,
  $25/month, removes pausing and raises limits. Also: no
  point-in-time restore on Free — that is why the spec's nightly
  export matters regardless of scale.
- **Plaid Trial:** verified banner terms are "up to 10
  connections," Production, no payment method, no paid plan.
  Breaks at: the 11th connection, or trial expiry/terms change —
  detailed terms (expiry, call limits, per-item pricing) are
  **unverified** because billing pages are gated behind MFA the
  owner has not enabled. Paid step: Plaid production pricing
  (per-item/per-call; exact numbers unverified — do not quote
  any). Mitigation already in the architecture: email + CSV keep
  working if Plaid stops.
- **GitHub Pages:** static hosting only — fine for the PWA, but
  it can never run server code, so all scale lives in Supabase.
  Exact Pages bandwidth/build limits were not verified from the
  files; do not promise "free forever" for it either.
- **Apple:** ~$99/year from day one of TestFlight/external
  distribution; TestFlight builds expire after 90 days even on a
  paid account.
- **Honest summary:** for two users, everything today is $0
  except the eventual Apple fee. The first paid step that actually
  matters is Supabase Pro ($25/mo) once real users arrive, then
  Plaid pricing once connections grow — in that order.

## 6. Prioritized roadmap

**Phase 1 — must-have for a believable public MVP**
- Fix live week chaining (pass carried debt/credit into
  `compute-week`) and verify the refund-sign question by hand —
  wrong weekly numbers destroy trust instantly. (S)
- Server-side role enforcement for transaction updates
  (admin-only exclude/restore/edits via RPC; member direct UPDATE
  closed) — closes the biggest security hole. (S)
- Invite-based onboarding: invite links/tokens with expiry,
  confirmation emails on, sign-ups gated, second-user flow that
  never shows a UUID — the current UUID-paste flow cannot ship. (M)
- In-app password reset + account deletion — Apple will reject
  without deletion. (S)
- Public landing page + hide demo behind a clear "try the demo"
  door; remove internal copy (compute-week, Supabase, UUIDs) from
  user-facing screens — a stranger must understand the product in
  30 seconds. (S)
- Live CSV import (the spec's fallback) — the app must work for
  users without Plaid. (M)
- Decide FIN-REFUND-001 (owner ruling, in writing) before any
  auto-release ships — blocks production fund logic. (S, decision
  not code)
- Nightly encrypted backup export + one restore test — Free tier
  has no point-in-time restore; data loss is otherwise
  unrecoverable. (M)
- Replace `prompt()`/`confirm()`/`alert()` with in-app sheets,
  and add loading + error states — the cheapest class upgrade
  available. (S)
- Quarantine UI/table for failed alerts and unparseable rows —
  today failures vanish into a 202 response nobody sees. (S)
- Remove the dead `bootstrap-household` function; fix or replace
  the legacy-key read in `ingest-amex-alert` — dead code with a
  known-broken credential pattern. (S)

**Phase 2 — makes it classier and better**
- Weekly history screen (past weeks, revised-week notes, CSV
  export) — the record users actually check at month-end. (M)
- Savings four-number display + transfer tracking with suggested
  transfer amount — completes the spec's A6 instead of one
  number. (M)
- Per-source sync health that persists across reloads +
  stale-feed warnings — today sync status is session-only and
  partly invented-looking. (S)
- Spend visuals: week bar, by-source/by-card breakdown, month
  totals — lists alone feel plain; one honest chart changes
  that. (M)
- Flag-for-review, 7-day unconfirmed flag, split normal/fund,
  reclassification — completes A1/A7 for daily use. (M)
- One-step bank connect (auto-sync + auto-register on Link
  success) — three taps today, should be one. (S)
- Transaction matcher v1 (pending→posted linking, tip
  corrections, ambiguous-match review queue) — hash dedupe alone
  will double-count real cases. (L)
- Plaid `removed` handling + disconnect warning — completes the
  Phase 3 demo. (S)
- Privacy policy, terms, support page, store screenshots — do
  before native, not during review. (S)

**Phase 3 — scale-only (do not build early)**
- Supabase Pro + read replica/connection pooling review — only
  when users or storage approach Free limits. (S, paid)
- Plaid production plan + multi-bank UI (multiple items per
  household already supported in code) — only past 10
  connections. (M, paid)
- Native SwiftUI + WidgetKit app + TestFlight pipeline — the App
  Store step; backend already ready for it. (L)
- Push notifications (purchase recorded, low balance, week
  reset, surplus released, sync failure) with per-user quiet hours
  and email/Plaid dedupe — spec-optional, post-MVP. (M)
- Multi-household support, household switching, member
  management — spec is two-person; do not generalize early. (L)
- Merchant rules, backup runbook, incident runbook, shadow-run
  reconciliation report — Phase 5 operational maturity. (M)

## 7. Could not verify from files (flagged, not assumed)

- Whether the deployed `compute-week` matches the repo copy
  (refund-sign question).
- Plaid's detailed trial terms beyond the 10-connection banner.
- GitHub Pages' exact bandwidth/build limits.
- Whether any real Amex alert has ever been ingested (context
  says no).
- Anything about the live database's actual row counts — this
  review read code and docs only, never the live service.
