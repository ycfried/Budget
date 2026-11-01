# Live app audit — Nov 1, 2026, evening

Live slice: `live.html` / `live.js` against the Supabase Budget project.
Demo: `index.html` / `app.js` (fake data, complete feature surface).
Spec: Household Budget — Revised iOS Spec (v2) + Addendum.
Verdict: the live slice proves sharing works, but it is NOT yet the
product the owner was promised. The gaps below are real, not polish
nitpicks, and they are the work list for today.

## What works in live (verified or built)
- Real Auth sign-up/sign-in, both phones reach the shared dashboard
  (owner confirmed "it works on both" after the grants fix).
- Household creation via create_household() RPC; spouse join by ID.
- Shared transactions read + manual provisional add (insert policies
  + grants applied and verified).
- Fund requests: create + queue read.
- Audit log: read (+ insert policy; writes from manual/fund actions).
- Week numbers from compute-week (server) — dashboard load is the
  remaining proof point; treat as unconfirmed until a dashboard load
  is seen with $375 allowance / real spent numbers.

## Missing vs demo/spec (build these, in order)
1. **Plaid end-to-end — BLOCKED, now unblocked by design below.**
   No Connect Bank button in live.html at all; no plaid-sync function;
   plaid-exchange deliberately blocked (no token vault); no Plaid
   secrets set. See "Plaid today" below.
2. **Gmail end-to-end — half built.** ingest-amex-alert is deployed,
   but INGEST_SECRET is not set, the Apps Script still has a
   placeholder search query, and no real alert has been inspected.
   No Gmail status in the live UI.
3. **Fund approvals/allocations.** Live can create a request and list
   the queue, but no admin approve/decline/split, no allocations list,
   no fund-available/pending/spent/shortfall display, no insufficient-
   fund block with typed-reason override. Demo has all of this.
4. **Settings.** No base-allowance or temporary-increase UI in live,
   and no server function to change them with admin checks. Demo has
   it; spec requires admin-only + server enforcement.
5. **Savings.** No savings page in live at all — none of the four
   numbers, no manual attestation. Demo has it (read-only + admin
   attestation forms).
6. **Transactions depth.** No search, no filters (current week /
   provisional / verified / refunds / fund-allocated), no exclude /
   restore, no fund-allocation from a row, no CSV import in live.
   Demo has all of these.
7. **Week history / fund releases.** Live shows only the current week
   from compute-week. No prior weeks, no surplus pending/released
   list, no release dates, no shortfall display, no late/locked-week
   labelling. Spec A4 requires all of it.
8. **Sync status.** No source counts, no last-sync, no per-source
   status (Plaid/Gmail/CSV) in live. Demo has a sync-status card.
9. **Admin/member UI gating.** Live hides nothing by role except via
   the role badge text. Settings/savings/admin actions must be hidden
   for members, as the demo does.

## Broken / fragile (fix before calling it done)
- Household screen after creation: boot() should switch to the
  dashboard; the grants fix should have resolved it, but it must be
  re-verified on both phones (owner reported it stuck twice).
- Sign-out and Refresh buttons are visible on screens where they do
  nothing useful (auth/household screens).
- No loading states: taps give no feedback while a function/RPC runs.
- No error display on the dashboard refresh path (compute-week
  failures are console-only).
- Auth: "Allow new users to sign up" is ON and email confirmation is
  OFF (owner decision: keep it that way for now). That is an open door
  until the owner says to close it — do not close it unprompted.

## Polish (after the missing pieces, not instead of them)
- Home-screen install: fixed with manifest-live.json (start_url
  live.html); owner must delete the old demo icon and re-add from
  live.html. Long term, live should replace index.html entirely.
- Live page title/banner already says LIVE — keep demo and live
  visually distinct until the merge.
- Fund request form in live has no transaction picker (demo does);
  requests are amount-only until the picker lands.
- Date inputs, amount formatting, and empty states are minimal in
  live vs demo.

## Plaid today — the design that makes "today" possible
Blocker was: "no safe place for the access token." The vault that can
be built today, with no new service and no new account, is encrypted
storage inside the project itself:
- New column `plaid_items.access_token_encrypted` (migration
  `supabase/plaid-token-column.sql`).
- plaid-exchange encrypts the access token with AES-GCM using a key
  held ONLY in Edge Function secrets (`PLAID_TOKEN_KEY`, generated,
  never in the repo/chat). The ciphertext (never the plaintext token)
  goes into that column; the plaintext token is never written to the
  database, the repo, or any log.
- plaid-sync (new function) decrypts in memory only, calls
  /transactions/sync, runs the existing matcher (dedupe, pending →
  posted, refunds), writes verified transactions, and updates the sync
  cursor. The decrypted token never leaves the function.
- Tradeoff, stated plainly: this is not Plaid's own hosted vault; it
  is encryption-at-rest with the key outside the database, accessible
  only to service-role functions. For a 2-user household app this is
  the standard small-app pattern, and it is strictly safer than the
  alternative (plaintext token in the DB, which will never be done).
  If the owner ever wants a dedicated vault later, the column can be
  migrated without changing the app's Link flow.
- Still needed from the owner (his step, via takeover, never via
  chat): Plaid Client ID + Secret from his Plaid dashboard, entered
  into Supabase Edge Function secrets, plus PLAID_ENV. Until those
  exist, plaid-link correctly returns "not configured" and no bank can
  be connected — that is the safe state, not a bug.
- When secrets exist, the owner connects Amex in the live app via
  Plaid Link, Transactions only. Never from the Plaid dashboard.

## Gmail today
- Generate INGEST_SECRET, set it as an Edge Function secret via the
  dashboard, and put the same secret + the live endpoint URL
  (https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/ingest-amex-alert)
  into the Apps Script. Owner installs the script in personal Gmail
  (Plan B, Amex-alerts-only search) and the first real alert's headers
  are inspected to tighten the search query and parser before trusting
  it. Alerts stay provisional-only.

## Order of work today
1. Plaid: token-column migration, encrypted plaid-exchange rewrite,
   plaid-sync function, Link UI in live.html/live.js, deploy all.
2. Secrets: INGEST_SECRET set via dashboard; Plaid keys via owner
   takeover into secrets.
3. Gmail: updated Apps Script, owner installs, first-alert inspection.
4. Fund approvals + settings + savings + transactions depth in live
   (functions with role checks, not client fakes).
5. Beta-test everything with test accounts, clean up test data, then
   report: what is connected, what is proven, what still needs owner.
