# Household Budget — Handoff (single source of truth)

> Last updated: Nov 1, 2026, evening (after the Supabase backend was built).
> If this file and any chat message disagree, this file wins — update it
> whenever the state changes, and say so in the reply that announces it.
> No secrets, passwords, tokens, or full card numbers ever belong in this
> file, in the repo, or in chat.

## 1. What this is

A private, shared household budget tracker for exactly two users — an
owner (admin) and a spouse (member). No public signup. One Amex Blue Cash
Everyday, two card numbers (suffixes only, never full numbers).
Amounts are integer cents, server authoritative. The financial rules come
from **Household Budget — Revised iOS Spec (v2)** (19 pages, kept at
`~/workspace/user/files/Household_Budget___Revised_iOS_Spec__v2.pdf`) plus
the **AI Coding Agent Implementation Addendum (Nov 1, 2026)**, which sets
the delivery order. Where they conflict, the spec rules and the addendum
governs delivery order.

Owner: Yehoshua Friedman (GitHub: Ycfried, Gmail: ycfried1@gmail.com).
The owner has no computer access — everything he does happens from his
iPhone, and he takes over the live browser (in the Muse app, not
WhatsApp) only to enter sensitive info himself. The agent does all
packaging, pushing, and deploying from its own environment.

## 2. Where everything lives

| Thing | Location / value |
|---|---|
| GitHub repo (public) | https://github.com/ycfried/Budget — branch `main` |
| Live demo PWA (fake data) | https://ycfried.github.io/Budget/ — serves `index.html` |
| Live shared app (new slice) | https://ycfried.github.io/Budget/live.html — serves `live.html` |
| Local working copy | `~/workspace/household-budget/` |
| Supabase organization | **Budget** — Free plan ($0). Created Nov 1, 2026, as a fresh org; the old **TRIAL** org (paused projects Hashgacha, J-Market) was deliberately left untouched and is not used |
| Supabase project | **Budget**, region **us-east-1** (East US / North Virginia), status **Healthy**, compute Nano |
| Supabase API URL | https://tnkhvdkmwmwiogiienee.supabase.co |
| Supabase dashboard | https://supabase.com/dashboard/project/tnkhvdkmwmwiogiienee |
| Plaid account | Trial **ACTIVE** ("Free trial", "You've got trial access", "No action is needed to access banks through Plaid's free trial"). No bank/Item connected, no payment method, no paid plan, production onboarding not started |
| Gmail account for alerts | Personal Gmail ycfried1@gmail.com — **Plan B** (see §6). Forwarding is DISABLED; the existing Cricket MMS gateway address (3054396766@mms.cricketwireless.net) was left untouched; no Gmail setting was changed at any point |

Git rule learned the hard way: no global git identity is configured, so
every commit must use `git -c user.name="Household Budget" -c user.email="demo@example.com"`.

## 3. How it works today (Nov 1, 2026, evening)

### Demo app (works, fake data only)
- `index.html` + `app.js` (527 lines) + `engine.mjs` + `styles.css`.
- State in browser localStorage under `hb-demo-v1`, seeded fake
  transactions (weeks 2026-10-11 → 2026-11-01). Demo sign-in buttons
  (Owner Admin / Spouse Member) sit behind a DEMO DATA banner.
- Tabs: Dashboard, Transactions, Extra Fund, Savings, Settings (admin
  only), Audit. Features: manual provisional entry (suffix only),
  CSV import with stable-hash dedupe, synthetic Amex-alert parser that
  fails closed into quarantine.
- Design (owner-approved Nov 1, 4:51 PM, "big improvement"): warm white
  #faf9f7, primary deep green #20392f, accent muted brass #b08d57,
  serif headings, white header, text tabs with brass underline,
  soft green/red/amber status tints only. The owner said perfecting the
  design can continue later — **functionality is now the priority**.
- Stale-design bug (fixed Nov 1): the v1 service worker was cache-first
  with a never-bumped cache name. Fix: cache `hb-demo-v2`, network-first
  fetch with cache only as offline fallback, stylesheet `styles.css?v=2`.
  If the old design ever reappears, bump the cache name again first.

### Live app (new slice, just built — needs its first real test)
- `live.html` + `live.js` + `config.js` (Supabase URL + publishable anon
  key — publishable keys are designed to ship in the client; the
  service-role key must never appear here).
