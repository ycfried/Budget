# S1 — SQL security + invites: interface notes

Workstream S1 for the OnBudget overnight build. Source: a private copy
of `~/workspace/household-budget` (branch `audit-fixes`); the original
repo was NOT modified. **Nothing here is deployed or live.** Every
statement below is unexecuted SQL until the parent deploys it against
a real database — live RLS behaviour, in particular, is UNVERIFIED.

Spec authority: `Household_Budget_Spec_FINAL.pdf` wins over
`HANDOFF.md` where they disagree (audit P1-47). Audit findings
addressed: P0-1, P0-2, P0-3, P0-4, P0-5, P1-12, P1-13, P0-14 (server
side), P1-8 (server side), P1-9 (server side), P0-15 (server side),
plus P1-10 (old approval path, via 04 §7) and P1-16 (grant half, via
03 §3) and P1-25 (second-household refusal, via 01).

## Deploy order (strict — files are numbered for this)

1. `01-invite-codes.sql`
2. `02-rls-hardening.sql`
3. `03-plaid-vault.sql`
4. `04-admin-rpcs.sql`
5. `05-transaction-mutation-rpcs.sql`

Deploy in order, in one maintenance window if possible: 02 revokes
direct writes that the 05 RPCs replace, and 03 revokes Plaid RPC
grants that plaid-sync must be re-keyed for (see "Deploy blockers"
below). Each file is self-contained and re-runnable (all DROPs are
`IF EXISTS`, all column adds are `IF NOT EXISTS`, all functions are
`CREATE OR REPLACE`).

## New / changed objects

### 01-invite-codes.sql

- `households.invite_code` — `text`, nullable; unique index
  `households_invite_code_key`. Backfilled for all existing rows.
