# OnBudget — Handoff (single source of truth)

> Last rewritten: Nov 2, 2026, ~7:20 PM EST. If this file and any chat
> message disagree, this file wins — update it whenever the state
> changes, and say so in the reply that announces it.
> No secrets, passwords, tokens, keys, full card numbers, household
> identifiers, or invite codes ever belong in this file, in the repo,
> or in chat. Secret NAMES are fine; secret VALUES never are.

## 1. What this is

A private, shared household budget tracker for exactly two users: the
owner (admin) and his spouse (member). One Amex Blue Cash Everyday, two
card numbers (suffixes only, never full numbers). Amounts are integer
cents; the server is authoritative. The app is a mobile-first
installable PWA for now; a native app is a later, separate step (§8).

Owner: Yehoshua Friedman (GitHub: Ycfried, Gmail: ycfried1@gmail.com).
The owner has no computer access — everything he does happens from his
iPhone/iPad, and he takes over the live browser (in the Muse app, not
WhatsApp) only to enter sensitive info himself. The agent does all
packaging, pushing, and deploying from its own environment.

**Base spec (FINAL, Nov 1, 2026, ~11:01 PM — supersedes all previous
spec versions):** `Household_Budget_Spec_FINAL.pdf` in this repo. Its
two substantive changes vs earlier specs govern everything below:

- The old refund-credit model is REMOVED entirely, replaced by
  **refund restoration**: a refund after its week locked is handled by
  a read-only simulation of every week from the purchase week through
  the **last completed week** (owner ruling on the horizon), reducing
  only that purchase's charge by total refunded so far, posting ONE
  restoration entry in the current week. Incremental; never exceeds
  the refund; never double-restores; credited only after the refund
  POSTS; the temp-increment-covered portion restores nothing; refund
  beyond the charge is HELD for admin review; credits offset recorded
  shortfall first; fund-purchase refunds credit the fund directly;
  locked history is never edited; simulation is idempotent.
- Amex cash-back statement credits are NOT refunds (excluded by
  default; admin can classify).

## 2. Where everything lives

| Thing | Location |
|---|---|
| GitHub repo (public) | https://github.com/ycfried/Budget — branch `main` (Pages from main) |
| Live app | https://ycfried.github.io/Budget/live.html (`live.js?v=8`, `styles.css?v=9`) |
| Landing (no demo link, owner ruling) | https://ycfried.github.io/Budget/ — demo lives at `demo.html`, unlinked |
| Reset page | https://ycfried.github.io/Budget/reset.html |
| Local working copy | `~/workspace/household-budget/` |
| Supabase org / project | Org **Budget** (Free); project **Budget**, region **us-east-1** |
| Supabase API URL | https://tnkhvdkmwmwiogiienee.supabase.co |
| Supabase dashboard | https://supabase.com/dashboard/project/tnkhvdkmwmwiogiienee |
| Spec / audits | `Household_Budget_Spec_FINAL.pdf`, `AUDIT_FULL.md` (gitignored — contains a household identifier, NEVER commit unredacted), `AUDIT_REAUDIT_2026-11-02.md`, `docs/BACKUP.md`, `docs/privacy.md` + `docs/terms.md` (DRAFTS — lawyer review required before publishing) |

Git rule: no global git identity is configured, so every commit must
use `git -c user.name="Household Budget" -c user.email="demo@example.com"`.
Untracked, intentionally uncommitted: `*_DRAFT.md` files, `brand/`
trials, `throwaway-csv-test.csv`. Do not commit them.

## 3. The money engine (canonical, do not re-derive)

`engine.mjs` is the single formula, shared by the PWA and (as a copy)
the compute-week function. All amounts integer cents.

- Base: **$375/week**, Sunday–Saturday, America/New_York.
- Week math (current model): available = base_available + T − C,
  where T is temporary increments and C is normal charges net of
  linked refunds (floored at 0). Carried debt = D (owner ruling).
