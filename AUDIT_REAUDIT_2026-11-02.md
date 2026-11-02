# OnBudget — Independent Re-Audit (read-only)

**Date:** November 2, 2026 (evening, EST)
**Audited tree:** `~/workspace/household-budget/`, git main at `ebb8c99`
("Gmail poll: match Large Purchase only in the subject")
**Baseline:** the FINAL spec, Revised iOS Spec v2-2
(`Household_Budget_Spec_FINAL.pdf`), which wins over all other docs.
**Prior audit:** `AUDIT_FULL.md` (Nov 1, 2026 — 15 P0, 50 P1, 30 P2,
verdict NOT public-ready at that time).
**Method:** code-and-docs review only, plus the verified live evidence
supplied in the audit brief (taken as established, not re-verified here).
No live database writes, no deploys, no state-changing function calls,
no fabricated test data, no secrets. Local test suites were run
(read-only execution): `engine.test.mjs` 27 pass / 0 fail,
`gmail.test.mjs` 14 pass / 0 fail (41 total, 0 fail).

## 1. Verdict

**NOT public-ready yet — but the reason has changed.**

The Nov 1 verdict rested on untrustworthy money figures and an open
front door. Both are resolved **in code** as of this tree: all 15 P0s
are closed (P0-1 re-scoped by an explicit owner decision — see below),
the refund-credit model is gone, refund restoration is built and unit
tested, direct-write holes are revoked, and the payment/cash-back
classification is in place. The current household (owner + spouse) is
safe to keep using: its money math no longer rests on the deleted
model, and its sync path is proven working after the grants fix.

What still blocks opening the app to strangers is a shorter, different
list — no longer wrong money, but unproven operations and one
authorization inconsistency:

1. **Account deletion is deployed but never throwaway-tested** (P1-33).
   A delete path that half-works is a data-integrity and privacy risk.
   It must be proven on a throwaway account before any public user can
   rely on it.
2. **Backups are documented, never run, never restore-tested** (P1-35).
   There is no proven recovery path for the live database.
3. **Bank link/exchange are still member-gated, while sync, disconnect,
   and webhook registration are admin-only** (new finding N1). A member
   can attach a new bank to the shared household. For the current
   two-person household this is low-risk, but it is an authorization
   inconsistency that needs an owner decision (make link admin-only, or
   document member-link as intended) before public launch.
4. **Automatic sync is unproven end to end.** Webhook-triggered sync
   code is deployed and probed, but no real purchase has proven the
   webhook path, and the hourly safety-net cron SQL has never been run.
   Manual sync is proven; "automatic" is still a promise, not a fact.

Everything in §5 (unproven gaps) must also be closed or explicitly
accepted before a public launch claim. None of it is papered over
below: a claim without evidence is listed as a gap, not a pass.

### What this audit could NOT verify (explicitly out of coverage)

- Live database row-level state (no live DB access in this pass).
- Deployed-vs-repo parity for any function whose dashboard state was
  not supplied in the brief (only the functions with supplied
  timestamps/probes are treated as proven live).
- 390px / 820px layout (no narrow-viewport tooling in this pass).
- The real Gmail charge-alert format (no real charge alert has been
  seen; the only poll matches so far were statement emails).
- Any behavior that requires a real bank purchase, a real refund, a
  real held refund, or a real week-close on live data after the fixes.

## 2. P0-by-P0 closure table

