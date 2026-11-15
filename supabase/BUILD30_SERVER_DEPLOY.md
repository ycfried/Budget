# Build 30 — server deploy note (Supabase)

Applies to: `native-fix-build30` branch, work under `supabase/`.
Parent applies the SQL via the Supabase dashboard SQL editor and
deploys Edge Functions by cherry-picking onto main. **Nothing in
this note has been applied live from here** (no browser access, no
live application by the server agent). The real household
(`647d1f23-606f-43af-92e5-1de2f1f34377`) is never touched by any
step below — every live check is test-household only
("Simcha House!", `95e1aff3-f664-41bb-be09-70e00f75a141`).

## What this ships

| # | Piece | Files |
|---|-------|-------|
| E | Merchant name rules (teachable rename + saved list) | `supabase/merchant-rules.sql`, `supabase/functions/_shared/canonical.ts` (+ identical copies in `plaid-sync/`, `gmail-poll/`, `ingest-amex-alert/`), wired into `supabase/functions/plaid-sync/index.ts`, `supabase/functions/gmail-poll/index.ts`, `supabase/functions/ingest-amex-alert/index.ts` |
| I | Auto-merge Bank+Email duplicates | `supabase/auto-merge-bank-email.sql`, same `canonical.ts` copies (eligibility + bank-first guard), `plaid-sync/index.ts` calls `try_auto_merge_bank_email` after each new bank-row insert |
| K | Partial debt clear | `supabase/partial-debt-clear.sql`, `computePartialClear` in `engine.mjs` (root canonical copy + `supabase/functions/_shared/`, `compute-week/`, `week-close/` — all four must stay byte-identical, enforced by `test/p2-engine.test.mjs`) |

No new Edge Function was created, so `supabase/config.toml`
needs no change — the three modified functions are already
declared there. No existing table column was renamed, dropped or
retyped; no existing RPC signature changed except `clear_debt`,
which only gained two optional (default NULL) parameters — the
old 2-argument call keeps working. The frozen web app (v69) reads
the same tables and will simply show cleaner merchant names once
rules have renamed rows.

## Apply order (dashboard SQL first, then functions)

1. **`supabase/merchant-rules.sql`** — creates `merchant_rules`,
   the match/rename/apply RPCs, and seeds the 9 owner-example
   rules for every existing household. Idempotent; safe to re-run.
   Prerequisite: `pgcrypto` (created by the file itself).
2. **`supabase/auto-merge-bank-email.sql`** — creates
   `merchants_related_for_merge`, `bank_email_merge_check`,
   `merge_bank_email_pair`, `try_auto_merge_bank_email`,
   `auto_merge_pending_bank_email_duplicates`. Idempotent
   (CREATE OR REPLACE). Prerequisites: `dedupe-review-queue.sql`
   (`duplicate_candidates`, `merchant_aliases`) and step 1 —
   both already live; if either table is missing the functions
   fail loudly instead of merging on a guess.
3. **`supabase/partial-debt-clear.sql`** — drops and recreates
   `clear_debt(uuid, text, integer default null, integer default
   null)`. Prerequisite: `debt-fund.sql` (already live Nov 15).
   Re-running is safe.
4. **Deploy Edge Functions by cherry-picking onto main** (per the
   normal flow — the parent deploys; no dashboard SQL covers
   these):
   - `plaid-sync` (rules at ingestion + auto-merge RPC call)
   - `gmail-poll` (rules at ingestion + widened bank-first guard)
   - `ingest-amex-alert` (rules at ingestion + widened
     bank-first guard)
   - `compute-week` and `week-close` — **no code change** (only
     the shared `engine.mjs` gained the `computePartialClear`
     helper, which neither function calls). Redeploy is NOT
     required for task K; cherry-pick them only if the parent
     wants the copies in sync on main. The SQL `clear_debt`
     change is what enables partial clear; the balance math
     (`debt_balance_cents`) already subtracts `clear` rows.
   - The `_shared/canonical.ts` and `_shared/engine.mjs`
     copies are deployed via their alongside copies in each
     function directory (the dashboard deploy pastes the
     alongside files verbatim — keep all four `canonical.ts`
     copies and all four `engine.mjs` copies byte-identical).