- Week close: Sunday 00:00 local, idempotent; surplus sits Pending 7
  days before releasing; released surplus is the only source of Extra
  Fund money; fund spending is admin allocation or approved member
  request only (insufficient-fund allocation blocked; override needs a
  typed reason, logged). Refund math fixed going forward — refunds no
  longer inflate the week's spending.
- Transactions: four sources through one matcher — Amex alert emails
  (provisional), Plaid (authoritative), weekly Amex CSV (stable-hash
  dedupe), manual (provisional). Provisional ≠ confirmed. Card
  payments are kind `payment` (excluded from week math and purchase
  totals); cashback rows are excluded from week math.
- Tests: `node --test test/*.test.mjs` → **46 pass / 0 fail**
  (engine + Gmail suites, re-run Nov 2, 2026).

## 4. Backend: what is live and proven

**Deploy route (standing):** GitHub auto-deploy of Edge Functions.
Dashboard code-editor paste is DISPROVEN for function deploys, and the
GitHub integration redeploys ONLY functions whose files changed in a
push — to pick up a changed secret, a function must be redeployed.

**Live Edge Functions (15):** compute-week, week-close, plaid-link,
plaid-exchange, plaid-sync, plaid-webhook, plaid-webhook-register,
plaid-disconnect, ingest-amex-alert, delete-account, gmail-oauth-start,
gmail-oauth-callback, gmail-poll, gmail-disconnect, plus the
`_shared` copies (gmail-parse.ts, canonical.ts). `bootstrap-household`
was removed from the repo and config Nov 2 (a deployed copy may linger
in the dashboard; it is dead and unused).

**Secrets (NAMES only):** PLAID_CLIENT_ID, PLAID_SECRET, PLAID_ENV,
PLAID_TOKEN_KEY, INGEST_SECRET, GOOGLE_CLIENT_ID,
GOOGLE_CLIENT_SECRET, SERVICE_ROLE_SECRET, GMAIL_TOKEN_KEY. Values are
never in chat, source, logs, or screenshots. Browser automation CANNOT
copy/paste at all — any value transfer into a dashboard field must be
done by the owner in person via live-browser takeover.

**Two durable lessons (do not relearn):**

1. **RLS policies alone do not grant table access.** Tables created
   via the SQL editor get no automatic grants. Nov 2, ~1 PM, the
   service role had NO grants on any public table, which broke
   week-close ("permission denied") and made plaid-sync a no-op.
   Fixed via SQL (`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES
   IN SCHEMA public TO service_role` + sequences + default
   privileges) and proven by a 200 + 200 owner Sync press. Do NOT
   "fix" this class of issue by re-granting member writes.
2. **Every encoder/decoder of a stored secret must use the same
   encoding**, proven by a full round trip. The Gmail token bug was a
   hex-vs-bytes mismatch (see §5).

**Auth (FINAL owner decision): sign-ups ON, "Confirm email" OFF.**
Auth URL configuration (fixed Nov 2, ~7:02 PM, §6): Site URL
https://ycfried.github.io/Budget/; Redirect URLs = reset.html +
live.html. A password-reset link previously went to the localhost
default because these were unset — that is fixed, not a standing bug.

## 5. Integrations: proven state

### Plaid (bank)
- Trial ACTIVE: **Production, up to 10 connections** (owner's Amex =
  1), no payment method/plan. Product `transactions` only.
- Amex connection PROVEN end-to-end Nov 1 (real transactions, card
  suffix 1005). Card payments surface as negative Plaid amounts and
  are classified kind `payment`; cashback is excluded from week math.
- **Payment backfill DONE Nov 2:** 9 rows / $3,023 reclassified
  refund→payment in one atomic transaction; locked-week figures
  untouched; backup taken first. Cashback rows: 0.
- plaid-sync reconciliation: (1) external_id match, (2)
  pending_transaction_id linkage, (3) canonical-hash match
  (cross-source, e.g. Gmail alert row) — merges an incoming Plaid row
  into the earliest provisional row instead of duplicating it.
