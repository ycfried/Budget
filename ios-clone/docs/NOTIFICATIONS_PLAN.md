# OnBudget Notifications — Plan

Date: Nov 16, 2026. Branch: `native-fix-notifications` (from `2801f8f`, build 40).
Status: plan + code in this PR. Do NOT merge, do NOT upload. Push delivery
cannot be proven until Mats's .p8 key arrives (see §9).

## 1. Triggers (13, confirmed by the owner)

One notification per event, never per row. A sync run that adds several
transactions sends one push per type (see trigger 6). Every type has a
per-user toggle (§5); a missing preferences row means all on.

| # | Type | Fires when | Recipients | Toggle | Dedupe key |
|---|------|-----------|------------|--------|-----------|
| 1 | `week_closed` | `week-close` closes ≥ 1 week | All members | `week_closed` | `week_closed:<household>:<week_start>` |
| 2 | `new_week` | Same `week-close` run as #1 (a new week started) | All members | `new_week` | `new_week:<household>:<week_start>` |
| 3 | `over_budget` | Current week's available goes below $0 (checked on the new-transaction path and the week-close path) | All members | `over_budget` | `over_budget:<household>:<week_start>` (once per week) |
| 4 | `new_income` | A sync ingests a new income transaction (see #6) | All members | `new_income` | `income:<dedupe_hash>` |
| 5 | `monthly_statement` | A monthly statement is generated (hook ready; the statement tool itself is NOT built here — see §7) | All members | `monthly_statement` | `monthly_statement:<household>:<YYYY-MM>` |
| 6 | `new_transaction` | A sync ingests new transactions: `plaid-sync` added > 0, or `gmail-poll` stored > 0. Grouped by kind — one push per kind present | All members | `new_purchase` / `new_income` / `new_charity` (per kind) | `<kind>:<dedupe_hash>` (see §1.1) |
| 7a | `member_joined` | A member joins (client call after `join_household_by_code` succeeds) | All members except the joiner | `member_joined` | `member_joined:<household>:<user_id>:<YYYY-MM-DD>` |
| 7b | `member_left` | A member is removed / leaves (client call after `remove_household_member` succeeds) | All remaining members | `member_left` | `member_left:<household>:<user_id>:<YYYY-MM-DD>` |
| 8 | `gmail_expiring` | `gmail-poll` finds a Gmail connection in `error` status (auth failed / refresh token dead) | Admins only | `gmail_expiring` | `gmail_expiring:<household>:<connection_id>:<YYYY-MM-DD>` (once per day per connection) |
| 9 | `fund_request` | A `fund_requests` row is inserted with `status = 'pending'` (client call after a successful insert) | Admins only, excluding the requester | `fund_request` | `fund_request:<request_id>` |
| 10 | `large_purchase` | A purchase (kind `charge`) is >= the household's large-purchase threshold (see §2) | All members | `large_purchase` | Derived from the purchase's `purchase:<dedupe_hash>` claim (same row, no second key) |
| 11 | `bank_broken` | `plaid-sync` finds a bank item whose `/transactions/sync` fails with an auth error (`ITEM_LOGIN_REQUIRED`, `INVALID_ACCESS_TOKEN`, `ITEM_NOT_FOUND`) — the bank needs re-login | Admins only | `bank_broken` | `bank_broken:<household>:<item_id>:<YYYY-MM-DD>` (once per day per item) |
| 12 | `budget_increased` | The weekly budget is made LARGER — a temporary-allowance increase, a base-allowance increase, or an "Add to Budget" top-up (client call after the increase is saved; only when new > old, never on a decrease) | All members except the admin who made the change | `budget_increased` | `budget_increased:<household>:<week_start>:<YYYY-MM-DD>` |
| 13 | `needs_review` | Something in the Review queue needs admin attention — a new possible duplicate (created during a sync) or a held refund (created during a week close). See §1.3 for the split from #9 | Admins only | `needs_review` | `needs_review:duplicate:<candidate_id>` / `needs_review:held_refund:<held_id>` (one per item, claimed atomically) |

### 1.1 Dedupe — the transaction-identity rule (owner, Nov 16)

Never report the same transaction twice from email + bank. The dedupe key
is the transaction's **dedupe_hash** (the identity the app's own merge logic
already uses — an email alert and its bank row hash the same), NOT the row
id. `push-notify` claims keys atomically: it inserts the candidate keys
into `push_deliveries` with `onConflict do nothing` and notifies only about
the rows whose keys were actually inserted. A purchase first seen by email
is not re-notified when the bank row arrives, and vice versa. Rows with no
dedupe_hash fall back to `purchase:<row_id>`.