## Live verification (test household ONLY — Simcha House!)

### E — merchant rules
1. In the test household, pick or create a transaction with
   merchant `AMAZON MARKEPLACE NA PA` (or use an existing one)
   and call `rename_transaction_and_apply_rule` with display
   name `Amazon`, `p_fixed_kind => null`, `p_match_type =>
   'exact'`. Expect: the call returns the count of renamed rows
   (≥1), all matching old rows now read `AMAZON`, and the new
   rule appears in `merchant_rules`.
2. Insert a NEW test transaction (or wait for the next sync)
   with merchant `AMAZON MARKEPLACE NA PA`: it must arrive
   stored as `AMAZON` (rule applied at ingestion).
3. Check a seeded rule: a row `BALTIMORE GAS AND ELECTRIC
   COMPANY` (old or new) must display `BGE` after running
   `select public.apply_merchant_rules_to_household(
   '95e1aff3-f664-41bb-be09-70e00f75a141');` — run that
   bulk-apply in the TEST household only, and only after
   confirming the seed rules look right in `merchant_rules`.
4. Rename with a fixed kind: rename a test charity merchant
   with `p_fixed_kind => 'charity'` and confirm matching new
   rows get kind `charity` while a negative-amount row from the
   same merchant does NOT (sign guard).

### I — auto-merge (real household, dashboard pass)
1. Run the pending-queue pass against the REAL household:
   `select * from public.auto_merge_pending_bank_email_duplicates(
   '647d1f23-606f-43af-92e5-1de2f1f34377');`
   Expect one row per visited pending candidate. The three
   Amazon pairs must come back `merged`:
   - **$6.35** (Nov 15, both Counted) → email row excluded,
     bank row still counted. Exactly ONE counted row.
   - **$79.99** (Bank Nov 14 Excluded / Email Nov 13 Counted)
     → bank row un-excluded and counted, email row excluded.
     Exactly ONE counted row, the bank's.
   - **$19.07** (Bank Nov 13 Excluded / Email Nov 12 Counted)
     → same as $79.99.
   Any pair that comes back `skipped: <reason>` did NOT merge —
   that is the designed conservative outcome; resolve it by hand
   in Review (do not force it).
2. Confirm in Review: the three pairs show under Resolved
   Duplicates as `Merged`, the week spent drops by
   $6.35 + $79.99 + $19.07 = **$105.41** of double-count, and
   each pair's email row is in Trash (restorable), not deleted.
3. Confirm the **TOIREMORG $2 pair is untouched**: both rows
   still counted, no new candidate, no merge. (If a pending
   candidate exists for it, it must come back
   `skipped: toiremorg pair never auto-merges`.)
4. Ingestion check (after the function deploy): the next
   Bank+Email pair that arrives with matching amount/card
   within 2 days must merge without appearing in Review; a
   pair the owner previously marked Separate must NOT merge.

### K — partial debt clear (test household ONLY)
Setup: give Simcha House! a test debt first (e.g. close a test
week with outgoing debt, or insert a test `week_closes` row the
way the build-29 verification did — do NOT fabricate debt in the
real household). Note the starting balance `D` from
`select public.debt_balance_cents('95e1aff3-f664-41bb-be09-70e00f75a141');`
1. **Fixed amount:** `select public.clear_debt('<test-hh>',
   'test partial', p_amount_cents => 10000);` Expect: returns
   `10000`; balance drops by exactly 10,000 cents; a `clear`
   row for 10,000 cents appears in `debt_payments`; an audit
   entry `Carried debt cleared` records the partial clear and
   the remaining balance.
2. **Percentage:** `select public.clear_debt('<test-hh>',
   'test percent', p_percent_bp => 2500);` Expect: clears
   `floor(balance * 25%)` — e.g. balance 100,000 → 25,000 —
   never a cent more (floor, not round).
3. **Over-amount refusal:** clear with an amount larger than
   the remaining balance. Expect: an exception (`amount exceeds
   remaining debt: …`), NOTHING written (no `debt_payments`
   row, no audit row, balance unchanged).
4. **Full clear still works:** `select public.clear_debt(
   '<test-hh>', 'test full');` Expect: clears the whole
   remaining balance, as before this change.
