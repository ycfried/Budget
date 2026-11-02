# S3 interface notes — ingestion + Plaid + card payments

Scope: S3 owns `plaid-sync`, `ingest-amex-alert`, `plaid-disconnect`,
the Apps Script, `_shared/canonical.ts`, and the SQL files listed below.
S3 does NOT own `compute-week`/`week-close` (S2) or `live.html`/`live.js`
(S4). Nothing in this file is claimed deployed or live.

## Deploy order (parent applies in this order; nothing was run live)

1. `supabase/payment-kind.sql` §1 (kind constraint) + §2 ONLY if S2's
   restoration-snapshots file has not added the linkage columns.
2. `supabase/dedupe-fix.sql` (drop hash uniqueness; partial unique
   indexes on `external_id` / `plaid_pending_transaction_id`).
3. `supabase/plaid-accounts.sql` (plaid_accounts + item status columns).
4. `supabase/ingest-secrets.sql` (per-household secrets + nonces +
   rotate function). Then set each household's secret via
   `rotate_household_ingest_secret` (admin) and the matching Apps
   Script property, and set the current secret key in Edge Function
   secrets (`SUPABASE_SECRET_KEY`, else `SUPABASE_SERVICE_ROLE_KEY` —
   legacy key is dead). Remove the old shared `INGEST_SECRET`.
5. Deploy the three Edge Functions + `_shared/canonical.ts`.
6. `supabase/payment-backfill.sql` is COMMENTED OUT on purpose: run its
   Step 0 verification SELECT first, get S2's ruling on locked-week
   handling, back up, and only then un-comment deliberately.
   See the backfill warning — it changes historical week math.

## plaid-sync — interface

- Request: caller JWT + `{household_id}`. Any household member may sync
  (matching the previous behaviour; admin-gating sync is S1/P1-14 scope
  and was not changed here — flagged in the final report).
- Response: `{added, updated, reversed, skipped, items,
  connected_items, skipped_disconnected, truncated,
  no_bank_connected?}`. `truncated: true` means the 200-page safety cap
  was hit with `has_more` still true; the cursor was still persisted
  for resume. `no_bank_connected: true` only when zero items exist.
- Per item: loads `sync_cursor` (never starts at null when one is
  stored), skips `status='disconnected'` items, upserts `plaid_accounts`
  from `/accounts/get`, backfills institution via `/item/get` then
  `/institutions/get_by_id` when `institution_name` is null, paginates
  `/transactions/sync` until `has_more` is false (cap 200, logged
  warning), persists `next_cursor` only after an error-free sequence.
- Row contract for S2 (compute-week MUST consume exactly these):
  pending → `state='provisional'`; posted → `state='verified'`;
  removed → `state='reversed'` + `excluded=true` (never deleted);
  `kind` in `charge|refund|fund_charge|payment|cashback` where
  payment = card payment (Plaid category or merchant pattern),
  cashback = statement credit (pattern), refund = real return only.
  S2 MUST exclude `kind='payment'` and `kind='cashback'` from normal
  week charges, and MUST exclude provisional refunds from week math
  and restoration until `state='verified'` (spec A4: a pending refund
  restores nothing; a pending refund Plaid later removes restores
  nothing — P1-3 + P0-12, S2-owned).
- Dedupe order per tx: `external_id` → `pending_transaction_id`
  (external or plaid_pending column) → canonical-hash match (update
  only) → insert. `dedupe_hash` is never a uniqueness constraint.
- `original_purchase_id` is ALWAYS NULL from plaid-sync: Plaid's sync
  payload carries no refund-to-purchase link, and merchant+amount
  window matching was deliberately not invented. S2 must treat null as
  unlinked.

## ingest-amex-alert — interface

Full contract: `integrations/INGEST_CONTRACT.md` (header
`x-budget-signature`; fields `messageId, auth_results, amount,
merchant, date, household_id, card_suffix, nonce, timestamp`; HMAC
canonical string
`timestamp.nonce.household_id.messageId.amount.merchant.date`;
10-minute window + nonce table; constant-time compare; label only on
`stored:true`). Rows: `source='amex_alert'`, `state='provisional'`
always, `external_id = messageId`, canonical `dedupe_hash` stored for
later Plaid matching.

## plaid-disconnect — interface

- Request: caller JWT + `{household_id, plaid_item_id}`. Admin-only
  (403 for members). Response `{disconnected: true, plaid_item_id}`.
- Calls Plaid `/item/remove` (in-memory token only), then sets
  `plaid_items.status='disconnected'`, `disconnected_at=now()`. Row and
  accounts kept for "Previously connected". Transactions untouched.
  Plaid failure (other than `ITEM_NOT_FOUND`) → 502 and the row is NOT
  marked, so disconnect can be retried. `ITEM_NOT_FOUND` → marked
  (idempotent). Already-disconnected → `{disconnected: true,
  already_disconnected: true}`.
- After disconnect, plaid-sync skips the item; Gmail ingestion is
  unaffected (spec Phase 3 disconnect demo).

## Cross-workstream dependencies (open, not assumed done)

- S1: `plaid_items_public` view concept (must exclude
  `access_token_encrypted`; column list to be confirmed by S1) — no S3
  function depends on it today, and no S3 function returns ciphertext.
- S1: restrict `get_plaid_ciphertext` / `update_plaid_sync` from
  `authenticated` members to admin/service identity (P1-16). S3's
  function-side mitigation is documented in plaid-sync's header; the
  grant change itself is S1's migration, not claimed here.
- S2: week-math exclusions for `payment`/`cashback` kinds and for
  provisional refunds (above); locked-week handling for the payment
  backfill; restoration snapshots file (linkage columns — see deploy
  order §1); refund matcher for `original_purchase_id`.
- S4: manual rows must set `dedupe_hash = canonical hash + '-' +
  random suffix` (dedupe-fix.sql); live UI must surface
  `plaid_accounts` / disconnected state and the sync `truncated` /
  `no_bank_connected` flags — S3 returns them but does not render them.
