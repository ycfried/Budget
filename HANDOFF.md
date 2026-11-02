# BRANCH NOTE — audit-fixes (NOT DEPLOYED — read first)

This branch (`audit-fixes`) contains the overnight post-audit build. NOTHING
here is live until the parent deploys it (checklist below). Do NOT merge to
main until the deploy checklist has been walked in order. The pre-existing
HANDOFF content below is retained for context but is known to be partly
contradictory (audit P1-47: a full HANDOFF rewrite is still owed); where it
disagrees with the FINAL spec (`Household_Budget_Spec_FINAL.pdf`) or with
this section, the FINAL spec and this section win. FIN-REFUND-001 is MOOT
under the FINAL spec (not open) — the old refund-credit model is retired
on this branch and refund restoration is built (see below).

## What changed on this branch (by workstream)
- S1 (SQL security + invites): `supabase/01-invite-codes.sql` (invite_code,
  generate_invite_code(), backfill, create_household() sets a code,
  join_household_by_code(code-or-legacy-UUID)), `02-rls-hardening.sql`
  (member direct writes revoked; member transaction inserts limited to
  manual/csv + provisional; fund-request pending + household validation;
  anon log_webhook_event revoked), `03-plaid-vault.sql`
  (plaid_items_public view WITHOUT access_token_encrypted; ciphertext RPCs
  revoked from members), `04-admin-rpcs.sql` (approve_and_allocate caps at
  requested amount with remainder_cents + split status, accumulates
  allocations, household lock; update_fund_shortfall path; old→new
  allowance audit; old approve path now delegates),
  `05-transaction-mutation-rpcs.sql` (exclude/restore/reclassify RPCs),
  `INTERFACE.md`.
- S2 (restoration engine): `engine.mjs` + all three function copies rewritten
  (inputs B/T/D/C only; available = base_available + T − C);
  `restoration.mjs` (simulation, incremental/posted-only/temp-excluded/
  held-excess/shortfall-first/fund-credit/idempotent rules);
  `supabase/restoration-snapshots.sql` (restoration_entries, held_refunds,
  linkage columns, week-close B/T snapshots, resolve_held_refund RPC —
  release action is REJECTED pending an owner decision on where released
  excess goes); `compute-week` (derives D/T server-side, ignores client
  values; returns the 8-field shape, no credit fields); `week-close`
  (snapshots, close-date-anchored pending window, post-release surplus
  delta, locked-week late adjustments, every write error checked,
  shortfall only via update_fund_shortfall); `test/engine.test.mjs`
  rewritten — 27 pass, 0 fail (old credit fixtures deleted).
- S3 (ingestion + Plaid + payments): `integrations/gmail-apps-script.gs` +
  `ingest-amex-alert` rewritten to ONE contract (`integrations/
  INGEST_CONTRACT.md`: x-budget-signature, per-household secret,
  timestamp+nonce replay protection, constant-time compare, HB_PROCESSED
  only on stored:true; key fallback SUPABASE_SECRET_KEY then legacy key);
  `plaid-sync` rewritten (cursor load/persist, removed[] → reversed,
  pending→posted linkage, canonical dedupe, payment/cashback kinds,
  plaid_accounts upsert, institution backfill, disconnected skip);
  `plaid-disconnect` (new, admin-only); `payment-kind.sql`,
  `payment-backfill.sql` (UPDATE COMMENTED OUT — see checklist),
  `dedupe-fix.sql`, `plaid-accounts.sql`, `ingest-secrets.sql`,
  `_shared/canonical.ts`, `S3_INTERFACE_NOTES.md`.