| ID | Prior finding | Status | Evidence in this tree (code) + supplied live evidence |
|----|---------------|--------|--------------------------------------------------------|
| P0-1 | Stranger self-registers + joins via published household UUID | **Closed (re-scoped by owner decision)** | `supabase/01-invite-codes.sql`: `join_household_by_code` is code-only; the legacy-UUID branch was removed (commit `105eaf4`); live removal verified via `pg_get_functiondef` per supplied evidence. `live.js` join handler calls the RPC only. HANDOFF contains zero occurrences of the old UUID. Join refuses callers already in a household and never mints admin. **Re-scope note:** the owner declined the original "disable sign-ups" half, so sign-ups stay ON. The closure therefore rests on the code-only join plus code secrecy: a stranger can create an account but joins nothing and sees nothing. Residual: 6-character reusable, non-expiring codes with no attempt throttling in the function (see N13, P2 advisory). |
| P0-2 | Member mints fund money / forges week closes by direct writes | **Closed** | `supabase/02-rls-hardening.sql` revokes INSERT/UPDATE on `week_closes`, `surplus_releases`, `fund_ledger` from `authenticated`. `live.js` only SELECTs those tables. Writes go through the service-role week-close function and admin-checked RPCs. |
| P0-3 | Member edits / excludes / fabricates transactions directly | **Closed** | `02` revokes transactions UPDATE from `authenticated`; the insert policy allows only `source IN ('manual','csv')` AND `state='provisional'`; both `live.js` insert sites comply. Exclude/restore/reclassify go through admin-only RPCs in `05-transaction-mutation-rpcs.sql` with same-household + role checks and audit rows. |
| P0-4 | Plaid token ciphertext readable by any member | **Closed** | `03-plaid-vault.sql` revokes `plaid_items` SELECT from `authenticated`, drops the member read policy, and exposes `plaid_items_public` (no ciphertext column); `live.js` reads the view. `get_plaid_ciphertext` EXECUTE is revoked from `authenticated`/`anon`/`public` and granted to `service_role` only (also in `07-service-rpc-access.sql`). Residual: the function body still contains a membership branch that is currently unreachable — see N2. |
| P0-5 | Cross-household write via fund-request linkage | **Closed** | `02` policy + `validate_fund_request_txn` trigger enforce transaction-household equality and pending-only creation for every writer, including SECURITY DEFINER paths; `approve_and_allocate` (`04`) re-checks the link and refuses mismatches. Documented caveat: a pre-existing mismatched row can be closed but can never gain a new mismatched link. |
| P0-6 | Stored XSS via showSheet | **Closed** | `live.js` `showSheet` escapes every interpolated value with `esc()` (title, message, labels, values, option labels/values). List rendering escapes merchant names; `bankLogoHtml` uses a fixed institution→domain map plus an escaped initial. No unescaped caller value into `innerHTML` was found in the reviewed paths. |
| P0-7 | Dashboard available adds a nonexistent refund-credit balance | **Closed** | `engine.mjs`: `available = baseAvailable + T − C` (FINAL A2, no credit term). `compute-week` returns exactly the 8-field shape (`week_start`, `base_available_cents`, `temp_cents`, `carried_debt_cents`, `charges_cents`, `available_cents`, `week_locked`, `pending_refund_excluded_cents`). Hero stats are Allowance / Spent / Carried over / Outgoing debt; no Credit stat. |
| P0-8 | Refund restoration entirely unbuilt | **Closed in code + unit tests; live-row proof pending** | `supabase/functions/week-close/restoration.mjs` + the week-close restoration phase + `restoration_entries` / `held_refunds` tables + `resolve_held_refund`. Posted-only (`verified` refunds), incremental (existing-entry map, never double-restores), fund-purchase refunds credit the fund, shortfall-first application of restoration credits, excess → held queue. Horizon is purchase week through the LAST COMPLETED week, never the in-progress current week (owner decision 5; see N10 on the spec wording). Engine tests pass, including the FINAL A4 acceptance cases. No live restoration has occurred yet — that proof awaits a real locked-week refund. |
| P0-9 | Late charge in a locked week counted NOWHERE | **Closed in code** | Week-close precomputes locked-week late charges as total-minus-stored and freezes them exactly once in `late_adjustment_cents`; compute-week applies the same rule dynamically. Unposted late amounts are reported as `pending_late_adjustment_cents`, never silently dropped. |
| P0-10 | Every negative amount classified `refund` (cash-back, payments) | **Closed in code + backfill run** | `plaid-sync` classifies `payment` (Plaid credit-card-payment category or MOBILE PAYMENT / PAYMENT - THANK YOU / CARD PAYMENT) and `cashback` (CASH BACK / CASHBACK / REWARD); engine excludes both kinds from week math. Transaction kinds include `charge \| refund \| fund_charge \| payment \| cashback`. Supplied live evidence: the backfill reclassified 9 rows totalling −$3,023.00 from `refund` to `payment` in one atomic transaction with a 9-row CSV backup; locked-week figures untouched; household total still 119 transactions. |
| P0-11 | Week-close rewrites all historical weeks with current allowance | **Closed in code** | `week_closes` stores per-week `base_allowance_cents` + `temp_increase_cents` snapshots; recompute uses a stored snapshot when present; compute-week's snapshot-wins rule means a later allowance change never rewrites a closed week. |
| P0-12 | Pending refunds counted immediately | **Closed in code** | `engine.isExcludedFromMath` excludes provisional refunds; compute-week reports them separately as `pending_refund_excluded_cents` (display only). Provisional charges still count, which is the intended provisional behavior. |
| P0-13 | Pending→posted linking by fragile hash | **Closed in code** | `plaid-sync` links via `pending_transaction_id` (matching `external_id` or `plaid_pending_transaction_id`), `dedupe-fix.sql` adds partial unique indexes, canonical-hash dedupe allows identical purchases to coexist. Pagination runs to `has_more=false` with a 200-page safety cap that logs truncation. |
| P0-14 | Empty allowance zeroes the budget; empty savings writes false $0 | **Closed** | `parseDollarsStrict` (empty / blank / non-numeric → null, never 0) is used at every money input in `live.js`; the old loose parser's definition remains but has no money-path call sites. Allowance changes require a confirmation sheet showing old → new. Savings movements reject null amounts. |
| P0-15 | Week-close shortfall write always fails; writes unchecked | **Closed** | Week-close checks every write (`check` / throw, including upsert retries) and fails loudly instead of returning success counts. The shortfall is persisted via the `update_fund_shortfall` RPC (checked, only when changed), not a direct `households` UPDATE. Supplied live evidence: the service-role grants fix (SELECT/INSERT/UPDATE/DELETE on all public tables + sequences + default privileges) turned week-close from 500 to 200, and the owner confirmed sync works afterward. True multi-table atomicity is still conditional-claim, not a DB transaction — see N9. |