- Manual Sync is admin-only (owner decision 15, now that server sync
  is live). plaid-sync auth: service-key bearer = server path; user
  JWT must be admin; else 401/403.

### Gmail (email alerts)
- Per-user OAuth: **CONNECTED** Nov 2 (~3:57 PM) — Bank & Funds shows
  the connected address, read-only. Google Cloud project "OnBudget",
  unverified (Testing) consent screen, scope gmail.readonly only,
  test users owner + spouse. Testing mode → refresh tokens expire
  after ~7 days → roughly weekly admin reconnect until verified.
- Query: `from:(americanexpress.com) subject:"Large Purchase"` —
  subject-only (statements, which mention it in body only, no longer
  match). Real alert subject is "Large Purchase Approved".
- **Parser saga, resolved Nov 2 (~6:01 PM):** the alert email has NO
  text/plain part — a single text/html part. The old extractor handed
  the parser raw HTML, and two more traps lived in the stripped text
  (footer prose "at americanexpress.com" as false merchant; "Ending:
  01005" with a space before the colon). Fix: prefer text/plain,
  convert HTML-only payloads (style/script dropped, tags→spaces,
  entities decoded), merchant cell strategy FIRST with a domain guard,
  amount = LARGEST dollar figure, suffix regex tolerates the space.
  A drift-guard test keeps the two parse copies identical (N12).
- **Verified against the three REAL payloads:** Nov 2 → $10.59 /
  AMAZON MARKEPLACE NA PA / suffix 1005; Nov 1 (two alerts) → $1.25
  and $1.50 / COLEL CHABAD / suffix 1005 (both already counted via
  Plaid, so their markers deliberately stay "unparseable" — the
  duplicate rule is: reprocess ONLY the Nov 2 message).
- **Email path PROVEN end to end Nov 2 (~6:06 PM):** first stored
  email row ever — 2026-11-02, AMAZON MARKEPLACE NA PA, $10.59,
  suffix 1005, state provisional, kind charge. When Plaid brings the
  purchase, hash-match merges it into this row.
- Old Apps Script path ("Household Budget Amex Ingest", 10-min
  trigger, old contract, HB_PROCESSED labels) created no rows and is
  now only a stale backup path; its trigger cleanup waits until the
  cron proves itself (§7).
- **Muse's own Gmail connector scope (owner, Nov 2): Amex-related
  messages ONLY.** No general inbox reading for learning, ever. The
  reset-test mailbox was never read through it.

### Auto-sync (server-side)
- **LIVE + VERIFIED Nov 2, ~7:11 PM.** The owner pasted the service
  key in both placeholders of `supabase/server-sync-cron.sql` and ran
  it (returned job id 2, as expected for the second job). Dashboard
  check confirms exactly 2 jobs, both active: `hourly-plaid-sync`
  (hourly bank sync) and `five-minute-gmail-poll` (email checks every
  5 minutes). Both POST with the service-key bearer + household_id
  body; gmail-poll fetches only unprocessed messages, so 5-min polls
  are cheap. Never commit a filled-in copy of the cron file.
- Caveats: Free-project pause stops cron; Testing-mode Gmail tokens
  expire ~7 days (above). First firings + webhook proof still to be
  observed (§7).

### CSV import
- **Parser PROVEN** Nov 2 (~6:30 PM): the real `parseCsvLive` +
  `parseAmountLive` + `normalizeMerchant` code from live.js, run
  against the test CSV, parses all 3 rows clean, 0 errors. The insert
  path is shared with proven manual-add.
- **Tap-through UI UNPROVEN:** the preview renders only on the file
  input's `change` event, which browser automation cannot fire (3
  attempts incl. reload; Confirm stayed disabled). This is an
  automation limitation, not an app defect. A human tap is still
  needed to prove preview + confirm (§7).

## 6. Tests closed Nov 2 (audit items)

- **All 15 P0s closed in code** (reaudit Nov 2, ~4:12 PM:
  `AUDIT_REAUDIT_2026-11-02.md`; verdict then: NOT public-ready, but
  the reason changed — the current household is safe to keep using).
