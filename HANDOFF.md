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

## Funds-actions-three (owner, Nov 4, Option A) — branch funds-actions-three, NOT MERGED
- Owner voice note Nov 4 (morning): four Funds actions buttons in a row are too heavy; chose Option A (of A/B/C): move Record income OUT of the Funds actions card into the Charity breakdown sheet.
- Funds actions card now has exactly three buttons, in order: Add money (primary), Use fund money (secondary), Ask for fund money (tertiary grey). Record income button (fundActionIncomeBtn), its setBtn admin-gating line, and its click listener are all removed; no other Funds actions button, label, order, or handler changed.
- New shared opener openCharitySheet() used by BOTH charity sheets (Home stat card and Funds balance panel): rows unchanged (Remaining, Committed, Given, Default rate, Period); admin-only extra action "Record income" (Weekly sheet extraAction precedent — primary button, Close second); choosing it closes the sheet and opens the existing Record income form via setFundForm('income'). Members get no extra action, so their sheet renders exactly as before. Extra Fund sheet untouched.
- Income form itself unchanged (fields/validation, admin gating, Back button returns to the three-button actions card via setFundForm(null)). Member visibility elsewhere unchanged (Add/Use admin-only, Ask for everyone).
- Secondary button treatment deliberately UNTOUCHED (light-blue deepening was NOT approved with Option A — still pending as a separate question). Detail-row five-button group also still pending.
- Tests 233/233 (225 before + 8 new in test/funds-actions-three.test.mjs). live.js v40, styles v30 (styles unchanged). Still to prove on a real phone at 390px after merge: three-button Funds actions row, Charity sheet Record income button for admin (absent for member), choosing it opening the income form, Back returning to the actions card.
## Addendum — auth-card-cleanup + two-step sign-up + household naming (owner, Nov 4, 2026; branch auth-card-cleanup, NOT YET MERGED at write time)
- Sign-in card (wife's-phone screenshot, voice note): card's own OnBudget heading deleted (app header already says it); "Sign in to your household budget." subtitle deleted; "New to OnBudget?" lead-in deleted; bottom "Card numbers are never shown — suffixes only." note deleted. Forgot password? KEPT (recovery path).
- Password toggle: Show/Hide TEXT beside the field replaced by a standard eye icon INSIDE the field (eye / eye-with-slash SVG, same togglePasswordBtn id, same aria-label + aria-pressed behavior, default hidden). Email and Password inputs are now the same width (base inputs are width:100%; the scoped #view-auth .password-row rule positions the 40px eye button inside the field with 48px right padding on the input). Scoped to #view-auth only: the change-password sheet keeps its side-by-side text toggle via the generic .password-row rule.
- Sign in + Create account are now one shared row (auth-btn-row, equal width), directly under the fields: sign-in OR create, nothing between. Order in the card: Email, Password (eye inside), [Sign in | Create account], Forgot password?, authMsg.
- Two-step sign-up (owner correction, supersedes PR #27's on-card Name field): the Name field does NOT sit on the sign-in card. Card Create account validates Email + Password only (existing fail() named errors + focus) and then shows a separate name step panel inside view-auth (title "Choose your name", single Name input, Back returns to the card with Email/Password intact, Create button on the step). Only the step calls signUp, with options.data { full_name }; abandoning the step creates no account. Sign-in never shows the name step. Implemented as a panel toggle, not a new show() view, so boot() routing is untouched. Sign-out resets both panel sets to their first panels and clears the name inputs.
- Household naming (owner, same morning): full create flow is Create account → user-name step → household choice page → IF Create household, a "Name your household" step (single input, OPTIONAL; blank keeps default 'Household'; Back returns to choice; its Create button calls the RPC). Join path unchanged, no naming step for joiners. Client passes { p_name } only when a name was supplied; blank passes no argument, so both the old no-arg RPC and the new defaulted RPC create 'Household'. On the old RPC, a named call fails with the existing "Could not create household" message — never a silent fallback. Stored name shows in the Settings Account & household card as a "Household:" line (static "Household: Household" fallback; the refresh() read fails silent).
- SQL: supabase/create-household-name.sql is a full replacement create_household(p_name text DEFAULT 'Household') based on the LIVE 01-invite-codes.sql version (invite_code via generate_invite_code() preserved), same guards/membership/audit/grants, name trimmed, blank → 'Household', capped at 80 chars. It DROPs both known signatures first so exactly one create_household remains, and its grants name the (text) signature. NOT APPLIED — built for owner review and approval with the exact change shown, per the standing DB rule.
- Versions: live.js v41 / styles v31 after rebasing onto PR #29 main (which had already taken live.js v40 — bumping past it avoids serving two different live.js files under one version number).

## Home hero/stat alignment (branch home-hero-stat-alignment, owner feedback Nov 4 morning)
- Hero Sync button moved out of .hero-head into .hero-number-row, vertically centered against the big weekly number; kicker row is now full width and wraps freely (no more truncation where the button sat). Button treatment, aria-label, handler, and the number's own tap target unchanged; button is a sibling of the number target, never nested in it.
- Home Charity stat-card kicker is now just "Charity" (was "Charity · November 2026 onward", wrapping to two lines and pushing its number lower than Extra Fund's). Period still lives in the Charity breakdown sheet title + Period row; Funds Charity panel heading untouched.
- Versions: styles.css v32, live.js stays v41 (live.js content unchanged). Tests: new test/home-hero-stat-alignment.test.mjs; type-scale pin test updated v31→v32.

## Fund-sheet-button-rule (owner, Nov 4, 2026; PR #32, merged, main ec000b7)
- Change A — Extra Fund breakdown sheet is exactly 3 rows (was 6): Available (role wording kept: admin "Spendable available", member "Available to request", value f.available) / Pending (f.pending + f.heldTotal: everything not yet available, pending releases PLUS held weeks; old "(not yet released)" parenthetical dropped as now wrong) / Total (Available + Pending). Deleted from this sheet only: Released total, Spent from fund, Owed back (shortfall), Held-for-review row. Upstream computation untouched; Review queue access stays on the Funds page (Review card). Home fund card aria-label updated to the folded Pending, no owed-back mention. Screenshot check: $67.11 / $0.00 pending / $375.00 held → Available $67.11, Pending $375.00, Total $442.11.
- Change C — Charity breakdown sheet is exactly 3 rows (was 5): Available (c.remaining, SIGNED via formatCents, so the rows add up — the old "Ahead by" wording is gone from the sheet) / Given (c.given, replacing Committed) / Total (remaining + given = the old Committed). Deleted from this sheet only: Committed, Default rate, Period rows. Sheet title "Charity · November 2026 onward" stays (period now lives in the title ONLY — this supersedes the home-hero-stat-alignment note that the period also lived in a Period row); default rate stays visible/editable on the Funds "Charity income & rate" card; Record income admin action stays. Negative case tested: remaining -$20.00 + given $120.00 = total $100.00.
- Change B — Two-button rule, platform-wide (owner ruling): any row with exactly two buttons is primary blue + grey tertiary; pale light-blue is reserved as the middle tier ONLY in three-button rows, and its exact redo shade is still unpicked, so the pale definition (#bfdbfe) is untouched. Plain btn renders pale in the app, so plain counts as pale. Changed to tertiary: sign-in Create account; sign-up Back; household choice Join; household naming Back; manual-form Cancel; Transactions Filters toggle; email Check email now; charity income Cancel correction (visible during correction, beside primary Save income); history Clear date filter; dedupe Separate; sheet Cancel (confirm+cancel sheets) and sheet Confirm (extra-action sheets: Weekly Show transactions + Close, Charity Record income + Close). Single-button sheets keep primary Close. Deliberately left alone: all 3-button rows (Funds Add/Use/Ask, filters Apply/Reset/Cancel, connect-bank Connect/Sync/Enable — middles stay pale), all single buttons (incl. plain singles: See all, View history, Backs, Save email, Add temp, Share invite, Save default rate, Record it), transaction detail rows (5-button group, pending owner question), hero sync button (separate branch), destructive/red buttons, request Decline (btn-quiet: transparent/muted, already distinct from primary and grey — converting it to a filled grey button would make a decline action heavier, against its quiet intent), + popup options (brief explicitly leaves them), CSV Choose-file label + Confirm (not a shared row: label sits in its own file row, Confirm below the preview).
- Two-button "first/second" read as tiers, not DOM order: Back buttons stay first (left) with primary second; the rule governs treatments, and every changed row is now {primary, grey} with no adjacent duplicates by actual treatment.
- Versions: live.js v42 (changed), styles.css v32 unchanged (sibling PR #31's pin). Rebased onto PR #31 main (8888aaa) before finishing so the branch carries the hero/kicker/styles-v32 changes; tests 265/265 (255 post-PR#31 baseline + 10 new in test/fund-sheet-button-rule.test.mjs, executing the shipped row functions sliced from live.js). Updated pins/tests: button-card-fix (new 3-row sheets), audit-fixes-morning + ux-review-fix (held folds into Pending), funds-actions-three (new charity rows), weekly-sheet-simple (confirm tertiary with extra action), filters-header-tabbar (Filters now tertiary), home-hero-stat-alignment + type-scale-live (live.js pin v41→v42). Id check: 188 ids, no duplicates; the 6 js-referenced-but-absent ids are pre-existing guarded refs (refreshBtn, fundHeldLinkWrap/Btn, settingsPasswordBtn, sheetOverlay/sheetInput), none touched here. Still to prove on a real phone at 390px after merge: 3-row fund + charity sheets with the screenshot arithmetic, grey second buttons everywhere listed, pale middles still pale in 3-button rows.
- NOT in this branch (separate owner items, do not conflate): Weekly popup rows (content change pending owner's clarification — Left-only reversal vs Room-based equation); transaction detail-row treatment (pending owner question); pale secondary redo shade (A/B/C unpicked); newer platform rules recorded the same morning (bottom padding, popup-only scroll, From/To date pairs, label shortening) and the History/Home-cards/Add-popup/Activity redesign recommendations — none built here.
## Popup-padding-labels-fix (owner feedback Nov 4 morning; rebased onto PR #32 main ec000b7)
- FIX 1 bottom padding, platform-wide: the footer sentence sits right after main, so the card-to-footer gap was card margin 16px + main bottom padding 48px + footer top padding 16px = 80px of dead scroll. body.live main bottom padding is now 0, so the gap is 16 + 0 + 16 = 32px of breathing room. Tab-bar clearance untouched: body padding-bottom (72px + safe-area) below the footer still keeps the footer clear of the fixed tab bar.
- FIX 2 popup scroll lock, all overlays: syncScrollLock() derived from the DOM (not a counter) — locked while #sheetOverlay exists, #txFiltersSheet is unhidden, or #addPopupOverlay is unhidden; unlock restores the saved scroll position. Hooked in showSheet open + done, openTxFilters + closeTxFilters, the showView tab-tap close path, and syncAddPopup (so view switches re-sync it, including stacked sheets over filters). Overflow hidden is set on both html and body (iOS Safari needs both). Cards scroll internally: generic .sheet gets max-height 85vh / calc(100dvh - 32px) + overflow-y auto + overscroll-behavior contain + -webkit-overflow-scrolling touch; tx-sheet-card and add-popup-overlay get overscroll-behavior contain (+ touch scrolling). Escape/focus-trap/backdrop-close untouched; the profile menu is a dropdown, not a scroll-blocking overlay, and is deliberately not locked.
- FIX 3 date pairs + short labels: Filters pair overlap was a grid-track bug — a bare 1fr track's minimum is its content minimum, and a date input's intrinsic width exceeds half a phone card. .tx-sheet-pair is now minmax(0, 1fr) columns (label/input min-width 0 already present); at 390px each half is ~160px. History filter pair (#section-history-filter .form-row-2) is exempt from the ≤520px stacking rule and stays side by side at every width; labels shortened "From date"/"To date" → exactly "From"/"To" (visible + aria-label). "Week of" dropped from Week history headings ("Week of Oct 25, 2026" → "Oct 25, 2026") and from the hero kicker ("This week · Week of Nov 1, 2026 (Sun–Sat)" → "This week · Nov 1, 2026 (Sun–Sat)"); the activity restoration sentence ("Week of … · Restored …") is deliberately untouched. No other labels renamed.
- Profile card (same theme): intro paragraph deleted; Email h3 + email explainer paragraph deleted (field label "Email" + input + Save email button unchanged, Save email treatment unchanged); "Password must be at least 8 characters." paragraph moved OUT of the card — not duplicated, because the change-password sheet already states "Password requirement: at least 8 characters." where the password is entered, and the email-change toast still carries the "until you confirm it" wording. Password section is now just h3 + Change password button. Even 20px section spacing: .profile-email-label and #section-profile h3 both margin-top 20px (Name → Email → Password, still one card). Password h3, Settings header, and Settings back button untouched.
- Bank card: heading is now exactly "Bank Connection" (Title Case, no "(read-only)"); sentence shortened to exactly "The app can see transactions." No other card retitled.
- No button classes changed anywhere in this branch (the 2-button rule belongs to the fund-sheet branch); no money/week math; no SQL; no ios/workflow.
- Versions: styles.css v33, live.js v43 (rebased onto PR #32 main ec000b7, whose live.js was v42 — pin moved to v43 so two different files never share one version number; styles v33 does not collide, PR #32 kept styles v32).
- Tests: new test/popup-padding-labels-fix.test.mjs (14 tests) + pin updates in home-hero-stat-alignment/type-scale tests + two intent-preserving updates in ux-review-fix (pair tracks minmax; email explainer assertion moved from static card text to the save-time toast). Full suite 269/269 in a clean worktree (255 on base + 14 new). node --check clean; 188 HTML ids, zero duplicates. Still to prove on a real phone at 390px/320px: footer gap, popup scroll lock on iOS Safari (filters + sheet + add popup, stacked), date pairs without overlap, profile spacing.

## Send-live-bundle (owner approvals Nov 4, 2026; branch send-live-bundle, NOT merged, NOT live — for parent review and PR merge only)
- 1. Weekly popup CUSTOM (supersedes Left-only): rows in order Allowance, Spent, Balance. Allowance = (w.baseAvailableCents ?? w.baseRoomCents ?? 0) + (w.tempCents ?? 0), i.e. total spending room left after previous weeks' debt, so Allowance − Spent = Balance always, including a temp week. Spent = w.chargesCents. Balance = w.availableCents (old Left). Show transactions stays primary, Close stays grey, row centered (PR #32 showSheet behaviour unchanged).
- 2. Pale option B: pale tier text is ink #0f172a, fill stays #bfdbfe. Changed the base .btn rule and the matching #txSortField rule (sort select matches the pale tier visually — this sort-field change was not named in the brief; it is a deviation, listed here). Primary #2f6bff, grey tertiary #e5e7eb/#0f172a, ink btn-mid #0f172a/white, destructive red untouched. Affects 3-button middles: Funds Use fund money, Filters Reset, Bank Sync.
- 3. History row for now: separate History card (#section-history-link) + View history button deleted from Home. See all under Recent transactions is now a quiet text link (class quiet-link, not a button) to Transactions. History is one full-width tappable row "History ›" to the History page. History relocation (fourth tab / inside Transactions / keep on Home) is NOT built — later owner decision.
- 4. Card colour subtle: hero gets faint blue wash (linear-gradient #ffffff → #eef4ff) + soft shadow (0 8px 24px rgba(47,107,255,.12)); other cards stay white with soft shadow (0 4px 16px rgba(15,23,42,.06)). No new hues, numbers untouched.
- 5. Add popup: visible <h3>Add</h3> header removed from #addOptionsCard (dialog aria-label "Add" stays). List rows Purchase/Donation/Upload with subtitles and chevrons unchanged; Cancel changed from plain pale to grey tertiary. Members see Purchase only (gating unchanged).
- 6. Activity timeline: rows are now dot + bold title + plain detail line + muted "actor · time". Dot classes via filterState.mjs: activityDotClass (charity → green #2e6b3e; system (weeks processed / week closed / household created) → grey #94a3b8; otherwise money → blue #2f6bff) and activityTitle ("Weeks processed ×N" → "N weeks closed", "1 week closed"). Jargon translated display-side only in formatAuditDetail: basis points → percent (2000 → 20%, 1000 → 10%, 250 → 2.5%). Stored rows untouched. Actor via existing formatAuditActor, never raw usernames. Day grouping and week-close collapsing unchanged.
- 7. Back header: Settings header is one line — "Settings" left, small quiet "← Back" text right (settings-back-link: no background/border, #475569, 600, 14px). Big Back button row on top deleted; subtitle deleted. Form-level Backs next to Save stay in-row and grey, untouched.
- 8. Unified sentence + Email/Budget cards: Bank card sentence is exactly "Look only — it never moves, sends, or changes anything." Email card heading is exactly "Email Alerts" (Title Case, no "(read-only)"), with exactly the same sentence as Bank. Status lines like "Connected (read-only)" are not headings and were left alone.
- 9. Budget card: heading is "Budget" + Admin role pill (same .role-pill styling as the profile menu header), "(admin only)" dropped. Sentence "Only the admin can change these." KEPT. Note: the pill is static "Admin" text (the card is admin-only); it is not dynamically set from household.role like the profile menu pill — a deviation to be aware of, not a bug.
- 10. Temporary increase layout + duration + override (scope update supersedes the original brief's lower-total placeholder): h3 class temp-increase-heading with margin-top 28px (padding below Save allowance). Field labels "Amount ($)" and "Amount for this week ($)" dropped; a "$" sign sits before each amount box (Weekly allowance and Temporary increase), inputs keep existing ids and handlers. Subheadings Title Case: "Weekly Allowance" and "Temporary Increase". Weeks selector next to the Temporary increase amount box, labelled "Weeks", options 1–4, default 1. Button label changed from "Add temporary increase" to "Set new total" (deviation: the brief did not name a rename; the old label would be misleading under new-total semantics), aria-label "Set the new total allowance for the chosen weeks".
- 10a. Lower totals MUST work — weekly allowance override: new file supabase/weekly-allowance-override.sql (NOT YET APPLIED, for owner review only — do NOT run against live until the owner approves the exact change shown). Table weekly_allowance_overrides (household_id uuid → households cascade, week_start date, allowance_cents integer check ≥ 0, created_by uuid → auth.users, created_at default now(), unique (household_id, week_start)); RLS enabled, select granted to authenticated, members-read-own policy like temp_increases. RPC set_weekly_allowance_override(p_household_id uuid, p_week_start date, p_allowance_cents integer) returns void, security definer: admin-only, allowance ≥ 0, upsert on (household_id, week_start), deletes temp_increases for that household/week so the override supersedes any old temp increase, audit "Weekly allowance set" with week and amount.
- 10b. Server override selection: compute-week reads weekly_allowance_overrides for the household; if a row exists for the requested week, B = override and T = 0, otherwise B = household base and T = tempSum as now. If the read errors (table does not exist yet), the override is treated as absent — old behaviour, no error. Week-close applies the same logic in weekPolicy for each week it computes (override map loaded once, same missing-table fallback), so closed weeks store the override base in their snapshot. Snapshot precedence: a week that already has a week_closes snapshot keeps its snapshot; an override set AFTER a week closed does NOT rewrite that closed week. The override does NOT change households.base_allowance_cents; weeks without an override keep using household base (+ temp, as before). The SQL file documents this explicitly.
- 10c. Client Temporary increase: amount entered is a NEW TOTAL allowance, repeating each week for the chosen duration. On submit, calls set_weekly_allowance_override once per week (current Sunday in America/New_York + each following Sunday, via UTC date arithmetic to avoid DST shifts), NOT add_temp_increase. No fallback to temp: if the RPC is missing or any call errors, the loop breaks on the first error and shows an error toast. Amount validation: null or negative → "Enter a valid amount." (0 is allowed). Weeks clamped to 1–4. Success toast: "Weekly allowance set to ${formatCents(cents)} for ${weeks} week(s)." — pluralised for grammar (deviation: the scope update's literal template was "for N weeks."; for N>1 it matches exactly). Error toast is "Could not set the weekly allowance. Try again." (deviation: the scope update said "the existing error toast", but the old wording "Could not add the temporary increase. Try again." would be misleading for a set-total action). No add_temp_increase RPC call remains in the handler.
- 11. Detail rows 4-action Actions sheet + Trash: the 5-button detail row is one "Actions" line under a tapped transaction, opening a list sheet (same pattern as Add popup) with exactly: Charity, Extra Fund, Other, Delete. Charity = old Mark as charity (whole only, admin only, posted charge only, via mark_transaction_charity; confirm text and toasts unchanged). Extra Fund = old Use Extra Fund (charges only, pending fund_requests row, not instant cover). Other = old Reclassify (admin only, pick Charge/Refund/Fund charge/Transfer + reason, via reclassify_transaction). Charity automatically excludes Extra Fund: charity rows show Delete only in the sheet; doTxExtraFund refuses charity rows outright ("Charity gifts cannot be covered by the Extra Fund.") in addition to the existing server guard; the sheet never offers Extra Fund on a charity row. Delete: hand-written rows = permanent delete with cannot-be-undone confirm (existing delete_transaction); bank/email/file rows = move to trash via existing exclude_transaction with reason required (sheet title "Move to trash", confirm "Delete", cancel "Keep it"), audit "Transaction moved to trash", toast exactly "Moved to trash bin.", row leaves the main list. Members: Actions sheet shows only Extra Fund for charges, nothing else (charity rows show Delete only for admins, so members get no Actions line on charity rows). Main list hides excluded rows for every filter (a legacy txFilter === 'excluded' resets to 'all'); the Excluded option is removed from the #txStatusSelect select. Empty-state hint when the list is empty but trash rows exist and no search/filter is active: "No transactions here — deleted bank rows live in the Trash below." Trash bin: admin-only bin icon button at the bottom of the Transactions page (#txTrashBtn, "🗑 Trash", grey tertiary, gated by household.role === 'admin' with a dataset.bound guard), toggling #txTrashList (hidden by default): "Trash" heading, line "Bank rows you deleted live here. The admin can bring them back.", excluded rows only with merchant/amount/date/suffix and a primary Restore button (data-trash-restore → existing restore_transaction + audit "Transaction restored" + refresh); empty trash shows "Trash is empty." Hand-written permanent deletions never appear in Trash.
- Removed sentences (declutter rule, full list): Bank "The app can see transactions."; Email full paragraph "Read-only — the app can read Amex transaction alerts, never your whole mailbox, and never sends or changes email. Transactions found here stay provisional until the bank confirms them. Connecting here does not change any existing email setup."; Settings subtitle "Connections, Budget, and Account & household."; field labels "Amount ($)" and "Amount for this week ($)"; the 'Add' <h3> header (visual header, not a sentence); the old Weekly Left-only row; the old 5-button detail row labels (Exclude, Mark as charity, Use Extra Fund, Reclassify, Remove/Delete as standalone buttons); the old Temporary "for this week only" toast wording; the old "Weeks processed ×N" activity wording and "basis points" wording. The old Temporary "for this week only" wording and the 5-button labels are replaced, not merely deleted, by the new rows/actions above.
- Versions: styles.css v34, live.js v44 (bumped together from v33/v43). Tests: new test/send-live-bundle.test.mjs (16 tests) + updated old tests (version pins v34/v44 in home-hero-stat-alignment, popup-padding-labels-fix, type-scale-live; pale #1e40af → #0f172a in button-card-fix, funds-actions-three, weekly-left-only-profile-menu; Weekly rows Left-only → Allowance/Spent/Balance in weekly-left-only-profile-menu, weekly-sheet-simple, weekly-sheet-words-buttons; detail-row assertions → Actions sheet in audit-fixes-morning, button-card-fix, fund-sheet-button-rule, ux-review-fix; settingsIntro presence → absence in audit-fixes-morning; bank sentence → unified sentence and History heading → History row in popup-padding-labels-fix; See-all .btn → .quiet-link in type-scale-live; loading-indicators slice marker section-history-link → section-history-row; ux-review-fix Use Extra Fund assertions → Actions-sheet fund gating). Full suite 295/295 (279 baseline + 16 new). node --check clean on live.js and filterState.mjs.
- NOT in this branch (separate, do not conflate): History relocation; override SQL application to live (owner approval required first); any wipe (settings-kept confirmed Nov 4 ~11:48 AM and execution ordered ~11:49 AM, but that is a separate parent-agent thread — this branch touches no live data); any transfer backfill Part B; dashboard checks (plaid-sync deploy timestamp, hourly-plaid-sync cron firings vs Nov 3 11:16 PM stale sync); S icon fix (deferred); tab-bar stay-vs-flash check (owner's own check); real-phone proving at 320/390px for all items.

## Declutter-cross-app (owner, Nov 4, 2026, 5:54–6:00 PM; branch declutter-cross-app, NOT merged, NOT live — for parent review and PR merge only)
- Scope: six owner items in one branch, same constraints as send-live-bundle (no main push, no merge, no PR, no live DB, no SQL, no math/Edge Function changes). Pins: styles.css v35, live.js v45 (bumped together from v34/v44). Tests: new test/declutter-cross-app.test.mjs (12 tests) + pin updates in home-hero-stat-alignment, popup-padding-labels-fix, send-live-bundle, type-scale-live + historyPeriodLabel expectation update in delta-package. Full suite run below; node --check clean on live.js and filterState.mjs.
- Task 1 — Minimize/simplify cross-app. REMOVED verbatim (page/section): History intro "Weekly summaries below are the financial record; the day-grouped activity after them is the shared record of account changes. Filter by date to narrow both, or clear it to see everything."; Week history intro "Closed weeks, read-only — week start, surplus, debt carried, released amount, and release status. The app never recomputes a closed week here."; Activity intro "Weekly summaries are above. Below, a shared record of every change in this household — who did what, and when — grouped by day, newest first."; History count block wording "Showing all recorded history." (historyPeriodLabel('', '') is now '' — the period line stays empty with no filter, and shows "Showing <from> to <to>." etc. only when a filter is active) and the unfiltered count line (now blank unless a filter is active or both lists are empty, so the filter result itself is never hidden); trailing activity line "Showing entries in the selected period." (the period line already states it when a filter is active); Review intro tail "Refund restorations, held refunds, and possible duplicates — nothing here deletes a row." (kept "Admin only."); Review restorations sub-intro "Restorations the refund rules posted, and refunds held for review because they exceeded the original charge." (headings below explain it); household choice paragraph "The first account creates the household (as admin). The second account joins with the invite code the owner shares — ask the owner to share it from Settings. Joining gives you member access: you can view the budget and ask for fund money; only the admin can change settings or move money. Creating a household and joining one are separate actions — pick only one." (replaced by "Create a household as admin, or join one with an invite code."); manual intro "Record a transaction by hand." + "Your draft stays here if you switch screens — Back keeps it, Cancel clears it." (kept "Counts as pending until the bank confirms it."); CSV "Sample row: 2026-11-01, AMAZON, 12.99, 1005 — card endings only, never a full card number." (kept "Expected columns: …" and both "Never enter a full card number." warnings); CSV "The preview numbers each row, flags duplicates, and shows any row it could not read." (kept "Preview first — nothing is added until you confirm."); charity gift "Record a gift you already gave." + "Only the admin can record gifts." (kept "Counts as given at once, never as weekly spending. Admin only."); Bank Previously connected "No tokens or account numbers are shown." (kept "Disconnected accounts stay listed here."); Account & household "Invite code and account deletion live here now — not in the profile menu." + "members who need an admin-only change should ask the admin." (kept "Only the admin can share the invite code."); Fund Add "This never changes your weekly allowance, spending, or debt." + "the rest becomes spendable fund money." (kept "Log cash already in checking — owed back is covered first."); Fund Add "Bank deposits never add fund money by themselves." + "if you already logged it, do not log it again when you see it in Transactions." (kept "Log each deposit only once."); Charity income "Nothing is pulled in automatically — a transfer, refund, reimbursement, loan, or fund top-up never counts as income on its own." (kept "Admin only. Nothing is pulled in automatically."); "To change an old income, correct it below — the old entry stays, marked reversed." (kept "Affects future incomes only."); Fund Use "This records spending from the Extra Fund itself —" + "never your weekly allowance or debt. The note is for the record." (kept "Lowers the fund balance only."); Fund Ask "Ask for money from the Extra Fund." + "and you can track its decision in the Fund requests list below — pending, approved, split, or declined." (kept "The admin approves or declines each request."); duplicates intro "Nothing here is deleted —" + "Same purchase keeps one row and excludes the other from counts; Separate keeps both and never flags the pair again." (kept "Pairs that may have been counted twice. Same keeps one row; Separate keeps both."); savings intro "Extra Fund is the savings story now." + "on request." (kept "Older savings records, read-only."); transaction detail lines shortened (charity "This gift is outside weekly spending and counts toward charity given once posted." → "Outside weekly spending."; excluded "This transaction is kept for the record but does not count toward any week." → "Kept for the record; does not count toward any week."; reversed → "Reversed; does not count."; payment/cashback/transfer "This is a … It does not count toward weekly spending." → "…; does not count toward weekly spending."; counted → "Counts toward its week unless excluded."); email-alert detail "This came from an email alert and is provisional — it becomes confirmed when the bank sync shows the same transaction." → "From an email alert — pending until the bank confirms it." (confirmed form shortened likewise).
- Task 1 — KEPT with reason (not deleted, listed so nothing was silently kept): titles, figures, form labels, button labels, errors; informative empty states ("No closed weeks yet.", "Trash is empty.", "No transactions yet.", "No money added yet.", "No income recorded yet.", "No restorations yet.", "Nothing held for review.", "No possible duplicates waiting."); status lines with a fact (Connected email, last synced/checked times, "Current default rate: 10%.", "Showing the first 20 of N possible duplicates.", "Showing the latest 20 records.", "More entries exist — tap Load more below.", count lines when a filter is active or a list is empty); safety ("Never enter a full card number." ×2, "Leave the card suffix blank for a cash gift."); form instructions that change behaviour ("Expected columns: …", "Blank = no limit. Refunds count as negative amounts.", "Log each deposit only once.", "Bank rows you deleted live here. The admin can bring them back."); permission consequences ("Only the admin can change these." — owner-approved, send-live-bundle; "Only the admin can share the invite code.", "Admin only." on Review/Charity); action consequences in sheets (charity confirm, reclassify, move-to-trash, fund-shortfall, delete-account — these explain an irreversible action, not a page, and are not explainer paragraphs); hero "Pending transactions are included and marked." (states a counting fact not visible in the number); week empty hint "No transactions this week yet — the full allowance is still available. Add one by hand, or connect a bank account in Settings." (informative empty state with an action); unified sentence "Look only — it never moves, sends, or changes anything." under Bank Connection and Email Alerts (owner-approved, ×2, untouched); fund/charity preview lines ("Enter an amount to see the split.", "Fund balance has not loaded yet — …"), savings "Past savings records exist, but no balance was ever recorded for them — that is a missing balance, not $0." (prevents a $0 misreading); transaction count line (scope: what the shown total covers, search covers loaded rows only).
- Task 2 — Text fields run into each other. Reported case (History From/To): the pair already had a nominal 10px gap in code, but the ID-scoped rule kept it side-by-side at phone width with bare 1fr tracks, so on a phone the two light-bordered date boxes read as one long box. Fix: History pair gap 10px → 16px, explicit min-width: 0 + box-sizing: border-box on label/input, explicit own border (1px solid #e5e7eb) + white background on the inputs. Other pairs: .form-row-2 (savings kind+amount, History) gap 10px → 12px with minmax(0,1fr) tracks + box-sizing; .form-row-3 base rule ADDED (charity gift + charity income triples previously had no grid CSS at all and stacked full-width) — minmax tracks, gap 12px, box-sizing; manual triple minmax tracks (was bare 1fr/1.25fr/0.9fr) + gap 12px; Filters sheet pairs (.tx-sheet-pair) gap 10px → 12px (minmax already present); Temporary increase row keeps its 12px flex gap, with min-width: 0 + box-sizing added to the $ input and Weeks select so they cannot touch when wrapping. No pair was stacked vertically as a lazy fix: at ≤520px .form-row-2/.form-row-3 stack to 1fr as before (single column, no touching), and the History pair deliberately stays side-by-side (a date is short with a day picker; full-width stacked dates waste the card) — that exception is the pre-existing popup-padding-labels-fix rule, now with the wider gap. Checked, not touching, left alone: sign-in Email/Password and Profile Name/Email (stacked full-width with 6px/14px vertical margins, not adjacent pairs); money-input $ prefix + input (prefix, not two fields, gap 6px kept); button rows (not text fields, own gap rules). NOT PROVEN at real phone width: the CSS rules above were inspected for 320px/390px containers (minmax tracks, box-sizing, gaps), but no real phone was used in this branch — the owner must confirm on his phone that the History From/To pair now reads as two separate boxes and that no pair overlaps at 320px/390px.
- Task 3 — Activity entry text, display-side only (stored audit_log rows untouched; no backend change). New filterState.mjs export simplifyActivityDetail(), called at the end of live.js formatAuditDetail() after the existing cents/date/basis-points/canonical translations, so the shipped display path and the tests use the same function. Before → after (full list in test/declutter-cross-app.test.mjs): Duplicate merged "Merged duplicate (TOIREMORG CHARITY $1.00) into the original bank row (TOIREMORG $1.00). Duplicate excluded, not deleted. Note: merge" → "Counted once: TOIREMORG CHARITY $1.00." (merchant/amount once, no "excluded, not deleted", no trailing Note — the note is always the default 'merge'/'separate' because the app never prompts for one here); Duplicate kept separate "Kept <id> and <id> as separate purchases. Note: separate" → "Kept as two separate purchases."; Weeks processed "2 weeks closed, 1 surplus released, 0 refunds restored, 0 refunds held for review." → "2 weeks closed · 1 surplus released." (zero parts dropped); Surplus released "Surplus $123.45 for week Oct 25, 2026 released to the Extra Fund." → "$123.45 to the Extra Fund · Week of Oct 25, 2026."; Refund restoration "Refund … for purchase week Oct 25, 2026: surplus $X, debt reduction $Y, fund $Z, held $W." → "Refund for the week of Oct 25, 2026: $X left to spend · $Z to the Extra Fund." (zero parts dropped, internal labels translated; amounts ≥$1,000 with commas handled); Transaction excluded "… excluded — reason: duplicate." → "Removed from the week: … (duplicate).", "— no reason given" → "Removed from the week: …."; Transaction restored "… restored to the week as posted/pending." → "Back in the week: …."; Transaction reclassified "… reclassified from charge to refund — reason: test." → "Now counts as a refund: … (test)." (kinds mapped: charge→a charge, refund→a refund, fund_charge→Extra Fund spending, transfer→a transfer, payment→a card payment, cashback→cash back; "— no reason given" likewise dropped); Transaction deleted "… (manual entry) deleted by admin." → "Deleted for good: …."; Transaction moved to trash "… moved to trash — reason: …" → "Moved to the Trash: …." (reason dropped here because the sheet already showed it and the Trash list is the place to act); Charity default rate "Default charity rate set to 20% (applies to future incomes only)." → "Charity rate: 20% for future income."; Charity income "Income … at … commits … to charity." → "Income … — … to charity."; Charity gift "Gift … on …" → "Gift given: … on …."; Extra Fund spending "Fund spending $X." → "Spent from the Extra Fund: $X."; Extra Fund request approved "Request … approved for $X." → "Extra Fund request approved: $X." (split/override parentheticals dropped — the request list shows the split); request declined → "Extra Fund request declined."; Base allowance "Base allowance set to $X." → "Weekly allowance: $X."; Weekly allowance set "Weekly allowance set to $X for week …" → "Weekly allowance: $X for the week of …."; Temporary increase "Temporary increase $X for week …" → "Weekly allowance raised by $X for the week of …."; Fund shortfall "Fund shortfall changed from $A to $B." → "Extra Fund shortfall: $B."; Household created "Created via create_household RPC; creator is admin." → "Household created."; Household joined "Joined via invite code." → "Joined the household.". Titles, dots, actor·time (Admin/Member, never raw usernames) and day grouping unchanged; week-close collapsing unchanged. Kept-with-reason (could not be shortened further without losing the fact): "Transaction added by hand" detail "… on <date> (••suffix)." (merchant + amount + date + card are the fact); "CSV import" detail "N added, M not inserted." (counts are the fact); "Extra Fund request created" detail "Requested $X for <merchant>." (amount + purpose are the fact); "Transaction restored" client audit "… returned to the week." (already one short line, now also simplified by the restored rule above when it comes from the RPC). Two fixes found by the tests, not by inspection: the excluded/reclassified patterns first missed the stored "— no reason given" form (no "reason:" prefix), so both patterns now accept it and drop it; the request-approved pattern first missed the no-UUID form ("Request approved for …"), so it now matches "Request" + anything + "approved for".
- Task 4 — Page jumps to top after an action. Root cause (confirmed in code): refresh() called showView(currentView) twice (mid-refresh and in its finally), and showView() always ended with window.scrollTo(0, 0) — so every action ending in refresh() (dedupe Same/Separate, transaction Actions, fund actions, saves, disconnects, filters, search) scrolled the page to the top. Fix, central in refresh() so every call site is covered (no per-handler edits, no action behaviour changed, confirmation copy untouched): refresh() captures savedScrollY = window.scrollY at entry; its two internal showView(currentView) calls now pass { preserveScroll: true }; showView() skips window.scrollTo(0, 0) when opts.preserveScroll is set; refresh()'s finally restores savedScrollY (direct + one requestAnimationFrame, best-effort) after the last re-render. If the list shrank (e.g. the resolved duplicate pair leaves the list), the browser clamps the restore to the new page height, landing the user as close as possible to where they were. Dedupe repro case: Funds → Review → Possible duplicates → "Same purchase" on the $33.03 EXXONMOBIL pair → confirm "Keep one transaction and exclude the other from counts? Neither row is deleted." (copy unchanged) → merge + refresh → page stays at the Review section instead of jumping to the top of Funds; the resolved pair leaves the list, the remaining $19.11 pair stays in place. Call sites audited (all fixed via the central refresh() change, no site left on the old path): dedupe Same/Separate; transaction Actions Charity/Extra Fund/Other/Delete/Restore from Trash; fund Add money/Use fund money/Ask for fund money/Approve full/split/override/Decline; held-refund release; nickname save; charity rate save; charity income/gift save; allowance + temporary-increase/override save; bank connect/disconnect/sync; email connect/disconnect/check; manual add; CSV import; profile name/email save; password change; filters Apply/Reset/Cancel; month/card/sort changes; search + amount-bound typing (debounced refresh). Intentionally left scrolling to top (navigation, not refresh): tab taps (showView with clearMessages, no preserveScroll), Settings Back, Weekly sheet "Show transactions", Add/Fund form opens — a real page change still starts at the top, as before. NOT PROVEN on a real phone: the code path exists and is statically tested (savedScrollY capture, preserveScroll wiring, finally restore, dedupe handlers unchanged apart from the central fix), but per the live UI audit skill, real-phone scroll behaviour (iOS Safari, installed PWA, after a list shrinks) cannot be fully proven without a phone — the owner must confirm the $33.03 dedupe repro stays in place on his phone.
- Task 5 — Refresh/restart/log-in opens Home. Diagnosis (honest): main tabs already persisted via hb-view (week/purchases/money/activity) and boot() already restored currentView — the actual gaps were (1) Settings was explicitly NEVER persisted (showView skipped localStorage for 'settings'), so any reload from Settings landed on the previous main view, usually Home; (2) sub-views did not persist (open Trash list, open fund/add forms); (3) scroll position did not persist across a full reload (Task 4 only covers in-page refresh). Fix: showView() now persists EVERY view including 'settings' under the same key hb-view (VIEW_STORAGE_KEY); entering Settings also persists hb-prev-view (PREV_VIEW_STORAGE_KEY) so Settings Back still returns to the previous page after a reload (without it, Back after a reload fell back to Home); boot() restores via resolveRestoredView() (unknown/blank saved value → 'week'); Trash persists as sub-view hb-view-sub = 'trash' on open and '' on close, restored only when currentView is 'purchases' AND role is 'admin' (resolveRestoredSubView returns null for members, so a member restoring 'trash' gets the Transactions list, not the Trash — that is the role fallback case; there is no admin-only main view, so no main-view role fallback exists to test); scroll persists per view under hb-scroll-<view> (scrollStorageKey) — saved on every view change (outgoing view) and on beforeunload, restored once in boot() after the first refresh (Task 4's in-refresh restore starts at 0 on a fresh load, so it cannot do this part). Auth and household-choice screens still come first in boot() (no session → auth, no household → household choice); a sheet/popup is never restored — the underlying page is (Add popup 'options' state and in-page fund/add forms are deliberately NOT persisted: their drafts do not survive a reload anyway, so restoring an empty form would only confuse; the underlying Transactions/Funds page is restored instead). Storage keys: hb-view (main view incl. settings), hb-prev-view (Settings Back target), hb-view-sub (trash only), hb-scroll-<view> (scroll per view). Fallbacks: no saved view → Home ('week'); invalid saved view → Home; member + saved trash → Transactions list; saved Settings with no saved previous view → Settings with Back falling back to Home. Task 4 + Task 5 together: an in-page action refresh keeps scroll via Task 4; a full reload restores page + scroll via Task 5; on a first-ever load there is no saved view or scroll and the app opens Home at the top, as before.
- Task 6 — Footer "Updating..." sticks / confuses. Diagnosis: refresh() set #refreshState to "Updating…" at start and cleared it in its finally when refreshInFlight hit 0, on the same footer line as "Last bank sync Nov 4 at 5:09 PM" — so the owner read an app-data refresh as a bank sync in progress, and a hung refresh (network reads have no timeout) left it stuck. Fix (cleanest option from the brief): the footer state is GONE, not renamed. #refreshState span removed from live.html; both refreshState assignments and the dead refreshBtn (no such element exists in live.html — the header Refresh button was removed earlier) handling removed from refresh(); refreshInFlight kept only as an overlap counter driving no UI text, so there is nothing that can stick, hang, or need a timeout clear — on success, on failure, and on a hung refresh alike, the footer shows only the last bank sync time. Bank sync in progress already has its own busy state, untouched: Sync button "Syncing…", Home sync icon spins (class 'syncing'), toast "Syncing bank transactions…", all restored in runBankSync()'s finally on success AND failure. Footer now shows, in every state: idle "OnBudget · Last bank sync <time>" (or "—" / "Not synced yet" when no sync has run, wording unchanged); refreshing (app data) — same line, no indicator (the app's own refresh is not a user-facing sync); refreshing (bank sync) — Sync button + icon + toast, footer still just the last sync time; failed — footer unchanged, failure shown by the sync toast / error message, never by a stuck footer word. Last-sync wording and assignment (lastSync from plaid_items) untouched.
- NOT in this branch (separate, do not conflate): top-blue hero decision (owner has not picked white hero vs fainter wash + border — NOT bundled here); History relocation (fourth tab / inside Transactions / keep Home row — NOT built); S icon fix (deferred); tab-bar stay-vs-flash (owner's own check); server-side fund-request kind guard (needs its own SQL + owner approval); real-phone proving for Tasks 2, 4, 5 (narrow widths, scroll after dedupe, reload-to-Settings/Trash) and for the declutter wording on a small screen.

## Task 7 — Smarter Funds bottom section (owner, Nov 4, 2026, 6:04 PM: "Whatever you recommend", Option A recommended; same declutter-cross-app branch, same pins v35/v45)
- Deleted as full cards (functions kept, presentation only): Funds actions card (#section-fund-actions, with its "Funds actions" h2 and three buttons), Review card (#section-fund-review, with its "Review" h2, "Admin only." sentence, and <details id="reviewDetails"> wrapper with <summary id="reviewSummary">Open review</summary>), Past savings card (#section-savings-past, with its "Older savings records, read-only." sentence, Past savings toggle button #pastSavingsToggle, and #pastSavingsWrap). Also deleted with them: the two activity disclosures (triangles) "View activity · Money added" (#fundTopupsDisclosure) and "View activity · Charity income" (#charityIncomeDisclosure); the Review "Pairs that may have been counted twice. Same keeps one row; Separate keeps both." sentence (the dedupe buttons themselves carry Same/Separate, and the alias label explains the remembering); form Back aria-labels changed from "Back to Funds actions" to "Back to Funds" (the actions card is gone). Intentionally NOT deleted: the "View activity · Fund requests" disclosure inside the Ask form section (it belongs to the Ask form, not to any deleted card); the fund add/use/ask forms themselves; the Charity income & rate form; Charity's Record income action.
- New: ONE quiet More card (#section-fund-more, h2 "More", no explainer sentences) at the bottom of the Funds page with exactly three tap rows (.more-row, flex title left + › chevron right, divider between, no ▶ triangles): "Fund activity ›" (#moreFundActivityBtn), "Review ›" (#moreReviewBtn, label #moreReviewLabel), "Past savings records ›" (#moreSavingsBtn). Each row toggles its section directly below the More card (toggleMore, with preserveScroll so the page does not jump to the top — Task 4): Fund activity section (#section-fund-activity-more: "Money added" h3 + #fundTopupsList, "Charity income" h3 + #charityIncomeList — ONE Fund activity row showing both types, as preferred in the brief, not two rows); Review section (#section-fund-review-more: "Refund restorations & held refunds" h3, "Restorations" h4 + #restorationList, "Held for review" h4 + #heldList, "Possible duplicates" h3 + #dedupeList — all ids unchanged, so refresh() still populates them and every handler (held Release, dedupe Same/Separate, alias checkbox) is untouched); Past savings section (#section-savings-more: #savingsSummary + #savingsList, read-only as before, no toggle button — the More row IS the toggle). The More card hides while a fund form is open (same as the old actions card); the three sections hide while a form is open, on a page switch, and for roles not allowed (below). VIEWS.money is now ['section-fund-balances', 'section-fund-more', 'section-fund-activity-more', 'section-fund-review-more', 'section-savings-more', 'section-fund-add', 'section-charity-income', 'section-fund-use', 'section-fund-ask'].
- Moved actions: Add money / Use fund money / Ask for fund money moved from the deleted actions card into the Extra Fund sheet itself. showSheet() gained an `actions` option (array of {label, result, btnClass}) rendered in the sheet button row; when actions are present, Close renders btn-quiet (distinct from grey Ask, pale Use, and primary Add) so Close cannot read as a fourth money action. New openFundSheet(withActions): Funds panel calls openFundSheet(true) — admin gets [Add money primary (btn btn-primary), Use fund money pale (btn), Ask for fund money grey (btn btn-tertiary)] in that order, members get [Ask for fund money grey] only; choosing an action closes the sheet and opens the same form via setFundForm('add'/'use'/'ask') with the same handlers as the old card buttons. Home stat card calls openFundSheet(false) — read-only breakdown (Available/Pending/Total + Close), unchanged, so Home behaviour does not change. Order, colours, labels, role gating, and handlers are exactly as now; only the location changed. Charity's Record income stays in the Charity sheet (extraAction, admin-only) and is NOT in the More card.
- Review count: #moreReviewLabel reads "Review" when nothing needs review and "Review (N)" when N > 0, where N = pending held refunds + pending duplicate candidates (reviewNeedsCount, updated after the held render and after the dedupe render in refresh()). Restorations do NOT count — they are already-posted history, not something needing review. The count comes from the latest successful reads; if a read fails, the label keeps the previous count rather than inventing one. Review row and section are admin-only (hidden for members in showView, same as the old Review card); Fund activity row and section are admin-only (their lists are admin-only reads, same as the old disclosures); Past savings row and section are visible to all roles (its read was never admin-gated).
- Held link: the Funds held-balance link now opens the More Review section (moreReviewOpen = true, scroll to #section-fund-review-more) instead of opening #reviewDetails and scrolling to #section-fund-review; its text and held gating are unchanged.
- Tests: 4 new tests in test/declutter-cross-app.test.mjs (old cards/triangles/sentences gone; More rows exist with chevrons and moved ids intact; Review count rule; sheet actions order/treatments/gating + Charity Record income staying in its sheet + More role gating). Old tests updated for the move (intent-preserving, not deleted): audit-fixes-morning (Review card → More Review section), button-card-fix + funds-actions-three + weekly-left-only-profile-menu + fund-sheet-button-rule + ux-review-fix + send-live-bundle (fund action buttons → openFundSheet actions) + weekly-sheet-simple (sheetConfirm class now has the actions branch; Extra Fund sheet call now carries `actions`). Full suite 311/311 (see branch tip). NOT proven on a real phone: the More rows' tap feel, the 4-button sheet row at 320/390px (Add/Use/Ask/Close wrapping), and the in-place section toggles — the owner must confirm on his phone.

## Native-style-live (owner, Nov 4, 7:11 PM — approved mockup direction, parent review + PR only)
Rollback: previous main tip 350e039 (PR #35 merged). Revert via PR revert if the owner dislikes it. UI only — no database, no math, no Edge Function changes; bank/email/transactions/fund/charity figures untouched, so a UI revert cannot hurt numbers. Pins styles v36 / live.js v46. Tests 321/321 (311 baseline + 10 new in test/native-style-live.test.mjs), node --check clean on live.js and filterState.mjs.
- 1. Combined hero: ONE hero card now contains Available (big, 44px), progress bar, Spent line ("$X spent" + "% used" or "Over budget" when capacity is 0), Weekly allowance, and Purchases count (this-week non-excluded row count, set in the transaction render). Hero face is the approved exception to the numbers-only rule. Below the hero, Charity and Extra Fund stay as the same stat-cards (same ids, same tap targets, same sheets) with a visible blue › chevron bottom-right — they were already tappable pots; the chevron makes the tap target obvious. NOT changed: "Recent transactions" heading was NOT renamed "This week's purchases" because that list is the newest 4 rows, not a week-filtered list — renaming it would misdescribe it.
- 2. Bottom sheets for ALL popups: generic showSheet, transaction Actions sheet, Filters sheet, and Add popup are all bottom-anchored, full width (max 520px centred), rounded top corners only (20px 20px 0 0), handle bar, scrim, scroll lock (sheet scrolls only, page behind does not — existing syncScrollLock, unchanged), safe-area bottom padding, buttons above the tab bar via the sheet's bottom padding. Generic sheets move Cancel to a quiet top-left "Cancel" (sheet-top-cancel) with the title centred; the bottom row keeps extra/actions/confirm, primary stretches full-width when alone. Actions list sheet: same handle + top Cancel, bottom Cancel removed. One sheet at a time: showSheet removes any existing sheet, Add popup already refused to open over a sheet. No centred floating modal remains. Deviation: the old centred-sheet test for "button row centered" was updated to the new stretch rule, not weakened silently.
- 3. Transactions Past weeks, NO fourth tab: navigation stays exactly Home / Transactions / Funds (app-nav-link ×3; Settings lives in the profile menu, as before). Home History row deleted (HTML, VIEWS.week, and its keydown handler). The History filter, Week history, and Activity sections now also appear in the purchases view, below the current list, under the heading "Past weeks" (renamed from "History"), with a 28px gap + 3px top border as the visual break. The History filter already only narrows week-history + activity, never the current transaction list, so current and past are not mixed. The old standalone 'activity' view still resolves for any saved last-view, but nothing navigates to it any more.
- 4. Trash: the grey pill "🗑 Trash" at the bottom under Load more is gone. Trash is now a quiet text link "Trash (N)" above the transaction list (after the count line, before the list), admin only, shown ONLY when N > 0; the Trash list itself opens right there, with Restore inside as before. Empty-list hint updated to point to "the Trash link above the list". Excluded rows still leave the main list and live only in Trash; hand-written deletes stay permanent.
- 5. Funds preserved: PR #35 More card (Fund activity / Review (N) / Past savings, quiet › rows) and Add/Use/Ask inside the Extra Fund sheet are untouched. Unified sentence kept ×2, "Only the admin can change these." kept on Budget, button tiers kept (primary #2f6bff, pale #bfdbfe/ink, grey #e5e7eb/ink, ink mid #0f172a/white), bottom blue toasts only, never red.
- 6. Display-side readability only (stored data unchanged): filterState.mjs adds titleCaseMerchant (all-caps runs title-cased, mixed-case words left alone) and relativeDayLabel (Today/Yesterday against the NY date, else null). live.js renders merchant names in Title Case and dates as Today/Yesterday in the Transactions list, Recent list, Trash list, detail headings, and Actions sheet title. Merchant-name ellipsis truncation already existed on tx rows and is now also asserted; amounts/figures unchanged. Note: "AMAZON MARKEPLACE NA PA" renders "Amazon Markeplace Na Pa" — the source spelling is kept, only the case changes.
- 7. Breathing room: hero padding 28px 24px 24px, hero big 44px, hero meta values 18px, sheet padding 22px sides, section spacing kept. No dark mode, no palette change, hero wash kept (top-blue question still open with the owner — this branch does NOT decide it).
- Old tests updated to the NEW approved behaviour (not weakened): pin assertions v35/v45 → v36/v46 everywhere; History-row assertions → removal assertions; Trash pill → quiet-link assertions; sheet button row centered → stretch; sheetCancel bottom button → sheetCancelTop; Home stat-kicker regex allows the new chevron span; loading S-mark → logo mark; sheet max-height calc(100dvh - 32px) → 88dvh (scroll properties unchanged). The filters-compact 14px sheet-padding assertion still passes verbatim but is superseded by the later bottom-sheet padding rule (22px sides) — the later rule wins in the cascade; see the appended native-style CSS block.
- NOT proven at real phone width: bottom-sheet height at 88dvh on small phones, buttons clearing the tab bar with safe-area padding, the 20px header O legibility, the 16px favicon, Past-weeks length on the Transactions page, and the hero meta rows at 320px. Owner must confirm on his phone.

## Logo — original picture everywhere (owner, Nov 4, 7:12 PM; clarified Nov 4 evening)
- The logo is the ORIGINAL sent picture itself, for now. Source: ~/workspace/user/media_library/image/e0/e0997782269eb865e7a34ba3e3e30c49a3fcc74a4d4c70f2838f8a64a020090a.jpg (1254×1254 JPEG, white background). NOTHING was redrawn, traced, or vectorised.
- CORRECTION recorded: an SVG recreation (~/workspace/household-budget/onbudget-logo.svg, a text-based "$" glyph with 5 equal 72° ring segments) was made during this work and then explicitly rejected by the owner as NOT accurate — wrong S shape, wrong ring segment proportions, wrong colours. It is NOT used anywhere in the app, NOT referenced by live.html or live.js, and NOT committed on this branch (it remains only as an untracked file; do not add it). If a true SVG is ever needed, it must come from a traced version of the original picture or from the original designer file, never from a hand-drawn text recreation. SVG work is paused.
- Generation (PIL only, from the original JPEG): cropped to the circle (box 122,135–1126,1139, centre ~624,637), supersampled circular alpha mask so the white background outside the circle becomes transparent (the white disc inside the ring is part of the logo and stays opaque). No colours changed, no S or ring redrawn.
- Places replaced and sizes generated: icon-512.png (512×512 RGBA, manifest any + maskable), icon-192.png (192×192 RGBA, manifest any + favicon), apple-touch-icon.png (180×180 RGB on a white square — iOS would show transparent corners as black, so the touch icon keeps the picture's white background), favicon-32.png (32×32 RGBA, new link), favicon-16.png (16×16 RGBA, new link). manifest-live.json itself needed no change (it already declares 192/512). Header wordmark: the circular picture serves as the O — <img class="wordmark-logo" src="icon-192.png"> at 1em (20px, matching the wordmark cap height) + "nBudget", aria-label "OnBudget" so screen readers still hear the full name. Loading screen: the old pulsing S-only mark (loading-brand-s) is gone, replaced by the picture at 60px inside the existing spinning ring; the "OnBudget" loading text below it is unchanged. Tests assert the icon files exist at manifest sizes, the header O pattern, the loading mark replacement, and that no SVG logo is referenced.
- Small-size check: at 32px the S and ring segments read clearly; at 16px the ring segments blur into a blue disc but the light S shape still reads. No simplified small version was made — the owner clarified to keep the picture as-is, so the 16px favicon is the picture downscaled, not a redraw.
- NOT proven on a real phone: the header O at 20px (S detail will be small — owner to judge), and the home-screen icon after a fresh install (phone caching means close/reopen after any push; a home-screen icon change may need re-adding the app to the home screen to appear).

## Merged-audit push package (owner, Nov 4, 10:12 PM — "take it down tonight" + SQL approval for this package; branch only, NOT merged, NOT live at commit time)
Rollback: previous main tip 68c27c7 (PR #36 merged). Revert via PR revert if the owner dislikes it. UI + Edge Function code only — the five prepared SQL files in supabase/merged-audit-*.sql are SEPARATE and must be applied via the approved browser SQL run (answer_to + verbatim file contents), NOT by merge, and only after the owner has seen each exact file. Pins styles v37 / live.js v47. Tests 353/353 (321 baseline + 32 new in test/merged-audit-push.test.mjs), node --check clean on live.js and filterState.mjs.
- SOURCE OF TRUTH: MERGED_AUDIT_2026-11-04.md, Section A (18 items) + Discussion decisions B1–B11 (all decided Nov 4 evening). No audit finding was re-litigated; items judged wrong by the owner in earlier rounds were not silently dropped — they are listed as still-open in the merged report, not in this branch.
- LIVE PROBE applied (parent, Nov 4, 10:12–10:18 PM, read-only, nothing changed live; counts transactions 36, week_closes 0, pre-Nov 0): live transactions_kind_check = charge, refund, fund_charge, payment, cashback, charity — transfer MISSING, confirming the Transfer reclassification failure; live approve_and_allocate = p_request_id/p_amount_cents/p_override_reason, MATCHING the UI — no signature fix needed live, and supabase/04-admin-rpcs.sql §1 (unprefixed) is OUTDATED and must never be re-applied after this package (it would break Approve); grants: transactions authenticated SELECT+INSERT, plaid_accounts SELECT+INSERT+UPDATE, fund_requests SELECT+INSERT; member INSERT transactions manual/csv provisional confirmed, plaid_accounts member INSERT+UPDATE confirmed; charity gift idempotency index transactions_household_client_key_idx (client_key IS NOT NULL) already PRESENT live; fund-request kind guard ABSENT live (trigger trg_fund_request_validate exists, body has no kind mention). The manifest and HANDOFF below were corrected to this probe; no SQL was applied by this branch.
- Section A built: A1 merged kind-constraint SQL file (seven kinds, live six + transfer) — file only, NOT applied; reclassify code path checked (UI offers charge/refund/fund_charge/transfer; RPC 05 allows six kinds, constraint is the blocker, not the RPC — the RPC's allowed list already includes transfer, and charity reclassification goes through mark_transaction_charity, not reclassify). A2 closed by probe (no SQL file; repo 04 file left untouched and flagged outdated in the manifest). A3 hero allowance now baseAvailable + tempC (effective allowance, matching Weekly breakdown Allowance − Spent = Balance). A4 Correct income now opens the income form (setFundForm('income')), scrolls it into view, focuses its source input; Record income with no correction active starts fresh (correctingIncomeId cleared by the existing form reset path — no new state added). A5 Home Recent + Trash share the Transactions Cash/no-card ternary (charity + suffix 0000 → "Cash / no card", never ••0000); Home Purchases count now counts only week-counted charge rows (thisWeekPurchases), never charity gifts. A6 openRecent rewritten robustly (implemented in this branch's final pass — the earlier batch's version had not landed): clears search + all filters + date/amount inputs, shows Transactions, refreshes, opens detail, scrolls it into view, highlights the row for 2500ms (tx-recent-highlight), and toasts plainly when the row is not in the loaded list. A7 search note "Searches loaded transactions." beneath the input; count line now "N transactions · Total shown $X"; no-match message ("No matching transactions — try a different search, or clear the search and filters.") takes priority over the zero-dollar total; the old packed txCount sentence (with its charity/excluded parenthetical) is gone. A8 past-savings empty state is now exactly one line "No past savings records." (the "Not recorded yet" metrics and the Extra Fund distinction sentence are gone from that path). A9 profile menu closes (aria-expanded false) when Settings opens, focus moves to the Settings heading (now tabindex="-1"), Back returns to the previous view via the existing showView previousView handling. A10 showAlert confirmLabel changed 'OK' → 'Close' for read-only detail; bottom sheets keep Cancel/Done; Escape/focus-return already existed in showSheet/Filters/Actions and was kept, not re-implemented. A11 narrow fund amounts: @media max-width 390px shrinks #section-stats .num / .stat-card .num / .fund-balance to 22px and hero .big to 36px with overflow-wrap anywhere (the ID selector was needed — the plain class rule lost to the #section-stats ID rule); fund-balance-grid already stacked at 420px. A12 negative Charity/Fund pots: .fund-balance.negative (soft-red, like hero) + class toggles on homeFundPrimary, homeCharityPrimary, fundSummary, charitySummary. A13 Add popup card now has background #fff + overflow-y auto (true bottom sheet; handle already on the card). A14 plaid-sync update never overwrites kind (kind set at insert only — posting changes state, not kind, so an admin reclassification survives sync) and never overwrites Trash state (excluded rows get bank facts refreshed only, no state change). A15 plaid-sync hash match now claims only source='amex_alert' rows (verified: ingest-amex-alert inserts source 'amex_alert'); identical real purchases insert as new rows instead of overwriting the earliest hash row. A16 prepared SQL only (see manifest): kind guard, plaid_accounts revoke, CSV admin-only; charity idempotency NOT duplicated (index already live — manifest gates the existing r13 file on a pg_proc signature probe). A17 ordered apply-manifest at supabase/APPLY_MANIFEST_MERGED_AUDIT.md (five files in order + explicit do-not-apply list). A18 cleanup: hero face sentence removed from live.html and moved into the Weekly sheet message ("Pending transactions are included and marked."); dead Funds held-review link code removed entirely (success block, catch block, and handler — the old tests that asserted guarded references remain were updated to assert no reference remains); stale comments corrected (Trash "below the list" → "above the list" in two places; three dedupe comments now say there is NO unique (household_id, dedupe_hash) constraint live, proven Nov 3 — dedupe is matching-only). The plaid-sync grants-header note (P1-16 residual) was left as-is: it describes a real remaining dependency, not a stale claim.
- Decided B built (code only): B1 Temporary Allowance rename + updateTempPreview() (Base / New total / Weeks / exact Sunday dates in NY time, same Sundays the save loop writes; listeners on amount + weeks inputs, refreshed after loadWeekNumbers; NO math change, new-total-repeats unchanged). B2 Funds More accordion (toggleMore closes all three, re-opens the tapped one only if it was closed; headers always visible, panel below its row). B3 Previous Weeks + Activity split, NO new tab: Transactions page stays the current list only, with two quiet links at top (Previous Weeks, Activity); Previous Weeks page = head card (Back → Transactions) + History filter + week-history, and week blocks are now tappable (role button, keyboard) — tapping a week sets Transactions date filters to that Sun–Sat week and shows its transaction rows; Activity page = head card (Back → Transactions) + timeline only, NOT transaction rows; both pages are restorable (MAIN_VIEWS + prevweeks; VIEWS.purchases no longer embeds history/activity). B4 desktop Add label: button aria-label "Add transaction" with .add-label-desktop span (hidden on phone, pill button ≥768px); chooser titles/subtitles unchanged. B5 mockup ONLY: card-standardization-mockup.html (standalone, labelled MOCKUP ONLY, not linked from live.html) shows Home hero + Charity/Extra pots + a Funds card with the same heading style, same chevron, same label-then-amount order; NO live card restyle beyond the A-items in this branch. B6 two-layer date guard: plaid-sync tracks fullPullSeen (any item starting with NULL cursor) and deletes date < '2026-11-01' rows for the household once, after all items; week-close and compute-week both filter loaded transactions to date >= '2026-11-01' (floor, so a slipped pre-Nov row cannot stamp old weeks or chain debt into November). B7 shared week logic: NO engine rewrite — compute-week and week-close already call the same computeWeek engine per week with the same snapshot > override > base/temp precedence; this branch adds the fixture (test/merged-audit-push.test.mjs: purchase → refund after lock → restoration, both engines agree, total never exceeds the refund, excess held) and a contract comment in week-close's restoration simulation. A full walk refactor was judged higher-risk than the fixture + the one concrete divergence fix (B8) and was NOT attempted; parent review should confirm this is acceptable against the "not just patch two cases" instruction. B8 atomic restoration: initialDebt now subtracts prior cuts (restorationEntries with week_start < currentWeekStart, floored at 0); restoration writes reordered (held insert BEFORE the entry, so a held failure leaves no completed entry hiding the queue) with unique-violation (23505) swallowed as idempotent on both inserts, and a concurrent-race guard (unique-violation on the entry → undo the in-memory shortfall offset, skip fund credits, continue — money is never credited twice); other held-insert failures still throw loudly (500, re-runnable, entry not yet created). B9 shortfall serialization: persistShortfall() re-reads households.fund_shortfall_cents fresh via the service client, applies only the delta since the last persist, and writes that target through update_fund_shortfall (replacing both absolute writes); the remaining race window is the read-to-write gap only, not the whole run — true row-lock serialization lives in the top-up RPC, and week-close cannot hold a Postgres transaction across PostgREST calls, so this is the strongest Edge-Function-level guarantee available; it is documented as such, not claimed as a DB lock. B10 held refunds: fixture in the new test file (shortfall-first release arithmetic + no-double-release rule) + the atomic resolve_held_refund replacement (prepared SQL: SELECT FOR UPDATE + conditional status='pending' update + row-count check raising 'held refund already resolved') + the week-close held-first/unique-swallow change above; failed held-inserts queue for admin review via the loud 500 + restorationsSkipped path, never a silent skip. B11 detail actions by kind: shared actionsForTxKind(kind, isAdmin, isVerified) in filterState.mjs (charge → charity [admin+verified]/extraFund/other/delete; transfer/payment/cashback/fund_charge → other/delete admin-only; charity → delete admin-only; members → extraFund on charges only), used by openTxActionsSheet, plus the plain "This row does not count toward weekly spending." line for non-counting kinds; existing code already gave admin transfer rows Other+Delete only, so B11's change is the shared helper + the explicit line + tests, not a new action set.
- Prepared SQL files (all marked PREPARED FOR OWNER-APPROVED APPLY, none applied): supabase/merged-audit-kind-constraint.sql (A1, seven kinds, live constraint name transactions_kind_check); supabase/merged-audit-fund-request-kind-guard.sql (A16, charge-only linked requests, unlinked path untouched); supabase/merged-audit-plaid-accounts-revoke.sql (A16, revoke member INSERT/UPDATE + drop two write policies, SELECT stays); supabase/merged-audit-csv-admin-only.sql (A16, CSV requires admin, manual stays member-allowed, provisional still required); supabase/merged-audit-held-release-atomic.sql (B10, resolve_held_refund with row lock + conditional update + row-count check, semantics otherwise identical). NO approve-signature file (A2 live-proven), NO new charity-idempotency file (index live; manifest gates existing r13 file on a pg_proc probe).
- Old tests updated to the NEW approved behaviour (not weakened): pin assertions v36/v46 → v37/v47 everywhere; add-plus-button + ux-review-fix Add aria-label "Add transaction" + desktop-label CSS; audit-fixes-morning + ux-review-fix held-link tests now assert NO fundHeldLink reference remains (A18 removal); button-card-fix face line now allows the negative class and asserts the Review (N) label instead of the removed held-link text; ux-review-fix charity figure now asserts the negative toggle; native-style-live + send-live-bundle Past-weeks assertions now assert the B3 split (prevweeks/activity views, no history in purchases view, Previous Weeks h2 with tabindex); popup-padding-labels + send-live-bundle Settings heading now allows tabindex="-1"; send-live-bundle Temporary heading now "Temporary Allowance" and Actions assertions now assert the actionsForTxKind helper (exact sets in the new test file). Full suite 353/353.
- Removed sentences (this branch): hero face "Pending transactions are included and marked." (moved to the Weekly sheet message, not deleted outright); past-savings empty metrics + "No past savings records yet — these old records are separate from the Extra Fund, which is the savings story now." (replaced by one line "No past savings records."); old packed txCount sentence (replaced by "N transactions · Total shown $X" + no-match recovery line); "Temporary Increase" heading (renamed "Temporary Allowance"). No other sentences removed.
- NOT built, and why: B5 live card restyle (mockup only, owner pick pending); SQL application (prepared only — parent applies via approved browser run after owner sees each file); live probe by this branch (forbidden — parent ran the read-only probe Nov 4, 10:12–10:18 PM and passed the results in; those results are recorded above and in the manifest); Edge Function deployment (merge + Pages build only, by parent); top-blue hero (still open, owner has not picked); previously-connected visibility (still open, PR #35 copy only); tab-bar stay-vs-flash (owner's own check); any financial rule not listed above; any live data change. NOT proven: real-phone rendering for every item in this branch (Add popup scroll, 390px fund numbers, 20px header O, Past-weeks length, sheet height/tab-bar clearance, home-screen icon after re-adding); synthetic-household write-path proofs for Approve, reclassify-every-type, Correct income focus, held release + re-release, kind guard, revoke, CSV admin-only, Trash survival, identical-purchase coexistence, full-pull Nov 1 drop; live-probe re-verification after SQL apply (kind constraint text, approve signature unchanged, grants, held RPC body); week close after Sunday Nov 8, 2026 (time-gated — verify week_closes becomes 1 on an admin load on/after Nov 8, never manufacture it on the real household); Section D acceptance (CSV retest on real phone + desktop, bank/email end-to-end, refunds/duplicates/past weeks, phone/member/screen-reader pass). Also NOT in this branch: the new app-icon image the owner sent Nov 4, ~10:22 PM (white rounded square on deep blue with wordmark) and the follow-up voice note asking for light-blue recoloring — clarification is pending with the parent on whether it replaces the circular picture logo and on a recolor test version; this branch keeps the existing circular-picture logo untouched and does not incorporate the new image.

## Feedback bundle (owner screenshot/voice-note burst, Nov 4, 10:34–10:40 PM; branch only, NOT merged, NOT live)
Rollback: previous main tip 6753f78 (PR #37 merged). Revert via PR revert if the owner dislikes it. UI + one prepared SQL file only — no live DB change, no Edge Function deployment, no data change. Pins styles v38 / live.js v48. Tests 368/368 (353 baseline + 15 new in test/feedback-bundle.test.mjs), node --check clean on live.js and filterState.mjs.
- 1. Loading, full screen: #view-loading is no longer a .card — it fills the viewport below the header (min-height calc(100dvh - 60px), flex-centred content, no border/shadow/gap). The footer is hidden while loading, both by the .is-loading body class set in show() and by a :has(#view-loading:not(.hidden)) CSS fallback, so the footer never shows on the first paint before JS runs either. Text changed "Loading your budget…" → "Loading Your Household" (Title Case).
- 2. Empty pages: boot() now keeps the loading view visible while the first refresh() runs and only then switches to the app view (previously it switched to the app shell first, so a slow/hung refresh left header + footer + tab bar with no content). A failed refresh still shows the app with its inline errors, never a blank page. Added an empty-page guard in boot(): if no section is visible after showView, it falls back to Home ('week'). No data is faked — sections still show their own "Loading…" / error states.
- 3. Past weeks From/To: both fields now share one explicit rule (block labels, width 100%, min-width 0, overflow hidden, same 10px 8px padding, 15px font, 12px gap, same border) so a track can never paint over its neighbour. Root cause: iOS Safari date inputs have a wide intrinsic width that ignores min-width: 0 at phone card widths. At 390px each field is (390-32-32-12)/2 = 157px, a full tap target. At 320px each would be 122px, below a readable iOS date input, so the pair stacks at max-width 360px only. This intentionally supersedes the earlier "side by side at every width" rule — equal and non-overlapping wins. Real-phone proving at 320px and 390px is still owed.
- 4. Home buttons: profile icon button and hero sync button are now primary brand blue #2f6bff with white icons and no glow/shadow (they were pale/light blue #eef4ff/#bfdbfe with a glow). Sync button keeps its 44px circular-arrow shape and size. Pale #bfdbfe stays the middle tier of 3-button rows only.
- 5. Hero kicker: "This week · " prefix removed; kicker shows only the date range, e.g. "Nov 1, 2026 (Sun–Sat)".
- 6. New-account hero: a sign-up with no explicitly set allowance no longer shows a figure — it shows a "Set Your Weekly Allowance" button (admin only; members see no figure and no button), and the Weekly allowance stat shows '—', progress bar 0%. The button opens Settings, where the allowance is set. Design: households are created with base_allowance_cents default 37500 ($375), so that column alone cannot distinguish "never set" from "set to $375". The client reads a new nullable households.allowance_set_at column when it exists; null = never set. If the column does not exist yet, the client falls back to the old behaviour (figure shown) — nothing breaks before the migration. The migration is PREPARED ONLY in supabase/feedback-allowance-set.sql (column + backfill of existing households to created_at, so the real household keeps its figure + a trigger stamping allowance_set_at whenever base_allowance_cents changes). It needs owner approval before any live apply. Do NOT apply it from a merge. The real household's allowance is unchanged by this branch.
- 7. Fill the page (Home, Your Household, sign-in, all views): main now stretches to at least the viewport height minus the header as a flex column, #view-app stretches with it, and the footer sits at the bottom of main (margin-top: auto), just above the tab-bar clearance, instead of floating mid-page. Cards keep their natural height — nothing is stretched absurdly on phone. Trade-off, stated plainly: on short pages (e.g. a new account on iPad) the empty space is not eliminated, it moves below all content to the very bottom, instead of sitting between the last card and the footer. The sign-in card (#view-auth) stretches to fill main with its panel centred vertically — layout only, no flow/field/button change.
- 8/12/A. Title Case + Your Household card: "Your household" → "Your Household"; "Or join a household" → "Or Join A Household"; "Name your household" → "Name Your Household"; "Household name" → "Household Name"; "Choose your name" → "Choose Your Name"; buttons/labels in the flow likewise Title Cased (Sign In, Create Account, Forgot Password?, Join As Member, Create Household, Back To …). Every word capital, including small words, per the owner rule. Create button text is now just "Create Household" — the "(I am the owner / admin)" parentheses are removed entirely, because the subtitle already says create as admin. The "Or Join A Household" section now sits 28px below the Create button (was claustrophobically close). The subtitle sentence ("Create a household as admin, or join one with an invite code.") is kept in sentence case because it is a sentence, not a headline — flagged so the owner can correct this if they wanted every word capital there too.
- 9. Household name REQUIRED: the sentence "Optional — leave it blank to keep the default." is removed, and a blank name is refused client-side ("Enter a household name.", focus on the field) before any RPC call — there is no default fallback any more. The RPC always passes { p_name: name }.
- 10. Repo SQL fix (file only): supabase/merged-audit-kind-constraint.sql first statement corrected from the invalid "drop constraint if exists transactions_kind_check on transactions;" to "alter table transactions drop constraint if exists transactions_kind_check;". Live DB already has the corrected version (applied Nov 4, ~10:36 PM) — do NOT re-apply this file live.
- 11/C. Red errors, platform-wide: error toasts (.toast.error, i.e. every showToast(..., true)) are now red #dc2626 with white text, and inline .result.error boxes in the live theme are now soft-red (#fef2f2 / #dc2626) instead of being washed out to blue by the .result override. Success/info toasts stay brand blue #2f6bff. This overrides the Nov 2 "no red toasts ever" rule for genuine errors only. Limitation, stated plainly: plain .result boxes are shared by success and error messages in the same element, so they cannot all go red without turning successes red too — only messages marked .error, and error toasts, go red. The two owner-circled cases are converted outright (see below).
- 11. Join error: a join failure is now a red pop-up with exactly "Check the invite code and try again" and nothing else. The old blue inline sentence ("Join failed. Check the invite code and try again, or ask the household owner to share it again from Settings.") is gone.
- B/D. Sign-in error: a sign-in failure is now a red pop-up reading "Incorrect email or password". Wording chosen: Supabase returns a generic invalid-credentials error, so this wording deliberately does NOT claim which field is wrong — it is the safe form of the owner's "incorrect email or invalid password, something like that" request. (An earlier pass in this branch kept the long generic text in the red pop-up; the owner clarification superseded that, and the final wording is the short one.)
- E. Password eye icon: it sat low because the password input kept its 14px bottom margin inside the relatively positioned row, so 50% of the row was below the input's centre. The input's margin is now 0 in that row, so top: 50% + translateY(-50%) truly centres the icon on the input.
- F. Forgot Password: now an underlined brand-blue link with the button's full tap area, no longer grey. Hex chosen: #2f6bff (brand blue), NOT the owner's suggested light blue #60a5fa — #60a5fa is about 2.5:1 on white and fails for link text, while #2f6bff is about 4.6:1 and readable. If the owner prefers the light blue for branding despite the contrast, say so and it can be swapped.
- Removed sentences (this branch): "Loading your budget…" (replaced by "Loading Your Household"); "This week · " hero prefix (removed); "Optional — leave it blank to keep the default." (removed); the old join-failure sentence (replaced by the exact red pop-up text); the old long sign-in failure sentence (replaced by "Incorrect email or password"). No other sentences removed.
- Old tests updated to the NEW approved behaviour (not weakened): pin assertions v37/v47 → v38/v48 everywhere; household-name-step optional → required assertions; loading-indicators budget wording → household wording; ux-review-fix kicker + boot-order + sign-in recovery assertions → new wording/order; native-style-live toast rule → red error; declutter/popup-padding history gap 16px → 12px and side-by-side rule → side-by-side ≥361px, stacked ≤360px; auth-card-cleanup Forgot/Sign In Title Case; weekly-left name-step Title Case + fail() error class; footer-gap regex now allows the new main min-height/flex declarations (bottom padding still 0, gap arithmetic unchanged); household-name-step blank-name test now asserts refusal instead of no-arg fallback.
- NOT built, and why: live DB apply of supabase/feedback-allowance-set.sql (prepared only — needs owner approval); real-phone proving for every item (320px/390px history fields, iPad Home fill, sign-in fill on iPad, loading full-screen on a real phone, eye-icon centering on a real phone); synthetic-household proof of the new-account hero (new sign-up → Set button → set allowance → figure appears, with the trigger stamping); the Your Household subtitle sentence-case choice (owner to confirm, see above); the #60a5fa vs #2f6bff Forgot Password choice (owner to confirm, see above). NOT changed: any financial rule, any figure, any Edge Function, the logo (header O / loading mark stay the circular picture — the app-icon recolor test is separate and rejected, not in this branch), top-blue hero (still open), previously-connected visibility (still open).