## 3. P1 / P2 classes touching money math, auth, or data integrity

Dispositions for the classes in scope. "Code" means verified in this
tree; "live" means supplied live evidence or a live behavior the brief
establishes. Items outside money/auth/integrity that were not
re-checked are listed at the end of this section as carried, not passed.

### P1

| ID | Status | Note |
|----|--------|------|
| P1-1 Gmail pipeline disconnected | **Partial** | OAuth path is live, connected, and polled (see §5). Parser-vs-real-alert unproven; Apps Script Plan B still needs the owner paste + per-household secret + a stored:true proof; old shared ingest secret removal is pending that proof. |
| P1-2 Ingest legacy key / no replay protection | **Closed in code; end-to-end unproven** | `ingest-amex-alert` uses per-household HMAC (`x-budget-signature`), nonce + 10-minute timestamp replay protection, and DKIM+SPF both-required (fail-closed to quarantine). The Apps Script sender side is the unproven half. |
| P1-3 `removed[]` never handled | **Closed in code** | `plaid-sync` marks removed rows `state='reversed'` + `excluded=true`, never deletes. |
| P1-4 Dedupe schemes incompatible | **Closed in code** | Canonical hash + partial unique indexes; identical purchases coexist. |
| P1-5 Compute-week trusts client D/T; no scheduled close | **Partial** | D/T are derived server-side by compute-week; the scheduled close is the unrun hourly cron (§5). |
| P1-6 Pending window skipped on late close | **Closed in code** | Release date = actual close date + 7 days, not week-start + 14. |
| P1-7 Surplus increase after release lost | **Closed in code** | Recompute releases the delta net of shortfall. |
| P1-8 Approve more than requested; split remainder lost | **Closed in code** | Over-approval raises (`amount exceeds requested amount`); partial approval records `status='split'` + `remainder_cents`. |
| P1-9 Concurrent approvals / week-closes | **Partial** | Approvals serialize (`FOR UPDATE` + pending-only guard); releases use a conditional claim (status=pending, row count checked) with best-effort revert. True atomicity still needs a DB transaction — see N9. |
| P1-10 Old approve RPC without money movement | **Closed in code** | `approve_fund_request` is now a delegating wrapper that calls `approve_and_allocate` with the full requested amount; the money-less body is gone. |
| P1-11 Decline writes false audit row | **Closed in code** | `08-decline-fix.sql` checks FOUND after the conditional UPDATE and raises `request already decided` before any audit insert. (A stale comment in `04` still says this "remains open"; the file is outdated, the code is not.) |
| P1-12 Audit forgery / pre-approved requests / sync suppression | **Partial** | Webhook UPDATE revoked; audit actor/actor_name forced by trigger; fund-request creation is pending-only by policy + trigger. Residuals: audit action/detail text is still member-writable (N5); see also N3. |
| P1-13 `log_webhook_event` granted to anon, no auth check | **Partial** | Anon grant revoked. Authenticated grant deliberately left (flagged as owed in `02` itself) — see N3. Dedupe-hash collision (same item/code/count for distinct events) is unaddressed. |
| P1-14 Link/exchange/sync not admin-gated | **Partial** | Sync (403 for non-admin members), disconnect, and webhook-register are admin-only. Link and exchange remain membership-only — see N1. |
| P1-15 Cursor never loaded; pagination cap | **Closed in code** | Cursor loaded from `plaid_items.sync_cursor`, persisted only after error-free sequences, moves forward only; 200-page cap logs truncation. |
| P1-16 Ciphertext / cursor RPCs member-granted | **Closed** | Both RPCs are service-role-only in grants; `live.js` uses the public view. Residual branch in the function body — see N2. |
| P1-17 Bank state per-device, no account list/disconnect | **Closed in code** | Accounts render from server truth (`plaid_items_public`, `plaid_accounts`); `plaid-disconnect` exists and is admin-only. Live disconnect is untested — note, not a failure. |
| P1-18 Sync "success" with zero accounts | **Closed** | The message now states the connected-account count, so a zero-account result reads as information, not success theater; the underlying cause (missing grants) is fixed and proven. |
| P1-19 "Automatic sync" actually sync-on-reopen | **Partial** | Webhook-triggered code is deployed and probed; the webhook proof and the hourly cron are both open (§5). |
| P1-20 Connect failure modes leave stale/no messages | **Partial** | Callback outcomes now surface via redirect + toast (connected/failed). Start-path failures still show generic messages only. |
| P1-21 Fund summary incomplete | **Closed in code** | Summary renders Available, Pending, Released total, Spent, Owed back (shortfall), Held for review; read failures are error states, not soft notes. |
| P1-22 Read failures masquerade as empty | **Closed in code** | Bank, fund, savings, and week-history reads all render explicit error states on failure. |
| P1-23 Totals include excluded; Reversed renders Posted | **Closed in code** | Totals exclude excluded rows and say so; `state='reversed'` renders "Reversed". |
| P1-24 Restore invents a state; reasons optional | **Partial** | Blank reasons are allowed per owner decision 4 (settled, not a gap). Restore state is now a documented date rule (before today → posted, today or later → pending) rather than an arbitrary invention — but it can still promote a pending refund to posted across midnight without bank confirmation; see N4. |
| P1-25 Second household / arbitrary boot pick | **Closed in code** | Join and create both refuse callers already in a household. |
| P1-26 Temporary increases invisible / irreversible | **Partial** | Temporary amounts count in week math (T) and the add flow confirms via toast + refresh; a dedicated on-screen temp line was not verified in this pass. |
| P1-27 Savings is one number, not four | **Closed in code + live SQL** | Display sums transfer_in / withdrawal / interest+adjustment; `record_savings_entry` RPC + Savings movement form exist; SQL applied and verified live per supplied evidence. |
| P1-28 No week-history display | **Closed in code** | Read-only History tab renders from `week_closes` + `surplus_releases`; the client never recomputes a week. |
| P1-29 No live CSV import | **Partial** | Import UI exists above the purchases list with preview-then-confirm, `source='csv'`, `state='provisional'`. Live end-to-end import is listed as still open in the brief and was not proven here. |
| P1-32 No password-reset flow | **Closed in code** | `reset.html` + change-password flow enforce minimum length 8 (raised from 6 per decision 14). The live reset flow itself is untested — note, not a failure. |
| P1-33 No account deletion | **OPEN** | `delete-account` is declared in `config.toml` and deployed, but has never been throwaway-tested. This is a launch blocker (§1). |
| P1-34 Public front door is the demo | **Closed in code** | Landing links to sign-in only; no demo link from the landing page (owner decision 12). The demo remains reachable by direct URL (see P2-14). |
| P1-35 No backups, no restore test | **OPEN** | `docs/BACKUP.md` procedure exists; it has never been run as a whole and no restore has been tested. This is a launch blocker (§1). |
| P1-36 Share household ID shows bare UUID | **Closed in code** | Share now shows the 6-character invite code with a copy action; no UUID is displayed. |
| P1-37 Profile menu usable before sign-in | **Closed in code** | Menu actions guard on a signed-in household and show "Sign in first" otherwise. |
| P1-38 Fund queue buried, no notification | **Partial** | Queue renders in its own card; no notification mechanism exists. Acceptable for a two-person household; not a launch blocker. |
| P1-40 Hero progress misleads with debt | **Closed** | Hero is debt-aware ("carried debt already came off the top", outgoing-debt tile) per code and owner screenshots. |
| P1-41 Stat labels inconsistent | **Closed** | Four tiles: Allowance, Spent, Carried over, Outgoing debt. |
| P1-42 Messages persist across tabs | **Closed in code** | Toast clears on tab switch and auto-dismisses after 4 seconds; all toasts are brand blue (no red), offset 120px clear of the tab bar. |
| P1-43 Sheet promise leak on double-tap | **Residual P2** | A `settled` guard prevents double-resolve within one sheet, but opening a second sheet removes the first overlay without settling its promise, so the first caller awaits forever. Money-safe (approval RPCs re-check pending status), but the awaited action never completes or refreshes. See N7. |
| P1-44 "Spent" breakdown sums all history | **Partial** | Hero Spent is week-scoped from compute-week. A separate breakdown panel was not re-checked in this pass. |
| P1-45 Warm theme leaks into live | **Closed in effect** | Live theme is blue/white; amber survives only as a semantic warning tint (Excluded/Pending pills), which is standard. The stale warm-palette comment at the top of `styles.css` is doc drift (P2-16 class). |
| P1-46 Shared service worker intercepts live | **Partial** | `live.html` never registers the worker, so a live-only user never gets it, and its fetch handler is network-first. Residual: the worker file lives at the site root and registers from the demo (`app.js`); after any demo visit it can claim live pages (same origin), and its offline fallback serves the landing page for a failed live fetch. |
| P1-47 HANDOFF contradictory / false stamp | **Partial** | The published UUID is scrubbed (zero occurrences) and the invite-code note is corrected. The full HANDOFF rewrite is still owed and the document is not yet trustworthy as a whole. |
| P1-49 Input validation gaps | **Closed for money inputs** | Strict parsing at every money input (see P0-14). Non-money inputs were not exhaustively checked. |
| P1-50 Raw server error text shown to users | **Closed** | No `error.message` is passed to user toasts/alerts in the reviewed code; failures show generic messages and log to console. |

