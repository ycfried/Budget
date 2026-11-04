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

## Addendum — Nov 3, evening (Round 3 fix round)
- The owner's updated audit copy (Rounds 1–3, all on v22) was
  reconciled against v23: bugs 1–7 in it are the ones PR #6
  already fixed; Round 3 added two new bugs. Bug 8 (gift
  double-submit, $25 recorded twice on a synthetic household):
  v23 already had the client lock; this round adds the server
  half — supabase/r13-gift-idempotency.sql gives
  record_charity_gift a p_client_key (default null, old calls
  unaffected) with a partial unique index on (household_id,
  client_key); replays return the original row with no second
  audit row, while fresh keys keep real identical gifts distinct.
  The client reuses its key only for an identical retry
  (merchant/amount/date/suffix match), like the top-up pattern.
  Bug 9 (non-last member deletion failed partway, membership
  gone, auth orphaned): root cause proven from source — eight
  history columns reference auth.users with no ON DELETE action
  (fund_requests x2, savings_ledger, audit_log, fund_ledger,
  temp_increases, fund_topups, charity_income), so any user with
  history blocks admin.deleteUser until the household cascades
  away. Fix is supabase/delete-account-fk-migration.sql (all
  eight re-pointed to ON DELETE SET NULL; the three NOT NULL
  columns relaxed — nothing reads them for display) plus a
  hardened delete-account function (household-cleanup errors no
  longer swallowed; membership restored on any later failure;
  failing step returned and shown). No real-household data was
  touched by any round (synthetic households only, since
  deleted). Still open: mark-as-charity end to end (needs a
  synced posted row — synthetic households have no bank link);
  a final pass on the confirmed-finished rollout; the TOIREMORG
  $2 pair review.
- Round 3 landed Nov 3, evening: both SQL files applied live via
  the dashboard and verified (gift idempotency: client_key column,
  partial unique index, 8-parameter function; FK migration: all 8
  references ON DELETE SET NULL), then PR #8 merged to main and
  live verified serving live.js v24. Read-only probe: NO unique
  constraint on (household_id, dedupe_hash) exists on live
  transactions — the deferred manual-row idempotency backstop
  still needs a deliberate scope decision. The delete-account
  function redeployed on the merge; its deploy status and a
  bug-9 end-to-end retest on a new synthetic household remain
  unproven.
- Delta package Nov 3, evening (PR #10 merged to main, live
  verified serving live.js v25 / styles v16; branch delta-package
  was 42f28f9, owner-approved History + Funds gates):
  A1 whole manual Savings section removed from everyday Funds
  screens (card, figures, form, write handlers); records untouched
  in the database, reachable read-only via a "Past savings records"
  link at the bottom of Funds. A2 arrows restored on the sort
  control (Date ↓ Newest / ↑ Oldest, Amount ↓ Largest / ↑ Smallest)
  and on Back buttons (← Back); SVG sync icon kept. B1 History
  moved to a Home button, off the bottom tab bar (Home /
  Transactions / Funds); weekly summaries + day-grouped Activity
  kept, date filter with visible Clear + stated active period,
  honest full-set counts, Load more for activity. B2 Transactions:
  chip row removed; search + one Filters button; filters in a
  bottom sheet (status, dates incl. This week + from/to, Card /
  Account, min/max, sorting, Apply/Reset/Cancel); applied filters
  as individually removable labels; Add button top right of the
  Transactions heading. B3 sync guard: repeat taps ignored while a
  sync runs, buttons disabled, Home icon spins. C1 buttons
  center content (inline-flex); C2 tertiary treatment #eef4ff /
  #2f6bff on 3rd+ adjacent buttons. C3 Funds: two balance cards
  on top (Available / Remaining prominent, pending-or-owed and
  committed-or-given as one secondary line each), actions as
  buttons opening one form at a time, activity behind per-fund
  disclosures, refund + duplicate review in one collapsed
  Review area hidden from members. Manual refunds deliberately
  NOT built (owner decision Nov 3: manual form stays
  purchases-only). Tests 89/89 (6 new delta helpers). Still to
  prove live (doc section D): the full checklist on a real phone
  at 320/390/desktop, incl. sheet behavior, sync progress, and
  member-vs-admin Review visibility. Live-fetch proof at merge:
  v25/v16 served, "View history" + "Past savings records" present,
  3 bottom tabs.
- UX audit fixes Nov 3, evening (PR #12 merged to main, live
  verified serving live.js v26 / styles v17; branch ux-audit-fixes
  was 2ffb1dc):
  live.js v26 / styles v17; reconciled against v25, NOT a rebuild
  of the delta): 02 Weekly Budget sheet now shows the reconciliation
  (base room = allowance - carried debt floored at 0; Left = room +
  temp - spent; outgoing = unabsorbed debt + new debt) — and the
  client outgoing derivation was corrected to the engine formula
  (it had added the full incoming debt; engine fixture D 42500 /
  B 37500 / C 0 -> outgoing 5000, not 42500; server math untouched).
  03 Transactions count line now reads "total of the rows shown".
  07 members read "Available to request" on the Home fund card, the
  Funds Extra Fund card, and the fund sheet (admin wording
  unchanged); Ask for fund money sits beside the Extra Fund balance
  as well as in the actions card, for all roles. 06 manual form has
  an explicit Cancel (closes + clears the draft); Back keeps the
  draft, and the hint says so; purchases-only, no refund option
  (owner decision Nov 3). 10 Settings intro is role-aware (members
  never promised a Budget section); auto-sync, email connect/check,
  and invite-share buttons hide for members, bank status lines stay
  visible, and the email card is now visible to members read-only
  (email_connections_public is member-readable by RLS; Disconnect
  stays admin-only; server authorization untouched). 09 activity
  groups repeated "Weeks processed" rows per day into one line with
  a count (user actions never collapse) and maps week(s)/canonical
  wording to household language, display-only. 11 thousands
  separators in formatCents + formatCentsHtml; one Title Case status
  mapping (stateWord now matches statePill). 05 transaction rows
  carry merchant + amount + date + status in the accessible name
  plus a CSS chevron that rotates on open, with Enter/Space support.
  01 savings-transfer VERDICT (see below): no code change.
  Owner screenshots folded in: week history redesigned as blocks
  (heading + labeled metric rows, "not recorded" kept honest);
  profile menu restyled (email + role pill, menu rows, red Sign
  out, viewport-capped width, same ids/handlers); History From/To
  date fields stack at 520px and below, and all other side-by-side
  rows were checked (btn-row wraps, fund/sav grids stack, search
  input shrinks). Tests 98/98 (89 before + 9 new ux-audit-fixes
  tests). Still to prove live: the full checklist on a real phone
  at 320/390/desktop, incl. the stacked date fields, profile menu,
  week blocks, grouped activity, member Settings view, and the
  member "Available to request" wording. Live-fetch proof at merge:
  v26/v17 served, "Available to request" + "total of the rows shown"
  + week-block + manual Cancel markers present. Review also added
  one label fix on top of the branch: payment/cashback detail lines
  now state the kind exclusion instead of the generic "counts toward
  its week" text.

