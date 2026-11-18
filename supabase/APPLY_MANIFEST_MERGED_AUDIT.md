# Apply manifest — merged-audit push package (Nov 4, 2026)

**PREPARED ONLY — NOTHING IN THIS MANIFEST IS APPLIED LIVE BY THE BRANCH.**
The parent applies these files in order, via the approved browser SQL
run (answer_to + verbatim file contents, Supabase GitHub sign-in),
after the owner has seen each exact file. Function code in this
branch (plaid-sync, compute-week, week-close) is deployed by merge
only; SQL below is separate and is NOT deployed by merge.

**Live state at probe time (Nov 4, 2026, 10:12–10:18 PM, read-only,
nothing changed live):** transactions 36, week_closes 0, pre-Nov rows 0
— matching the Nov 4 rebuild. Re-probe before applying if any live
change has happened since; do not apply blindly on a stale probe.

## Order

### 1. `supabase/merged-audit-kind-constraint.sql` — A1, REQUIRED
Merged transactions kind CHECK: the six live kinds (charge, refund,
fund_charge, payment, cashback, charity) PLUS transfer — seven total.
Live probe proved the live constraint is `transactions_kind_check`
with exactly the six, transfer missing — the confirmed cause of the
live Transfer reclassification failure. This replaces it.
Verify with the query in the file header, then retest every offered
reclassify type on a SYNTHETIC household (transfer row must save
and count $0 toward weekly spending).

### 2. `supabase/merged-audit-fund-request-kind-guard.sql` — A16, REQUIRED
Replaces `validate_fund_request_txn()` so a linked fund request
requires the linked transaction to be kind='charge'. Unlinked
fund-form requests are untouched. Live probe proved the trigger
`trg_fund_request_validate` exists but its body has NO kind check —
this guard is still needed. Verify on a synthetic household:
linked non-charge request rejected, linked charge and unlinked
requests still succeed.

### 3. `supabase/merged-audit-plaid-accounts-revoke.sql` — A16, REQUIRED
Revokes member INSERT/UPDATE on plaid_accounts and drops the two
member write policies; member SELECT stays. Live probe proved
authenticated had SELECT+INSERT+UPDATE. Retest bank sync and
disconnect/reconnect on a synthetic household after applying
(they run server-side and must be unaffected).

### 4. `supabase/merged-audit-csv-admin-only.sql` — A16, REQUIRED
Replaces the member INSERT policy on transactions so source='csv'
requires admin, while source='manual' stays member-allowed (by
design) and state must still be 'provisional'. Live probe proved
the member INSERT policy allowed manual/csv. Retest on a synthetic
household: member CSV insert fails, member manual and admin CSV
inserts succeed.

### 5. `supabase/merged-audit-held-release-atomic.sql` — B10, REQUIRED
Replaces `resolve_held_refund()` with the same semantics plus a
row lock and a conditional status='pending' update with a row-count
check, so a concurrent second release raises instead of crediting
twice. Retest on a synthetic household: release a held refund once
(queue + fund reconcile exactly, shortfall first), release again —
second call must raise and the fund must not move.

## Explicitly NOT in this manifest (do not add, do not apply)

- **A2 Approve signature — NO SQL NEEDED, live-proven.** Live probe
  proved `approve_and_allocate` already has the UI signature
  (p_request_id uuid, p_amount_cents integer, p_override_reason
  text). Do NOT change it live. The repo file
  `supabase/04-admin-rpcs.sql` §1 defines the OLD unprefixed
  signature and is OUTDATED — **never re-apply 04-admin-rpcs.sql §1
  after this package**; doing so would break Approve. The live
  signature is the one in `supabase/approve-ambiguity-fix.sql`,
  already applied Nov 3. A2 is closed by the probe plus a synthetic
  Approve retest (full / split / member request / override), not by
  any new SQL file.
- **A16 charity gift idempotency — INDEX ALREADY LIVE, probe the
  function first.** Live probe proved the partial unique index
  `transactions_household_client_key_idx` (client_key IS NOT NULL)
  already exists. Do NOT create a duplicate index. Before applying
  anything for this item, probe `pg_proc` for `record_charity_gift`:
  if its signature already includes `p_client_key`, the replay logic
  is already live and NO file is needed; only if `p_client_key` is
  absent should the existing repo file
  `supabase/r13-gift-idempotency.sql` be applied (it uses
  `create unique index if not exists`, so re-applying it is a
  no-op on the index). No new charity-idempotency file is created
  in this branch, deliberately, to avoid duplicating that index.
- **Any other repo SQL file.** In particular, do NOT re-apply
  `supabase/04-admin-rpcs.sql` in full, `supabase/transfer-kind.sql`,
  or `supabase/r13-charity.sql` — each would re-impose its own
  absolute kind list or signature and undo items 1–2 above. The
  ordered apply-manifest (this file) is the single source of order
  for this package.

## After the SQL steps

1. Merge the branch (parent review first, isolated worktree, as with
   PR #34/#35/#36), verify live pins (styles v37 / live.js v47)
   by fresh fetch, and check the Pages build status — do not assume
   a build failure is transient (PR #35 errored Nov 4, 6:22 PM).
2. Synthetic-household acceptance, in order: Approve retest, every
   reclassify type, Correct income open/focus, cash-gift Home
   display + Purchases count, Recent-row jump, search/totals,
   Temporary Allowance preview, Funds More accordion, Previous
   Weeks tap-to-transactions, Activity page, desktop Add label,
   kind-restricted detail actions, held-refund release + re-release,
   fund-request kind guard, plaid_accounts revoke, CSV admin-only,
   plaid-sync Trash survival + identical-purchase coexistence +
   full-pull Nov 1 drop (fake pre-Nov row + cursor reset simulation).
3. Section D acceptance (merged audit): CSV retest on a real phone
   + desktop, bank/email end-to-end, refunds/duplicates/past weeks,
   week close after Sunday Nov 8, 2026 (verify week_closes becomes
   1 on an admin load on/after Nov 8; never manufacture it on the
   real household), phone/member/screen-reader pass, real-phone
   proving for PR #35 + PR #36 + this package.
4. B5 card standardization: owner picks from the standalone mockup
   (`card-standardization-mockup.html`, mockup-only, not linked
   from live.html) BEFORE any live card restyle. No live restyle
   is in this branch.
