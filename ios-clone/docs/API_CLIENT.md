# OnBudgetKit API layer — notes for screen builders

Basis: live web **v66** (`origin/main` 872ae11). All call shapes were read
from `origin/main`: `live.js` call sites, `supabase/*.sql` RPC definitions,
and `supabase/functions/*/index.ts`. The client displays server figures
and never recomputes week math.

## Files

```
ios-clone/OnBudgetKit/
├── Package.swift                  # scaffold manifest; target root widened
│                                  #   to "Sources" so Sources/API/ is in
│                                  #   the module (see "Layout notes")
└── Sources/
    ├── OnBudgetKit/               # scaffold: tokens, TitleCase, Configuration
    ├── API/
    │   ├── SupabaseClient.swift   # GoTrue auth, session persistence/refresh
    │   ├── PostgrestClient.swift  # typed table reads + member inserts
    │   ├── RPCs.swift             # one typed fn per RPC the app calls
    │   ├── EdgeFunctions.swift    # typed Edge Function invocations
    │   ├── Models.swift           # Codable rows + display aggregates
    │   ├── Errors.swift           # error mapping + LoadState
    │   └── SHA256.swift           # pure-Swift SHA-256 (dedupe hashes)
    └── Tests/OnBudgetKitTests/    # unit tests (fixtures only, no network)
        ├── APIRequestTests.swift
        ├── APIDecodingTests.swift
        ├── APISummaryAndHashTests.swift
        └── APIErrorMappingTests.swift
```

## How screens call it

```swift
let client = SupabaseClient()                 // UserDefaults session store
try await client.signIn(email: email, password: password)

let week = try await client.functions.computeWeek(householdId: householdId)
let (rows, hasMore) = try await client.postgrest.transactionsPage(householdId: householdId)
// hasMore is true exactly when a probe row came back (fetch limit+1).

try await client.rpcs.excludeTransaction(txnId: id, reason: "Duplicate")
```

* `client.postgrest` — reads + the two member inserts (manual / CSV
  transactions, fund requests, audit rows).
* `client.rpcs` — mutations. Every refusal text is carried through
  unchanged: catch `OnBudgetError` and show `error.userMessage`.
  `.sessionExpired` means "Your sign-in expired" + a Sign in again action.
* `client.functions` — compute-week, week-close, Plaid, Gmail, delete-account.
* Loading: render `LoadState` — `.loading`, then `.loaded` or `.failed`
  with a retry. Never leave a spinner up with no error (the web app has
  a live "Loading…" hang; the clone must not copy it). Requests time out
  at 30 s (`.timedOut`).

## Server rules the client must not re-derive

* Week math is server-authoritative. `computeWeek` sends ONLY
  `household_id` (+ optional Sunday `week_start`) — never D, T, or credit.
* The 35-day lock: a week's transactions are immutable once the current
  Sunday week is more than 35 days past the transaction's Sunday week.
  The server raises `week is locked: …`; the client shows it verbatim.
* Extra Fund top-ups are shortfall-first (server split is authoritative;
  the client preview is informational only). Idempotency keys
  (`p_client_key`) are UUIDs reused across retries of the same attempt.
* Charity is 10% on money actually received + manually entered amounts,
  from November 2026. Pending gifts count toward Given only once posted.
* `add_temp_increase` is dead: the Temporary Increase box writes one
  `set_weekly_allowance_override` row per week (1–4 weeks, new total).
* Refunds link by hand via `linkRefund`; auto-linking is server-side only.

## RPC inventory (all implemented, exact names + params)