### P1/P2 items NOT re-checked in this pass (carried, not passed)

P1-39 (search/filter state), P1-48 (keyboard/focus accessibility),
P2-15 (390px tap targets — not verifiable here), P2-17 (muted-text
contrast — unmeasured), P2-18 (two meanings of "Restore"),
P2-19 (wording consistency), P2-21 (audit display of free text),
P2-24 (remaining auth UX gaps), P2-25 (form feedback beyond toasts),
P2-26 (manual-entry limitations), P2-29 (week-breakdown panel state).
None of these touch money math, auth, or data integrity as scoped.

### P2 dispositions (checked subset)

- **Closed:** P2-7 (temp increases use the current NY Sunday; no
  arbitrary date), P2-8 (`isWeekLocked` 28-day window — confirmed by
  the spec itself: "a week stays open for 28 days after it ends"),
  P2-9 (`fund_charge` is now a live, admin-gated kind via reclassify,
  not a dead dangerous one), P2-12 (empty-household week-close returns
  fund/shortfall figures, no misreport), P2-13 (temp-week computation
  is server-consistent), P2-23 (`Math.round` on parsed amounts),
  P2-27 (recent-purchase tap jumps to Purchases).
- **Partial:** P2-14 (demo unlinked from landing but reachable by
  direct URL and explicitly fake), P2-16 (stale comments found:
  `04`'s P1-11 note, the gmail deploy note claiming the shared path
  does not exist when it does, the warm-palette header),
  P2-20 (cache-busting done — styles v9, live.js v5; the `hb-view`
  localStorage key is unscoped, low risk on a single-app origin).
