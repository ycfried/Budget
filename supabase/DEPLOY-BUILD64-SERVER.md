# DEPLOY — Build 64 server-side audit fixes (STAGE)

Branch: `ios-clone-testflight` (work uncommitted at time of writing;
nothing here is live until the steps below are done). Owner said
"Push it live" for the combined build 64 — this file is the server
half of that push. The app (Swift) half deploys via the TestFlight
upload workflow; the server half deploys as below. Do NOT deploy
anything from this file by the app upload.

## A. SQL — owner pastes, in this order

Paste each file via GitHub **"Copy raw contents"** (any other paste
loses line breaks and silently no-ops). Each file is self-contained
and idempotent — re-pasting is safe. Run each file's verification
steps (in the file's comments) after pasting it.

| # | File | Finding | What it lands |
|---|------|---------|---------------|
| 1 | `supabase/refund-linking.sql` | F-4 | Defines `repoint_refund_links` (was called but never existed) + the arrival-direction rule in `auto_link_refund`: a refund whose purchase was excluded follows the purchase into exclusion instead of netting against the current week. **First** — files 2–3 and plaid-sync depend on it. |
| 2 | `supabase/n4-pre-exclusion-state.sql` | F-4, F-14 | `exclude_transaction`: linked-refund guard (refuse, or re-point to a surviving same-hash purchase) + `restore_transaction` restores refunds excluded with their purchase. `exclude_transaction` now callable by service_role (plaid-sync). |
| 3 | `supabase/cleanup-same-hash-duplicates.sql` | F-3 | Cleanup restricted to real duplicates only (bank-anchored or same-alert-twice); two Plaid rows with the same hash are two real purchases and stay. Exclusions snapshot `pre_exclusion_state` so a normal restore works. |
| 4 | `supabase/delete-transaction-rpc.sql` | F-2 | `guard_transaction_delete()` + `BEFORE DELETE` trigger: reverses any active linked charity accrual; refuses the delete when a live refund links either way. |
| 5 | `supabase/04-admin-rpcs.sql` | F-2 (mirror), F-32 | Same delete guard, mirrored per this file's own rule (§5). §6 `set_base_allowance`: NULL = unset (stores NULL; $375 default applies), 0 = $0; `ALTER TABLE ... DROP NOT NULL` included. |
| 6 | `supabase/live-admin-rpcs.sql` | F-32 | Live-applied copy of `set_base_allowance` with the same NULL/0 rule. Keep in sync with file 5, §6. |
| 7 | `supabase/charity-auto-accrue.sql` | F-10 | Documentation only (no behaviour change): the rate locks at accrual time; household rate changes are future-only; nothing restates existing accruals. Paste it so the live file carries the rule. |
| 8 | `supabase/reclassify-income-accrual.sql` | F-5, F-10 | v5 trigger: fires on `UPDATE OF kind, excluded, amount_cents, date`; an amount/date correction re-derives the accrual at the ORIGINAL rate (e.g. $1,000 → $1,200 re-accrues $100 → $120 at 10%). Verification step 12 covers it. |
| 9 | `supabase/refund-classification-income-kind.sql` | F-31 | `reclassify_transaction` clears `original_purchase_id` when the new kind is not `refund`. The superseded copy in `05-transaction-mutation-rpcs.sql` is bannered never-apply — do NOT paste it. |
| 10 | `supabase/restored-source.sql` | F-12, F-15 | Still NOT applied live — pasting it IS the fix. `force_restore_transaction` already has the household-scoped admin check and refuses rows WITH a snapshot (routes them to `restore_transaction`); the file now documents that, adds a cross-household verification step, and adds `'chase_alert'` to the source check. |

Order matters only for 1 → 2/3 (the function must exist before its
callers run) and for 5 → 6 (same function, two copies — paste both).
If a paste fails part-way, re-paste that one file; nothing above
depends on a half-applied file.

## B. Edge Functions — focused cherry-pick PR to main (do NOT open yet)

`main` vs `ios-clone-testflight` diverged in `supabase/functions/`
(20 files). Cherry-pick exactly these 20 files into the PR — NOT a
wholesale merge. The build-58 files (marked ◆) are still NOT
deployed and ride in the same PR; the build-64 files (marked ★)
are the new changes in this push.

| File | Build-64 change in this push |
|------|------------------------------|
| `supabase/functions/_shared/canonical.ts` ★ | `EMAIL_SOURCES` gains `'chase_alert'` (F-15). All four copies byte-identical. |
| `supabase/functions/_shared/engine.mjs` ★ | F-1 owner refund rule (see below). Byte-identical to the other two engine copies. |
| `supabase/functions/_shared/gmail-parse.ts` ★ | F-15 Chase scaffold: `authResultsPassFor`, `buildChaseAlertQuery`, `parseChaseAlertText` (fail-closed, UNPROVEN). Byte-identical to the gmail-poll copy. |
| `supabase/functions/check-email-exists/index.ts` ◆ | Build-58 pending only. |
| `supabase/functions/compute-week/engine.mjs` ★ | F-1 (same as `_shared/engine.mjs`). |
| `supabase/functions/compute-week/index.ts` ★ | F-1 countable-refund netting (verified OR provisional); NULL household base → 37500 (F-32). |
| `supabase/functions/gmail-poll/canonical.ts` ★ | F-15 (same as `_shared/canonical.ts`). |
| `supabase/functions/gmail-poll/gmail-parse.ts` ★ | F-15 (same as `_shared/gmail-parse.ts`). |
| `supabase/functions/gmail-poll/index.ts` ★ | F-15 Chase dispatch + `CHASE_ALERTS_ENABLED = false` gate; F-19 member sync auth. |
| `supabase/functions/ingest-amex-alert/canonical.ts` ★ | F-15 (same as `_shared/canonical.ts`). |
| `supabase/functions/ingest-amex-alert/index.ts` ★ | F-15 comment only: Amex-only HMAC contract, Chase deliberately NOT added here. |
| `supabase/functions/plaid-sync/canonical.ts` ★ | F-15 (same as `_shared/canonical.ts`). |
| `supabase/functions/plaid-sync/index.ts` ★ | F-14 removed[] via `exclude_transaction`; F-19 member sync auth. |
| `supabase/functions/plaid-webhook/index.ts` ◆ | Build-58 pending only. |
| `supabase/functions/push-notify/apns.ts` ◆ | Build-58 pending only. |
| `supabase/functions/push-notify/index.ts` ◆ | Build-58 pending only. |
| `supabase/functions/register-push-token/index.ts` ◆ | Build-58 pending only. |
| `supabase/functions/week-close/engine.mjs` ★ | F-1 (same as `_shared/engine.mjs`). |
| `supabase/functions/week-close/index.ts` ★ | F-1 countable-refund netting (open weeks); F-13 fallback upsert keeps `debt_payment_cents`; NULL household base → 37500 (F-32). |
| `supabase/functions/week-close/restoration.mjs` ◆ | Build-58 pending only. |

**F-19 deploys in this PR, not in the app upload.** Until it
deploys, members tapping sync still get a 403 (the app shows a
plain message for that — another stream's file). Admins are
unaffected.

**Deploy order inside the PR:** SQL first (section A), then the
Edge Functions — plaid-sync's F-14 path calls `exclude_transaction`
(F-14 SQL allowance) and `repoint_refund_links` (F-4 SQL), so a
deployed plaid-sync against un-applied SQL would fail those calls
(best-effort logged, sync continues, but removals would not
exclude).

## C. What each finding means (server side)

- **F-1 — owner refund rule (DONE).** A refund restores to the
  classification of the charge it links to (spending charge →
  reduces the week's spending; fund charge → back to the fund).
  A PENDING refund counts RIGHT AWAY, like a pending charge, and
  auto-reverses if it disappears. No splits: Cover with Savings is
  always the whole charge, so `linkedRefundNormalPortionCents`
  (fund-first) is MOOT — kept for its pinning test, documented
  moot; the live helper is `linkedRefundSpendingPortionCents`.
  Shared fixture: `supabase/tests/f1-owner-refund-rule.test.mjs`
  (week 2026-11-15, net $115.00) — the Swift list side must match
  this fixture (another stream's file). **Boundary, not done:**
  a pending refund on a LOCKED-week purchase still restores only
  once it posts — `restoration.mjs` is posted-only by design, and
  posting a provisional restoration that might need reversing was
  judged out of scope. Flag to the owner, do not silently extend.
- **F-2 — delete guard (DONE).** Trigger-only enforcement, so
  direct SQL deletes are covered too. The `charity_income` FK
  stays `ON DELETE SET NULL` (a conditional RESTRICT does not
  exist in Postgres; unconditional RESTRICT would also block
  deletes of rows whose accrual was already reversed).
- **F-3 — same-hash cleanup (DONE, SQL side).** List-collapse side
  (only collapse when at least one row is an email-alert row) is
  another stream's Swift file.
- **F-4 — linked-refund guard + arrival rule (DONE).**
- **F-5 + F-10 — charity re-derive at original rate (DONE).**
  Ingest-side note: `accrue_charity_for_transaction` still
  requires `state='verified'`; provisional income accrues via the
  trigger on reclassification/restore. Do not change ingest call
  sites on this basis.
- **F-12 — restored-source (DONE, as documented).** The audit's
  "no household check" does not match the file as written — the
  check and the snapshot guard were already there. The fix is
  pasting the file (it was never applied) + the verification step.
- **F-13 — week-close fallback keeps debt_payment_cents (DONE).**
  Pinned by `supabase/tests/week-close-upsert.test.mjs`.
- **F-14 — Plaid removed[] via exclude_transaction (DONE).**
  A locked-week removal is left live and logged (owner-approved
  one-off repair, never a silent sync write). The refund is
  unlinked BEFORE the RPC call, or the F-4 guard would refuse a
  genuine bank reversal.
- **F-15 — Chase scaffold (DONE, gated OFF).** Parser + query +
  dispatch exist and are wired behind the same dedupe-hash guard,
  but `CHASE_ALERTS_ENABLED = false` in gmail-poll. **UNPROVEN:**
  no real Chase alert sample exists; the parser's patterns are
  best-guess shapes. Flip the gate ONLY after a real redacted
  Chase alert is verified against `parseChaseAlertText` (see
  `supabase/tests/gmail-chase-scaffold.test.mjs`). Amex is
  untouched. Capital One: not started.
- **F-19 — member sync auth (DONE).** Any household member may
  trigger a manual sync (plaid-sync + gmail-poll); non-members
  still 403. Admin-only mutations untouched.
- **F-24 — simulator split (NOT DONE — comment only).** The YAML
  now carries an "F-24 SPLIT — PENDING" comment: the script
  (`ios-clone/scripts/macos_simulator_test.sh`) needs a leg
  selector (`ONBUDGET_SIMULATOR_LEG=iphone|ipad`) before two jobs
  can exist without each running the whole script. The upload
  workflow also gates on this run for the commit SHA.
- **F-25 — canonical test household (DONE).**
  `supabase/TEST-HOUSEHOLDS.md`: Proof Household 2 (invite
  `Q6GFME`) is canonical; Goldstein (`XPKVGJ`,
  `95e1aff3-f664-41bb-be09-70e00f75a141`) is noted for retirement.
  Nothing deleted. Proof Household 2's UUID is not recorded in
  the repo — record it when next read from the dashboard.
- **F-26 — merchant-rules test (DONE).** One failing test pinned
  pre-build-34 `prefix` semantics; rewritten to pin the current
  `includes` behaviour. 21 pass, 0 fail.
- **F-30 — polling discipline (DONE, half).** `CONTRIBUTING.md`
  now holds it (trigger commits, sparse 5-min polls, NEVER
  `gh run watch`). The upload-workflow comment half is outside
  the owned files — still owed.
- **F-31 — reclassify clears refund link (DONE).**
- **F-32 — base allowance NULL vs $0 (DONE, server side).**
  Swift side follow-up: `setBaseAllowance` takes a non-optional
  `Int`, so the app cannot send NULL yet; new-household never-set
  also needs create-household inserts to pass NULL
  (`feedback-allowance-set.sql`'s `allowance_set_at` is the
  existing mechanism). Until then, NULL is reachable only via SQL.

## D. Tests

New: `supabase/tests/f1-owner-refund-rule.test.mjs` (5 tests),
`supabase/tests/week-close-upsert.test.mjs` (2 tests),
`supabase/tests/gmail-chase-scaffold.test.mjs` (5 tests).
Updated pins: `supabase/tests/merchant-rules.test.mjs`,
`supabase/tests/pending-totals.test.mjs`, `test/engine.test.mjs`,
`test/gmail.test.mjs`, `test/charity-auto-accrue.test.mjs`
(the last two moved the build-44 "no Chase" pins to the F-15
scaffold — the old pins encoded a decision F-15 overrides).

Full run at handoff: **247 pass, 1 fail** across
`test/engine.test.mjs test/p2-engine.test.mjs
test/math-fixes-n1-n2.test.mjs test/refund-classification-fix.test.mjs
test/p2-functions.test.mjs test/gmail.test.mjs
test/charity-auto-accrue.test.mjs supabase/tests/*.mjs`.
The 1 failure is **pre-existing on the base commit, unrelated to
this work**: `test/refund-classification-fix.test.mjs` — "classifier:
plaid-sync passes the account type through" pins a 5-arg
`upsertPlaidTx(...)` call shape; the live call at
`plaid-sync/index.ts:629` has a 6th argument (`merchantRules`).
Not fixed here (out of scope — F-26 covers merchant-rules only).

## E. Scope notes (disclose, do not hide)

- Repo-root `engine.mjs` and `test/engine.test.mjs` are outside
  the assigned owned list, but F-1's repo convention (P2-M1
  byte-identity across the three engine copies) forced editing the
  canonical root engine and its pinning test. Mechanical sync/pin
  updates for F-1 only.
- `test/gmail.test.mjs` and `test/charity-auto-accrue.test.mjs`
  are likewise root test files, updated only to move the pins
  F-15 overrides.
- No file outside the owned list was otherwise touched. No commit,
  no push, no PR, no deploy, no live-household contact. The dirty
  Swift files in `git status` pre-date this work (other streams).