| RPC | Params | Notes |
|---|---|---|
| `reclassify_transaction` | `txn_id, new_kind, reason` | Admin; 35-day lock. Never send `charity` — use mark-as-charity. |
| `exclude_transaction` | `txn_id, reason` | Admin; 35-day lock. Moves to Trash. |
| `restore_transaction` | `txn_id` | Admin; 35-day lock. "cannot restore: no prior state recorded". |
| `delete_transaction` | `p_transaction_id` | Admin; hand-entered rows only. |
| `mark_transaction_charity` | `p_transaction_id` | Admin; charge only, pending/posted, no fund allocation, ≥ Nov 1. |
| `link_refund` | `p_refund_id, p_purchase_id` | Admin; returns linked purchase id. |
| `unlink_refund` | `p_refund_id` | Admin; refused after a restoration exists. |
| `dismiss_refund_link_suggestion` | `p_refund_id, p_purchase_id` | Admin; dismissals stick. |
| `resolve_duplicate_candidate` | `p_candidate_id, p_action, p_note, p_remember_alias` | Admin; `merge` / `separate`. No bulk merge. |
| `reopen_duplicate_candidate` | `p_candidate_id` | Admin; merged pairs undo from Trash, not here. |
| `resolve_held_refund` | `p_held_id, p_action, p_note` | Admin; `release` / `resolve` / `write_off`. "held refund already resolved". |
| `approve_and_allocate` | `p_request_id, p_amount_cents, p_override_reason` | Admin; split when amount < requested; insufficient-fund → retry with reason. |
| `decline_fund_request` | `p_request_id` | Admin. |
| `allocate_fund` | `p_household_id, p_amount_cents, p_note, p_override_reason` | Admin; same override rule. |
| `add_fund_money` | `p_household_id, p_amount_cents, p_note, p_client_key` | Admin; returns shortfall-first split + `replayed`. |
| `update_fund_shortfall` | `household_id, shortfall_cents` | Admin; **live UI never calls it** — server maintains the shortfall. Included per brief. |
| `set_account_nickname` | `p_household_id, p_plaid_item_id, p_plaid_account_id, p_card_suffix, p_nickname` | Admin; nil nickname clears. |
| `set_base_allowance` | `p_household_id, p_cents` | Admin; current week onward. |
| `set_weekly_allowance_override` | `p_household_id, p_week_start, p_allowance_cents` | Admin; Sunday only; new total. Multi-week helper loops 1–4 weeks. |
| `set_charity_default_rate` | `p_household_id, p_rate_bp` | Admin; 0–10000 bp. |
| `record_charity_income` | `p_household_id, p_amount_cents, p_income_date, p_source_label, p_rate_bp, p_note` | Admin; returns income id / rate / committed. |
| `correct_charity_income` | `p_income_id, p_amount_cents, p_income_date, p_source_label, p_rate_bp, p_note` | Admin; reverses + reinserts. |
| `record_charity_gift` | `p_household_id, p_merchant, p_amount_cents, p_date, p_card_suffix, p_note, p_dedupe_hash, p_client_key` | Admin; returns transaction id / `replayed`. |
| `create_household` | `p_name` | Returns household id. Name required (max 80). |
| `join_household_by_code` | `code` | Returns household id or nil (invalid code). Rate-limited: 5/hour. |
| `list_household_members` | — | All members of caller's household; no full email. |
| `remove_household_member` | `p_user_id` | Admin; never self, never last admin. |

## Edge Function inventory

