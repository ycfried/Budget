# Gmail → ingest-amex-alert contract (S3, authoritative)

One contract end to end. The Apps Script (`integrations/gmail-apps-script.gs`)
and the Edge Function (`supabase/functions/ingest-amex-alert/index.ts`) must
match this document exactly. If either side drifts, ingestion breaks loudly
(401/202/500, message left unlabelled) rather than silently — that is the
intended failure mode. Fixes audit P1-1 and P1-2.

This contract supersedes the old script/function behaviour (header
`X-HB-Signature`, raw-body HMAC, shared `INGEST_SECRET`, unconditional
`HB_PROCESSED` labelling, `auth_results === 'pass'`). None of that old
behaviour remains in either file.

## 1. Transport

- Script polls personal Gmail (Plan B) for Amex Large Purchase alerts only:
  `in:inbox -label:HB_PROCESSED from:(americanexpress.com) "Large Purchase"`.
  Tighten sender/subject terms once a real alert has been inspected.
- Script POSTs one JSON body per message to the `ingest-amex-alert` function URL.
- Script Properties (never in the repo): `WEBHOOK_URL`, `HOUSEHOLD_ID`,
  `HOUSEHOLD_INGEST_SECRET` (per-household secret; the old `SHARED_SECRET`
  property is not read).

## 2. Header

- Exactly one signature header: **`x-budget-signature`**
  (HTTP header names are case-insensitive, but both sides use this spelling).
- Value: HMAC-SHA256 of the canonical string (§4), hex-encoded, lowercase.

## 3. Body fields (exactly these; no `from`, `subject`, or raw `body`)

| Field | Type | Rule |
|---|---|---|
| `messageId` | string | Gmail message id (`msg.getId()`). Stored as `transactions.external_id`; it is the dedupe identity for Gmail (§6). |
| `auth_results` | string | The `Authentication-Results` header, **verbatim** (`msg.getHeader('Authentication-Results')`), unparsed. Empty string if absent (then quarantined, §7). |
| `amount` | integer | Amount in **integer cents** (e.g. `4800` for $48.00). A decimal-dollar string (`"48.00"`) is also accepted by the function, but the script always sends integer cents. |
| `merchant` | string | Merchant name exactly as parsed by the script (see §5). Stored upper-cased/normalised server-side; the signature covers the as-sent string. |
| `date` | string | **`YYYY-MM-DD` only** (message date in `America/New_York`). ISO timestamps are rejected as unparseable. Note: email receipt time is not purchase time (spec B3); the Plaid row carries the authoritative date on reconciliation. |
| `household_id` | string | Household UUID from Script Properties. Never trusted alone — the HMAC must verify against that household's stored secret (§7 step 1). |
| `card_suffix` | string | Last 4 of the card if found in the alert text, else `'0000'`. |
| `nonce` | string | Fresh random value per send attempt (script: UUID without dashes). Never reused. |
| `timestamp` | integer | Epoch **seconds** at send time (`Math.floor(Date.now()/1000)`). |

## 4. HMAC canonical string (exact)

```
timestamp + '.' + nonce + '.' + household_id + '.' + messageId
  + '.' + amount + '.' + merchant + '.' + date
```

- `.` is a literal dot separator; no trailing dot, no whitespace, no newline.
- `amount` is `String(amount)` exactly as sent in the body; `merchant` is
  the merchant string exactly as sent (not the server-normalised form);
  `timestamp` is the epoch-seconds integer exactly as sent.
- Algorithm: HMAC-SHA256, key = the household's secret, message = the
  canonical string UTF-8 encoded, output = lowercase hex (64 chars).
- Worked shape (values illustrative, NOT a real secret or signature):
  `1700000000.abc123.<household-uuid>.msg123.4800.AMAZON.2026-11-01`
- Verification on the function side is constant-time (byte-loop OR-diff,
  no early-exit `.every()`). Length mismatch fails closed.

## 5. Script-side parsing (provisional — see flagged items)

The exact Amex Large Purchase alert template has **not** been confirmed
against a real redacted sample (spec Phase 0 gate). The script therefore
parses best-effort and fails closed:

- Amount: first `$X,XXX.XX` in the message body, else in the subject.
- Merchant: `at <NAME>` phrasing if present, else the subject tail after
  the last `:`/`-`/dash.
- Card suffix: `ending in NNNN` / `•NNNN` / `xxNNNN` if present, else `0000`.
- If amount or merchant cannot be parsed, the script sends **nothing**
  and leaves the message unlabelled for manual review. It never sends a
  guessed value.

## 6. Dedupe