- **Open (minor):** P2-5 (bootstrap-household still declared in
  `config.toml` and deployed, unused — remove in cleanup), P2-6 (CORS
  `*` on every function — auth still enforced per function, so this
  is a design note, not a hole), P2-10 (latent: a legacy row with
  `state='excluded'` but `excluded=false` would still count, because
  `isExcludedFromMath` consults the flag; all current writers set
  both), P2-11 (no audit row seen for late-reduction adjustments),
  P2-22 (one wasted tap at exact load-more multiples), P2-28
  (override with a blank reason yields a bare "Override:" note).

## 4. NEW findings vs the FINAL spec (this pass)

Severity is judged against public launch. None of these is a wrong-
money P0; N1 is the only one that changes an authorization decision.

### N1 (P1) — Bank link and exchange are still member-gated

`plaid-link` and `plaid-exchange` check membership only (403 for
non-members). Sync, disconnect, and webhook registration are
admin-only. A member can therefore attach a new bank account whose
transactions enter shared week math, without admin approval. For the
current two-person household this is low-risk, but it is an
authorization inconsistency, and it is exactly what P1-14 flagged.
**Fix or decide before public launch:** either require admin in both
functions (matching sync/disconnect/register), or record an explicit
owner decision that member-link is intended behavior.

### N2 (P2) — `get_plaid_ciphertext` still contains a membership branch