| Function | Request | Response / notes |
|---|---|---|
| `compute-week` | `household_id, week_start?` | `WeekResult` (flat; wrapped `result` tolerated). Any member. |
| `week-close` | `household_id` | `WeekCloseResult`; `weeks_closed: 0` is a no-op. Admin. |
| `plaid-link` | `household_id` | `{link_token, expiration}`. Admin. App presents Plaid Link itself. |
| `plaid-exchange` | `household_id, public_token, institution_name?` | `{item_id, connected, duplicate, duplicate_of}`. Admin. |
| `plaid-sync` | `household_id` | Counts; 502 partial failure keeps counts + `failed_items`/`failed_institutions` — use `plaidSyncAllowingPartialFailure`. Admin. One sync at a time. |
| `plaid-disconnect` | `household_id, plaid_item_id` | `{disconnected, plaid_item_id, already_disconnected}`. Admin. |
| `plaid-account-disconnect` | `household_id, plaid_item_id, plaid_account_id` | `{disconnected, …, item_disconnected}`. Admin. |
| `plaid-webhook-register` | `household_id, enabled` | `{webhook_url, enabled, results[]}`. Partial failure stores nothing — switch must not move. Admin. |
| `gmail-oauth-start` | `household_id?` | `{auth_url}`. 409 → multi-household admin must name one (status 409 preserved). Admin. |
| `gmail-poll` | `household_id` | Counts + per-connection `errors[]` (read them — no top-level error on per-connection failure). Admin. |
| `gmail-disconnect` | `household_id, connection_id` | `{disconnected, connection_id}`. Admin. |
| `delete-account` | `{}` | `{deleted: true}` / `{error, step}`. Via `SupabaseClient.deleteAccount()`. |

Never client-invoked (server-to-server only, modelled or noted, not exposed):
`plaid-webhook`, `gmail-oauth-callback`, `ingest-amex-alert`.

## Deliberately absent RPCs (do not re-add without a live grant check)

* `add_temp_increase`, `attest_savings`, `record_savings_entry`,
  `approve_fund_request` — no live.js call sites AND EXECUTE revoked live
  Nov 9, 2026 (`supabase/p2-revoke-dead-rpcs.sql`). Replacements:
  `setWeeklyAllowanceOverride`, `approveAndAllocate`; savings is read-only.
* `auto_link_refund`, `link_refunds_to_purchase`, `get_plaid_ciphertext`,
  `update_plaid_sync`, `log_webhook_event` — `service_role` only.
* `rotate_household_ingest_secret` — manual rotation path, no app flow.

## Layout notes (deviations from the brief, forced by the scaffold)

* **Package manifest**: the brief's `ios-clone/Package.swift` would have
  created a second package next to the scaffold's
  `ios-clone/OnBudgetKit/Package.swift`. It was not kept. Instead the
  scaffold manifest's target root was widened from `Sources/OnBudgetKit`
  to `Sources`, so `Sources/API/` compiles into the same `OnBudgetKit`
  module. Do not narrow it back — the API files would silently drop out.
* **Tests live in the package** (`OnBudgetKit/Tests/OnBudgetKitTests/`),
  not `ios-clone/OnBudgetTests/`. That directory is the Xcode test target
  with explicit per-file membership: adding files there without editing
  the `.pbxproj` (forbidden to this workstream) leaves them uncompiled,
  and CI's `swift test --package-path ios-clone/OnBudgetKit` step only
  runs the package tests. The coordinator/scaffold can move them into the
  Xcode target with a `.pbxproj` edit if desired.
* **Configuration**: `SupabaseConfiguration.live` derives its URL/key from
  the scaffold's `Configuration` (same module) instead of duplicating them.
* **Session store**: the shipped default is UserDefaults. Face ID
  unlock (`BiometricUnlock` / `BiometricSessionStore`) swaps in the
  biometric Keychain store via `SupabaseClient.replaceSessionStore`
  on opt-in, and back on opt-out — see PROGRESS.md "Face ID unlock".
* **Platforms**: the scaffold manifest targets iOS 18 / macOS 14; the API
  code uses Foundation only and compiles under those.

## Ambiguities found (live.js line / source)

1. `approve_and_allocate` params differ across SQL files: `04-admin-rpcs.sql`
   defines unprefixed args, but the canonical definition
   (`approve-ambiguity-fix.sql`, `test/p1-fixes-audit-r2.test.mjs:202`) and
   live.js:1256 use `p_request_id, p_amount_cents, p_override_reason`.
   This client uses the `p_` names, matching the live calls.
2. Transaction `kind` CHECK differs: `refund-classification-income-kind.sql`
   allows 8 kinds (incl. `transfer`, `income`); `r13-charity.sql` re-adds a
   6-kind constraint that drops them. If the r13 version is live, a
   reclassify to `transfer`/`income` would fail at the CHECK even though
   the RPC allows it. `TransactionKind` decodes any string via `.other`
   so a row with an unexpected kind never breaks a list.