### 1.2 Copy — no source naming (owner, Nov 16)

A notification NEVER names the source — no "from email", "from bank",
"from Amex". It names only the TYPE of transaction plus amount/merchant.
Title Case titles, plain bodies.

- Week closed: "Week Closed" / "Week of Oct 25, 2026 is closed. $12.34 left went to Savings." (fund name = the household's current name; no-surplus variant drops the second sentence; multi-week: "2 weeks are closed. $12.34 left went to Savings.")
- New week: "New Week" / "A new week started. $300.00 to spend this week." (amount from `compute-week` for the current week; falls back to "A new week started." if the figure is unavailable)
- Over budget: "Over Budget" / "You're over budget this week. $45.67 over."
- New purchase: "New Purchase" / "$12.34 at Amazon." (2+: "3 new purchases, $45.67 in total.")
- New income: "New Income" / "$1,200.00 from Acme Payroll." (2+: "2 new incomes, $1,450.00 in total.")
- New charity: "Charity Gift" / "$10.00 to Toiremorg." (2+: "2 charity gifts, $12.00 in total.")
- Monthly statement: "Monthly Statement" / "Your October statement is ready."
- Member joined: "Member Joined" / "Shuki joined the household."
- Member left: "Member Left" / "Shuki left the household."
- Gmail expiring: "Gmail Connection Expiring" / "Your Gmail connection needs attention. Reconnect it in Settings so purchase alerts keep coming."
- Fund request: "Fund Request Waiting" / 'Shuki asked for $50.00 from Savings. "New tires."' (no note: 'Shuki asked for $50.00 from Savings. Tap to review.')
- Large purchase: "Large Purchase" / "$150.00 at Best Buy — a large purchase." (2+: "2 large purchases, $320.00 in total.")
- Bank broken: "Bank Connection Broken" / "Your bank connection needs attention. Reconnect it in Settings to keep purchases syncing."
- Budget increased: "Budget Increased" / "Budget increased by $50.00. Weekly budget is now $450.00."
- Needs review: "Possible Duplicate" / "Two purchases look the same. Tap to review." (single held refund: "Refund Held for Review" / "A $25.00 refund is held for review. Tap to review."; 2+: "Needs Review" / "3 items need review. Tap to review.")

Deep links (`data.screen`): `week` → Home (week_closed, new_week,
over_budget, budget_increased), `purchases` → Transactions (new_purchase,
new_income, new_charity, large_purchase), `settings` → Settings
(member_joined, member_left, gmail_expiring, bank_broken), `money` →
Funds (fund_request, needs_review — the Review queue lives under Funds), `statement` → Home for now (monthly_statement; the
statement viewer will define its own screen later).

### 1.3 Notes on the trigger list

- **#4 and #6 are one ingestion path.** "New income" and "New transaction"
  overlap: an income IS a new transaction. They are implemented as one
  path grouped by kind, with a toggle per kind, so an income is notified
  exactly once (as income), never twice.
- **#3 fires on the next sync after the crossing.** The over-budget check
  runs inside `push-notify` (via `compute-week`, the single source of
  truth for the week's available — no formula duplicated). It is evaluated
  when a sync ingests charges and when a week closes. If a week is already
  over budget and no sync runs, nothing fires until the next sync.
- **#2 fires when the close runs, not at midnight Monday.** Week-close is
  client-driven (an admin opening the app), so the "new week" push arrives
  when the close happens, which may be after the week boundary.
- **#10 replaces the regular purchase push for that row.** A purchase at
  or above the threshold is notified as a large purchase, NOT also as a
  regular new purchase (one push per transaction, never two). A sync run
  with one large and two small purchases sends one large-purchase push
  (for the large one) and one new-purchase push (for the two small ones).
  The large-purchase toggle and the new-purchase toggle are independent:
  with new-purchase off and large-purchase on, only large purchases
  notify; with large-purchase off and new-purchase on, a large purchase
  notifies as a regular purchase.
- **#12 fires only on increases.** The client compares old vs new and
  calls push-notify only when new > old. The server verifies the stored
  value matches the claimed new value and that new > old; otherwise it
  returns 400 and sends nothing. A decrease never notifies. The admin
  who made the change is excluded from the recipients (they already
  know); the other member(s) get it.
- **Fund request waiting (#9) was a candidate and is now confirmed.**
  It is built in this PR (it was in the original 3-trigger plan, dropped
  to candidate when the owner did not list it, and re-confirmed Nov 16).
- **#13 vs #9 — kept separate, no double-notify (call made Nov 17).**
  "Needs review" is the Review-queue trigger, and a fund request IS a
  Review item — so the owner said to fold #9 into #13 OR keep both. The
  call: KEEP BOTH, with a clean split. A fund request keeps its own
  trigger because its copy is specific and actionable ("Shuki asked for
  $50.00 from Savings") — folding it into a generic "needs review"
  would make that push less useful. `needs_review` covers the OTHER
  Review items: possible duplicates and held refunds. Each Review item
  maps to exactly one trigger type by its kind, so the same item can
  never fire twice. Refund suggestions are NOT covered: they are
  computed client-side from transactions (no server creation event),
  so there is nothing server-side to fire on — they appear in Review
  when the admin opens it. A server-side suggestion detector would be
  a separate piece if the owner wants pushes for those too.

## 2. Large-purchase threshold — a Funds-page setting

- A dollar-amount field in the **Spending fund's detail** on the Funds
  page, alongside the Weekly Allowance editor (same editor shape: label
  on its own line, $ field + Save + Reset on the row below, 17pt).
  Label: "Large Purchase Threshold". Admin-only (members see the
  read-only value + "Only the admin can change the large purchase
  threshold."). The field has a `$` prefix, like the dollar fields.
- Stored per household: `households.large_purchase_threshold_cents`
  (integer, >= 0). **Default $100.00 (10000 cents)** — a sensible
  default; the user can change it. Set by the RPC
  `set_large_purchase_threshold(p_household_id, p_threshold_cents)`
  (admin-only, SECURITY DEFINER, like `set_base_allowance`).
- The notification fires when a purchase (kind `charge`, money out —
  never income, never a transfer) has `amount_cents >= threshold`.
  `push-notify` reads the threshold from `households` at send time
  (falls back to $100 if the column is not yet migrated).

## 3. "Add to Budget" — one-time top-up (separate button)

- A **separate button** in the Spending fund's detail on the Funds page
  ("Add to Budget"), alongside the other Spending fund actions.
  Temporary Allowance sets a NEW TOTAL that repeats for 1–4 weeks (a
  sustained change); "Add to Budget" is a one-time top-up to the
  CURRENT week's budget only (e.g. +$50 this week). Different intents,
  so a separate button keeps it simple. Temporary Allowance is unchanged.
- Tap → popup (amount field + Add/Cancel, 17pt, iPad 600pt, following
  the Add to Charity popup pattern from build 40). Enter an amount >
  $0 → it adds that amount to the CURRENT week's budget, one-time, this
  week only. The user never does the math — they just enter the amount
  to add. Admin-only.
- Implementation: a new server RPC `add_to_weekly_budget(p_household_id,
  p_week_start, p_amount_cents)` returns the new total. It reads the
  week's current total (the override's allowance, or the base when no
  override exists), adds the amount, and upserts the override for that
  week only — reusing the existing `weekly_allowance_overrides` table
  and the week-close engine's override semantics (the override IS the
  week's total). Atomic server-side, so two admins adding at once
  cannot overwrite each other. The RPC writes the audit_log entry
  ("Added to weekly budget"). The client calls it with the amount only
  and shows the returned new total in the success toast.
- This action fires the **budget-increased** notification (#12): after a
  successful add, the client calls push-notify with the added amount and
  the new total.

## 4. Permission flow

- Asked **once, after first sign-in, when Home first appears with a
  household loaded** — never at first launch, never before the value is
  clear. Guarded by a UserDefaults flag (`onbudget.pushPermissionAsked`):
  if authorization is `.notDetermined` and we have not asked before, ask.
- No custom pre-prompt dialog (the system prompt is the ask). The
  one-line explainer lives in the Settings Notifications card:
  "Get a heads-up when a week closes or a new purchase comes in."
- A decline is respected forever: never re-prompted, no banner. The only
  trace is the Settings row showing the system state and, when off, an
  "Open Settings" button that opens iOS Settings.
- Re-register the token on launch when already authorized (tokens rotate).
  On sign-out / account deletion, unregister best-effort (fire-and-forget).
  All failures are silent to the user.

## 5. Master on/off + per-type toggles (owner, Nov 16, ~11:56 PM)

- Table `notification_preferences`: one row per (user_id, household_id).
  - **Master on/off** `notifications_enabled` (boolean, default true):
    off means the server sends this user NOTHING, whatever the per-type
    flags say. The client shows it as "All Notifications" at the top of
    the Notifications card. When it is off, the per-type toggles do not
    appear at all — never greyed out (standing rule: an action the user
    cannot perform must NOT appear).
  - **Per-type toggles** — one per trigger type, booleans, all default
    true: `week_closed`, `new_week`, `over_budget`, `new_purchase`,
    `new_income`, `new_charity`, `monthly_statement`, `member_joined`,
    `member_left`, `gmail_expiring`, `fund_request`, `needs_review`,
    `large_purchase`, `bank_broken`, `budget_increased` (15 toggles).
- RLS: a user reads/writes only their own rows. Writes go through the
  RPC `set_notification_preferences(...)` (SECURITY DEFINER,
  membership-checked, upsert; all sixteen flags required).
- Client: a Notifications card in Settings (after Profile) showing the
  system state row + the master toggle + one toggle per trigger (only
  while the master is on). A failed save reverts the toggle and shows a
  plain-language error (never raw server text).
- Server: `push-notify` (service role) reads the recipients' rows at send
  time and skips any user whose master is off, and any type a user turned
  off. No row = all on. A missing column (migration lag) reads as on.

## 6. Device-token registration

- Table `push_tokens`: id, household_id, user_id, device_token (hex,
  never logged or returned), platform ('ios'), environment
  ('sandbox'/'production'), last_seen_at. Unique (user_id, device_token).
- RLS: a user may insert/select/update/delete only rows where
  user_id = auth.uid(). Admins may NOT read other members' tokens.
- `register-push-token` Edge Function (`verify_jwt = true`): user JWT,
  membership-checked, upserts the token (or deletes it on unregister).
  Called from the AppDelegate when APNs issues a token, and on sign-out.
- `push_deliveries`: household_id, event_key, sent_at. Unique
  (household_id, event_key). Dedupe store for §1. Rows older than 90 days
  may be pruned.

## 7. Server sending — `push-notify`

- One Edge Function owns all APNs traffic (`verify_jwt = false`, in-code
  dual auth copied from `gmail-poll`: a user JWT is checked for household
  membership; otherwise the bearer must equal the service key).
- The function re-reads the underlying data and derives copy + recipients
  itself. It never trusts the caller's title, body, or recipients.
  It reads `notification_preferences` and `push_tokens` (service role).
- APNs: one HTTP/2 POST per token to `https://api.push.apple.com/3/device/<token>`
  (production) or `https://api.sandbox.push.apple.com/3/device/<token>`
  (sandbox, per the token's environment — never mixed). Headers:
  `authorization: bearer <APNs JWT>`, `apns-topic: <bundle id>`,
  `apns-push-type: alert`, `apns-priority: 10`,
  `apns-collapse-id: <household_id>:<type>`. Body:
  `{aps: {alert: {title, body}, sound: "default"}, data: {...}}`.
  No badge in v1.
- APNs JWT: ES256 from the .p8 key (WebCrypto), header
  `{alg: "ES256", kid: "<key id>"}`, payload `{iss: "<team id>", iat: <now>}`,
  valid 1 hour, cached and re-signed on expiry.
- **When the .p8 key is NOT configured, sending is a safe no-op:** the
  function logs `push-notify: APNs not configured, skipping` and returns
  `{ok: true, skipped: "apns_not_configured"}`. It never crashes, never
  errors, never blocks the caller. The trigger's main work always
  completes.
- Response handling: 200 = delivered to Apple; 410 or 400
  BadDeviceToken/Unregistered = delete the token row immediately;
  429/500/503 = log and drop (no retry queue in v1); any other 400 = log
  the reason, drop the token only if the reason names the token.
- Logging: type, household_id, token count, per-token HTTP status only —
  never device tokens, merchant names, or amounts beyond what the
  household already stores.
- Trigger wiring (all best-effort, must never fail the main work):
  - `week-close`: after a successful close with weeks_closed > 0, calls
    push-notify `week_closed` (with the closed week starts) and
    `new_week`, and `needs_review` (a close can hold a refund for
    review). Not on the 500 restoration-error path.
  - `plaid-sync`: after a successful return with added > 0, calls
    push-notify `new_transaction` (source plaid) and `needs_review` (a
    sync can create possible duplicates); when an item's
    `/transactions/sync` fails with an auth error code, calls push-notify
    `bank_broken` (once per day per item, via the dedupe key).
  - `gmail-poll`: after a successful return with stored > 0, calls
    push-notify `new_transaction` (source gmail) and `needs_review` (a
    sync can create possible duplicates); when a connection is
    in `error` status, calls push-notify `gmail_expiring` (once per day
    per connection, via the dedupe key).
  - Client (native app): after a successful `join_household_by_code`,
    calls push-notify `member_joined`; after a successful
    `remove_household_member`, calls push-notify `member_left`; after a
    successful fund-request insert, calls push-notify `fund_request`;
    after a temporary-allowance increase, a base-allowance increase, or
    an "Add to Budget" top-up, calls push-notify `budget_increased`
    (only when new > old).
  - `compute-week` gains the same service-key path `gmail-poll` has, so
    `push-notify` can call it server-to-server for the new-week amount
    and the over-budget check. (User path unchanged.)
- No new scheduled job. The existing `hourly-plaid-sync` (hourly) and
  `five-minute-gmail-poll` (every 5 min) cron jobs already drive the sync
  paths. TestFlight builds use production APNs; development builds use
  the sandbox.

## 8. Monthly statement — OWED as a separate piece

The monthly-statement notification hook IS built in this PR
(`push-notify` type `monthly_statement`, copy, recipients, toggle,
dedupe key, `statement` deep link). The **statement tool itself is NOT
built here** — it is too big to fold in cleanly (it needs a monthly
aggregator, storage, and a viewer screen; a notification with nowhere to
open is a dead end).

Owed piece (separate plan + build): a `monthly-statement` generator —
monthly aggregates (spent, income, charity given, savings change, debt),
stored per household per month, a viewer in the app, and a monthly trigger
(1st of the month) that generates the statement and then calls
`push-notify {type: "monthly_statement", household_id, month: "YYYY-MM"}`.
Until that tool exists, nothing ever calls the hook and no statement
notification fires.

## 9. What depends on Mats vs what is done in code

Done in code (this PR): the plan, client permission/token/toggles/tap
routing, `push-notify` + `register-push-token`, all trigger wiring, the
SQL migration file, kit + TS tests, the monthly-statement hook, the
large-purchase threshold setting, the "Add to Budget" button + RPC.

Waits on Mats (Apple Developer account holder — only he can do these):
1. The **.p8 key file + key ID** (APNs key, created in his developer
   account; downloads once). Until it arrives, sending is a safe no-op.
2. **Enable the Push Notifications capability on the App ID**
   (com.onbudget.ios) and regenerate the "OnBudget App Store"
   provisioning profile. The `aps-environment` entitlement is NOT in
   this repo on purpose: `ios-clone/scripts/validate_project.py`
   requires `OnBudget.entitlements` to contain ONLY the App Groups key
   (it names push as a forbidden stray key), and the simulator run
   fails if it is added. The entitlement comes from the provisioning
   profile at archive time, once the App ID has push enabled — so the
   next TestFlight upload's manual signing picks it up. If the upload
   fails on entitlements, this is the step to check.

Supabase secrets to set when the key arrives (names only, never values):
- `APNS_KEY_P8` — the .p8 file contents
- `APNS_KEY_ID` — the 10-char key id
- `APNS_TEAM_ID` — the 10-char Team ID
- `APNS_BUNDLE_ID` — the bundle id (`com.onbudget.ios`)

## 10. Not in v1

No rich media, no reply actions (no Approve/Decline on a notification),
no quiet hours, no sound choice, no badge counts, no critical alerts, no
notification history inside the app, no web push, no per-device targeting
UI, no retry queue, no DB trigger via pg_net (client calls + sync hooks
are the v1 wiring; pg_net is the long-term hardening for join/leave and
fund requests).

## 11. Files

- Plan: `NOTIFICATIONS_PLAN.md` (this file; copy in the repo at
  `ios-clone/docs/NOTIFICATIONS_PLAN.md`).
- SQL (owed — apply via dashboard, do NOT apply from this task):
  `supabase/push-notifications.sql` — `push_tokens`, `push_deliveries`,
  `notification_preferences` (master on/off + 15 toggles) + RLS +
  `set_notification_preferences` RPC; `households.large_purchase_threshold_cents`
  (default $100) + `set_large_purchase_threshold` RPC;
  `add_to_weekly_budget` RPC (one-time top-up, audited).
- Server: `supabase/functions/push-notify/index.ts` (+ `apns.ts`),
  `supabase/functions/register-push-token/index.ts`; hooks in
  `week-close`, `plaid-sync`, `gmail-poll`; service-key path in
  `compute-week`; both functions added to `supabase/config.toml`.
- Client: `ios-clone/OnBudgetKit/Sources/Notifications/` (manager +
  preferences), `ios-clone/OnBudget/AppDelegate.swift`,
  `AppViewModel` (permission ask + tap routing),
  `Settings/NotificationsSettingsView.swift`,
  `HouseholdViews` (join call), `MembersSettingsView` (remove call),
  `FundsViewModel` (fund-request call, budget-increased calls,
  add-to-budget, large-purchase threshold),
  `FundsRulesView` (threshold editor), `FundsView` (Add to Budget
  button + popup), `OnBudget.xcodeproj/project.pbxproj` (the 3 new app
  files added — the simulator validator fails without pbxproj entries).
  `OnBudget.entitlements` is deliberately UNCHANGED (App Groups only —
  see §9: `aps-environment` comes from the provisioning profile).
- Tests: kit tests (token hex, screen parsing, preference defaults),
  `supabase/tests/push-notify.test.mjs` (copy builders, dedupe keys,
  APNs JWT helper).