- S4 (live UI + public surfaces): `live.html`/`live.js` (showSheet escaping,
  strict amount validation, Credit stat + FIN note removed, debt-aware
  hero, outgoing-debt stat, this-week spent scope, server-truth bank
  state, bank accounts + logos, merchant icons, fund summary, week
  history, savings four numbers display, live CSV import, password reset
  link, delete-account button, invite-code join/share);
  `styles.css` (live-scoped only); `demo.html` + `app.js` (demo credit
  retired); `index.html` replaced by landing content (public root is now
  the landing page; demo lives at demo.html with NO link from landing —
  owner to confirm); `landing.html`, `reset.html`,
  `supabase/functions/delete-account/index.ts`, `docs/BACKUP.md`.
- Coordinator integration patches: `plaid-sync`, `plaid-webhook-register`,
  `plaid-disconnect`, `plaid-exchange` now use a service-key client for
  DB access after caller membership/admin verification (caller JWT still
  proves identity); `week-close` uses a service-key client for table
  writes (update_fund_shortfall RPC stays on the caller JWT);
  `plaid-webhook` uses a service-key client for log_webhook_event;
  `05` reclassify allows payment/cashback; `03` view gained
  institution_id + status and `live.js` bank queries moved to the view;
  `supabase/07-service-rpc-access.sql` (ciphertext/sync RPCs accept
  service_role explicitly, members NOT re-granted; log_webhook_event is
  service_role only; member INSERT/UPDATE on plaid_items revoked — no
  client code writes plaid_items, all functions use the service key);
  `supabase/08-decline-fix.sql` (closes audit P1-11: decline writes its
  audit row only when the request was actually pending).

## DEPLOY CHECKLIST (parent executes — coordinator never deploys)
- 0. BACKUP FIRST (docs/BACKUP.md). Do this deploy while the household is
  not using the app: between the SQL deploy and the Pages push, the OLD
  live app will error on admin actions (direct writes now revoked).
- 1. Edge Function secrets: set SERVICE_ROLE_SECRET (a custom secret
  holding the CURRENT secret key value — the dashboard REJECTS the
  SUPABASE_ prefix, so a custom secret named SUPABASE_SECRET_KEY is
  impossible to create; the function code was renamed accordingly.
  The legacy service key is dead and must not be relied on).
  Confirm PLAID_CLIENT_ID / PLAID_SECRET / PLAID_ENV / PLAID_TOKEN_KEY
  are set. Keep "Verify JWT with legacy secret" OFF on plaid-webhook.
- 2. SQL, in this order, in the Supabase SQL editor (stop on any error):
  01-invite-codes, 02-rls-hardening, plaid-accounts (MUST run BEFORE
  03-plaid-vault: file 3's plaid_items_public view selects
  institution_id/status, which only file 9 creates — running file 3
  first fails with "column institution_id does not exist" and leaves
  plaid_items unreadable to clients, which is what stopped the first
  deploy attempt), 03-plaid-vault, 04-admin-rpcs,
  05-transaction-mutation-rpcs, restoration-snapshots,
  payment-kind (§2 linkage columns are no-ops if restoration-snapshots
  ran first — verify types match), dedupe-fix,
  ingest-secrets, 07-service-rpc-access, 08-decline-fix.
  DO NOT RUN payment-backfill.sql's UPDATE (it is commented out on
  purpose). Before ever running it: run its verification SELECT and
  confirm ~6 rows / ~$2,273 of MOBILE PAYMENT rows; get a ruling on
  locked-week handling (locked weeks must not be rewritten); back up.
- 3. Edge Functions, deploy/redeploy: compute-week, week-close, plaid-sync,
  plaid-exchange, plaid-disconnect (new), plaid-webhook, plaid-webhook-
  register, ingest-amex-alert, delete-account (new). Deno type-check
  first (the build environment had no Deno, so functions were NOT
  type-checked here).
- 4. Owner's Gmail: paste the rewritten Apps Script into the "Household
  Budget Amex Ingest" project; create the owner's per-household ingest
  secret (ingest-secrets table) and set Script Properties to the new
  contract (household_id + secret). Remove the old shared INGEST_SECRET
  only after the new path proves a stored:true delivery.