3. `compute-week` returns its fields flat, but live.js:605 reads
   `week.result ?? week`. The client decodes both shapes.
4. `plaid_items_public`: `INTERFACE.md` says `sync_cursor` is exposed,
   but the view in `03-plaid-vault.sql` has no such column and live.js
   never selects it. The client does not model it.
5. Password reset: the web app redirects to its `reset.html`; the native
   app must pass its own allow-listed deep link as `redirectTo` (or nil
   for the project Site URL). Completing the reset (setting the new
   password on the recovery session) is the app's job — use
   `changePassword(_:)` while that session is active.
6. `update_fund_shortfall` is granted and implemented, but the live UI
   never calls it; the shortfall is maintained server-side. Screens
   should not call it in normal flows.
7. `households.allowance_set_at == null` means the $375 base allowance is
   the schema default, not a choice — see `householdAllowance`.
8. Plaid Link UI is not in this package: it returns the link token only.
   The app must present Plaid Link (SDK) and call `plaidExchange` on success.
9. `gmail-poll` / `plaid-sync` staleness: both return a `stale` flag with
   minutes-since-previous-run; the client surfaces it, the UI words it.

## Verification

* Unit tests: fixtures only, no network, no live data. Run
  `swift test --package-path ios-clone/OnBudgetKit`.
* **Locally verified Nov 9, 2026 (Swift 6.1.2, Linux): 57 tests, 0
  failures** — run against a scratch copy of the package with only the
  `platforms:` block removed (Linux ignores Apple platforms; the
  committed manifest is untouched). That run caught and fixed four
  real bugs in this layer: (1) a UTC-vs-New-York weekday shift that
  made every Sunday fail the multi-week override check; (2) GoTrue's
  dead-refresh-token text ("Refresh Token Not Found") misclassified
  as `.notFound`; (3) `invalid_grant` on sign-in misclassified as
  session-expired instead of "Incorrect email or password";
  (4) unrecognised 400 Edge Function errors surfacing as generic
  `serverError` instead of `.validationFailed`. The library files
  also carry `#if canImport(FoundationNetworking)` imports so the
  same sources build on Linux CI and Apple platforms.
* **Scaffold manifest issue (for the coordinator, not fixed here):**
  `Package.swift` declares `swift-tools-version: 5.9` but uses
  `.iOS(.v18)`, which requires PackageDescription 6.0 — `swift test`
  fails at manifest load ("'v18' is unavailable"). Fix in the
  scaffold: bump the tools version to 6.0, or drop the platform to
  `.iOS(.v17)`. Until then, no CI or local `swift test` run can load
  the package as committed.
* **No live calls have been made.** Nothing here was run against the real
  household, the owner's account, or real Plaid items. A screen agent must
  run the calls against the test backend first.
* CI: the simulator workflow file is NOT on origin yet (blocked on token
  scope — see `ios-clone/PROGRESS.md`). No CI run is claimed here.

## Live-backend defects this client surfaces but does not fix

Synthetic live proofs (Nov 9, 2026, test household) found two
server-side defects in the RPCs this client calls. They are SQL-level,
out of scope for this package — the client carries the refusals
through verbatim and must NOT work around them:

1. Merged duplicates can never be restored from Trash:
   `resolve_duplicate_candidate` excludes without recording
   `pre_exclusion_state`, although the UI promises restoration.
2. Held refunds can never be released: `resolve_held_refund`
   (atomic version) expects `status='pending'` but the
   `held_refunds` CHECK constraint allows only
   `held`/`written_off`/`resolved`, and Review shows "Resolved" with
   no Release button.

Screens should surface the resulting refusal text and the fix belongs
in the web/SQL workstream (branch-only first, exact SQL to the owner
before any live apply).