- **N1 (admin-only bank linking):** live (commit 4f35a83, deploy
  confirmed 4:22 PM).
- **N2+N3 (ciphertext RPC + webhook-log execute):** applied + verified
  ~4:24 PM (postgres + service_role only).
- **N13 (invite join rate-limit): APPLIED + VERIFIED live Nov 2,
  ~6:31 PM.** New `invite_join_attempts` table (RLS on, no member
  policies, grants revoked); rewritten `join_household_by_code`:
  max 10 failed attempts/hour per caller AND per code value (plus a
  per-household bucket). Codes stay REUSABLE and NON-EXPIRING;
  success path unchanged; invalid-code path returns NULL (logs
  survive — raising would roll the log back) and the live.js handler
  shows the same generic message. Known wart (not blocking): the
  per-household bucket can never trigger in practice because the
  already-member path inserts then raises, rolling the insert back;
  buckets 1+2 still throttle brute force fully.
- **N4 (stored pre-exclusion state): APPLIED + VERIFIED live Nov 2,
  ~6:31 PM.** New `transactions.pre_exclusion_state` column (CHECK:
  provisional/verified/reversed, never 'excluded'); rewritten
  exclude/restore RPCs (re-exclude keeps the original snapshot; NULL
  snapshot keeps the old date fallback for pre-migration rows).
  Verification: attempts table count 0, column present, all 3 RPCs
  present.
- **N8 (restoration/held UI):** live (live.js v8) — admin-only card on
  Bank & Funds listing restoration_entries + held_refunds (read-only),
  Release button for pending held rows (confirm-gated).
- **N12 (parse drift guard):** test in repo (both parse copies must
  match).
- **Owner decisions 2–16, ALL APPROVED Nov 2, ~12:00 PM** (👍 = yes):
  (2) held-refund release → spendable surplus; (3) split remainder
  keep as-is; (4) blank reasons allowed; (5) restoration horizon =
  last completed week; (6) fund-first refund ordering; (7)
  carried_debt_cents = D; (8) DKIM+SPF both-required (revisit after
  first real alert — real alerts pass, 0 quarantined); (9) parser
  provisional pending a real alert (now resolved, §5); (10) Plaid
  refund linkage stays NULL; (11) UUID join path removed NOW, codes
  stay reusable + non-expiring (P0-1 closed); (12) landing keeps no
  demo link; (13) savings write paths + fund_charge in reclassify —
  BUILT (record_savings_entry RPC, admin-only); (14) password min
  length 8 — BUILT; (15) manual sync admin-only once server sync
  live — now live; (16) payment backfill — DONE (§5).
- **Delete-account test (P1-33) PASSED Nov 2, ~6:30 PM:** throwaway
  account + household created, deleted via the app's own flow
  ("Your account was deleted."); before: households 2, members 3;
  after: households 1, members 2 (exactly −1 each); post-delete
  sign-in failed as expected; owner household untouched.
- **Password-reset test (P1-32) CLOSED Nov 2, ~7:11 PM:** found and
  fixed a real bug — the first reset link opened "localhost" because
  Supabase Auth URL Configuration still had the default localhost
  Site URL and the live reset page was not in Redirect URLs, so
  Supabase ignored the app's correct redirectTo. Fix applied +
  verified after reload (Site URL = live app; Redirect URLs =
  reset.html + live.html). Fresh link reached the live reset page
  ("Password saved. You can now sign in with it."), fresh sign-in
  verified (7:10 PM detail panel, matching the owner's "It worked"),
  throwaway deleted via dashboard; Users list back to exactly 2
  (owner + spouse). The app's reset page (`reset.html`, updateUser
  as recovering user) was already correct; only the dashboard
  setting was wrong.