- 5. Pages: merge audit-fixes → main, then verify: sign-in works, join
  by invite code works, bank list renders from plaid_items_public,
  compute-week returns the 8-field shape, week-close runs without
  errors (watch the FIRST run closely — restoration posting needs 07
  applied; a 500 with partial counts means re-run, it is idempotent).
- 6. Auth lockdown (OWNER DECISION — not yet approved): disable "Allow
  new users to sign up" in Supabase Auth settings. After transition,
  remove the legacy-UUID path from join_household_by_code (follow-up
  migration) — the UUID is already public, so history scrubbing alone
  fixes nothing. Note: invite codes in this build are reusable and
  non-expiring (audit proposed single-use/expiring — owner to rule).
- 7. Owner decisions still open (see final build report): held-refund
  release destination (S2 rejects money-posting release until ruled);
  split-remainder re-approval (this build: split is closed, remainder
  recorded only); blank exclusion/reclassification reasons (spec wants
  a reason — this build accepts blanks); savings transfer_in/withdrawal/
  interest write paths (display shows $0 until added); landing page
  with no demo link (confirm vs adding a labelled demo link);
  auth-results strictness (DKIM+SPF both required — confirm after a
  real alert's headers); Plaid refund original_purchase_id stays NULL
  (no reliable link field — matcher work later).
- 8. Reaudit: runs AFTER this deploy lands (separate step). Do NOT claim
  the build is live or verified until then. AUDIT_FULL.md (untracked)
  contains the household UUID and must NOT be committed to the public
  repo unredacted.

---

# Household Budget — Handoff

## FINAL BASE SPEC (Nov 1, 2026, ~11:01 PM — owner-delivered, supersedes all previous spec versions)
- File: `Household_Budget_Spec_FINAL.pdf` in this repo (uploaded as Household_Budget___Revised_iOS_Spec__v2-2.pdf, 20 pages). From now on this is the base. The old v2 PDF (19 pages) is superseded.
- Headline delta vs old v2 (verified by text diff; everything else is repagination/reordering): the ENTIRE refund-credit model is removed (no R_in/X/R_out, no credit-pays-debt-first, available = base_available + T − C) and replaced by REFUND RESTORATION (read-only simulation from the purchase's week to the present; one restoration entry in the current week with restored surplus + debt reduction; posted-only; temp-covered portion restores nothing; over-refund held for admin review; restoration offsets shortfall first; fund-purchase refunds credit the fund). Amex cash-back statement credits are NOT refunds (excluded by default, admin can classify).
- Consequence: FIN-REFUND-001's old question is MOOT (the credit model is gone), but restoration itself is UNBUILT — the current engine/week-close still implement the old credit model (R chaining, "Refund credit" stat, held weeks). Retiring the old model and building restoration is the biggest post-audit build item. The running full audit has been redirected to this final spec.
 (single source of truth)

> Last updated: Nov 1, 2026, ~9:45 PM EST (all evening progress: screens, filters, webhooks, proper-look batch, review).
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
- BETA POLISH PASS 2 LIVE Nov 1, evening (owner unavailable to
  test; agent-tested against the original spec): card padding
  22px / 24px gaps, header and banner wrap on narrow phones,
  filter chips enlarged to real tap targets, long merchant names
  truncate with ellipsis and expand on tap (amount can never be
  pushed off-screen), negative weekly-available shown red,
  refunds tinted, "This week only" toggle (current Sun–Sat week),
  Exclude now admin-only in the UI with a reason prompt recorded
  in the audit log. Note: server-side admin-only exclude still
  needs an RPC to be fully enforced; the spouse no longer sees
  Exclude/Restore buttons. Spec gaps still open: week history /
  surplus releases, fund allocations, live CSV import, savings
  four numbers, persisted sync health, FIN-REFUND-001.
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

- **PLAID WEBHOOKS DEPLOYED Nov 1, 2026, ~8:03–8:09 PM EST** (all
  five steps confirmed, every file pasted verbatim from this repo,
  no secrets set — none needed). Design, corrected after the v1
  HMAC design was caught wrong: Plaid verifies webhooks with a
  signed JWT in the `Plaid-Verification` header (ES256, kid fetched
  via /webhook_verification_key/get, iat within 5 minutes, SHA-256
  of the raw body must match the request_body_sha256 claim). There
  is NO shared webhook secret. Steps done: (1) webhook-events-v2.sql
  — UPDATE grant on webhook_events + "members update own webhook
  events" policy ("Success. No rows returned"); (2) plaid-webhook
  redeployed with the corrected JWT version, "Verify JWT with legacy
  secret" toggle verified still OFF; (3) plaid-webhook-register
  created and deployed (admin-only; registers the webhook URL on
  each household item via Plaid /item/webhook/update, token
  decrypted in memory only); (4) plaid-link redeployed, now passes
  the webhook URL at Link token creation so future connections get
  webhooks automatically; (5) plaid-sync redeployed — after a
  successful sync it marks that item's webhook_events processed.
  Live app: Bank card has an "Enable automatic sync" button and
  auto-syncs on refresh when an unprocessed webhook event exists.
  NOT yet proven: the owner still has to tap "Enable automatic
  sync" in the app (admin), and a real SYNC_UPDATES_AVAILABLE
  webhook still has to be observed recorded + auto-synced. Do not
  claim webhooks work until that chain is observed.
- **EVENING POLISH, live Nov 1, ~8:40–9:45 PM EST** (all in the
  repo and pushed; nothing held locally):
  - Purchases sort: date newest/oldest, amount least→most and
    most→least; remembered across visits; works with filters and
    search.
  - Purchases filter by month (built from months actually present,
    year included) and by card suffix; the count line shows the
    total of the shown rows.
  - Week screen tightened: empty message boxes no longer render as
    blank strips (`.result:empty` hidden); card spacing and stat
    grid gaps reduced; the "tap a number" hint no longer takes a
    grid row.
  - Top banner REMOVED (Nov 1, ~9:36 PM): Refresh moved into the
    header next to Sign out; last-updated time stays on the
    Connections screen. The LIVE · ADMIN header badge was also
    removed (~9:41 PM) after the owner circled it; the header is now
    just the title, Refresh, and Sign out. Role is still enforced
    server-side and visible via which cards appear (Settings is
    admin-only).
  - Proper-look batch (~9:38 PM): friendly dates ("Week of Nov 1,
    2026", "Nov 1" in lists; raw ISO dates stay in data and search);
    hero no longer mentions "compute-week"; the household UUID is
    behind a "Share household ID" tap instead of sitting on the
    dashboard; stat labels simplified ("Spent this week", "Owed
    from last week", "Refund credit"); cents render smaller in the
    hero and stat numbers; empty weeks teach ("No purchases this
    week yet…"); Refresh shows "Updating…" while it works and a
    plain error appears if the week's numbers fail to load.
  - Browser prompt/confirm/alert dialogs REPLACED with in-app
    sheets (exclude reason, delete, remove, duplicate warning, all
    error messages) — no grey browser boxes remain in the live app.
  - Buttons/chips restyled, live app only (demo untouched):
    filter chips are filled pills (warm tint off, solid deep green
    on); buttons have a clear hierarchy (solid green primary, warm
    filled secondary) and dim on tap; nav active tab has a bolder
    brass underline.
  - Real home-screen icons: PNG icons generated (180px
    apple-touch-icon, 192px, 512px incl. maskable) and wired into
    manifest-live.json; the old icon was SVG, which iPhones mostly
    ignore — the owner must delete and re-add the home-screen icon
    once to pick the new one up.
  - Fund allocations per spec A5/A4 (week close → 7-day pending →
    release → allocation) were APPROVED by the owner Nov 1 evening
    and are IN PROGRESS (not yet live). Two findings from the
    spec check that this work must resolve: live week chaining is
    broken (live.js passes only T to compute-week, so debt/credit
    do not carry between weeks) and the compute-week refund-sign
    question (C = charges − refunds with refunds stored negative)
    must be verified by hand before trusting refund weeks.
  - Public-app review saved as REVIEW_PUBLIC_APP.md in this repo
    (spec gaps, onboarding, App Store readiness, cost triggers,
    phased roadmap). Owner direction recorded: App Store app for
    anyone, onboarding as simple as possible, paid tiers only when
    scale demands them.
  - Git hygiene verified Nov 1, ~9:45 PM: working tree clean, local
    HEAD equals GitHub main — every file above is pushed,
    including the new PNG icons, REVIEW_PUBLIC_APP.md, and
    supabase/delete-transaction-rpc.sql.
- **REAL SCREENS + TAPPABLE ROWS + DELETE, live Nov 1, ~8:20 PM EST:**
  the nav tabs are now real screens (only one section group shows at
  a time; choice remembered). Tapping a purchase opens its detail
  (week it counts in, source, status, actions); tapping a stat card
  shows the week breakdown by source; fund requests expand too.
  Delete: hand-entered purchases truly delete via the admin-only
  delete_transaction RPC (applied Nov 1, ~8:23 PM EST, "Success. No
  rows returned"; deletion itself is audit-logged). Bank/email/file
  rows cannot be erased (the bank would re-sync them), so the UI's
  Remove button excludes them from week math instead. Manual entry
  warns on an apparent duplicate (same store, amount, date).
- **SECTION NAVIGATION, live Nov 1, ~8:05 PM EST:** the live app
  has a sticky tab bar (Week · Purchases · Bank · Savings ·
  Extra Fund · Activity) that jumps to each section and highlights
  the section in view — added after the owner said the app felt
  like one long scrollable page.

## Nov 1, ~10:05 PM — restyle direction FOUND + audit fixes + fund backend (owner-directed)
- Owner found the look: two Fireart Studio Dribbble shots ("Personal Finance & Budgeting Mobile App" and "Saving Mobile App") — white, near-black type, one blue accent, pill buttons, thin progress bars, bottom tab bar. Restyle hold is LIFTED. Borrowed the visual language only: our app stays weekly (theirs is monthly) and no math changed.
- New skin (body.live scope, demo untouched): white bg, ink #0f172a, blue #2f6bff primary, sans headlines, 20px cards, bottom tab bar with icons (Home / Purchases / Bank & Funds / History), hero progress bar (spent vs allowance), merchant icon squares in rows, blue app icon + white theme-color, stylesheet v3.
- Audit fixes applied in the same pass: Settings moved Home → Money; Share household ID + Change password moved into the profile menu; Connections card deleted (status folds into Bank card); Purchases filters collapse behind a Filters toggle, "This week" is a chip, Load more pages of 100 with honest "of loaded" counts, capped lists note their limits; tab taps show cached content and refresh in background (30s throttle); per-stat breakdowns (each number explains itself); pills in normal case (Bank / By hand / Email alert); buttons: one 10px gap system, red destructive, quiet Decline, sheets/menu use the same skin via body.live; Bank card: Connect quiets to "Connected ✓" after connection, Sync becomes primary, webhook button shows "Automatic sync is on ✓", last-sync persists in localStorage; FIN note is one plain line; sign-in/join copy cleaned of Supabase/uuid jargon; error text no longer references the deleted Refresh button; footer shows last-updated.
- Fund backend (the audit's #1 item, and the previously approved fund build): supabase/fund-ledger.sql (week_closes, surplus_releases, fund_ledger, households.fund_shortfall_cents, RLS + grants, approve_and_allocate + allocate_fund RPCs with balance check + override reason) and supabase/functions/week-close/ (admin-only, idempotent, chains debt/credit, FIN-REFUND-001 weeks 'held' never auto-release, late-reduction shortfall rule). compute-week fixed: C/X now derived from signed amounts minus fund allocations (old code did charges − refunds with negative refunds, overstating spending 2x in refund weeks) and the live app now chains D/R_in from the latest week_close.
- Fund UI: balances on top of the Extra Fund card (Available / Released / Pending / Spent / Shortfall / held count), admin "Process completed weeks" button, direct allocation form, approve flow with split amount + override-reason retry, "Use Extra Fund" on any purchase row.
- DEPLOY STATUS (Nov 1, ~10:17 PM): backend DEPLOYED — fund SQL ran "Success. No rows returned" (week_closes, surplus_releases, fund_ledger, fund_shortfall_cents, RPCs); week-close function created + deployed (engine.mjs alongside index.ts, './engine.mjs' import — the dashboard's flat layout, repo updated to match); compute-week redeployed with the refund-math fix. Nothing else touched (no other project, Auth setting, user, or plan). Fund balances are now live in the app; admin taps "Process completed weeks" to close completed weeks.

## Nov 1, ~9:55 PM — restyle ON HOLD (owner-directed)
- Owner: the current look "feels like a typical AI" and a restyle is needed, but **do NOT push any restyle live** — he will try to find a reference look first. The live app stays exactly as it is (4-tab nav + consistency pass) until he sends what he finds.
- The design audit already running still reports, but its fixes are also held until the restyle direction lands, so restyle and fixes land together instead of twice.

## Nov 1, ~9:55 PM — navigation + consistency pass (owner-directed)
- Tabs regrouped 6 → 4: **Home** (week, stats, Settings, FIN note), **Purchases** (transactions + add-by-hand), **Money** (bank + connections + savings + Extra Fund), **Activity** (audit log). Tapping a tab refreshes that screen; header Refresh button already removed.
- Buttons: one size across the live app (the small variant made neighbours look mismatched); side-by-side buttons get 8px gaps.
- Wording unified: user-facing status is **Pending / Posted** everywhere (internal state name 'provisional' remains in code only); manual-add heading/button, stats subtitle, and connections note rewritten; 'Base weekly allowance' → 'Weekly allowance'.
- Header: title centered; profile icon menu (email, role, Sign out) replaces header Sign out button.
- A read-only design/structure audit agent was commissioned after this pass to catch what it missed; apply its findings when it reports.

## Public-app direction (owner, Nov 1, 2026, evening)

The owner wants this to become an App Store app anyone can use,
with onboarding as simple as possible. Scale later means paid
tiers (Plaid beyond trial, Supabase Pro, Apple Developer), but
nothing paid before scale demands it. Full gap analysis against
the spec, onboarding, design, App Store readiness, and cost
triggers: see REVIEW_PUBLIC_APP.md in this repo. Headline
findings: live week chaining is broken (debt/credit do not carry
between weeks — the in-flight week-close work is the fix); the
refund-sign question in compute-week must be verified by hand;
UUID-paste onboarding + open sign-ups + no account deletion
cannot ship publicly; there are no backups at all.

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
   EST: ID [REDACTED — household join now uses invite codes, see audit-fixes section] (owner = admin).
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

## Brand decision (Nov 1, 2026, ~11:11 PM — owner)
- App name: **OnBudget** (chosen over Allowance, UnderBudget, Balanced, Weekly, Spare — Spare rejected: does not sound like a budget app).
- Mark direction (updated ~11:16 PM): the power-button donut — bold blue vertical bar breaking the top of a clearly segmented donut (bright blue / light blue / grey segments, wide white dividers) on white — file `brand/media-generation-logo-power-donut-white-0-92a0eaa8-973b-4c4c-8579-257c05fa1c18.webp`. The earlier thin-line ring was rejected: not clearly an on-button, splits too subtle. Rename + icon set + App Store name-availability check still to do once the mark is confirmed final.