- `generate_invite_code() returns text` — 6 chars from
  `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no 0/O/1/I/L), random, retries
  up to 100 times on collision, then raises. NOT granted to
  `authenticated` (callers go through SECURITY DEFINER functions).
- `create_household() returns uuid` — REPLACED: identical to the old
  RPC plus assigning an invite code on insert.
- `join_household_by_code(code text) returns uuid` — SECURITY
  DEFINER, granted to `authenticated`. Accepts a 6-char code
  (case-insensitive, trimmed) OR a legacy household UUID during
  transition. Raises `not authenticated`, `already in a household`
  (caller belongs to ANY household), or `invalid invite code`
  (unknown/malformed input — same message for both, no existence
  leak). Inserts `role='member'` only, writes one audit row.
- DROPPED policy: `users join as member for themselves` on
  `household_members` (the P0-1 hole). Direct membership inserts now
  fail RLS for everyone.

### 02-rls-hardening.sql

- REVOKED from `authenticated`: INSERT/UPDATE on `week_closes`,
  `surplus_releases`, `fund_ledger`; UPDATE on `transactions`;
  UPDATE on `webhook_events`.
- DROPPED policies (exact names from the repo): `members write own
  week closes`, `members update own week closes`, `members write own
  surplus releases`, `members update own surplus releases`,
  `members write own fund ledger`, `members update own transactions`,
  `members update own webhook events`.
- `members insert own transactions` — REPLACED: WITH CHECK now
  requires membership AND `source IN ('manual','csv')` AND
  `state='provisional'`. Policy-only on purpose (a table CHECK would
  also bind the future privileged sync path, which bypasses RLS but
  not CHECKs).
- `members insert own fund requests` — REPLACED: requires
  membership, `requested_by = auth.uid()`, `status='pending'`, and
  transaction-household equality when `transaction_id` is set.
- `validate_fund_request_txn()` + trigger
  `trg_fund_request_validate` (BEFORE INSERT OR UPDATE on
  `fund_requests`): enforces `status='pending'` on INSERT and
  transaction-household equality on INSERT / on change of
  `transaction_id`. Fires for all writers, including SECURITY
  DEFINER RPCs that bypass RLS.
- `audit_log` INSERT policy deliberately KEPT (membership-scoped):
  week-close and the live.js `audit()` helper write audit rows with
  the caller's JWT. Forgery is closed instead by the 04 trigger.
  See "Residual risks".
- `log_webhook_event(text,text,text)`: EXECUTE revoked from `anon`
  only (brief scope). Authenticated grant remains — see "Residual
  risks".

### 03-plaid-vault.sql

- `plaid_items`: SELECT revoked from `authenticated`; policy
  `members read own plaid items` DROPPED.
- VIEW `plaid_items_public` — explicit column list: `id`,
  `household_id`, `plaid_item_id`, `institution_name`, `sync_cursor`,
  `last_sync_at`, `created_at`. **No `access_token_encrypted`
  column.** Membership predicate inside the view (it runs as the
  view owner, so base-table RLS does not apply — the predicate IS
  the enforcement). SELECT granted to `authenticated` only.
  Column list is explicit, never `SELECT *`, so a future sensitive
  column is not silently exposed.
- `get_plaid_ciphertext(uuid, text)` and
  `update_plaid_sync(uuid, text, text)`: EXECUTE revoked from
  `public`, `authenticated`, and `anon`. Granted to NO member role.
  Only the service-role key (used by the plaid-sync Edge Function)
  may call them — that is the brief's rule, implemented by granting
  them to nobody. Function bodies unchanged.

### 04-admin-rpcs.sql

- `fund_requests.remainder_cents` — `integer NOT NULL DEFAULT 0`,
  `CHECK (remainder_cents >= 0)`.
- `approve_and_allocate(request_id uuid, amount_cents int,
  override_reason text) returns void` — REPLACED. Contract argument
  names (no `p_` prefix) — existing live.js calls using
  `p_request_id`/`p_amount_cents`/`p_override_reason` MUST be
  updated by the UI workstream. Rules: authenticated; pending only;
  admin of the request's household; `amount > 0`; NEW:
  `amount <= requested` (over-approval raises); NEW: linked
  transaction must be in the same household (P0-5); fund balance /
  override rule unchanged; `status='approved'` if equal else
  `'split'` with `remainder_cents = requested - amount`;
  `decided_by`/`decided_at` now recorded; transaction
  `fund_allocation_cents` ACCUMULATED (`+= amount`, household-guarded
  WHERE), never overwritten. Serialized with `SELECT ... FOR UPDATE`
  on the households row for the whole RPC transaction (P1-9).
- `allocate_fund(p_household_id uuid, p_amount_cents int, p_note text,
  p_override_reason text)` — REPLACED with the same household-row
  lock only; signature and balance/override behaviour unchanged.
  (`p_` names kept: not in the brief's contract list, existing
  callers unaffected.)
- `update_fund_shortfall(household_id uuid, shortfall_cents int)
  returns void` — NEW, SECURITY DEFINER, admin-only. Rejects
  negative shortfall; updates `households.fund_shortfall_cents`
  under row lock; audits old → new. This is the P0-15 path
  week-close must call instead of a direct households UPDATE.
- `force_audit_actor()` + trigger `trg_audit_log_force_actor`
  (BEFORE INSERT on `audit_log`): when the caller has a JWT,
  overwrites `actor := auth.uid()` and `actor_name` from
  `household_members.display_name`, else JWT `user_metadata`
  `full_name`/`name`, else JWT `email`, else `auth.uid()` as text.
  When there is no JWT (service-role path), supplied values are
  kept, blank `actor_name` defaulting to the actor id. Consequence:
  RPC audit rows that used to say `actor_name='admin'` will now
  show the real caller — anything filtering on `'admin'` must change.
- `delete_transaction(p_transaction_id uuid)` — RE-CREATED with
  byte-for-byte behaviour from `delete-transaction-rpc.sql`:
  admin + `source='manual'` only, audit row before delete. Verified,
  not weakened.
- `set_base_allowance(p_household_id uuid, p_cents integer)` —
  REPLACED: reads the old value first; audit detail now reads
  `changed from X cents to Y cents`. `>= 0` validation unchanged.
- `approve_fund_request(p_request_id uuid)` — REPLACED: delegates
  positionally to `approve_and_allocate` with the FULL requested
  amount (P1-10: no money-less approval path remains). Behaviour
  change: old-path approval now fails on insufficient fund instead
  of approving anyway — that failure is the fix.

### 05-transaction-mutation-rpcs.sql

All SECURITY DEFINER, granted to `authenticated` only, admin-checked
against the ROW's household, each writing one audit row:

- `exclude_transaction(txn_id uuid, reason text)` — sets
  `excluded=true` AND `state='excluded'`, stores `reason` in
  `exclude_reason`. Re-exclusion allowed (idempotent, re-audits).
- `restore_transaction(txn_id uuid)` — raises unless the row is
  currently `excluded`; sets `excluded=false`, clears
  `exclude_reason`, restores state to `verified` if the row's date
  is before today in America/New_York, else `provisional` (mirrors
  the existing live.js rule — see "Flagged ambiguities").
- `reclassify_transaction(txn_id uuid, new_kind text, reason text)`
  — `new_kind` must be `charge`, `refund`, or `fund_charge`;
  reason recorded in the audit detail (no `reclassify_reason`
  column exists).
- No delete path is duplicated here: `delete_transaction()` (04)
  is the only delete.

## Deploy blockers — do NOT deploy until these are handled

1. **Plaid sync upsert (02 §3):** plaid-sync currently upserts
   transactions with the caller's JWT (`source='plaid'`,
   `state='provisional'/'verified'`). After 02, member INSERT is
   limited to `manual`/`csv` + `provisional` and member UPDATE is
   revoked, so sync FAILS until it moves to a service-role or
   SECURITY DEFINER upsert path (the audit's prescribed fix).
2. **Plaid RPC re-keying (03 §3):** plaid-sync and
   plaid-webhook-register currently call `get_plaid_ciphertext` /
   `update_plaid_sync` with the caller's JWT. After 03, those calls
   fail for everyone except the service-role key. The repo's Nov 1
   notes record the legacy service-role key as broken/deprecated
   for this project — the parent must prove a working service-role
   credential path BEFORE deploying 03, or Plaid sync stops.
3. **UI switches (01, 02, 05):** live.js join handler (direct
   membership insert), exclude/restore/remove handlers (direct
   transaction UPDATE), and approve calls (`p_` argument names)
   must move to `join_household_by_code`,
   `exclude_transaction`/`restore_transaction`, and the contract
   argument names at the same deploy, or those buttons fail.
4. **Week-close rewrite (04 §3):** week-close must call
   `update_fund_shortfall()` instead of a direct households UPDATE
   AND must start checking its write errors (it currently ignores
   them — P0-15's second half). Until then, shortfall is still lost
   even with the RPC deployed.

## Residual risks (fixed only partially, by brief scope)

- **Reusable, non-expiring invite codes (01):** the audit's correct
  fix is single-use, expiring, admin-approved invites. The brief
  specifies a household-level code; this migration implements that
  and does NOT implement single-use/expiry. A leaked code joins
  anyone until the code is rotated (no rotation RPC exists yet).
- **Legacy UUID join path (01):** kept during transition per the
  brief. Any published household UUID remains a valid join secret
  until the parent removes Path 2 AND rotates exposed UUIDs.
  Open sign-ups must also be disabled in Supabase Auth and UUIDs
  removed from the public repo — neither is achievable in SQL.
- **Audit direct INSERT (02/04):** members can still insert audit
  rows with arbitrary action/detail text, but the 04 trigger makes
  them attributable (actor/actor_name forced). Full closure needs
  an audit-write RPC + week-close/live.js migration.
- **`log_webhook_event` authenticated grant (02):** anon revoked;
  any authenticated user can still plant events. Revoke for
  authenticated too once plaid-webhook writes via its own verified
  service-role path. The P1-13 dedupe-hash collision is also
  untouched.
- **plaid_items member upsert (03):** INSERT/UPDATE grants and
  policies left in place for plaid-exchange's caller-JWT upsert. A
  member cannot read the ciphertext but could overwrite it with
  garbage and break that item's sync. Close by moving exchange to
  the service-role path.
- **Week-close double-release (P1-9, second half):** not fixed —
  week-close is an Edge Function sequence, not an RPC; it needs its
  own atomic rewrite with conditional release.
- **decline_fund_request false audit (P1-11):** untouched (outside
  this file's brief). It still audits unconditionally even when the
  row was already decided.

## Flagged ambiguities — parent must rule, S1 did not decide silently

1. **Split remainder is closed, not re-approvable (04 §1):** the
   brief says `status='split'` + `remainder_cents`. The audit's
   alternative (remainder stays pending) was NOT implemented. If
   re-approvable remainders are wanted, that is a new design task.
2. **Restore target state (05):** no pre-exclusion state is stored,
   so restore mirrors live.js (past date → `verified`, today/future
   → `provisional`, America/New_York). A stored pre-exclusion
   state would need a new column + exclude-time snapshot.
3. **Blank exclusion/reclassification reasons (05):** accepted and
   stored verbatim ("no reason given" in audit detail). Spec A7
   says exclusion needs a reason; the brief does not say blank
   must raise. Rule needed: reject blank, or accept as implemented.
4. **Audit actor_name fallback (04 §4):** when no display name or
   JWT name/email exists, `actor_name` becomes the uid string.
   Display names are usually empty in this app, so audit rows will
   often show a uid/email rather than a friendly name until a
   display-name source is populated.
5. **FIN-REFUND-001:** untouched by S1. Per the FINAL spec it is
   MOOT (not an open owner question) — the spec's refund-restoration
   rules govern. Nothing in these migrations encodes a refund-credit
   or surplus-release policy beyond the existing ledger tables.

## What was NOT verified (honest limits)

- No live database was touched (hard constraint): no SQL was
  executed against Supabase, no RLS policy was tested with real
  JWTs, no RPC was invoked. The commented verification block in
  each file is the deploy-time checklist, not a passed test suite.
- Syntax sanity pass performed locally only: re-read of every file;
  automated checks that all `$$` delimiters balance, all
  `CREATE OR REPLACE FUNCTION` bodies open/close, and no file
  contains a secret, token, key, or card number (none do — the only
  key-like strings are the invite alphabet and UUID placeholders
  inside comments). No SQL parser (psql/pg_format/sqlparse) is
  installed in this environment, so no machine parse was possible;
  the parent should run the files through the Supabase SQL editor
  or `psql --single-transaction` on a staging database first and
  treat the first deploy as the real syntax test.
- Interface compatibility: `approve_and_allocate`'s argument rename
  (contract names vs live.js `p_` names) and the three deploy
  blockers above are the known breaking changes; they are flagged
  here rather than smoothed over.