- **Backup (P1-35) CLOSED Nov 2, ~6:40 PM:** durable copy verified
  + restore test passed in a local scratch DB (all 13 tables exact:
  transactions 120, audit_log 21, fund_ledger 6, fund_requests 1,
  household_members 2, households 1, plaid_accounts 1, plaid_items 1,
  processed_email_ids 3, surplus_releases 6, week_closes 6,
  webhook_events 2, email_connections 1). Correction caught by the
  restore test: the FIRST unordered transactions export overlapped by
  3 rows (116 distinct, not 119); the ordered re-export
  (`ORDER BY id` slices, 100 + 20, zero overlap, union 120 = live
  count incl. the Nov 2 email row) supersedes it. Sources:
  `~/workspace/browser_downloads/sess-256598780/` (13 tables) +
  `sess-1034500803/` (ordered transactions). Restore runbook: use
  explicit column lists on COPY (CSVs predate the N4 column);
  disable triggers on fund_requests for the load, then re-enable;
  reload fund_ledger AFTER fund_requests (FK order); the scratch DB
  `onbudget_restore_test` was left in place and can be dropped.
  Note: `week_snapshots` has no creating file in the repo SQL
  (schema drift to look at); 7 tables were empty at backup time and
  restore empty by design.

## 7. Still open (not blockers for the owner's household use)

- **Webhook proof:** needs a real purchase with the app closed →
  plaid-sync invocations > 0 + new transaction visible on next open
  + 24h clean counts. Unprovable except by real life.
- **First cron firings observation:** gmail-poll within minutes of
  ~7:11 PM, plaid-sync at the top of the hour; invocation counts to
  be checked.
- **CSV UI tap-through (P1-29, UI half):** needs a human tap (§5).
- **Apps Script 10-min trigger cleanup:** after the cron proves
  itself (coexistence is harmless due to processed markers).
- **Reaudit residuals (accepted/bounded, not launch blockers):**
  N5 (audit text member-writable), N6 (webhook no signature
  verification, bounded — Plaid verifies via signed JWT, there is no
  shared webhook secret), N7 (sheet promise orphaning), N9
  (week-close conditional-claim, accepted), N11 (legacy rows
  unverifiable without live access).
- **P1-46:** the live app never registers the service worker.
- **Icon small fix:** DEFERRED by the owner (~2:12 PM); details TBD
  by him — do NOT redesign until he says what. Current mark: the
  owner's S mark (`brand/onbudget-mark-s-owner.jpg`); lockup and
  landing/demo favicons still carry old marks.
- **Standing design rules (owner):** all cards/fields sized to what
  is necessary and comfortable — never too long or big — everything
  easy to find, on the RIGHT page. **Toast rules:** transient
  messages in the bottom toast only, never inside cards; ALL toasts
  brand blue (#2f6bff) with white text, error or not (no red toasts,
  ever); auto-dismiss after 4s; bottom offset 120px (never flush
  with the tab bar). Sync bank button lives INSIDE the hero card.
  Bank & Funds lists swap atomically (fragment + replaceChildren) —
  the Nov 2 "glitching card" was refresh() clearing lists then
  re-appending row by row (fixed, live.js v7+).
- **Queued under the design rule (not yet changed):** savings balance
  form, fund use/ask forms, settings card fields.
- **Owner's remaining loose confirmations:** toast auto-dismiss (not
  provable from a still); glitch-fix confirmation.

## 8. Deferred until AFTER launch (owner decisions)