5. **Old client call still works:** the existing native
   `clearDebt` call passes only `(p_household_id, p_note)` —
   confirm it still clears in full (the new parameters default
   to NULL). No Edge Function redeploy is needed for this RPC.

## What could NOT be verified without live access

- The SQL files were **not executed anywhere** (no database
  access from here). They were written to match the live schema
  as recorded in the repo (`transactions` columns, the 8-kind
  check, `duplicate_candidates`/`merchant_aliases`,
  `debt_balance_cents`/`debt_payments`), but a live apply could
  still surface a drift (e.g. a column that exists in the repo
  but not live, or vice versa). If the dashboard reports an
  error on any file, stop and report the exact error — do not
  force-apply.
- The three Amazon pairs' live state (pending-candidate status,
  kinds, card suffixes) was **not read live**. The pass is
  written to skip — not merge — any pair whose kinds/card/date
  do not match, or which is not pending. If any of the three
  comes back `skipped`, that is a signal to check the live rows
  before merging by hand, not a failure of the pass.
- The Edge Function edits were **load-tested in Node with stubs**
  (all three import and parse), not run against Deno/Supabase.
  A deploy-time import error would surface in the function logs;
  the new code paths are best-effort (a rules-load or auto-merge
  failure never fails a sync/poll/ingest — it logs and continues
  with the old behaviour).
- The `clear_debt` signature change was not verified against
  PostgREST: PostgREST applies defaulted parameters for omitted
  arguments, which is the documented behaviour, but the old
  native `clearDebt` call should be exercised once live (step
  K.5 above) to confirm.

## Coordinator additions (Nov 15, after the server agent finished)

### Pre-exclusion-state snapshot fix (merge paths)
`restore_transaction` (n4) refuses a row whose
`pre_exclusion_state` is null — but BOTH merge paths excluded
without snapshotting it, so a merged row was unrestorable from
Trash (the same class as the Nov 5 fix that made merges set
`state='excluded'`). Fixed, mirroring `exclude_transaction`:
- `dedupe-review-queue.sql` — `resolve_duplicate_candidate`
  (manual merge): snapshots the duplicate row's prior state.
  Re-apply this file (idempotent, CREATE OR REPLACE) to pick it
  up; it also re-creates the tables only if missing.
- `auto-merge-bank-email.sql` — `merge_bank_email_pair`: snapshots
  the email row's prior state on exclude, and restores the bank row
  to its prior state (was forced `'verified'`) on un-exclude.
  Re-apply with step 2 below.
The JS tests do not cover SQL; these two lines were not
re-verified by a test run after the edit — the parent's live
verify (step I.4 below) should include restoring one auto-merged
email row from Trash to prove the snapshot is taken.

### TOIREMORG correction (real household — parent applies live)
`supabase/toiremorg-correction.sql` corrects the wrong "Merged ·
Nov 12, 2026" resolution for the TOIREMORG / TOIREMORG CHARITY $2
pair (two real gifts, owner ruling Nov 3 — never a merge). Run its
STEP 1 read-only first, then STEP 2, then STEP 3 to verify. It
backfills the missing `pre_exclusion_state` from the date rule
before restoring, because the Nov 12 merge never snapshotted it.
Idempotent (a second run no-ops once the candidate is 'separate').

## Decisions the owner may still want to make

- **Seed rule kinds:** the `ONLINE TRANSFER / PAYMENT: DEBIT →
  TRANSFER` seed carries fixed kind `transfer` (the owner's own
  label for the row). The wire-transfer seeds carry NO fixed
  kind (a wire out is a payment to someone else, not an
  internal transfer). If the owner wants wire transfers to
  count as transfers too, set the kind on those two rules.
- **Tenyad Kallah Gemach kind:** the seed renames the name only
  (no fixed kind). If every payment to it is a gift, the owner
  can set fixed kind `charity` on that rule.
- **New households start with no rules.** The seeds were
  inserted for existing households only. If the owner wants new
  households to start with the same defaults, that is a small
  follow-up (seed on household creation).
- **Matching strictness:** exact/prefix/squash only, never fuzzy.
  A merchant nobody has taught (e.g. a new store-number variant)
  will not auto-match until renamed once. That is the
  conservative default chosen here; loosening it needs an owner
  decision, not a code change made silently.