- Gmail dedupe identity is `messageId` (stored as `external_id`).
  A second delivery of the same message returns
  `{stored: true, duplicate: true, state: 'provisional'}`.
- The canonical hash (`supabase/functions/_shared/canonical.ts`:
  `SHA256(normalised merchant | date | signed cents | card suffix)`)
  is stored on every row for later Plaid matching — plaid-sync's step-3
  hash match updates the Gmail row when Plaid sees the same purchase —
  but the hash alone **never** drops a Gmail alert, so two real identical
  purchases (different messageIds) both insert (spec test 20).

## 7. Function verification order (every step fails closed)

1. `household_id`, `nonce`, `timestamp` present; timestamp an integer
   within **10 minutes** of server time (absolute difference ≤ 600 s),
   else 401.
2. Per-household secret looked up from `household_ingest_secrets`
   (service role only; no authenticated grants). Unknown household or no
   secret → 401. HMAC verified constant-time → else 401.
3. Nonce claimed in `ingest_nonces` (`unique(household_id, nonce)`)
   **before** any transaction insert. Reused nonce → 401. (A claimed
   nonce for a later-quarantined alert is not refunded: the script sends
   a fresh nonce on retry, and a quarantined alert is a new signed
   delivery, not a replay.)
4. `auth_results` acceptance rule (exact): the verbatim header must
   mention `americanexpress.com` AND contain `dkim=pass` AND contain
   `spf=pass` (case-insensitive). Anything else → **202**
   `{quarantined: true, stored: false, reason: 'authentication-results not pass'}`.
5. Fail-closed parse: amount parseable, merchant non-empty,
   date matches `^\d{4}-\d{2}-\d{2}$`. Else **202**
   `{quarantined: true, stored: false, reason: 'unparseable alert'}`.
6. Insert as `source='amex_alert'`, `state='provisional'`,
   `kind` by merchant pattern (`payment`/`cashback` patterns in
   `_shared/canonical.ts`, else `refund` if negative, else `charge`).
   Insert failure → 500. Success → **200**
   `{stored: true, duplicate: false, state: 'provisional'}`.

## 8. Script labelling rule (exact)

- Label the thread `HB_PROCESSED` **only** when the function response
  parses as JSON and `stored === true`. That includes the
  `duplicate: true` case (the purchase is already stored).
- **Never** label on 401, 202 (quarantined), 500, fetch failure, or
  unparseable response. **Never** label unconditionally.
- Consequence, stated plainly: a quarantined alert is retried on every
  poll until its cause is fixed (new nonce each time). That is
  deliberate — a silently-labelled quarantined alert is how P1-1 lost
  alerts. If retry noise becomes a problem, the parent should add an
  explicit script-side quarantine label as a separate, deliberate change,
  not by weakening this rule silently.

## 9. Service key (deploy note — parent action)

- The function reads its key from env with fallback order:
  **`SUPABASE_SECRET_KEY` then `SUPABASE_SERVICE_ROLE_KEY`**.
- The legacy service-role key is dead (it failed for bootstrap-household
  on Nov 1). **The parent must set the current secret key in Edge
  Function secrets before deploying this function.** Do not claim the
  legacy key works. If neither env var is set, the function returns 503
  (`ingest not configured`), never a silent fallback.
- The old single shared `INGEST_SECRET` must be removed from Edge
  Function secrets once per-household secrets are live, so it cannot be
  replayed against any household.

## 10. Residual risks and flagged items (not decided silently)

- **Secret storage:** the function needs the secret value to verify the
  HMAC, so `household_ingest_secrets` stores the value (not a hash) in
  a table readable only by the service role (RLS on, no authenticated
  policies). Anyone holding the service-role key or SQL-editor access
  can read it. Rotation is via `rotate_household_ingest_secret`
  (admin-only, write-only, ≥ 32 chars). Moving the secret to a dedicated
  vault is a parent follow-up.
- **Auth-results rule:** requiring both DKIM **and** SPF to pass may
  quarantine legitimate alerts if Amex (or an intermediate) fails SPF
  on some path. Fail-closed was chosen; the parent should confirm or
  deliberately relax this rule after inspecting a real alert's headers.
  Nothing is mis-stored either way — quarantined alerts are visible as
  202s in script logs, not in transactions.
- **Alert parser:** §5 patterns are provisional until checked against a
  real redacted Amex alert sample (spec Phase 0 gate). Do not present
  Gmail ingestion as proven until a real alert has landed end to end.
- **Date:** the script's date is the message date, not necessarily the
  purchase date. Week assignment for provisional Gmail rows is therefore
  provisional until Plaid reconciliation corrects it.