- **Native SwiftUI + WidgetKit app is LAST.** No Swift code exists.
  The store does not accept web apps, so this needs a Mac + Xcode +
  Apple Developer (~$99/yr via the friend's account) + a native build
  on the same backend. Never call an uncompiled project "App Store
  ready." Shortcut already told to the owner: other people can use
  the web version (link + Add to Home Screen) once the safety proofs
  are done — no store needed.
- **Google verification + domain purchase.** Verification only gates
  strangers connecting their Gmail; the owner's own Testing-mode
  connection works (weekly reconnect). Apple does not require Google
  verification — it needs a public privacy-policy URL, which the
  existing site can host. So: launch bank-only (hide Gmail connect
  in the native app until verified), add verified Gmail later.
  Domain guidance (Oct 31, 2026 price data): registration ~10 min;
  DNS minutes–hours; homepage/privacy/terms build ~1 hour once the
  domain exists; Google review = days to a few weeks (gmail.readonly
  is a sensitive scope). Renewal reality: .com cannot hit $5 (floor
  ~$10–11; wholesale alone ~$11.17); true ~$5 renewals exist only on
  other extensions (.top ~$4–7, .uk ~$5.30 at Cloudflare). Any TLD
  works for verification. Owner wants rock-bottom (~$5 renewal);
  domain purchase itself needs the owner (payment).
- **Paid foundations: Supabase Pro ($25/mo) + Plaid production
  billing — AFTER launch.** Workable because the scheduled jobs keep
  the Free project from idling into a pause, and the trial covers 10
  connections. Tripwires: idle pause, or connections approaching 10.
- **Name check: CROWDED, not clear, not blocked.** No App Store app
  literally named "OnBudget" found. But a San Diego company literally
  named OnBudget sold a personal budgeting tool (Finovate Spring
  2014 / Fall 2015; later renamed Engage Financial Technology).
  Nearby: "OpenBudget" (live app), "On a Budget" (removed),
  "On Budget!" (tiny Google Play app). **USPTO status NOT verified**
  (trademark search is interactive) — before investing in the name,
  run a direct clearance search at tmsearch.uspto.gov for ONBUDGET
  in financial-services classes and consider a trademark lawyer.

## 9. Hard boundaries (do not soften)

- All financial integrations read-only. Never change existing
  Gmail / Amex / Plaid / Apple / DNS or other live account settings
  without explicit approval for that specific change.
- Owner performs logins / consents / sensitive pastes. No passwords,
  tokens, or full card numbers in chat, source, logs, or screenshots.
- No paid plan / payment method without approval. Never promise fixed
  hours/days, instant bank sync, or perpetual free operation.
- Never silently "fix" an ambiguous financial rule — escalate it with
  a failing/pending test.
- A 👍 reaction from the owner means yes / approval in general.
- Testing is report-only by default for shared/demo surfaces; the
  assistant is the beta tester for this app — do not send the owner
  back to manual trial-and-error testing as the first resort.
- WhatsApp copy quirk: long-press copies a WHOLE message bubble, so
  copyable values go one per bubble or in one single combined block.

## 10. How to verify this handoff is current

- `git log` main tip and `git status` vs origin; live app serves
  live.js v8 / styles.css v9; `node --test test/*.test.mjs` passes.
- Supabase: 2 cron jobs active (hourly-plaid-sync, five-minute-
  gmail-poll); Users list = owner + spouse only; Auth URL config =
  live Site URL + reset.html/live.html redirects.
- Live app: owner + spouse household, bank connected, email
  connected, first email row stored, auto-sync scheduled.
- Verdict as of this rewrite: **safe for the owner household to keep
  using; NOT public-ready and NOT App Store ready** — the gating
  items are the native build (§8) and, for strangers' Gmail,
  verification (§8). The remaining §7 items are proofs and polish,
  not money-trust blockers.

## Addendum — Nov 2, evening (after the rewrite)

- **CSV import is a real bug, not just an unproven tap (P1-29 UI half).**
  Owner repro, Nov 2 evening, on his phone: file attaches (name shows),
  no preview renders, Confirm stays disabled. This is the same symptom
  automation hit earlier — the "automation limitation" conclusion was
  wrong; the UI path itself fails, at least on his phone. Checked:
  live.html IDs all match the JS (csvFile, csvPreview, csvConfirmBtn,
  csvMsg) — not a wiring typo. Strongest hypothesis: `file.text()`
  rejects on WhatsApp-originated files, and the change handler has no
  try/catch and no error UI, so it dies silently with zero message.
  Workarounds to try first: Save to Files, then pick from Files; or
  stale PWA cache (delete home-screen icon, re-add from Safari).
  Fix needed: try/catch around the read with a visible error, then
  root-cause the read failure. Parser itself is proven (3/3 rows).
- **FINAL vs v2 spec — follow FINAL (verified from both PDFs' text).**
  Exactly one substantive contradiction: refunds. V2 uses a carried
  refund-credit balance (R_in→R_out, covered_credit) offsetting future
  weeks; FINAL removes it entirely, replaced by refund restoration
  (re-simulate locked weeks, one entry in current week, incremental,
  never double, only after posting, temp-covered part restores
  nothing, over-charge held). Owner confirmed Nov 2 evening: the
  change makes sense (old model could double-benefit) and FINAL is
  what the live app runs. Plus one gap filled: v2 never mentions
  cashback; FINAL says Amex cash-back credits are NOT refunds,
  excluded by default, admin can classify. Everything else agrees
  ($375 Sun–Sat week, temp increments, debt, idempotent close).
  Quirk: the FINAL PDF still carries the v2 cover page (built by
  editing v2 in place) — filename + refund sections are what make
  it FINAL.

## Addendum — Nov 3, evening (full build R12 + R13, then audit)
- Branch full-build-2, tip 4e4ca78, pushed, NOT live, NOT merged.
  Live main is still d616a29. R12 + R13 code is built and tested
  (77/77: engine + gmail + dedupe + r12 + r13); their SQL files are
  PREPARED ONLY and need owner dashboard approval before the features
  work live. Nothing in this branch touches supabase/functions, ios/,
  or compute-week, so merging it redeploys no functions.
- R12 Add Money (owner rule: shortfall first): admin-only RPC
  add_fund_money, serialized on the household row, idempotent on a
  per-submit client key, one fund_topups row + one ledger row for
  the spendable part only + audit row; never touches week math or
  transactions; bank deposits never auto-credit. UI: Funds admin
  card with unchecked "already put this money in checking" box,
  live split preview, and a Money-added history list showing each
  split. Doc cases verified in tests.
- R13 Charity (owner basis: 10% of money received + manual entries,
  from Nov 1, 2026): new transactions kind 'charity' (compute-week
  counts only charge/fund_charge + refund, proven from
  chargeContribution, so gifts sit outside weekly spending with no
  server math change). Funds Charity summary + Home Charity card
  show Committed / Given / Remaining ("Ahead by $X" when negative).
  Income is recorded explicitly by the admin (default rate editable,
  per-income overrides replace, corrections append-only reversed +
  replacement, half-up per income). Manual gifts via Add > Give to
  charity post as verified gifts at once. Posted charges can be
  marked as gifts whole-row only (server guards: posted, unexcluded,
  no fund part, Nov 2026 onward, unlocked week). NOT built, by
  design, not by omission: part-gift splits, locked-week
  reclassification (refused with a message), and any auto-
  classification by name similarity. A gift entered by a member is
  not possible yet: gift entry is admin-only; a member's donation
  becomes a gift when the admin marks the posted charge.
- Still pending, unchanged: DB approvals in order A1 grants, dedupe
  tables/RPC, R3 nicknames, R12, R13, then the Amazon merge (needs
  dedupe SQL first + the merge-now vs wait-until-posts decision).
  Until those land, the new cards show their error states, never
  zeros; the old live app is unaffected.
- Post-build audit: AUDIT_2026-11-03_POST_BUILD_R12_R13.md. No money
  or security break found in R12/R13. Open from the earlier audit
  and still open: unicode glyph controls, sort-row shape mismatch,
  full-width money inputs outside the new forms, .btn-small not
  small in the live restyle, dedupe N+1 queries, savings recording
  still impossible (R11 hid the forms, no replacement), fund card
  stale on read failure, dead weekBreakdown panel. Also still
  open from the doc: R1 per-section loading/Error-Retry, R10
  date/week filters + Clear, R3 nickname ordering note.

## Addendum — Nov 3, evening (SQL applied + branch merged live)
- Owner authorized the full chain ("you could approve"): all six
  SQL files applied in order via the Supabase SQL editor and each
  verified with a read-only check — A1 grants, dedupe tables/RPC,
  R3 nicknames, R12 top-ups, R13 charity (kind check now includes
  'charity', all five RPCs), then the Amazon merge. Amazon Step 0
  showed exactly the two $10.59 rows; Step 3 confirms the Plaid
  AMAZON row counts and the email AMAZON MARKEPLACE NA PA row is
  excluded (kept as evidence, not deleted), with a merged candidate
  + alias + audit row recorded. The $10.59 double-count is fixed.
- PR #4 merged full-build-2 into main (8fa5eb2). Live verified by
  fresh fetch: live.js v22, styles v14, Add money / Give to charity
  / Charity income all served. Native ios-native-rebuild tip
  unchanged (971903a); no ios/ files and no workflow on main.
- Still open, not fixed by this round: the possible second $2
  double-count (bank TOIREMORG vs email TOIREMORG CHARITY) needs a
  human look — it predates lookalike detection, so it will not
  appear on the Possible duplicates card by itself; plus the audit
  carryovers (glyph buttons, sort-row shapes, full-width money
  inputs outside the new forms, .btn-small sizing, dedupe N+1,
  savings recording with no form, fund card staleness, dead
  weekBreakdown panel) and the doc leftovers (R1 per-section
  loading/Error-Retry, R10 date/week filters + Clear, part-gift
  splits, locked-week reclassification).

## Addendum — Nov 3, evening (external audit fix round)
- An independent live audit (Round 2, v22, by the owner's other
  agents) confirmed 7 bugs, 2 of them high. All are fixed on branch
  fix-audit-round2: (1) CSV import moved out of the sign-in handler
  to top level, so it works after a plain reload; (2) manual + gift
  submits disable first and guard on an in-flight flag, closing the
  double-tap race (the old code disabled only after the duplicate
  check's network call); (3) error toasts stay white on blue via a
  .toast.error override — the generic .error color was leaking red
  text into the toast, which this session's own audit missed;
  (4) the dated-vs-late breakdown now appears as lines in the
  Weekly Budget sheet (the hidden weekBreakdown panel had no
  control); (5) refund panels need a DB migration, not code — see
  supabase/restoration-columns-migration.sql; (6) sign-out clears
  the email/password fields; (7) the profile button hides until
  signed in. Plus this session's audit P1s: fund card clears its
  cached data on read failure; Transactions total excludes charity
  gifts except on the Charity filter; all glyph controls replaced
  (sync is an SVG icon, Back/Filters/sort are words); sort select
  matches its button; number inputs capped at 220px; .btn-small is
  actually small; dedupe loads all pairs in one query capped at 20;
  stale "SQL not applied" messages reworded; Savings form back,
  admin-only, in the same card; live-sw.js (network-first, shell
  only) replaces the demo-era sw.js, which must never be registered
  for the live app. NOT built here: server-side idempotency
  constraint for manual rows (needs a deliberate scope decision —
  identical real purchases are legitimate); hand-entered refunds
  (manual form stays positive-only by design); R1 per-section
  loading, R10 filters, fixed charity commitments (features, not
  bugs — owner decision).

## Addendum — Nov 3, evening (refund migration applied)
- supabase/restoration-columns-migration.sql applied live via the
  SQL editor and verified: all 7 expected columns now present
  (restoration_entries: debt_reduction_cents, fund_credit_cents,
  purchase_transaction_id, refund_transaction_id; held_refunds:
  purchase_transaction_id, refund_transaction_id,
  resolution_note), plus the unique-per-refund guards and both
  indexes, no errors, no unique_violation. The refund panels
  (restorations + held refunds) should now load, and week-close
  restoration writes are unblocked. Note: restorations that failed
  while the columns were missing were loud 500s, not silent
  losses, but whether a past locked-week refund still needs a
  re-run after this migration is an open week-close question.