## DELTA3 ADDENDUM (branch delta3, NOT merged — parent reviews and ships)
Live at branch point: v26/v17 (PR #12). Delta3 bumps live.js to v27
and styles.css to v18. NO SQL applied to production, NO rows written
to the owner household, NO live-app loads on the owner household
(code analysis only for real-household questions). No week-close
math, allowance, or authorization change. Manual refunds still NOT
built (owner decision Nov 3 stands). History relocation stays.
  1. TRANSFER KIND (owner: "the transfer issue needs to be
  resolved"). New kind 'transfer': TRANSFER_PATTERN
  (/INTERNAL TRANSFER/i) checked FIRST in classifyKind in all four
  canonical.ts copies (_shared, plaid-sync, ingest-amex-alert,
  gmail-poll — verified byte-identical after the edit), so it
  applies to both classifyKind and classifyMerchantOnly; TxKind
  union extended in all four. engine.mjs isExcludedFromMath excludes
  transfer in all four copies (root, _shared, compute-week,
  week-close), so it contributes 0 to charges, refunds, and
  restoration, either direction. reclassify_transaction RPC now
  allows 'transfer' (supabase/05-transaction-mutation-rpcs.sql),
  and the client reclassify sheet offers Transfer — this is the
  path for NON-internal transfers (to another person), which stay
  charge/refund on ingest by design. Detail label + impact line:
  "This is a transfer between your accounts. It does not count
  toward weekly spending." CSV import uses the same rule
  (classifyCsvKind in filterState.mjs: transfer first, else sign).
  PREPARED ONLY, NOT APPLIED: supabase/transfer-kind.sql (CHECK
  constraint drop/re-add following payment-kind.sql, adding
  'transfer' to the full list) and supabase/transfer-backfill.sql
  (Part A read-only impact queries — rows by kind, by week,
  locked-vs-open via week_closes, current-open-week delta,
  restoration/held linkage — then Part B, the idempotent update
  of merchant ILIKE '%INTERNAL TRANSFER%' charge/refund rows to
  'transfer'). Live backfill is HELD for owner approval on the
  measured Part A numbers. Locked weeks keep closed figures (the
  locked-week guard); open weeks recompute on the next run. If
  Part A query 5 returns linked restoration/held rows, STOP and
  decide with the owner — the backfill never edits those links.
  2. WEEK-CLOSE LOGGING + FIGURE CHECK. Server
  (supabase/functions/week-close/index.ts) writes the "Weeks
  processed" audit row ONLY when something actually happened
  (weeksClosed > 0, releasesDone > 0, restorations > 0, or
  heldCreated > 0); no-op runs return the summary silently.
  heldLegacy deliberately excluded (counted, never changed).
  Client (live.js refresh()): the close call moved to AFTER
  compute-week loads, gated by a due-check (filterState.mjs
  isWeekCloseCheckDue) against a localStorage fingerprint
  (ob-weekclose-<household_id>) holding the last checked week
  start — same week as the last check skips the call; a week
  boundary since the check calls; unknown due-ness (compute-week
  failed) falls back to calling, because the server no-op is
  silent. The close path itself is NOT removed (admin loads are
  what close weeks; no scheduled week-close). When a call actually
  closed a week, figures reload once. Release inserts harden
  against concurrent runs: a 23505 unique violation on
  (household_id, week_start) is swallowed (the other run already
  created that release); other errors still retry once without
  closed_at, then fail loudly. IDEMPOTENCY (why repeats do not
  move closed figures): locked + already-closed weeks are skipped
  outright (walk loop, chain from recorded values); open-week
  recomputes are deterministic upserts on (household_id,
  week_start) with the late-adjustment freeze (unposted =
  max(0, lockedAlreadyClosed - alreadyPosted), absorbed once);
  releases are claimed by conditional status updates (pending ->
  released; surplus-delta claim on status + old value);
  restorations are guarded by the in-memory existingEntryByRefund
  set plus the unique-per-refund constraint. New transactions
  arriving between runs legitimately change open weeks — that is
  new data, not run instability. Tests: shouldLogWeekClose /
  isWeekCloseCheckDue / classifyCsvKind / transfer exclusion in
  test/delta3.test.mjs.
  3. LOADING SCREEN. view-loading is the HTML default (brand-blue
  spinner, "OnBudget", "Loading your budget…"), so a signed-in
  reload never flashes the sign-in form; boot() replaces it
  directly with auth, household, or app. Signed-out visits go
  loading -> sign-in, no app-shell flash. Figures keep "…"
  placeholders while unresolved (never $0.00 or empty-state text
  before the request finishes); refresh keeps the last successful
  value while new figures load. Auth-flow buttons now show
  progress + block repeats like the sync button (sign-in
  "Signing in…", sign-up "Creating account…", create "Creating…",
  join "Joining…", each restored after; sign-in/sign-up route
  through the loading screen on success).
  4. UI CLEANUP BATCH. (a) Add subtitle sits on the same line as
  the "Add" header (inline header row); no other card has a
  single short subtitle line left after declutter, so no other
  card changed. (b) DECLUTTER — removed sentences (pure
  describers only): Transactions "Everything spent on the
  household cards. Tap a transaction for detail and actions.";
  CSV "Never enter a full card number — the file should contain
  card endings only."; History link "Closed weeks and a shared
  record of every change in this household, grouped by day.";
  Funds actions "Money moves open one at a time, so the page
  stays short."; Extra Fund "Leftover money from weeks you spent
  under budget — use it for extras."; Charity "November 2026
  onward. Committed is 10% of income recorded here (or the rate
  set for that income); given is confirmed gifts only. A negative
  remaining means you are ahead." (the ahead-meaning survives in
  the figure itself, which renders "Ahead by $X" when negative).
  CSV expected-columns paragraph shortened to the columns list
  plus one short line: "Preview first — nothing is added until
  you confirm." (dropped clauses: "Nothing is added until you
  review the preview and tap Confirm. Duplicates are skipped.
  Imports are provisional until the bank confirms them." — the
  preview itself shows new/duplicate counts). Settings intro
  admin version trimmed of the stale "…moved here from Funds."
  clause. KEPT + flagged (carry real rules/state, not bloat):
  manual-form "Never enter a full card number.", gift-form
  "Leave the card suffix blank for a cash gift. Never enter a
  full card number.", filter-sheet amount explainer (refund
  counts as a negative amount), History sections intro (carries
  the date-filter instruction), fund/charity/review form
  explainers (rules, not describers). (c) Pills squarish: .pill,
  .role-pill, .badge, .tx-chip, .tx-active-filter 999px -> 8px
  (colors unchanged; hero progress bar keeps 999px — not a
  label). (d) Third-button coloring: Add choices verified as
  primary (Add by hand) / secondary (Import CSV) / tertiary
  (Give to charity); .btn-tertiary now has a 1px brand-blue
  border (#eef4ff / #2f6bff unchanged; border-box sizing means
  no size shift). Same tertiary border applies to every 3-level
  row (Funds actions, filter sheet Cancel). (e) Transaction
  detail: labeled metric rows (Date / Week / Card / Source /
  Status) + one kind-specific impact line; button order Exclude,
  Mark as charity, Use Extra Fund, Reclassify, Remove LAST
  (Exclude/Reclassify secondary, charity/fund tertiary, Remove
  destructive red; excluded rows: Restore, Reclassify, Remove;
  the destructive button keeps its honest per-source label —
  "Delete" for hand-entered rows, "Remove" for bank/email/file
  rows). Buttons wrap via .btn-row flex. (f) CSV: styled file
  control (label-as-button + file-name text; native input
  visually hidden but accessible, same id/handler). (g) Charity
  in regular filters: status control already first in the sheet;
  options now in plain words in this order — All transactions,
  Charity gifts, Pending, Posted, Refunds, Excluded. Filter logic
  verified in code: byFilter maps 'charity' to kind === 'charity'
  and the count line totals gifts on the Charity filter (excluded
  rows not counted); the removable label stays "Charity".
  (h) Home dashboard: Weekly/Charity/Fund breakdown sheets now
  use labeled metric rows (showSheet rows param); the weekly
  reconciliation equation stays below the rows, unchanged;
  Weekly Home card secondary now reads "Spent $X of $Y room"
  (same room figure as the hero). Presentation only; no figure
  changes anywhere in item 4.
  4b. FUNDS BALANCE PARITY (added owner screenshot, Nov 3
  evening): both panels now share the identical template —
  title, prominent figure, secondary lines — with no explainer
  paragraphs and no button rows, so Available and Remaining sit
  at the same height; grid stretch + flex-column panels keep
  equal height; secondary lines wrap inside the panel
  (overflow-wrap: anywhere on panel muted lines). Button parity
  by REMOVAL: the Extra-only beside "Ask for fund money" button
  (fundAskBesideBtn + handler) is gone — Ask already lives in
  Funds actions below (fundActionAskBtn, all roles). This
  SUPERSEDES the v26 HANDOFF line claiming Ask "sits beside the
  Extra Fund balance as well as in the actions card". Figures and
  values unchanged; side-by-side above 420px, stacked below
  (breakpoint unchanged). Still to prove live: the parity at
  320/390/desktop widths with real figures.
  Tests 110/110 (98 before + 12 new delta3 tests). Still to prove
  live on a real phone (synthetic households only for writes):
  loading screen on signed-in reload / signed-out visit / slow
  connection; 3 admin loads -> no new "Weeks processed" rows +
  figures unchanged; closing a synthetic week -> exactly one
  activity row with the correct summary; CSV import incl. an
  INTERNAL TRANSFER row -> kind 'transfer', excluded from week
  math; double-tap guards; delete-member end-to-end (bug 9);
  mark-as-charity on a synced posted row; Funds parity at
  320/390/desktop; transfer backfill Part A numbers on the real
  household (read-only) before any Part B decision. Deliberately
  NOT in delta3: the duplicate-Plaid-item guard (owner queued it
  post-delta3: reconnecting must not silently create a second
  item for the same bank account) and the new-browser admin
  sign-in report (cause not diagnosed; exact message/screen
  still needed — delta3 touches sign-in progress display only,
  not auth logic).

  BUTTON-CARD FIX (branch button-card-fix, built Nov 3 evening, NOT
  merged, NOT live): owner rule — nowhere may two adjacent buttons
  share a treatment — plus Funds card tap work, three-blues palette,
  and reference typography. Live.js v28 / styles v19 on the branch
  (live still serves v27/v18 until this is merged).
  1. BUTTON COLORS — root cause VERIFIED in code, not just assumed:
  styles.css `body.live .btn-tertiary` (no id) lost to
  `body.live #view-app .btn` (id specificity) for background/border/
  color, so tertiary rendered as grey secondary with dark text and
  the v27 border fix never showed. Fix: tertiary selector now
  includes #view-app like primary. THREE BLUES (owner reference
  screenshot, Nov 3 evening — strong bright blue, pale light blue,
  very pale tint; no grey fill for a button level in a row):
  primary = #2f6bff fill, white text; secondary (base .btn) =
  #bfdbfe fill, #1e40af dark-blue text (readable at phone size,
  distinct from both neighbours); tertiary = #eef4ff tint fill,
  #2f6bff text + border. A fourth blue-bordered treatment, outline
  (white fill, #2f6bff text + border, never grey), is used ONLY
  where a row has four buttons, so no adjacent duplicate occurs.
  Sort select, legacy chips, and the profile button were moved off
  grey to the same family (sort/chips = secondary light blue;
  profile button = tint with blue border, single button, not a row).
  Grey remains only where it is NOT a button level (progress track,
  logo tiles, status pill, menu-row active state). Bank buttons
  fixed to stay primary (Connect) / secondary (Sync) / tertiary in
  every state: the old code stripped primary from Connect and
  toggled it onto Sync when active, leaving Connect + Sync as
  adjacent secondaries with no active item.
  Button-row audit (treatment sequence, DOM order, neighbours all
  differ; P=primary, S=secondary light blue, T=tertiary tint,
  O=outline, D=danger, Q=quiet text-only):
  Auth: Sign in P, Create account S, Forgot password? Q.
  Household: Create household P, Join S.
  App nav tabs: intentional EXCEPTION — tabs share a base treatment
  except the active tab (blue); different colours per tab would
  break tab semantics. Home stat cards: same reasoning (tap cards
  in a grid, uniform by design, different kickers/figures).
  Add choices: Add by hand P, Import CSV S, Give to charity T.
  Manual form: Add transaction P, Cancel S. CSV Confirm P alone;
  Back S alone in its row. Charity gift Record gift P alone.
  Transactions head/search rows: Add P vs Filters S (different
  rows, differ anyway). Filter sheet: Apply P, Reset S, Cancel T.
  Sort row: select S + direction button S — matched pair, one
  control, not two buttons. Load more S alone. Settings Back S alone.
  Bank connection: Connect P, Sync S, Enable/tertiary control T in
  every state (see fix above). Email: Connect email P, Check email S.
  Settings Budget: Save allowance P alone, Add temporary increase S
  alone (different sections). Settings Account: Share invite code S,
  Change password T (was S/S duplicate, fixed). Settings Delete: D alone.
  Funds actions: Add money P, Use fund money S, Ask for fund money
  T, Record income O (was P/S/T/T duplicate Ask/Record, fixed).
  Fund forms: Save top-up P alone, Save default rate S alone,
  Save income P + Cancel correction S (when visible), Record it S
  alone, Send request P alone. History filter: Apply filter P, Clear
  S. Past savings toggle: Q alone. Sheet overlay: Cancel S, Confirm P.
  Transaction detail, admin, non-excluded: Exclude S, Mark as
  charity T, Use Extra Fund O, Reclassify S (separated from Exclude
  by T+O, so not adjacent), Remove D last. Admin, excluded: Restore
  P, Reclassify S, Remove D (was S/S duplicate Restore/Reclassify,
  fixed). Charity row: Remove D alone. Member rows: Use Extra Fund S
  alone. Fund requests: Approve P, Decline Q. Bank list: nickname S
  alone per account, Disconnect D alone per item. Email list:
  Disconnect D alone. Charity income list: Correct S alone. Held
  refunds: Release P alone. Duplicate review: Same purchase P,
  Separate S.
  2. FUNDS BALANCE CARDS — face is now Title + Amount only (big
  32px bold figure, amount alone; negative charity remaining still
  reads "Ahead by $X" as the figure). ALL secondary lines moved off
  the face to the tap sheet, no information lost: Extra Fund —
  Spendable/Available wording (member "Available to request" vs
  admin "Spendable now" lives in the sheet), Pending, Owed back,
  Released total, Spent, Held for review (added to the fund sheet,
  which was missing it; shown only when heldWeeks > 0); Charity —
  Remaining, Committed, Given, Default rate, Period (added to the
  charity sheet, which was missing it, "November 2026 onward").
  Both sheets are the single source shared with the Home stat-card
  sheets (fundBreakdownRows / charityBreakdownRows). Cards look
  tappable: blue chevron in the head row, whole card a tap target
  (role="button", tabindex="0", aria-label "Show Extra Fund/Charity
  breakdown", click + Enter/Space), opening that breakdown sheet.
  Identical template (title, amount, chevron), equal height,
  side-by-side above 420px, stacked below, no overflow. Figures and
  values unchanged; presentation and tap affordance only.
  3. TYPOGRAPHY (owner reference screenshot, Nov 3 evening) —
  clean modern system sans throughout the LIVE app only (demo
  untouched): stack -apple-system, BlinkMacSystemFont, "Segoe UI",
  "Helvetica Neue", Helvetica, Arial, sans-serif. No paid/licensed
  font, no web-font download, and NO exact font name claimed from
  the screenshot (on iPhone this renders as the system sans).
  Hierarchy as on the reference: headings 800 (was 600), large bold
  figures (hero 42px/800, stat numbers 26px/800, fund face 32px/800),
  smaller grey secondary labels (kicker 12px #6b7280, muted small
  13px #6b7280). Applied in body.live, so Home, Transactions, Funds,
  and sheets all share it — no page keeps the old weight.
  4. BUG CAUGHT BY THIS PACKAGE'S OWN CHECKS: a stray `],` left in
  the Charity Home-card sheet call would have broken live.js at
  parse time; removed, and `node --check` is clean on all changed JS.
  Tests 119/119 (110 before + 9 new static tests in
  test/button-card-fix.test.mjs: three-blues rules, Funds actions /
  detail / Settings sequences, panel tap attributes + sheet
  completeness, face Title + Amount, typography). HTML ids: 168,
  no duplicates (unchanged from delta3; no new ids added).
  JS-referenced ids not in HTML are pre-existing and safe:
  sheetOverlay/sheetInput are created dynamically by showSheet,
  refreshBtn is a guarded legacy reference (if (rb)) on main.
  Member-vs-admin visibility unchanged (presentation/tap only);
  no money/week/kind/allowance/authorization change; no SQL; no
  live-household writes; live app never loaded signed in as owner.
  Still to prove live on a real phone after merge: button rows at
  320/390/desktop (neighbours visibly different in daylight, esp.
  light blue vs tint), Funds card tap (chevron, Enter/Space, sheet
  completeness), fund face at 32px with long amounts, headings at
  800 across Home/Transactions/Funds/sheets.

## Addendum — ux-review-fix (Nov 3, 2026, evening; UNMERGED branch, NOT live)

Branch `ux-review-fix`, from origin/main 86557cf (PR #15, live.js v28 /
styles v19). This package is live.js v29 / styles v20 in live.html.
Owner approved the package by 👍 to the triage message; every owner
update below was folded into the same branch before finishing. HARD
STOPS HONOURED: no merge, no PR, no SQL applied to production, no
writes to the owner's real household, the live app was never loaded
signed in as the owner, no ios/ or workflow files, no secrets or
real-household UUIDs in the diff, no money/week/allowance/
authorization changes, no figure changes — only displayed labels,
states, layout, and action gating where the review explicitly
corrects them.

### Fixed in this package

P1 — transfer gating: Use Extra Fund is offered only when
`qualifiesForFund = t.kind === 'charge'` (admin detail row, member
detail row, plus a defensive handler gate that shows "Does not
qualify" and returns). Mark as charity was already gated to charges.
Reclassify stays on every row (it corrects misclassification).
Payment and cashback rows: same gating applies — they are not
charges, so they no longer offer Use Extra Fund either. SERVER
FINDING (report, not changed): `supabase/02-rls-hardening.sql`
`validate_fund_request_txn()` + trigger only check the linked
transaction belongs to the household and the request is pending; it
does NOT check kind. Client gating is currently the only kind check;
a server-side kind guard needs a SQL change and is deferred.
P1 — charity Home card: success path now sets the signed number
(`formatCents(remaining)` — a confirmed $0.00, never "—"). The dash
remains only for loading and for failed loads. Period/rate stay in
the detail sheet.
P1 — weekly kicker: hero kicker is now "This week · <weekLabel>"
(neutral; the weekLabel itself is the date range), and the sentence
"If the big number is negative, you're over this week's budget." was
removed from the hero paragraph.
P2 — held money: new `#fundHeldLinkWrap` / `#fundHeldLinkBtn` under
the Funds balance cards, hidden unless a held week exists, reading
e.g. "Held for review: $X across N weeks — Open Review queue".
Tapping opens Funds, expands the Review section, and scrolls to it.
The Fund breakdown sheet Held row ends with "— open the Review queue
under the Funds cards". Held/restoration logic untouched.
P2 — bank connections: accounts were already grouped under each
connection. Added "Connected <date>" per block and Disconnect
identification by masked accounts in the button aria-label and the
confirmation ("Disconnect American Express (••1005, ••1636)? The app
will stop syncing this connection only. Past transactions stay in
the list, and other connections are untouched."). Disconnect server
behaviour unchanged.
P3 — sign-in: Sign in primary, Create account secondary-pale and
stacked with a "New to OnBudget?" line above it; password visibility
toggle added (see Show password); failure message now ends with
"If you forgot the password, use Forgot password? below to reset it."
(generic, privacy-safe, direct recovery action). Pending/retry
states already present, kept.
P3 — forgot/reset: forgot sheet now gives the clear sequence (enter
email, check inbox, choose password, return to sign-in, fresh link
if expired). reset.html now has step-3 sequence copy and password
requirements beside the field before submission. Change-password
sheet message now includes "Password requirement: at least 8
characters."
P3 — profile menu: household line in plain language (admin /
member wording), Settings and Sign out rows, menu closes on
destination open, outside-click resets aria-expanded, Escape closes
the menu and returns focus to the profile button. Focus return on
destination-open is not separately implemented (the destination
takes focus).
P3 — history: location kept (View history on Home, same for both
roles; no History tab by design). Settings Back returns to
`previousView`. Scroll-position/filters restore on return from a
detail view is NOT implemented as new state machinery — transaction
detail is inline (expand/collapse in place), so there is no return
navigation to restore; tab switches intentionally scroll to top via
showView. Reported as a limitation, not claimed.
P3 — transactions: entry is one Add action with three choices (Add
by hand / Import CSV / Give to charity) plus the Transactions-header
Add button, which opens the same choice card (not a duplicate
form). Recent items on Home now jump to Transactions AND expand
that row's detail (`data-recent-tx`, `openRecent`, awaits refresh
if stale, then unhides the detail, adds .open, scrolls into view;
keyboard Enter/Space works). Detail is the way back (tap the row
header to collapse). Count line now ends with "· search covers
loaded rows only" (in addition to "total of the rows shown" and
Load-more guidance).
P3 — filter sheet keyboard: Escape closes it (like Cancel,
preserving applied filters via the existing snapshot restore),
Enter on Cancel closes it without submitting (Cancel is a plain
button, never a submit — verified), focus moves inside on open,
Tab stays inside (new keydown trap), Cancel preserves applied
filters (existing snapshot restore, verified), focus returns to the
Filters button on Escape close. Scope is the filter sheet ONLY.
P3 — transaction detail: reordered to What it is / What week /
Whether it counts first (title, impact paragraph, then Week, Date,
Status, Card, Source rows; source metadata below). Email-alert rows
get a provisional/confirmed line.
P3 — manual entry: form boundary already exists (choice card vs
form, one form at a time); Back keeps draft, Cancel clears
(existing rule, verified, plus Cancel now also hides the new inline
error). Field errors now sit beside the form
(`#manualFormError`, role=alert, above the buttons): amount failure
→ "Amount: enter a positive amount." + focus amount; suffix failure
→ "Card suffix: enter exactly 4 digits. Never enter a full card
number." + focus suffix. Duplicate warning stays a dialog (it is a
decision, not a field error). Gift-form field errors remain dialogs
— deferred, same pattern, not yet done.
P3 — CSV import: preview rows now numbered; sample row added to
the card; preview copy now says it numbers each row, flags
duplicates, and shows any row it could not read. Sequence
(choose → preview → confirm → receipt toast) already existed.
P3 — charity entry/reclassification: Record a gift (form) vs Mark
as charity (row button) already separate; mark-as-charity
confirmation already previews the effect and warns part-gifts are
not supported. No change beyond fund gating and detail wording.
P3 — Exclude/Restore/Remove/Delete/Reclassify: distinct labels and
placement already existed (Restore primary first on excluded rows,
Reclassify secondary, Delete for hand-entered / Remove for
bank/email/file last and destructive red; Exclude/Remove sheets
state the record stays and stops counting, with a required reason;
Delete confirmation shows merchant + amount + "cannot be undone").
No change except fund gating.
P3 — funds forms and request detail: Add money preview (split,
owed-back first) and success toast already existed; Use fund money
card now has an intro (spending from the Extra Fund itself — lowers
the fund balance, never allowance or debt); Ask card now says
requests can be tracked in the Fund requests list. Request detail
now shows Requested, Fund available now, Approved (requested −
remainder for splits, in full for approvals), remainder + "needs a
new request", Note, Requested date, and a pending tracking
sentence. Success states already say what changed.
P3 — charity income and rate: preview now says whether the rate is
this-entry-only or the default applied to this entry. Rate-form
success toast already says "for future incomes." Income save toast
already states the commit amount and, for corrections, that the old
entry stays marked reversed.
P3 — history/settings: week blocks already have date headings and
consistent Carry-in / Surplus / Debt carried out / Release labels,
with "not recorded" never $0. History period line already near
results; Clear button relabeled "Clear date filter". Email card
already separates status, last checked, and last error, and its
intro already says alert-derived transactions stay provisional
until the bank confirms them. Allowance change sheet now previews
old → new PLUS effective scope ("This applies from the current
week onward (week of …). It does not rewrite closed weeks.");
temp-increase toast now says "Temporary increase added for this
week only (week of …)." Member Settings intro already role-aware;
Settings Account card intro now adds "Only the admin can share the
invite code; members who need an admin-only change should ask the
admin." Invite copy success state already existed. Password
requirements beside fields: change-password sheet + reset page.
Deletion already in a visually separate danger area with two-step
confirmation stating it removes only the member or, if last
member, the entire household, and "cannot be undone."
P3 — past savings: "attestation" wording removed from user-facing
copy. `savingsSummary` now renders: no rows → one plain message
("No past savings records yet — these old records are separate
from the Extra Fund, which is the savings story now."); rows but
no recorded balance → "Past savings records exist, but no balance
was ever recorded for them — that is a missing balance, not $0."
The `savingsList` empty branch now renders empty — ONE empty
message only, in the summary. No SQL change; savings_ledger rows
untouched.
P3 — visual polish: consistent headings/cards/dividers/chevrons/
badges already existed; button treatments are the four solid blues
below; tabular figures / currency grouping already existed;
zero/missing/pending/over-budget labels already distinct. No new
colors outside the existing palette.

ITEM A — blank app shell (owner, Nov 3, 7:48 PM, live v28): root
cause verified in code — `#view-app > .card { display: none; }`
until showView runs, and showView only ran late inside refresh()
after the transactions/fund/charity/bank/email reads. Fix: boot()
now calls showView(currentView) immediately after show('app'),
BEFORE refresh(), so cards with their existing "Loading…"
placeholders appear instantly; the loading screen is kept until
that point, never a blank shell. refresh()'s finally block now
also re-runs showView(currentView) (guarded, household present),
so a single failed read cannot blank the page — a failed section
shows its own inline error + the placeholders, not a hidden page.
No refresh data logic, week math, or sync behaviour changed.
STILL DEPENDS ON NETWORK SPEED: placeholders are instant, figures
are not. Create/join handlers were NOT changed (boot is the
reported fix).

ITEM B — possible duplicates list (owner, Nov 3, 7:49 PM): each
pair is now a vertical comparison card (`.dedupe-card`), NOT a
horizontal bank-row. Structure: merchant on its own bold line
(full name, `overflow-wrap: break-word`, `word-break: normal`,
never mid-word truncation, no "·" paragraph), then labeled rows
Amount / Date / Card / Source / Counts (like transaction detail
rows), Keep and Possible duplicate stacked on phone and
side-by-side only at ≥640px (`.dedupe-pair` grid), a one-line
match summary on top when fields match (e.g. "Match: same amount,
same date, same card.", otherwise "Compare the two records
below."), Same purchase / Separate in a button row BELOW the
comparison (primary vs secondary, no adjacent duplicates, as
before), and the "Remember as same merchant" checkbox BELOW the
buttons with a plain explanation ("remembers these two merchant
names as the same for future review, so similar pairs are treated
as the same merchant next time."). No duplicate resolution logic,
RPCs, or flagging changed — presentation only.

BUTTON COLORS (owner, Nov 3, 7:50 PM, live v28): the two circled
styles are replaced APP-WIDE, not just Funds actions. Tertiary
tint #eef4ff and outline white/blue are gone as button levels.
New treatments, drawn from the existing brand palette, no new
colours: primary #2f6bff fill (kept, looks good), secondary pale
#bfdbfe fill / #1e40af text (kept, looks good), tertiary = solid
deep #1d4ed8 fill, white text, fourth treatment = solid mid
#3b82f6 fill, white text, class renamed `btn-outline` →
`btn-mid` (old name survives only in CSS comments explaining the
rename). Assignment is SWAPPED from the first draft on purpose:
mid #3b82f6 sits only one step lighter than primary #2f6bff and
would blur against it, so tertiary (the widely used third level)
takes deep #1d4ed8, which is unmistakably darker than primary,
and the fourth treatment takes mid. The fourth treatment never
sits next to primary in any row. Tertiary selector still includes
#view-app (the v27 border fix's root cause — the unscoped selector
lost to `#view-app .btn` — stays fixed). No grey, pale tint, or
white outline remains as a button level. Button-row audit (DOM
order, all neighbours differ): Funds actions Add primary / Use
secondary-pale / Ask tertiary-deep / Record btn-mid; Add choices
Add primary / Import secondary-pale / Give tertiary-deep;
transaction detail admin (charge) Exclude secondary-pale / Mark
tertiary-deep / Use fund btn-mid / Reclassify secondary-pale
(separated from Exclude by two buttons) / Remove danger;
transaction detail excluded Restore primary / Reclassify
secondary-pale / Remove danger; filter sheet Apply primary /
Reset secondary-pale / Cancel tertiary-deep; Settings bank row
Connect primary / Sync secondary-pale / Enable automatic sync
tertiary-deep; Settings account row Share secondary-pale / Change
password tertiary-deep; dedupe cards Same primary / Separate
secondary-pale; held link button single, no row adjacency;
profile card buttons stacked vertically, primary / secondary-pale
/ tertiary-deep in order; sheet password toggle alone beside its
input; reset toggles alone beside their inputs; auth toggle alone
beside the sign-in password field.

ITEM C — Funds card chevrons (owner, Nov 3, 7:51 PM): chevron spans
moved out of `.fund-balance-head` (head is now just the `<h2>`)
to the bottom of each panel, after the summary div:
`<span class="fund-balance-chevron" aria-hidden="true">⌄</span>`.
CSS: `align-self: flex-end; margin-top: auto; padding-top: 8px;`
(panel is a flex column, so margin-top:auto pushes it to the
bottom), colour #2f6bff, weight 700, size 22px. Tap behaviour
unchanged (whole panel is the tap target, same size and aria-label
"Show Extra Fund breakdown" / "Show Charity breakdown"). Home stat
cards have NO chevron pattern (kicker + num only) — left alone,
as instructed.

ITEM D — too much bold (owner, Nov 3, 7:51 PM): audit was under
`body.live` only (demo/global styles at the top of styles.css
untouched). Weight map applied (sizes, colours, layout unchanged,
except weight): figures (hero `.big`, stat `.num`, fund
`.fund-balance`) 800, kept — the dominant element of their card;
headings (h1/h2/h3, topbar strong) 800 → 700; buttons (base
`.btn`), nav labels, chips, sort select, filter labels, sheet
subheads, disclosure summaries, menu rows, role pill 700 → 600;
detail/sheet/week/dedupe values, merchant names, row amounts, bank
names 700/800 → 600 (plus new overrides `.tx-line1.tx-name`,
`.tx-line1.tx-amount`, `.bank-info strong` at 600); icon/letter
tiles 800 → 700; fund chevron 800 → 700; body text, labels (already
600), secondary lines, kickers (600, 12px grey) unchanged. After
the pass, the only `font-weight: 800` rules under `body.live` are
the three figure rules — verified by grep. Residual: `<strong>`
elements rendered by live.js templates still render at the browser
default (~700) unless a specific override exists; the pass did not
chase every `<strong>`.

WEEKLY SHEET paragraph (owner, Nov 3, 7:52 PM): put BEHIND A TAP,
not removed outright — because Base spending room is not itself a
labeled row above (Allowance, Carried debt, Temp, Spent, Left,
Outgoing are rows, but Base room = Allowance − Carried floored at
$0 is computed), so outright removal would lose that computed
figure from the sheet. `showSheet` now accepts an optional
`disclosure` param `{ label, rows }`, rendered as a
`<details class="sheet-disclosure">` (label + amount rows only,
never a paragraph; collapsed by default). The Weekly Budget sheet
call now passes `disclosure: { label: 'Show how this adds up',
rows: [['Base spending room', …], ['Left', …], ['Outgoing debt',
…]] }` and NO message paragraph. No new figure, no row value
change, no week math change. The hero "Available this week" kicker
in the same screenshot is already covered by the weekly-kicker
item — no duplicate work was done in the sheet code for it.

HOME STAT CARDS numbers-only (owner, Nov 3, 7:53 PM): applied to
ALL Home stat cards (Weekly Budget, Charity, Extra Fund),
matching the Funds-card face rule: at first glance a stat card
shows Title + Amount only, no sentence figure and no secondary
sentence on the face. Weekly: figure is the signed number alone
via `formatCentsHtml(avail)` — "-$4,058.42" in red when over
budget (`.stat-card.num.negative { color: var(--soft-red); }`,
same soft red as the hero big figure), plain number in ink/black
when under budget. Charity: figure is the signed number via
`formatCents(remaining)` — $0.00 when confirmed zero, signed
negative when given exceeds committed. Extra Fund: figure was
already amount-only; the secondary line is now removed from the
face. Secondary divs were REMOVED from the three stat cards in
live.html (`homeWeeklySecondary`, `homeFundSecondary`,
`homeCharitySecondary` no longer exist; zero references in
live.js/live.html). All JS assignments to those elements were
removed or replaced; `clearWeekNumbers` secondary assignments were
removed (primary dash assignments kept). Words and secondary
lines moved to the tap sheets, which already carry the breakdowns
(Weekly rows, Charity rows, Fund rows), PLUS the hero progress
sentence: `weekProgressText` is now always set to empty (bar
itself remains, no words); locked status and pending-refund
status moved into the Weekly sheet as conditional rows
(`['Week status', 'Locked']` when `weekLocked`,
`['Pending refunds excluded', …]` when >0). Spent/room/carried/
over figures were already Weekly sheet rows. Accessibility
guardrail: each card's `aria-label` still says the words, set
dynamically in JS (e.g. Weekly: "Weekly Budget, over budget by
$4,058.42, show breakdown"; Charity: "Charity, no charity tracked
yet, show breakdown" / "Charity, ahead by $X, show breakdown" /
"Charity, $X remaining, $Y given, $Z committed, show breakdown";
Fund: "Extra Fund, $X spendable now / available to request, [$Y
pending / $Z owed back], show breakdown"; failure states:
"could not load" variants). Visual face is numbers-only,
accessible name keeps the words. Funds charity face consistency:
Funds charity panel figure was also changed from "Ahead by $X" to
the signed number `formatCents(remaining)`, with its panel
aria-label updated to "Show Charity breakdown, ahead by $X" /
"Show Charity breakdown, $X remaining". No figure or math change
anywhere in this item.

ITEM E — profile name (owner, Nov 3, 7:53 PM): profile menu head
is now the user's name as the large header
(`#profileName`, 18px/700), email below in smaller muted text
(14px), then role pill and household line as now. Name source:
session `user_metadata.full_name`, falling back to
`user_metadata.name`, falling back to email only if no name is
set, with the menu row reading "Add your name" in that fallback
case. NO name is ever hardcoded — a name appears only after that
user sets it. Edit profile: a new "Edit profile" / "Add your name"
row in the menu opens Settings and scrolls to a NEW Profile card
(`#section-profile`, after `#section-settings-head`, before
`#section-bank`; chosen over a separate sheet so name, email, and
password live in one place next to the account controls they
relate to) with three editable fields: (1) Name — saved via
`supabase.auth.updateUser({ data: { full_name: <name> } })`,
shown in the header immediately after save (blank name refused
with "Enter a name to save." — clearing a name is NOT offered in
this pass); (2) Email — via `supabase.auth.updateUser({ email:
<new> })`, with plain copy BEFORE saving that a confirmation email
will be sent to the new address and the sign-in email does not
change until it is confirmed; on success the displayed email is
deliberately NOT changed and the toast repeats the confirmation
copy; same-as-current refused with "That is already your sign-in
email."; (3) Password — reuses the existing `changePasswordFlow`
in Settings, no second password flow built. Profile editing is
per-user, NOT admin-only — both roles can edit their own
name/email/password (section-profile is NOT in the admin-gated
special-case list in showView). Household membership, roles,
invite, and deletion logic untouched. SAVE PATHS: auth metadata
only. NO SQL file was added or changed for this item (verified by
`git status`: no changes under `supabase/`). Backend context, as
verified: `household_members.display_name` already exists and the
audit trigger in `supabase/04-admin-rpcs.sql` already prefers it,
then auth `user_metadata` full_name / name, then email — so a
metadata name already flows into audit actor names as the
trigger's second preference.

ITEM F — Show password (owner, Nov 3, 7:53 PM): a Show/Hide toggle
on EVERY password input in the live app, with accessible label
("Show password" / "Hide password") and aria-pressed, switching
input type between password and text, never logging or displaying
the value anywhere else. No auth logic change, no password policy
change (still at least 8 characters where already required).
Fields covered: (1) sign-in password field (live.html
`authPassword` + `#togglePasswordBtn`, `span.password-row`,
btn-quiet); (2) change-password sheet (live.js `changePasswordFlow`
via the generic `showSheet`: when `safeType === 'password'`, the
input is wrapped in a `span.password-row` reusing the existing
`body.live .password-row` CSS, with a type=button btn-quiet toggle
— this covers the Settings password button AND the new
profile-card password button, since both reuse
`changePasswordFlow`; (3) reset.html New password
(`newPassword` + `toggleNewPasswordBtn`) and Confirm new password
(`confirmPassword` + `toggleConfirmPasswordBtn`), with
`.password-row` flex rules in reset.html's inline `<style>` and
listeners switching only their sibling input. No other password
inputs were found in live.html/live.js/reset.html.

ADD CARD (owner, Nov 3, 7:54 PM): the inline subtitle "Record a
transaction you already made, or import a file of them." is
REMOVED entirely; if the card is shown at all, its header is
simply "Add / Import transaction" (title only, no subtitle, no
explainer sentence). DIRECTIONAL, WORKING ASSUMPTION — FLAGGED,
NOT CONFIRMED: the Add choice card is hidden from the
Transactions page by default — the Transactions list is the page,
and the existing top-right "Add" button in the Transactions card
header is the entry point that reveals the Add choices
(manual / CSV / charity). Implementation: `addFormOpen` is now
null = list only, 'choice' = choice card, 'manual'/'csv'/'charity'
= that form; `txAddBtn` sets 'choice'; Back from a form returns to
'choice'; Cancel/submit return to the list. The Add choices and
forms are NOT deleted, only their default visibility changed. The
owner said a next picture will show where Add should live instead
— this hide-by-default is pending confirmation against that next
picture and can be adjusted without rework (one state value, no
form or handler rework).

FILTERS SHEET (owner, Nov 3, 7:55 PM): one label per group only,
audited across the whole sheet. New label set: Status — single
"Status" label above its select, section heading removed; Card /
Account — single "Card / Account" label, section heading removed;
Amount — "Amount" heading kept once, fields renamed "From ($)" /
"To ($)"; Dates — "Dates" heading kept (it groups several
distinct fields — Month, This week only, From date, To date —
and no field repeats "Dates", so it is not a duplicate); Sorting —
section heading removed, single "Sort by" label above the select
(the direction button keeps its own aria-label). Pairs put
side-by-side on one line (`.tx-sheet-pair`, 1fr 1fr grid, 10px
gap): Amount From + To, and From date + To date. At 390px each
half is ~200px wide — still a full-size tap target, not squeezed.
Full-width kept where a field genuinely needs it: Status, Month,
and Card selects. The sheet is shorter overall (three headings
removed, two stacked full-width pairs collapsed to two lines),
with Apply/Reset/Cancel reachable with less scrolling. NO filter
logic, option values, or match behaviour changed — labels and
layout only.

### Already-done (verified, not rebuilt)

Over-budget primary wording; Weekly breakdown labeled rows +
equation; History separation/grouping; Funds duplicate Ask
removed; "total of the rows shown"; Transactions total excludes
charity except on Charity filter; manual Cancel (Back keeps draft,
Cancel clears); Settings intro role-aware, admin buttons hidden
from members, email card read-only to members; activity grouping
("Weeks processed ×3") + plain wording; thousands separators; row
accessible names + chevron; week-history labeled blocks ("not
recorded", never $0); profile menu restyle; History From/To stack
≤520px; payment/cashback detail exclusion labels; declutter
removals (delta3); pills 8px; Funds parity (delta3, confirmed live
by the owner's 7:31 PM screenshot); CSV styled file control;
charity prominent in filters; Home sheets labeled metric rows;
button levels three-blues system (button-card-fix, superseded by
the solid-blues change above).

### Deferred, with reason

- Server-side fund-request kind guard (needs SQL; client gating is
  the only kind check today — see P1 server finding above).
- Duplicate-Plaid-item guard design (warn / update-mode /
  duplicate banner) — separate queued decision, explicitly out of
  scope; presentation grouping/disambiguation above does NOT
  replace it.
- Scroll-position/filters restore on return from detail (inline
  detail, no return navigation; tab switches scroll to top by
  design — see P3 history above).
- Generic showSheet Escape/focus-trap (filter sheet only; other
  sheets are single-action popups closing on backdrop/confirm/
  cancel).
- Gift-form field errors beside the field (manual form only; gift
  remains dialog — same pattern, not yet done).
- Fund-request detail available balance on first load (may read
  "not loaded" until the next refresh, because fundQueue renders
  before the fund summary in the same refresh).
- Review summary count (the held link itself carries the count
  instead).
- Clearing a profile name (not offered — a name can be changed,
  not removed, in this pass).
- Add card final home (hide-by-default is a working assumption
  pending the owner's next picture — see Add card above).
- Mobile layout / assistive-technology / save-flow verification
  (the review itself says these remain unverified; proving here
  is code/static + synthetic only).
- Real-phone proving still owed (320/390/desktop, daylight):
  button rows, Funds card tap + sheet completeness, stat-card
  faces, profile edit, password toggles, blank-shell behaviour on
  slow load, duplicates card readability, filters sheet at 390px.

### Verification

- Full suite: `node --test test/*.test.mjs` → 139/139 pass
  (includes new `test/ux-review-fix.test.mjs`: transfer gating,
  charity $0.00, neutral kicker, blank-shell showView in boot +
  finally, solid button colours + no adjacent duplicates for new
  buttons, held link, bank disconnect identification, filter
  Escape/focus, savings wording, dedupe card structure, chevron
  bottom-right/down, weight map, weekly disclosure, stat-card
  numbers-only + aria-labels, profile name elements + save paths,
  show-password toggles, Add card header + hide-by-default,
  filters one-label + side-by-side pairs).
- `node --check live.js` clean. `git diff --check` clean.
- Duplicate/missing id check: live.html 179 ids, zero duplicates;
  reset.html 6 ids, zero duplicates. New ids: `profileName`,
  `menuEditProfileBtn`, `section-profile`, `profileNameInput`,
  `profileEmailInput`, `saveProfileNameBtn`, `saveProfileEmailBtn`,
  `profilePasswordBtn`, `fundHeldLinkBtn`, `manualFormError`,
  `togglePasswordBtn`, `toggleNewPasswordBtn`,
  `toggleConfirmPasswordBtn`. Removed ids: `homeWeeklySecondary`,
  `homeFundSecondary`, `homeCharitySecondary`.
- No secrets, no real-household UUID, no full card numbers in the
  diff. No ios/ or workflow files in the diff. No changes under
  `supabase/`.
- `test/button-card-fix.test.mjs` updated for the new design
  (tertiary deep, fourth btn-mid, chevron ⌄, headings 700, Funds
  charity face signed number) and passes standalone.

## Filters-compact — branch filters-compact (NOT merged, NO PR)

Branch point: origin/main ff59c44 (PR #16, live.js v29 / styles v20).
Branch versions: live.js v30 / styles v21 in live.html. Live still
serves v29/v20 until this is merged.

Owner feedback (Nov 3, 8:09 PM): calendar and amount filters can be
much smaller, and the app needs a simpler but clear way of
referencing them — labeling is the issue. The old system collided:
amount min was "From $X" while date from was "From YYYY-MM-DD", and
both amount max and date to were "Up to …".

### Label map — one consistent system (old → new)

Sheet (live.html, Filters sheet only):
- Dates group heading "Dates" → "When"
- "This week only" → "This week"
- "From date" → "From" (aria-label stays "Filter from date")
- "To date" → "To" (aria-label stays "Filter to date")
- "From ($)" → "Min" (placeholder "$0.00", aria-label stays
  "Minimum transaction amount"; placeholder carries the $, so
  number parsing is untouched)
- "To ($)" → "Max" (placeholder "$0.00", aria-label stays
  "Maximum transaction amount")
- Amount explainer paragraph → one short line: "Blank = no limit.
  Refunds count as negative amounts."
- Unchanged: Status, Card / Account, Month, Sort by labels (v29
  already removed their duplicate heading+label pairs; no
  duplicates reintroduced — sheet test asserts Status, Card /
  Account, and When each appear exactly once as a visible label).

Pills (filterState.mjs activeFilterLabels, rendered by live.js):
- amount min "From $10.00" → "Min $10.00"
- amount max "Up to $50.00" → "Max $50.00"
- date from "From 2026-11-01" → "From Oct 1" (short month-day)
- date to "Up to 2026-11-07" → "To Oct 31"
- week "This week" (unchanged), status/month/card labels unchanged.
- Pill dates: new formatShortDate helper — "Oct 1" for current-year
  dates, "Oct 1, 2025" only when the year is not the current year;
  a non-YYYY-MM-DD value passes through unchanged, never dropped.
- Count line in live.js: "· this week only" → "· this week", so
  the count suffix matches the sheet checkbox and the pill.
- Rule going forward: From/To always means dates, Min/Max always
  means amounts. History period line (historyPeriodLabel) already
  uses from/to wording and was left alone.

### Compact sizing (Filters sheet only, not the whole app)

Before: card padding 22px; group headings 16px above; labels 10px
above; inputs 11px vertical padding at 16px font with 6px/14px
margins — about a 43px-tall control box, about 63px per control
row with margins. Sheet buttons 13px vertical padding (~48px).
After (scoped to body.live .tx-sheet-card only): card padding
14px; headings 10px above at 13px; labels 6px above; inputs/selects
10px vertical padding at 15px font with 2px/6px margins — a
40px-tall control box (10 + 10 + 18 line-height + 2 border);
sheet buttons 11px vertical padding (~40px). Every control stays
a full tap target at 390px. Pairs stay side-by-side (Min/Max on
one line, From/To dates on one line) and Escape/focus-trap
behaviour is untouched. App-wide input padding (11px 12px) is
unchanged — other forms keep their roomier controls.

### What did NOT change

No filter logic, option values, ids, or match behaviour; no
money/week math; no figure changes; no SQL; no supabase/ files;
no ios/ or workflow files. Two existing tests were updated for
the renamed labels (delta-package single-bound label, ux-review-fix
Filters sheet labels) — the label change itself, not a behaviour
regression.

### Verification

- Full suite: `node --test test/*.test.mjs` → 144/144 pass
  (139 before + 5 new in test/filters-compact.test.mjs: pill
  label system + no "Up to", short-date year rule, sheet labels
  with no duplicates, one-line explainer, compact sheet-scoped
  sizes with app-wide padding unchanged).
- `node --check live.js` and `node --check filterState.mjs` clean.
  `git diff --check` clean. live.html ids: zero duplicates (no
  ids added or removed). No secrets, no real-household UUID, no
  full card numbers in the diff.
- Still to prove on a real phone after merge: Filters sheet
  height and tap targets at 390px, pill labels ("Min $10",
  "From Oct 1") reading clearly, and that date inputs still open
  the native picker at the compact height.

## Addendum — Audit-merge fix (Nov 3, 2026; branch audit-merge-fix, NOT merged)

Owner rule, applied throughout: only fix audit findings that make
sense; findings judged wrong are listed here as excluded, not
silently fixed or silently dropped. Merges audit A (the v29 audit,
OnBudget-UX-Audit-2026-11-03-2c7d0c3a.docx, audited 7:36–8:15 PM on
v29 across 4 synthetic households, real household never loaded,
bank/email real connections untested) with review B (the original
full UI/UX review, OnBudget-UX-Audit.docx, H1–H5/T1–T5/F1–F5/S1–S5/
A1–A5, much of which v29 already fixed). Base: origin/main 89b2a36
(PR #17, live.js v30 / styles v21). This branch: live.js v31 /
styles v22. No money-math, week-math, or filter-match changes; no
manual refunds; no writes to the owner's household; live app never
loaded signed in as the owner.

### Included fixes (each verified in current code before editing)

1. Audit A finding 1 — Extra Fund Approve always failed (headline).
   Root cause, verified in supabase/04-admin-rpcs.sql §1: the
   function parameters were named request_id / amount_cents /
   override_reason, and amount_cents collides with the amount_cents
   column of fund_requests / fund_ledger inside the UPDATE and
   INSERT statements, so Postgres reports "column reference
   amount_cents is ambiguous". (The first ambiguous statement is
   most plausibly the `sum(amount_cents)` over fund_ledger, where
   the name can mean the parameter or the column.) Deliverable:
   NEW file supabase/approve-ambiguity-fix.sql — DROP FUNCTION IF
   EXISTS approve_and_allocate(uuid, integer, text), then CREATE
   OR REPLACE as an exact copy of §1 with parameters renamed to
   p_request_id / p_amount_cents / p_override_reason at every
   parameter use, grants unchanged (revoke from public, grant to
   authenticated). Column references are deliberately UNCHANGED:
   v_req.amount_cents, sum(amount_cents) over fund_ledger, and
   the INSERT column list (amount_cents, request_id) keep their
   column names — only the VALUES side uses the p_ parameters.
   A blanket rename would have broken both the sum and the column
   list; both were caught and corrected during the build, and the
   test proves reverse-renaming the file reproduces §1 exactly.
   live.js approve RPC calls now pass p_request_id /
   p_amount_cents / p_override_reason. approve_fund_request (§7)
   calls this function positionally and is unaffected — verified
   by grep. The OLD p_-prefixed version in supabase/fund-ledger.sql
   is an earlier, weaker function (no household lock, no
   over-approval guard, overwrites fund_allocation_cents); it was
   NOT used as the source — §1 is the live behaviour to preserve.
   NOT APPLIED BY THE BUILDER: the parent applies this SQL in the
   Supabase dashboard after the code ships, then retests Approve
   (full, split, member request, override) on a synthetic
   household. User-facing failure message is now "Could not
   approve this request. Please try again in a moment."; the
   diagnostic stays in console.warn only, no raw DB text to users.
2. Audit A finding 2 — "This week" wiped on Status=All. The apply
   handler forced txWeekOnly=false when txFilter==='all', wiping a
   box ticked in the same sheet. Fixed: the handler always reads
   the txWeekCheck checkbox, whatever the status. Reset/Cancel
   snapshot behaviour unchanged.
3. Audit A finding 3 — Weekly breakdown amounts split on phones.
   The .sheet-rows value span used overflow-wrap:anywhere, which
   breaks "$0.00" mid-number. Changed to overflow-wrap:normal:
   values still wrap at spaces (the long Left row needs that),
   never mid-number. .week-metrics untouched.
4. Audit A findings 4/5 — stale copy hints. Post-create hint
   "from your profile menu" → "from Settings" (live.js); Home
   weekEmptyHint "on the Funds tab" → "in Settings" (live.html).
5. Audit A finding 6 — silent failures. Create-account now names
   the missing field before calling Supabase (email present +
   valid, password present + at least 8 characters — policy
   unchanged, only surfaced). Manual entry: the form is now
   novalidate so the handler runs when the native required date
   is empty (previously only a browser bubble showed); an empty
   date shows the inline #manualFormError pattern ("Date: pick
   the date of this transaction.") with focus on the date field,
   and a merchant check guards the field the native required
   attribute used to cover. Charity gift form: same treatment —
   novalidate, new #charityFormError inline element, empty date
   (and amount/suffix) errors inline with focus; the pre-November
   date rule still uses its dialog, as before.
6. Review B T2 — search no-match state. The Transactions list had
   one empty state for everything. Split: a typed search or any
   active filter (month, card, week, dates, amount bounds) with
   no matches shows "No matching transactions. Try a different
   search, or clear the search and filters." with a working
   "Clear search and filters" button that resets everything to
   defaults. Status-only filters keep their specific hints
   (excluded/refunds/charity). The new-household message only
   appears with no search, no filter, and no loaded transactions.
   Search matching itself unchanged.
7. Review B S2 — profile email twice. When no name is set, the
   profile header falls back to the email while profileEmail
   shows it again. The email line is now hidden exactly when its
   text equals the header text; with a name set, both lines show.
8. Review B H3 — tap hints removed. live.html #section-hint ("Tap
   a card for its breakdown.") deleted; the repeated "Tap for
   detail" text removed from transaction rows (the chevron
   disclosure cue already in the markup stays) and fund-request
   rows. Accessible row names keep their words ("— show detail").
   Home cards stay numbers-only with no chevron, per the owner's
   decision — no new chevron system invented.
9. Review B F2 — admin fund wording "Spendable now" → "Available
   to use". Member wording "Available to request" unchanged. The
   wording lives in tap sheets and aria-labels, never on card
   faces.
10. Review B A1 (High) — keyboard behaviour for all generic
    sheets. #sheetOverlay dialogs (showSheet) now: Escape closes
    (same result as Cancel/backdrop), Tab is trapped inside, and
    focus returns to the opener on close when it is still on the
    page. No-input sheets focus their confirm button on open.
    The filter sheet is a separate element with its own handler:
    when it is open, the sheet handler stands aside for
    Escape/Tab rather than fighting it. Read-only breakdown
    sheets get Close semantics via their confirm button; form
    sheets keep Cancel.

### Verify-then-decide items (checked, not invented)

- H4 roles: NOT PRESENT — no checkbox roles exist in current
  code; transaction rows, recent rows, and fund-request rows all
  use role="button" with descriptive aria-labels. History's
  stable entry is the Home "View history" button (owner-approved
  relocation, no History tab by design). Nothing added.
- S1 sighted identity: DONE in v29 — connections are grouped
  with a "Connected <date>" line and Disconnect identifies the
  connection by masked accounts in its aria-label and
  confirmation. Nothing missing except the duplicate-connection
  guard, which is excluded below as a separate decision.
- S3 History Load more scope: TRIVIAL FIX INCLUDED — the button
  sits inside the Activity card and only pages activity entries
  (weeks are counted separately in the count line), but was
  labelled just "Load more". Relabelled "Load more activity"
  with a matching aria-label.
- H5 sync status: LARGELY DONE — Syncing… button state, Sync
  done/failed toasts, and the footer "Last bank sync" timestamp
  from server truth all exist. TRIVIAL FIX INCLUDED: the footer
  also showed ("Last bank sync —", empty) on the sign-in screen
  because it sits outside view-app; it is now hidden off the app
  screens, like the profile button.
- T3 count-line density: DONE once item 8 lands — the count line
  already says "total of the rows shown" and "search covers
  loaded rows only", row names carry merchant/amount/date/
  status, and the chevron is the disclosure cue.

### Excluded as judged-not-sensible (owner rule — not built)

- H1 hero merge with "Over budget by $X" wording: conflicts
  with the owner's numbers-only card-face decision (Nov 3,
  7:53 PM) — minus sign and colour do the talking on card faces.
- Password-change requiring the current password: design
  tradeoff, not a bug (a signed-in session authorises the
  change); tightening it is a separate owner decision.
- A2 blanket size/spacing rebuild: a full type/spacing system
  rebuild is out of scope for a fix package; the sheet-specific
  compaction in this package is the targeted change.
- H4 filter/scroll restore: detail is inline — there is no
  return navigation to restore from; tab switches scroll to top
  by design.
- T4 Add location change: Add's final home is still pending the
  owner's picture; v29's hide-by-default stands until then.
- S1 duplicate-connection guard design: separate queued
  decision (warn / update-mode / banner) — presentation grouping
  does not replace it, and it is not smuggled into this package.
- A4/A5/T5/S5 sign-off and retests: testing, not code fixes —
  still owed after this package settles, on synthetic households
  and the owner's real phone for visual items.
- H2 linking breakdown totals to transactions: navigation scope
  creep — the rows reconcile, the link is a future feature, not
  a fix for any failing behaviour.

### Verification

- Full suite: `node --test test/*.test.mjs` → 156/156 pass
  (144 before + 12 new in test/audit-merge-fix.test.mjs: approve
  RPC parameter names, SQL rename-only proof, week flag surviving
  Status=All apply, sheet-rows wrap rule, Settings hints, field
  errors + novalidate forms, search no-match vs new-household
  states, profile-email-once rule, tap-hint removal with
  accessible names kept, admin fund wording, generic-sheet
  keyboard handling, history scope label + footer visibility).
- `node --check` clean on live.js and filterState.mjs.
  `git diff --check` clean. live.html ids: 179, zero duplicates
  (one id removed: section-hint; one id added: charityFormError).
  No secrets, no real-household UUID, no ios/ or workflow files.
  supabase/ changes: exactly ONE new file
  (supabase/approve-ambiguity-fix.sql); no existing SQL file
  touched.
- Still to prove after merge + SQL application: Approve end to
  end (full, split, member request, override) on a synthetic
  household; generic-sheet Escape/focus behaviour on a real
  phone; sheet value wrapping at 390px; search no-match and
  clear-filters action; profile email shown once with and
  without a name set.

## Excluded-decisions (owner decisions, Nov 3, 9:42 PM) — NOT MERGED
Branch excluded-decisions, base origin/main e60dbb2 (PR #18, live.js
v31 / styles v22). Branch versions: live.js v32 / styles v23. Live
still serves v31/v22 until merged. Tests 168/168 (156 before + 12
new in test/excluded-decisions.test.mjs; one stale assertion in
test/ux-review-fix.test.mjs updated for the removed card — intended
removal, not a regression). `node --check` clean on live.js and
duplicateConnection.mjs; `git diff --check` clean; live.html ids
zero duplicates; homeWeeklyPrimary gone from HTML and JS; no
secrets, no UUIDs, no ios/ or workflow files, no SQL file (code-only
guard), no money/week math or filter-match changes, no manual
refunds, no transactions ever deleted by the guard.

### 1. HERO ONLY — smaller Weekly Budget card removed
Home showed the same weekly figure twice: the hero card
(#section-week, big number + progress bar) and a smaller Weekly
Budget stat card (data-home-card="weekly", #homeWeeklyPrimary).
Owner: they are basically the same thing, keep ONE, numbers-only.
Implemented: the stat card is deleted (Charity and Extra Fund
cards untouched); the Weekly sheet is unchanged and now opens
from the hero number itself via a new openWeeklySheet() (same
rows, same handler, no duplication). The hero already has a Sync
button in its head row, so ONLY the number area is the target
(role="button", tabindex="0", click + Enter/Space) — no button
nested inside a button, and Sync keeps working on its own. The
face stays numbers-only (signed number + red when negative);
the words live in the hero number's aria-label, exactly as the
card used to carry ("Weekly Budget, over budget by $X, show
breakdown" / "Weekly Budget, $X left this week, show breakdown").
All homeWeeklyPrimary references removed (clearWeekNumbers and
loadWeekNumbers now update #weeklyAvailable only). Bonus: the
stats grid was already 2 columns, so the two remaining cards
now fill it exactly. Still to prove on a real phone: hero number
tap + keyboard opening the Weekly sheet at 390px.

### FUTURE RULE recorded from the same discussion (NOT code)
When a detail/return navigation exists in future, filters and
scroll position must be restored on return. The current detail
is inline, so there is nothing to restore today — this rule is
recorded here only, and was not built into this package.

### 2. DUPLICATE-CONNECTION GUARD — same account cannot connect twice
Owner: it should not be possible to connect the same bank
account twice; a blanket block by institution name is wrong
(genuinely different accounts at the same bank must still work).
The owner's own case was two American Express items whose
accounts overlapped. Constraints honoured: plaid-exchange
fetches no accounts at exchange time (accounts arrive later
via plaid-sync into plaid_accounts), so no guard is possible
at exchange time; the guard therefore lives at pre-Link
warning time and at sync time, when accounts are known.
(a) CLIENT pre-Link warning — FULLY BUILT in live.js: before
Plaid Link opens, if any ACTIVE connection exists, a
confirmation lists the active connections by name + masked
accounts and warns that connecting the same account again
creates a duplicate; Cancel (rendered first) is the safe
path and only an explicit "Connect anyway" proceeds. A
failed read fails OPEN and never blocks a legitimate
connection. (b) SERVER duplicate-account block — FULLY BUILT
in supabase/functions/plaid-sync/index.ts (deploys with the
branch on merge, via the repo GitHub integration — NOT live
until then): after /accounts/get, if a newer item's accounts
are entirely already carried by ONE older ACTIVE item at the
SAME institution, matched on mask AND account name (mask
alone is not identity — two cards can share a last-4), the
newer item is removed at Plaid via /item/remove and marked
disconnected (plaid-disconnect semantics: past transactions
stay, plaid_accounts rows stay, item moves to Previously
connected), its transactions are skipped for that run, and
the sync response carries duplicate_removed, which the
client surfaces in the sync toast. Disconnected items are
excluded from keepers, so reconnecting after a disconnect
still works. Any failure fails OPEN: unprovable duplicates
(missing masks/names/institution/dates), a failed Plaid
removal, or a failed status update all leave the item
syncing normally instead of removing it on a guess. No
transaction row is ever deleted by this guard. Shared rule:
duplicateConnection.mjs (client, unit-tested) and the
plaid-sync helper are the same algorithm and must stay in
step. Still to prove after merge: a real duplicate sync run
(newer fully-duplicated item removed, older kept, different
account at the same bank kept), and the pre-Link warning
on a real phone.

## Add-plus-button (owner design Nov 3, 9:49 PM; supersedes the pending Add picture — no picture is coming)

The Transactions page header now has ONE entry point to Add: a brand-blue
(#2f6bff, via btn-primary) round 44px "+" button (txAddBtn, aria-label
"Add") in the same header position. The old inline choice card
(section-add-choice, "Add / Import transaction") is DELETED — there is no
second way to open Add, and the Transactions list is the page when no
popup is open.

Tapping + opens an options POPUP (#addPopupOverlay, dialog, aria-modal,
Escape to close, Tab trapped inside, backdrop click closes; the handler
stands aside when a generic sheet or the filter sheet is open on top).
Options, one full-width row each with a plain sub-line: Purchase ("Add a
transaction by hand"), Donation ("Record a gift by hand"), Upload
("Import transactions from a file"). Role rule — the owner's "regular
user just purchase, no?" is answered YES: ADMIN sees all three; MEMBER
sees ONLY Purchase. The options list hides Donation/Upload unless admin,
setAddForm refuses charity/csv for members (sends them back to options),
and the CSV confirm path refuses members before any row is inserted
("Only the admin can import transactions."). Note this narrows Upload
for members: previously the choice card offered Import CSV to members;
per the owner design, import is now admin-only. Manual purchase entry
stays available to members, as today; charity gifts stay server
admin-only as before.

Choosing an option MOVES that form's existing section (section-manual,
section-csv, section-charity-gift) into #addPopupFormSlot and restores
it to its home position on close — the section is moved, not copied or
rewritten, so fields, validation, inline errors, duplicate warnings,
CSV preview/confirm, gift idempotency, and submit handlers behave
exactly as they do inline. Back from a form returns to the options;
Cancel returns to the list (manual Cancel still clears its draft; Back
keeps the draft, including across a tab switch — returning to
Transactions reopens the popup with the draft intact). A successful
submit now closes the popup and returns to the list for all three
forms: gift already did this; manual and CSV now call setAddForm(null)
on success (previously they stayed open after saving) — this is the
popup close behavior the design specifies, not a change to what a
submit saves. Backdrop click closes the popup without clearing a draft
(like Back, not like Cancel).

No form-behavior compromise was needed: every form works inside the
popup with no logic change, because the DOM move preserves handlers
and state. Still to prove after merge: + button tap, options popup,
and each form popup on a real phone at 390px (especially the CSV file
picker inside the popup), member seeing Purchase only, and draft
survival across a tab switch.
## Weekly-sheet-simple (owner decision, Nov 3, 9:53 PM, item 7)
Owner: tapping the card — now the hero number after PR #19 — still
opens the Weekly popup as today, but it showed way too many
numbers and calculations. Keep ONLY basic stuff visible, and below
it put a button saying "Show transactions" that does that.
VISIBLE on open, in order, same values and formatting as before:
Left (including the "(over budget by $X)" note when negative),
Spent, Allowance. Nothing else is visible on open.
BEHIND the existing "Show how this adds up" disclosure, nothing
deleted and no value changed: the disclosure's pre-existing rows
(Base spending room, Left, Outgoing debt) first, then the moved
rows in their old visible order — Dated this week, Late charges
from earlier locked weeks (only when lastSpentBreakdown exists),
Carried debt, Temporary increase, Week status (only when locked),
Pending refunds excluded (only when present). Outgoing debt was
already a disclosure row, so it appears there once, not twice.
BUTTON: a primary "Show transactions" button in the sheet's button
row, below the rows and below the disclosure. Tapping (or
Enter/Space) closes the sheet and opens Transactions with the
existing week filter turned on (txWeekOnly = true) via the existing
showView('purchases') + refresh() path — no new filter mode, no
change to what the week filter matches, other active filters left
alone. The count line gains "· this week" and the removable "This
week" pill makes the filter obvious. Focus lands on the Filters
button at the top of the Transactions view (overriding the sheet's
usual focus-return to the hero, since the user has moved views).
IMPLEMENTATION: showSheet gains an optional extraAction
{label, result}; when present the extra button renders primary
and the confirm (Close) button drops to the plain treatment, so
two adjacent buttons never share a color (the no-adjacent-
duplicate button rule). Sheets without an extra action render
exactly as before. Charity and Extra Fund sheets are untouched.
The hero number remains the only Weekly entry point and stays
numbers-only on its face, words only in its aria-label. live.js
v33 (styles unchanged, v23). Tests: 176/176 (168 before + 8 new
in test/weekly-sheet-simple.test.mjs). Still to prove after merge:
the button's week-filtered Transactions view on a real phone at
390px, and keyboard flow (hero number → sheet → Show
transactions → Filters button focus).

## Weekly-sheet-trim (owner correction, Nov 3, ~9:59 PM, supersedes the PR #21 disclosure design)

Owner: the Weekly sheet still showed too much — remove the "Show me"
part and all the bloating, trim it down. The "Show how this adds up"
disclosure AND every detail row it held are REMOVED from the Weekly
sheet entirely: no Base spending room, no dated/late split, no
carried debt, no temporary increase, no outgoing debt, no week
status, no pending-refunds line, no equation text, no disclosure
control at all. They are not hidden behind a tap and not moved
elsewhere in the sheet.

Final Weekly sheet contents, exactly: Left, Spent, Allowance (same
values and formatting as before, in that order) and, below them, the
primary "Show transactions" button from PR #21, which closes the
sheet and opens Transactions filtered to the current week. The
generic showSheet disclosure parameter itself is untouched (no
other sheet uses it); the Charity and Extra Fund sheets are
untouched; the hero number remains the only Weekly entry point and
stays numbers-only on its face. Branch weekly-sheet-trim, live.js
v35 (styles unchanged, v24). Tests: weekly-sheet-simple test file
updated to the trim (exactly three rows, no disclosure element in
the Weekly sheet, Show transactions button still week-filtering).
Still to prove after merge: the trimmed sheet and the button's
week-filtered Transactions view on a real phone at 390px.
## Loading-indicators (owner complaint, Nov 3, 10:01 PM, Home screenshot) — branch loading-indicators, NOT MERGED
Owner: the loading symbols are ugly/horrible — wants classier, on-brand indicators with cooler effects. Brand palette only, slow and calm, never flashy.
- Hero + stat figures: the "…" / "—" placeholders are gone from the loading state. weeklyAvailable, homeCharityPrimary and homeFundPrimary now render a rounded pale-blue (#dbeafe) skeleton bar with a slow (2.2s) brand-blue-tinted shimmer sweep, sized like the figure (hero 180×40px, stats 110×28px), so the card does not jump when the real number lands. Skeleton spans are aria-hidden; the figure container carries aria-busy="true" plus a screen-reader-only "Loading" label, cleared by JS when the real figure lands.
- Recent transactions: the visible "Loading…" line is replaced by 4 skeleton rows (36px round tile placeholder + two shimmer lines each) at real row spacing, inside an aria-busy list with an accessible "Loading recent transactions" label and no visible Loading text.
- Full-page loading view: the plain spinner is gone. A 72px on-brand mark — bold brand-blue S with a gentle pulse inside a thin rotating brand-blue ring (2.4s) — above the kept "OnBudget" / "Loading your budget…" words.
- Kept as words (status, not placeholder): footer "Last bank sync — Updating..." and other error/status text. The "—" that remains in live.js appears only in error/unavailable paths (clearWeekNumbers, fund/charity read failures) with explanatory aria-labels — failure indicators, not loading symbols, deliberately not dressed as loading bars. weekLabel's "…" also became a small inline skeleton bar.
- Reduced motion: prefers-reduced-motion stops all shimmer, ring and pulse animation, leaving static pale bars. No red anywhere. No figure, label, button or data behavior changed. Versions: live.js v35 / styles v25. Tests: test/loading-indicators.test.mjs (6 tests). Still to prove after merge: skeletons on a real phone at 390px (no layout jump when figures land), reduced-motion rendering, full loading screen mark.

## Type-scale-live (owner approval, Nov 3, ~10:12 PM) — branch type-scale-live, NOT MERGED
Owner: "just make it live, it looks much nicer than what's going on now" — the revised Part 1 proposed Home scale from the onbudget-mockups artifact goes to the live app. Typography/spacing/color only; no figure, label, button-level, or behavior change. Body 16px; supporting/secondary text 13–14px (kicker 13px, .small 13px, labels/toast 14px as before); dashboard amounts 34px in ink #0f172a (hero .big, stat .num incl. the section-stats override, fund-balance); shared card treatment (1px #e5e7eb border, 16px radius, 24px padding, 16px stat-card padding, 16px grid gaps, 8/16/24 spacing steps). Transaction amounts are brand blue #2f6bff ONLY when positive — the negative rule (body.live .tx-line1 .tx-amount.negative, soft-green #2e6b3e) is more specific than the blue rule and comes after it, so a negative amount still renders green with its minus sign under the new blue rule; hero/stat negative figures stay soft-red. Progress bar fill blue (already was), "See all" text blue (treatment unchanged), Sync bank stays the blue primary action. Styles only: styles.css v26, live.js unchanged at v36. Tests: new test/type-scale-live.test.mjs. Still to prove after merge: the scale at 390px on a real phone, and a negative (refund) row rendering green beside blue positive rows.

## Filters-header-tabbar (owner, Nov 3, ~10:37–10:38 PM, two screenshots) — branch filters-header-tabbar, NOT MERGED
Fix 1 — Filters on the header line: the Filters button moved out of
the search row and into .tx-head-row, inside a .tx-head-actions
group immediately left of the + button, so the header reads
Transactions … Filters (+). The search input now spans its row
alone. Filters keeps its id, secondary pale-blue treatment,
aria-expanded, sheet-open behavior, Escape/focus-trap, and its role
as the focus-return target after "Show transactions" jumps to
Transactions; + keeps primary blue, so the adjacent buttons still
differ in color/treatment. Active-filter pills stay below the search
row. At ≤380px the header gap shrinks and Filters pads down, while +
stays 44px, so the row cannot push + off-screen at 320px.
Fix 2 — Tab-bar audit and hardening: the bug report showed the
bottom tab bar floating mid-list, overlapping a transaction row,
in one screenshot while a second screenshot the same minute showed
it correctly pinned at the bottom. Audit found NO static root cause:
no ancestor of .app-nav carries transform/filter/perspective/
will-change (transforms exist only on descendants — chevrons,
skeleton pseudo-elements, keyframes), no JS moves the nav or
toggles body.live (body class="live" is static in HTML), and the
live override is fixed bottom with safe-area padding. The pattern
matches iOS Safari leaving a fixed element painted at a stale scroll
position during scrolling. Hardening, not a redesign: the nav itself
is promoted to its own composited layer (-webkit-transform /
transform: translateZ(0), will-change: transform — a transform on
the nav does not re-anchor the nav itself), and body bottom
clearance is raised from a flat 88px to calc(72px +
env(safe-area-inset-bottom)), which exceeds the bar's full height
(~62px plus the safe-area inset) on every view, so no row hides
behind the bar. Bar design, labels, order, and active color are
unchanged; it is not moved to the top. Versions: styles.css v27,
live.js unchanged at v36. Tests: new test/filters-header-tabbar.test.mjs
(7 tests); the older type-scale version-pinning test was updated to
v27, invariant unchanged. Still to prove on a real phone: Filters +
header row at 320/390px, and the bar staying pinned through a fast
scroll on Transactions.

## Weekly-sheet-words-buttons (owner feedback, Nov 3, ~10:48 PM, Weekly Budget popup screenshot)
(1) "The words don't belong, only number": the Left row read "-$X (over
budget by $X)". The parenthetical is removed entirely — the Left row is
now formatCents(w.availableCents) alone, the signed number, exactly as
computed before. The hero's aria-label keeps its words for screen
readers only (not visible text). Spent, Allowance, and the Show
transactions button are unchanged, as are all other sheets.
(2) "And the buttons should be centered": the shared sheet button row
(#sheetOverlay .sheet-btns) moves from justify-content: flex-end to
center, so the Weekly sheet's Show transactions + Close buttons sit
centered; this is harmless for confirm/cancel dialogs, which is why it
was done in the shared rule rather than scoped to one sheet. Button
labels, colors, treatments, order (Show transactions primary first,
Close second), Escape/focus-trap, and focus behavior are unchanged,
and the two buttons still fit side by side on narrow screens.
Versions: live.js v37, styles.css v28. Tests: new
test/weekly-sheet-words-buttons.test.mjs (4 tests); the older
type-scale version pin was moved to v28/v37 because this branch
touches both files (invariant unchanged: pins match live.html).
Still to prove on a real phone at 390px: trimmed Weekly sheet with the
bare Left number and centered buttons.

## Weekly-left-only + profile-menu rework (owner, Nov 3, ~11:20–11:22 PM) — branch weekly-left-only-profile-menu, NOT MERGED
Change A (approved "Yeah let's try"): the Weekly popup is Left only.
openWeeklySheet now builds exactly one row, ['Left',
formatCents(w.availableCents)] — same value and formatting as
before — plus the existing Show transactions button and centered
Close button. The Spent and Allowance rows are removed from the
popup: balances, not spent totals, are what shows, and allowance
lives in Settings for the admin (the Settings allowInput is
untouched). The hero figure is unchanged (same Left value). Home
stays balances-only: no spent section was added. Charity and Extra
Fund sheets are untouched.
Change B (profile-menu screenshot): the avatar menu header is
first name + role pill on one line (flex row, 8px gap), with the
user's email below in small muted (non-bold) text. First name =
first whitespace token of the display name; a string with no space
(e.g. the email fallback) is shown unchanged. The existing
no-duplication rule is kept: when no name is set and the header
itself falls back to the email, the email line below is hidden
(hideDupEmail); saving a name unhides it. The role pill is
capitalized Admin/Member from the household role. The role wording
paragraph ("Admin — you manage this household's settings and
money." / member equivalent, profileHousehold) is deleted entirely
— element and rendering, no empty gap left. The Edit-profile row
is deleted from the menu (button, listener, and all JS references);
profile editing lives only in the Settings Profile card, which is
unchanged. Menu order is now: header, Settings, Sign out. Full name
appears only in the Settings name field, where it is edited.
Change C (sign-up name requirement, owner ~11:22 PM): the auth card
gains a "Name for a new account" input (id authName, autocomplete
name, maxlength 80, grouped with Create account under "New to
OnBudget?"). Create account requires it: an empty name fails before
any Supabase call via the existing fail() pattern (named error in
authMsg, focus on the Name field). A supplied name is passed as
signUp options.data { full_name }, so the existing profileName read
(user_metadata.full_name) picks it up immediately. Sign-in ignores
the Name field entirely — it never reads it and never requires it.
Existing users and Settings name editing are otherwise untouched.
Versions: live.js v38, styles.css v29. Tests: new
test/weekly-left-only-profile-menu.test.mjs (Weekly one-row shape,
header first-name + pill line, email line + no-duplication, pill
capitalization, wording paragraph gone, no Edit-profile row,
Settings card unchanged, sign-up Name input + empty-name refusal
before signUp + full_name metadata + sign-in ignores Name); older
weekly-sheet tests updated to the one-row shape and the stale
profile-menu test updated (no Edit-profile row); type-scale version
pin moved to v29/v38 (invariant unchanged: pins match live.html).
Still to prove on a real phone at 390px: Left-only Weekly popup,
menu header (first name + pill + email), and the sign-up Name field
with its empty-name error.

## Tertiary-grey (owner, Nov 3, ~11:23 PM, Settings Bank card screenshot) — same branch weekly-left-only-profile-menu
The three bank buttons were too close in color (Connect primary
#2f6bff, Sync secondary pale #bfdbfe, Enable automatic sync
tertiary deep #1d4ed8). ONLY the tertiary treatment changed, in
both live selectors (body.live #view-app .btn-tertiary and
body.live .btn-tertiary): solid light-grey fill #e5e7eb with ink
#0f172a text (grey family already used for card borders), not an
outline. Primary, secondary, and btn-mid (#3b82f6) are unchanged.
This supersedes the Nov 3, 7:50 PM deep-blue tertiary decision for
the tertiary level only; the comment above the rule was updated so
it no longer claims "no grey" for tertiary. Adjacency audit after
the change (no two adjacent buttons share a treatment): Bank card
primary / secondary / tertiary-grey; Filters sheet Apply primary /
Reset secondary / Cancel tertiary-grey; Funds actions primary /
secondary / tertiary-grey / btn-mid; Settings Share secondary /
Change password tertiary-grey; transaction detail rows Exclude
secondary / Mark as charity tertiary-grey / Use Fund btn-mid /
Reclassify secondary / Remove danger. No other button uses #e5e7eb
as a fill (it appears only as card/input border), so the grey
tertiary collides with nothing. Versions unchanged by this addition
(live.js v38, styles.css v29). Tests: tertiary grey/ink/solid-fill
assertions plus adjacency assertions in
test/weekly-left-only-profile-menu.test.mjs.

## Bank-icon top alignment (owner, Nov 3, ~11:25 PM, Connected accounts screenshot) — same branch weekly-left-only-profile-menu
The bank icon tile sat vertically centered against a tall
multi-account institution block (institution name + account lines
+ nickname buttons + last-synced), because body.live .bank-row is
display:flex with align-items:center. Narrow fix only: a scoped
rule gives the logo tile inside .bank-row align-self:flex-start,
so the icon sits at the top of the block, aligned with the
institution name. The row's own alignment is unchanged (the
Disconnect button stays where it is) and transaction merchant
tiles are untouched. No version change (styles.css is already at
v29 on this unmerged branch). Tests: bank-row logo flex-start
assertion plus row-unchanged and merchant-tiles-untouched
assertions in test/weekly-left-only-profile-menu.test.mjs.

## Audit-fixes-morning (owner approval, Nov 4, 2026, to the overnight audit's decision list) — branch audit-fixes-morning, NOT merged
Five overnight-audit recommendations, all approved by the owner
("Yes yes ye" to the morning report's decision list). No SQL, no
money/week math, no classification/matching changes.
1. B1 — Funds "Held for review" button REMOVED: the
fundHeldLinkWrap block (button fundHeldLinkBtn + explainer
paragraph) deleted from live.html, plus its dead CSS rules. The
Review card's "Open review" is now the single way to open the
queue; the fund sheet Held row is untouched, so the held amount
is not lost. Every remaining JS reference to the deleted elements
is ?.-guarded (null-checked or optional-chained), so nothing
throws.
2. A1 — btn-mid to dark ink fill #0f172a with white text, in both
live selectors (was mid blue #3b82f6). NOT grey: in Funds actions
it would sit adjacent to the grey tertiary Ask button. Detail-row
Use Extra Fund (ink) sits between grey Mark as charity and
secondary Reclassify — both distinct from ink.
3. C3 — Disconnect button top-aligned in Connected accounts:
scoped body.live .bank-row .btn-danger { align-self: flex-start; }
only. Row-level alignment unchanged; info column untouched; the
PR #27 logo top-align stays.
4. C2 — Plain-language account types, DISPLAY ONLY: new
plainAccountType() in live.js maps credit -> "Credit card",
depository -> "Checking" (checking) / "Savings" (savings) /
"Bank account" (otherwise), loan -> "Loan", investment ->
"Investment", unknown -> omitted entirely (never a raw Plaid
word); type/subtype duplicates render the label once. Expected:
"Blue Cash Everyday® ••1005 · Credit card", "Rewards Checking
••1636 · Checking". Nothing stored, nothing touches
classification, matching, or week math.
5. B2 — Duplicate Change password removed: the Account &
household card's settingsPasswordBtn deleted and that card's
intro now reads invite code + account deletion (no "password").
The Profile card's profilePasswordBtn and handler are untouched.
Bundled trivial declutter: the stale Settings intro sentence
"Bank and email connections moved here from Funds" deleted.
Versions: live.js v39 / styles.css v30. Tests: 225/225 (219 + 6
new in test/audit-fixes-morning.test.mjs, incl. the mapping
function executed from the shipped code). Still to prove on a
real phone at 390px after merge: ink Record income, grey Ask
beside it, top-aligned Disconnect, plain-language account lines,
Settings with one Change password, Funds with no held button.