- Flow: sign up / sign in (Supabase Auth, email + password) → first
  account creates the household via the `bootstrap-household` function
  (admin) → second account joins by pasting the household ID (member)
  → shared transactions, fund requests, audit log, and week numbers
  from the server's `compute-week` function.
- The demo is untouched. `live.html` is the shared version; do not
  merge it into `index.html` until it has passed a two-account test.
- Known limits of this slice (by design, not bugs): admin allocations,
  settings changes, and savings attestation are not wired yet — they
  need Edge Functions with explicit role checks and are never faked
  from the client. Live CSV import is not wired yet (demo CSV works).

### Database (applied, verified)
- `supabase/schema.sql` — applied Nov 1 via SQL editor ("Success. No
  rows returned", verified in Table Editor). Tables: households,
  household_members, transactions, fund_requests, savings_ledger,
  audit_log, plaid_items. Every row carries `household_id`. Row Level
  Security is on for all seven tables with seven "members read own …"
  select policies. Audit log is append-only by design.
- `supabase/schema-inserts.sql` — applied Nov 1 ("Success. No rows
  returned", verified in `pg_policies`). Four insert policies: join as
  member for yourself, members insert own transactions, members insert
  own fund requests, members insert own audit rows.
- Plaid access tokens are NEVER stored in this database — only the
  Plaid item id and sync cursor. The token lives in Edge Function
  secrets / a token vault (see §7).

### Edge Functions (all deployed via the dashboard editor, verbatim)
- `compute-week` — https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/compute-week
  Server-side week math from the single shared engine. Verifies the
  caller's JWT and household membership. Flags FIN-REFUND-001 outputs.
  Note: the dashboard editor is flat per function (no `_shared/`
  folder), so `engine.mjs` sits inside the function folder and the
  import is `./engine.mjs`, not `../_shared/engine.mjs` — the only change
  from the repo copy.
- `plaid-link` — creates a Plaid Link token, **Transactions only**.
- `plaid-exchange` — exchanges a public token, stores item id only,
  and is deliberately blocked until a token vault exists (see §7).
- `ingest-amex-alert` — Gmail alert endpoint: HMAC signature check,
  Authentication-Results pass required, fail-closed quarantine, dedupe,
  provisional-only storage.
- `bootstrap-household` — https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/bootstrap-household
  Deployed Nov 1, 2026, evening, verbatim, via the dashboard editor —
  but FAILED in its first real use (Nov 1, 5:39 PM EST, two HTTP 500s)
  and is now UNUSED. Cause, proven from the logs: the user's JWT was
  valid and auth passed, but the households insert failed because the
  function reads the deprecated legacy SUPABASE_SERVICE_ROLE_KEY, which
  this project no longer provisions with a working value. Do not try to
  fix it by chasing that legacy key.
- `create_household()` RPC — `supabase/create-household-rpc.sql`,
  applied Nov 1, 2026, evening ("Success. No rows returned", verified
  in pg_proc: security_definer = true). This REPLACES bootstrap for
  household creation. SECURITY DEFINER, granted to `authenticated`
  only, acts only for auth.uid(), refuses if the caller already belongs
  to a household, creates one household + one admin membership + one
  audit row, returns the new ID. No secret key is involved. live.js
  calls this RPC.
- Membership policy fix, Nov 1, 2026, evening
  (`supabase/fix-membership-policy.sql`, "Success. No rows returned",
  verified in pg_policies: exactly one SELECT policy on
  household_members, qual `user_id = auth.uid()`): the original
  self-referential membership read policy made membership reads come
  back empty, so the live app stayed stuck on the household screen
  after a household was created. Replaced with the direct rule above;
  the other tables' membership-check policies (which check a different
  table) now resolve correctly. live.js also surfaces membership-read
  errors instead of silently staying on the household screen.
- Plaid token-column migration, Nov 1, 2026, evening
  (`supabase/plaid-token-column.sql`, "Success. No rows returned",
  verified in information_schema/pg_proc): plaid_items.
  access_token_encrypted exists; get_plaid_ciphertext and
  update_plaid_sync exist, both SECURITY DEFINER, granted to
  authenticated only; "members insert own plaid items" policy created.
- Plaid functions + secrets, Nov 1, 2026, evening (dashboard
  toasts confirmed): plaid-exchange v2 deployed ("Successfully
  updated edge function"), plaid-sync created + deployed
  ("Successfully deployed edge function"), INGEST_SECRET and
  PLAID_TOKEN_KEY saved as Edge Function secrets. PLAID_CLIENT_ID,
  PLAID_SECRET, PLAID_ENV NOT set yet — they come from the owner's
  Plaid dashboard; an autonomous keys-transfer task was blocked
  because the Plaid session had expired and the owner must sign in
  to Plaid first (owner authorized autonomous connections/tokens,
  login-when-necessary, Nov 1 evening). Owner confirmed "You're in
  plaid" at 6:40 PM and the keys transfer was resumed.
- PLAID KEYS SET, Nov 1, 2026, evening (all three confirmed in the
  Supabase Custom secrets table, today's timestamp): PLAID_CLIENT_ID,
  PLAID_SECRET, PLAID_ENV = production. The Plaid dashboard's Free
  trial banner reads "up to 10 connections" (0/10 used) and "No action
  is needed to access banks through Plaid's free trial" — so the
  trial DOES cover real bank connections under Production, and the
  earlier "10-Item cap unverified" note is now superseded: the cap
  is 10 connections, verified from the dashboard banner. The
  Production keys were copied dashboard-to-dashboard by the agent;
  no key values were asked of the owner or shown in chat. Plaid is
  now fully configured — the remaining step is the owner tapping
  "Connect Amex via Plaid" in the live app and signing into Amex
  himself (Transactions only), then "Sync bank transactions now."
  Owner confirmed Nov 1, evening: "I did connect my credit card from
  Amex the plaid connection went through" — BUT the follow-up sync
  reported 0 connected items, and a read-only DB check proved
  plaid_items is EMPTY (0 rows). Root cause chain, both fixed the
  same evening: (1) the exchange code ignored the upsert result and
  reported "Connected" even when the item row never landed; (2) the
  reconnect with the fixed exchange surfaced the true error,
  "permission denied for table plaid_items" — fix-grants.sql had
  granted only SELECT on plaid_items, and the token-column migration
  added an insert policy but no insert grant. fix-plaid-grants.sql
  applied Nov 1, evening ("Success. No rows returned"): INSERT +
  UPDATE grants on plaid_items + "members update own plaid items"
  policy. Next step: owner taps Connect Amex again — the store
  should now succeed. A first real sync is still unproven until a
  row lands. UPDATE, Nov 1, evening: reconnect succeeded
  ("Connected: American Express", 1 connected item) but the first
  sync reported "0 added, 0 updated, 121 skipped" — Plaid returned
  121 transactions and every upsert was refused, because
  transactions had no UPDATE policy (upsert needs one). Fix
  applied the same evening ("Success. No rows returned"):
  fix-transactions-upsert.sql — UPDATE grant + "members update
  own transactions" policy. Next step: owner taps Sync again;
  the 121 should land this time. PROVEN Nov 1, evening: the
  retry sync landed the real Amex transactions — owner's
  screenshot shows PLAID-badged rows (VERIFIED for posted,
  PROVISIONAL for pending, card ••1005, dates Oct 27–Nov 1,
  including a -$10.70 refund). Plaid end-to-end is now PROVEN.
  Beta-test cleanup COMPLETE Nov 1, evening: both test auth
  users deleted, verified 1 household and 2 members (owner +
  spouse) only — no test data remains.
- Home-screen icon CONFIRMED FIXED by the owner Nov 1, evening:
  the icon now opens the live app, not the demo.
- POLISH PASS LIVE Nov 1, evening: transaction filter chips
  (All / Pending / Posted / Refunds / Excluded, combined with
  search, with a Showing-X-of-Y count), per-row Exclude/Restore
  (excluded rows dimmed, labeled EXCLUDED, and dropped from week
  math by compute-week's excluded=false filter), plain-English
  subtitles on every card, labels on every button, stale "next
  slice" copy removed, Connections card (bank sync result this
  session + email poller note + last refresh). User-facing labels
  are now bank-agnostic ("Connect a bank account", "Bank
  connection (read-only)", source pills BANK / EMAIL ALERT /
  FILE / MANUAL); internal function and database names unchanged
  by design. Owner direction Nov 1 evening: the app must scale to
  other households and other bank accounts, easy and user-friendly
  above all — household isolation and multi-item sync already
  support that. Still missing: fund allocations against the fund
  balance, week history / surplus releases, live CSV import.
- Live admin RPCs applied Nov 1, evening ("Success. No rows
  returned"): approve_fund_request, decline_fund_request,
  set_base_allowance — all SECURITY DEFINER, admin-only, audit-logged.
  The live UI already has Approve/Decline buttons (admin only) and
  the Settings card, so the owner's $25 PENDING Tzedaka request can
  now be approved/declined from the app after a refresh. (Note from
  the same DB check: household_members = 4 — owner + spouse + the
  2 beta-test accounts, whose cleanup is still pending.)
- Live savings RPC applied Nov 1, evening ("Success. No rows
  returned"): attest_savings (SECURITY DEFINER, admin-only,
  audit-logged) + actual_balance_cents column on savings_ledger.
  Attestations store amount_cents = 0 so they are never mistaken for
  a money movement; the live UI now has a Savings card (attestation
  form for admins, history list for both) and a transaction search
  filter. Temporary weekly increases also live Nov 1, evening
  ("Success. No rows returned"): temp_increases table + admin-only
  add_temp_increase RPC, audit-logged; the live app sums this week's
  grants and passes T to compute-week on every dashboard load, and
  the Settings card has an Add-temporary-increase form. Still
  missing in live: week history / surplus releases display, live
  CSV import.
- GMAIL INSTALLED Nov 1, evening: Apps Script project "Household
  Budget Amex Ingest" in the owner's personal Gmail, script verbatim,
  WEBHOOK_URL + SHARED_SECRET properties set, 10-minute trigger
  active (1 trigger shown), manual run succeeded 7:26:11–7:26:13 PM
  with no errors after the owner approved OAuth himself. No Gmail
  settings/forwarding/filters changed. NOT yet proven: an actual
  Amex alert being ingested — the manual run found no error, but
  no alert ingestion has been observed yet; the first real Amex
  alert is the remaining Gmail proof point.
  The plaid-sync mask-fix redeploy completed the same evening
  ("Successfully updated edge function"; editor confirms the
  /accounts/get mask lookup) — the corrected version is now live.
  Note: the Plaid keys task's Supabase tab showed "no custom secrets
  yet" at 6:37 PM, before this deploy task's secrets step completed
  at 6:38 PM — that was timing, not a missing-secret problem.
- Grants fix, Nov 1, 2026, evening (`supabase/fix-grants.sql`,
  "Success. No rows returned"): the spouse's join failed with
  "permission denied for table household_members" — a missing
  table-level GRANT, not an RLS rejection. Tables created via the SQL
  editor get no automatic grants to authenticated, and schema.sql never
  issued any, so every client read/write was refused at the table door
  (this also explains the owner's stuck household screen). Grants now
  issued: SELECT on all 7 tables; INSERT on household_members,
  transactions, fund_requests, audit_log only. No UPDATE/DELETE granted
  to authenticated. Auth "Confirm email" verified still OFF after this
  run.
- Open risk, same root cause, not yet tested: compute-week, plaid-link,
  and plaid-exchange also read the legacy SUPABASE_ANON_KEY /
  SUPABASE_SERVICE_ROLE_KEY. The live app itself uses the new
  publishable key, so the RPC and direct-table paths are safe — but the
  first real compute-week call (which happens once the dashboard loads)
  will prove whether those functions need the same kind of fix. Do not
  claim they work until that call succeeds.
- **No secrets have been set on any function yet.** Functions correctly
  return "not configured" until secrets exist. Never set a secret from
  chat; secrets go in the Supabase dashboard (owner, via takeover) or
  the Secure Vault flow.

## 4. The money engine (canonical, do not re-derive)

`engine.mjs` is the single formula, shared by the PWA, the Node server,
and (as a copy) the compute-week function. All amounts integer cents.

- Base: **$375/week**, Sunday–Saturday, America/New_York.
- Inputs: B (base), T (temporary increment), R_in (carried refund
  credit), X (new excess refund credit), D (incoming debt), C (normal
  charges net of linked refunds, floored at 0).
- Order: credit pays debt first (R = R_in + X; debt paid = min(D, R));
  carried_debt = max(0, D − B); base_available = max(0, B − D);
  covered_base = min(C, base_available); over_base = C − covered_base;
  covered_temp = min(over_base, T); covered_credit = min(over_base −
  covered_temp, R); new_debt = over_base − covered_temp − covered_credit;
  outgoing debt = carried_debt + new_debt; R_out = R − covered_credit
  (never expires, never earns surplus; temp used before credit; credit
  never becomes fund money unless it refunds a fund purchase);
  earned surplus = base_available − covered_base;
  dashboard available = base_available + T + R − C (can be negative;
  temp never pays down earlier debt).
- Week close: Sunday 00:00 local, idempotent, ledger entries only;
  surplus pending 7 days then released; week open 28 days for recompute
  then locks (late items post as current-week adjustments labeled
  "late"); released-surplus reduction floors fund at $0, remainder =
  shortfall netted against next release, no automatic clawback.
- Extra Fund: earned only from released surplus; spend only via admin
  allocation or approved member request; insufficient-fund allocation
  blocked (override needs typed reason, logged).
- Savings: four separate numbers (fund available; earned-not-yet-
  transferred; actual balance; interest/outside movements tracked
  separately, not spendable); transfers manual only, never app-initiated,
  never counted as spending/income.
- Transactions: four sources through one matcher — Amex alert emails
  (provisional), Plaid (authoritative if viable), weekly Amex CSV
  (dedupe by stable hash + reference id), manual (provisional).
  Provisional ≠ confirmed; dedupe re-deliveries / pending-to-posted /
  tips / refunds; absent alert ≠ no spending; append-only ledger; role
  checks enforced server-side.
- Engine tests: `node --test test/engine.test.mjs` → 15 pass, 0 fail,
  1 skipped (FIN-REFUND-001, see §8). CSV parser tested Nov 1 against
  a real Amex-style file (quoted commas, MM/DD/YYYY, $123.45, a (15.00)
  refund, a duplicate, a bad row): 2 added, 1 duplicate skipped, 1 bad
  row reported, no crash; full re-import added 0.

## 5. Decisions and why (so a handoff doesn't re-litigate them)

- **Supabase Free over Cloudflare Workers + D1** (owner re-confirmed
  Nov 1, after considering Cloudflare): Supabase bundles Postgres +
  Auth + RLS + functions in one place, matching the spec; Cloudflare
  D1 is SQLite with no built-in auth/RLS, so login and household
  isolation would have to be built (and could be built wrong). Free
  limits (500 MB, 50k MAU, 5 GB egress, 2 projects) are far above a
  2-user household. The one catch: free projects pause after 1 week of
  inactivity and need a dashboard click to restore — no data loss, just
  a manual step; the owner's own TRIAL projects (Hashgacha, J-Market)
  are currently paused for exactly this reason. Upgrade path, if
  pausing ever annoys: Pro $25/month. No upgrade is approved.
- **GitHub Pages for hosting**: free HTTPS, no purchased domain, no
  Apple Developer / TestFlight for Milestone A (per the addendum).
  Pages is static, so it cannot hold Plaid's secret key — that is why
  a backend was required at all, and why shared data waited for it.
- **Plaid on Trial, Transactions only**: the owner approved proceeding
  "it will be free for us" (Nov 1). Trial is active with no bank
  connected and no paid plan. Plaid's public pricing page lists only
  Pay as You Go / Growth / Custom; its FAQ describes free use via
  "Limited Production" (up to 200 API calls per product). The earlier
  "10-Item cap" claim could NOT be verified and must not be recorded
  as fact — dashboard pages showing caps/expiry/included products are
  gated behind two-factor authentication, which the owner has not
  enabled (dashboard shows an MFA warning). Do not request Auth or
  Transfer alongside Transactions in the same Link flow — Plaid's own
  docs say that excludes credit-card accounts.
- **Gmail Plan B** (owner decision Nov 1, 4:49 PM): ingest Amex alerts
  directly from the personal Gmail account, no dedicated inbox, no
  forwarding, "simpler to set up and use." The dedicated-inbox plan is
  deferred, not deleted (see INTEGRATIONS.md). Accepted tradeoff: the
  poller runs in the personal account, mitigated by an Amex-alerts-only
  search query (the query is the boundary — nothing else is read),
  Authentication-Results (SPF/DKIM) checks server-side, dedupe, and
  provisional-only marking. The search query in
  `integrations/gmail-apps-script.gs` (`from:(americanexpress.com)
  "Large Purchase"`) is a placeholder to be tightened once a real alert
  is inspected. The $1 alert threshold is enabled; the owner observed
  one alert arriving ~6 min after a purchase.
- **No client-side admin grant** (fixed during the live build): a
  client that can insert its own admin membership can make itself admin
  of any household. Household creation therefore goes through
  `bootstrap-household` (service role), never through a client insert.
- **Demo kept separate from live**: the demo stays working on fake
  data while the live slice is tested. Do not merge them until a
  two-account shared test passes.

## 6. Hard boundaries (owner's words, do not soften)

- All financial integrations read-only. Never change existing
  Gmail / Amex / Plaid / Apple / DNS or other live account settings
  without explicit approval for that specific change.
- Owner performs logins / consent / forwarding verification / Apple
  signing. No passwords, tokens, or full card numbers in chat, source,
  logs, or screenshots.
- Ask before creating live external resources/accounts, OAuth,
  connecting banks, configuring Gmail forwarding, deploying publicly,
  incurring costs, or sending real notifications.
- No paid plan / payment method without approval. Never promise fixed
  hours/days, instant bank sync, or perpetual free operation.
- Never silently "fix" an ambiguous financial rule — escalate it with
  a failing/pending test.
- Milestone B (native SwiftUI + WidgetKit) comes last, signed/submitted
  via the owner's friend's Apple Developer account (friend controls the
  app record; TestFlight builds expire after 90 days). Never call an
  uncompiled project "App Store ready." Public release is future-only.

## 7. What is NOT done yet (in order)

1. **First real two-account test of the live slice — WORKING on both
   phones, Nov 1, 2026, evening** — owner created an account and, via
   the create_household RPC, created the household on Nov 1, ~5:44 PM
   EST: ID 647d1f23-606f-43af-92e5-1de2f1f34377 (owner = admin).
   Spouse joined after the grants fix (and after email confirmation
   was turned off temporarily to get past the 2/hr Free email limit).
   Owner confirmed "it works on both" — both phones reach the shared
   dashboard.
2. **Agent beta test, Nov 1, 2026, 6:26–6:30 PM EST — PASSED end to
   end** (two fake accounts, owner's household untouched): signup
   with no confirmation; Create household succeeded (test household
   3ffa2bc7-da11-44b2-92e7-de2a3a122445, left for the cleanup step);
   compute-week loaded real numbers ($375.00 available/allowance,
   $0.00 spent/debt/credit on a fresh household) — so compute-week
   works with the caller's own JWT and is NOT affected by the legacy
   key problem; $1.00 TEST STORE provisional transaction saved and
   updated the week to $374.00 available / $1.00 spent; second test
   account joined and saw the same dashboard (LIVE · MEMBER) and the
   TEST STORE transaction plus both audit entries. One UX bug
   reproduced: after Create household the app stayed on the household
   screen until Refresh (same as the owner saw) — fixed the same
   evening by navigating directly from the RPC/insert result instead
   of re-reading the membership (live.js, pushed). Cleanup of the
   test household/accounts/transaction is still pending — do it as a
   separate step, and do not delete the owner's household.
3. Owner decision, Nov 1 evening: leave email confirmation OFF and
   sign-ups ON for now ("Keep it off for now, it's fine") — do NOT
   disable sign-ups unprompted; the planned permanent close is
   deferred until the owner says so.
- Auth note, Nov 1, 2026, evening: the Free plan's built-in email
  limit is 2 emails/hour, which blocked the spouse's sign-up (and the
  agent's beta-test sign-up). Owner approved turning "Confirm email"
  OFF temporarily (saved, dashboard confirmed "Successfully updated
  settings"); "Allow new users to sign up" remains ON for now. With
  confirmation off, sign-up needs no email and the limit cannot block
  it. Owner decision later that evening: "Keep it off for now, it's
  fine" — i.e. leave confirmation OFF and sign-ups ON for now, do NOT
  disable sign-ups yet. The planned permanent state (disable new
  sign-ups once both accounts exist) is deferred until the owner says
  so; do not apply it unprompted.
2. **Function secrets** (dashboard, owner via takeover — never via
   chat): PLAID_CLIENT_ID + PLAID_SECRET for plaid-link/exchange, and
   INGEST_SECRET for ingest-amex-alert (the same secret must go into
   the Gmail Apps Script). Plaid secrets come from the Plaid dashboard
   the owner already signed into.
3. **Plaid token vault** — plaid-exchange is deliberately blocked until
   a safe store for access tokens exists (it must never land in the
   database, the repo, or the browser). Decide the vault before
   connecting any bank. Until then, plaid-link can create a Link token
   but no Item can be completed — that is the safe state, not a bug.
4. **Plaid Link connection** — in the live app, owner signs into Amex
   via Plaid Link, Transactions only. Do not connect anything in the
   Plaid dashboard directly; the app's Link flow is the connection.
5. **Gmail Plan B script install** — owner installs the Apps Script in
   personal Gmail (Amex-alerts-only search), after the ingest endpoint
   exists (it does) and after one real alert's headers have been
   inspected to tighten the search query and parser.
6. **Admin slices** — fund approvals/allocations, settings, savings
   attestation behind Edge Functions with explicit role checks; live
   CSV import; then Milestone B (native app) only after the owner
   approves it.

## 8. Open questions (do not resolve by inventing a policy)

- **FIN-REFUND-001 (OPEN, owner-deferred)**: the spec's later refund
  test says a $100 excess refund in a week with no debt and no charges
  yields $375 earned surplus AND $100 outgoing refund credit — a
  possible double benefit. The engine reports both numbers and the UI
  flags dependent outputs as not production-certified. The test stays
  skipped. Do not deploy automatic fund release on an unreviewed
  interpretation. The owner must rule before production use of
  refund-credit/surplus logic.
- **Plaid detailed Trial terms** (Item cap, API-call limit, expiry,
  whether Transactions is included): unverified, blocked on the owner
  enabling MFA in Plaid (or Plaid surfacing the terms another way).
- **Supabase Free pause**: accepted (see §5). If it bites in practice,
  the move is to Pro ($25/month) or a Postgres export — not a redesign.

## 9. Files that matter (repo layout)

- `index.html`, `app.js`, `engine.mjs`, `styles.css`, `manifest.json`,
  `sw.js`, `icon.svg` — demo PWA.
- `live.html`, `live.js`, `config.js` — live Supabase slice.
- `server.mjs` — zero-dependency Node demo server (local only; the
  live backend replaces it, it does not deploy to Pages).
- `test/engine.test.mjs` — engine tests (15 pass / 1 skipped).
- `supabase/schema.sql`, `supabase/schema-inserts.sql` — applied.
- `supabase/functions/` — compute-week (+ engine.mjs copy),
  plaid-link, plaid-exchange, ingest-amex-alert, bootstrap-household,
  `_shared/engine.mjs` (repo copy; dashboard uses the in-function copy).
- `supabase/README.md` — backend build order.
- `INTEGRATIONS.md`, `NEXT_STEPS.md`, `OPEN_QUESTIONS.md`,
  `ARCHITECTURE.md`, `TASKBOARD.md`, `DEPLOY.md`, `README.md` —
  planning docs (some predate the Supabase build; this HANDOFF.md is
  the current state, and those docs are background).
- `integrations/gmail-apps-script.gs` — Plan B script (placeholder
  search query; see §5).
- `.env.example` — placeholders only, never real values.

## 10. How to verify this handoff is current

- `git status` is clean and `git rev-parse HEAD` equals
  `git ls-remote origin HEAD` (both were fd4c2ce before this file was
  added; this file's own commit is the new head — check it the same
  way after pushing).
- Supabase: project Budget is Healthy; Tables shows the 7 tables;
  Edge Functions lists compute-week, plaid-link, plaid-exchange,
  ingest-amex-alert, bootstrap-household, all Deployed.
- Plaid dashboard: Trial ACTIVE, no Item, no payment method.
- Gmail: forwarding DISABLED, Cricket gateway address untouched.
- Live app: https://ycfried.github.io/Budget/live.html loads and
  shows the LIVE banner (not DEMO).