`07-service-rpc-access.sql` re-creates the function with a
service-role path AND a membership path that returns the ciphertext to
any household member. The grants currently make that branch
unreachable (EXECUTE revoked for `authenticated`/`anon`/`public`,
granted to `service_role` only), so this is latent, not live. But any
future migration that re-grants EXECUTE to `authenticated` silently
reopens P0-4. **Fix:** delete the membership branch; the function
should serve the service role only.

### N3 (P1 residual) — `log_webhook_event` still executable by any authenticated user

`02-rls-hardening.sql` revoked the anon grant and explicitly flagged
the authenticated grant as owed work ("the parent should revoke the
authenticated grant too once plaid-webhook writes events through its
own verified service-role path"). That condition is now met:
`plaid-webhook` calls the RPC through its service-role client. The
authenticated grant should now be revoked. Impact is bounded (planted
rows do not trigger sync by themselves; sync looks up known items),
but an authenticated user can still write rows into the webhook log.
The dedupe-hash collision noted in the same file (same
item/code/count for distinct events) is likewise unaddressed.

### N4 (P1 residual) — Restore reconstructs state from the date, not from history

`restore_transaction` sets a restored row to posted if dated before
today (America/New_York) and pending if dated today or later, because
the schema stores no pre-exclusion state. The file flags this as an
ambiguity. The concrete risk: a refund excluded while pending, then
restored after midnight, becomes posted without any bank confirmation
— and a posted refund counts in week math / restoration while a
pending one does not. **Fix for full closure:** store the
pre-exclusion state at exclude time and restore to it. Until then,
admins should treat restores of refund rows with care.

### N5 (P2) — Audit rows: actor is forced, content is still member-writable

The `04` trigger forces `actor`/`actor_name` from the caller's JWT,
so a member can no longer impersonate another user — but a member can
still insert an audit row with arbitrary action/detail text. The file
documents this as owed work requiring an RPC write path for week-close
and the `live.js` audit helper. Attributed forgery is much weaker than
impersonation, but the audit log is not yet tamper-evident for content.

### N6 (P2) — Plaid webhook has no signature verification

`plaid-webhook` accepts unauthenticated POSTs (`verify_jwt=false`)
and there is no webhook secret in the design (per the brief, none
exists or is needed). An unauthenticated caller can plant
`webhook_events` rows and trigger best-effort sync attempts. Impact is
bounded: sync is idempotent and read-only, unknown items do not sync,
and the function still returns 200 either way. For a public app this
deserves either Plaid signature verification or an explicit
accepted-risk note; it is not a data-corruption path as built.

### N7 (P2) — Second sheet orphans the first sheet's promise

`showSheet` removes any existing overlay before building a new one,
but does not settle the removed sheet's promise. A rapid double-tap
that opens a second sheet strands the first caller in an await that
never resolves (no toast, no refresh for that action). Money-safe —
approval RPCs re-check pending status, so a retry cannot double-
approve — but the first action appears to hang. **Fix:** settle (or
reject) the orphaned promise when replacing the overlay.

### N8 (P2) — No UI surface for restoration entries or held refunds

The spec says a restoration entry "shows both calculations"
(restored surplus and debt reduction). Both are stored
(`restoration_entries` columns), and held excess is stored
(`held_refunds`) with an RPC release path — but no UI lists either.
An admin cannot review a held refund in the app; release is
RPC-callable only. This is a follow-up UI item, not a money error, but
it means the held queue is invisible until that screen exists.

### N9 (P2, accepted residual) — Week-close is not atomic

Week-close uses a conditional claim for releases plus loud failure and
best-effort revert, as the audit prescribed for Edge Functions — not a
database transaction. A crash mid-run can leave partial state, though
the design is re-runnable (total-minus-stored late charges, claim
checks, idempotent upserts). This is documented in the code, not
hidden. A future S1 RPC could make it atomic; until then, re-runs are
the recovery path, and any week-close failure should be re-run, not
hand-patched.

### N10 (P2, spec-reading note) — Restoration horizon: "present" vs "last completed week"

The spec says the simulation runs "from the purchase's week up to the
present." The implementation runs through the LAST COMPLETED week,
never the in-progress current week, per owner decision 5 (settled; not
re-litigated here). The rationale is sound — simulating an
in-progress week would make restoration unstable as the week evolves —
but a future reader comparing code to spec text will see a
discrepancy. It should stay recorded as an owner-approved
interpretation, not drift into an undocumented deviation.

### N11 (P2, legacy-data note) — Pre-fix rows may still carry old shapes

Two documented pre-fix residues cannot be verified without live row
access: (a) rows with `state='excluded'` but `excluded=false` would
still count (P2-10 latent); (b) pre-fix mismatched fund-request links
can be closed but never gain new links. If a future live-row check
finds either shape, it should be repaired by a targeted, backed-up
migration — not by hand edits.

### N12 (P2) — Two copies of the Gmail parse module can drift

`gmail-poll/gmail-parse.ts` (the copy the deployed function imports)
and `supabase/functions/_shared/gmail-parse.ts` (which nothing
imports) are maintained in parallel; the deploy note in the poll even
claims the shared path does not exist, when it does. The `ebb8c99`
query tightening updated both, but nothing enforces that. **Fix:**
make the poll import the single shared copy (or delete the unused
one) so the next parser fix cannot land in only one place.

### N13 (P2, advisory) — Invite codes: 6 characters, reusable, unthrottled

Owner decision 11 settled that codes stay reusable and non-expiring.
The remaining advisory is brute-force surface: a 6-character code
from a 32-character alphabet (~1 billion combinations) with no
attempt throttling in `join_household_by_code`. For the current
household this is negligible (the code is shared privately with one
person). For public launch, consider longer codes, attempt throttling,
or both — or explicitly accept the risk. This does not reopen P0-1:
without a code, a stranger still joins nothing.

## 5. Unproven gaps (restated explicitly — none of these is a pass)

1. **Webhook-triggered server sync on the next real purchase.**
   Code deployed, probes passed, but no real Plaid announcement has
   yet driven a sync with the app closed and a new transaction visible
   on next open.
2. **Hourly safety-net cron.** `supabase/server-sync-cron.sql` is
   prepared with a placeholder key and has never been run; the
   service-key paste into it is still pending.
3. **Gmail parser against a REAL charge alert.** No real charge alert
   has been seen. The first poll's 2 matches were statement emails,
   correctly left unparsed; the query is now tightened to
   `subject:"Large Purchase"`. Parser rules (YYYY-MM-DD date, first
   `$X.XX` amount, merchant via `at NAME` or subject tail, suffix via
   `ending in` etc.) are untested against a real alert body.
4. **Delete-account throwaway test.** Deployed, never executed on a
   throwaway account.
5. **Bootstrap-household removal.** Still declared in `config.toml`
   and deployed, unused.
6. **Backup procedure + restore test as a whole.** Documented only;
   the targeted 9-row backfill backup does not substitute for it.
7. **HANDOFF.md full rewrite (P1-47).** UUID scrubbed, but the document
   is not yet trustworthy as a whole.
8. **Held-refunds review UI** (see N8) and a live-row test of the
   held-refund release path (no held rows exist; none were fabricated,
   correctly).
9. **Live CSV import end to end; live password-reset flow; live bank
   disconnect.** UI/function code exists; live execution unproven.
10. **Live-row verification, deployed-vs-repo parity beyond the
    supplied timestamps/probes, and 390px/820px layout.** Not
    verifiable in this pass (see §1).
11. **Icon small fix (deferred by the owner) and lockup + landing/demo
    favicons still showing old marks.** Cosmetic; owner-gated.

## 6. Next proof steps, per gap

1. **Webhook proof:** after the next real Amex purchase, check
   `plaid-sync` invocations with the app closed, then confirm the new
   transaction appears on next open without a manual press. Also
   collect 24 hours of clean invocation counts.
2. **Hourly cron:** owner pastes the service key into the placeholder
   in `server-sync-cron.sql` (never commit a filled-in copy), runs it
   in the SQL Editor, and confirms the `hourly-plaid-sync` job exists
   and fires.
3. **Real-alert parser proof:** when the next genuine Large Purchase
   alert arrives, run "Check email now" and confirm one provisional
   `amex_alert` row with the right merchant, amount, and suffix. If
   it lands in "could not be read," share one redacted alert's wording
   and fix the parser against it — do not guess the format.
4. **Delete-account:** create a throwaway account + household, run
   delete, and verify the account, membership, and household data are
   gone and nothing else changed. Only then offer it to real users.
5. **Bootstrap removal:** remove the function from `config.toml` and
   redeploy, then confirm it no longer appears in the functions list.
6. **Backups:** run the documented procedure end to end, then restore
   to a scratch target and verify row counts match. Record the run.
7. **HANDOFF rewrite:** rewrite from the current tree + live evidence,
   removing all stale claims (including the outdated P1-11 comment in
   `04` and the gmail deploy note), and re-stamp it.
8. **Held-refund UI + live test:** add a review screen listing held
   rows with a release action; test the release path when the first
   real held refund occurs (refund exceeding its charge).
9. **CSV / reset / disconnect:** one live run each on non-critical
   data (a test CSV row, a throwaway password reset, a disconnect +
   reconnect), confirming the UI result matches server state.
10. **Layout:** a 390px and 820px pass over Home, Purchases, and
    Bank & Funds once viewport tooling allows it.
11. **Pre-public hardening (from §4):** decide N1 (admin-only link vs
    documented member-link); delete the N2 membership branch; revoke
    the N3 authenticated grant on `log_webhook_event`; add
    pre-exclusion state storage for N4 or document the date rule as
    accepted; settle orphaned sheet promises (N7); unify the Gmail
    parse module (N12).

## Appendix — evidence relied upon

- **Repo state:** main `ebb8c99`; recent history includes `9a890db`
  (Gmail hex-key fix), `55e8333` (decisions 2/13/14),
  `e22e410` (server sync), `105eaf4` (UUID join removal),
  `7310090` (Gmail config entries).
- **Supplied live evidence (brief, taken as established):** grants fix
  and post-fix week-close/plaid-sync 200s; UUID removal verified via
  `pg_get_functiondef`; payment backfill (9 rows, −$3,023.00, atomic,
  CSV-backed); server-sync probes (bare 401, garbage-token 401) and
  1:24 PM deploy timestamps; decision-build SQL verified live;
  Gmail connect + first poll (`0 added, 0 already known,
  0 quarantined, 2 could not be read`, matches identified by the
  owner as statement emails); owner screenshots (Sync button inside
  the hero card, brand-blue toasts, connected email list).
- **Local verification performed in this pass (read-only):** full
  test suites (engine 27/27, gmail 14/14); targeted code reads for
  every P0 and every money/auth/integrity P1 class listed in §3;
  HANDOFF UUID occurrence count (zero); cache-bust versions
  (styles v9, live.js v5).
- **Explicitly NOT claimed:** anything in §1's out-of-coverage list
  and §5's gap list. Where the brief and the code disagree, the code
  was checked and the disagreement is noted (e.g., the stale P1-11
  comment in `04`, the gmail deploy note about the shared path).
- **No secrets, key material, or full card numbers appear in this
  report.** All findings are stated from code structure and from
  counts/timestamps supplied in the brief.
