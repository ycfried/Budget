# OnBudget Native iOS — APNs Notification Design (v1)

> Branch: `ios-clone-v66/notify-store` · Baseline: live web **v66**, `origin/main` `872ae11`
> (Merge PR #61, refund-link-and-merge). Sources read for this design:
> `live.js` (week-close call, fund-request insert, `deleteAccountFlow`),
> `supabase/functions/week-close/index.ts`, `plaid-sync/index.ts`,
> `gmail-poll/index.ts`, `supabase/04-admin-rpcs.sql`,
> `supabase/live-admin-rpcs.sql`, `supabase/server-sync-cron.sql`,
> `HANDOFF.md` §§3–5, `FULL_AUDIT_2026-11-09_R5.md`.
>
> Status: **design only**. No server code, no SQL, and no Swift files are
> delivered with this document — the scaffold branch was not up when it
> was written (sibling branches `ios-clone-v66/apiclient` and
> `ios-clone-v66/spec` contain no `ios-clone/` Swift code yet), so the
> client skeleton is a clearly marked code block in §8 below, not files
> on disk. No notification is simulated anywhere: there is no local-only
> demo that pretends to be push.

## 0. Principles

- **Server event, server send.** A notification is sent by the backend
  function that already knows the event happened. The client never
  invents a notification from local state.
- **One notification per event, not per row.** A sync run that adds
  several purchases sends one summary notification, never one per
  purchase. The hourly bank sync and the 5-minute email poll would
  otherwise flood a household.
- **Plain language, Title Case.** Titles follow the app's standing
  Title Case rule (minor words lower). Bodies are short, plain
  sentences — the same voice as the app's toasts and confirm dialogs.
  No jargon ("sync", "webhook", "Plaid") in user-facing copy.
- **No nagging.** Permission is asked once, after first sign-in. A
  decline is respected forever; the app never re-prompts on its own.
- **Household-scoped.** Every notification belongs to exactly one
  household. A device only ever receives notifications for households
  its signed-in user belongs to.
- **Test data only.** Push is tested against synthetic/test households,
  never the live household. TestFlight builds use production APNs;
  development builds use the APNs sandbox.

## 1. The v1 set — three notifications

| # | Event | Server trigger | Recipients | Deep link |
|---|-------|----------------|------------|-----------|
| N1 | Week closed | `week-close` returns `weeks_closed > 0` | **All household members** | Home (week view) |
| N2 | New purchase synced | `plaid-sync` returns `added > 0`, or `gmail-poll` returns `stored > 0` | **All household members** | Transactions |
| N3 | Fund request waiting | `fund_requests` row inserted with `status = 'pending'` | **Admins only** | Funds (fund-request list) |

Recipients are decided by the server at send time from
`household_members` — never by the client, and never by a stored
audience list that can go stale.

### N1 — Week Closed

- **Exact trigger.** The `week-close` Edge Function finishes a run for
  a household with `weeks_closed > 0` in its response payload
  (`supabase/functions/week-close/index.ts`, payload fields
  `weeks_closed`, `releases`, `fund_available_cents`,
  `shortfall_cents`). Today week-close is **not** scheduled: it runs
  when an admin loads the web app (`live.js`, admin-only, once per
  session, fingerprinted per household so a reload does not re-close).
  The send hook lives inside `week-close` itself, so it fires
  whichever caller triggers the close — today's admin app-load, or a
  future scheduled close.
- **Who receives it.** Every member of that household (admin + member).
  Both people share one budget; both need to know the week turned over.
- **Exact copy.**
  - Title: `Week Closed`
  - Body (one week closed, surplus moved to the fund):
    `Week of Oct 25, 2026 is closed. $12.34 left went to the Extra Fund.`
  - Body (one week closed, no surplus — spent exactly or over):
    `Week of Oct 25, 2026 is closed.`
  - Body (more than one week closed at once — catch-up after a gap):
    `2 weeks are closed. $12.34 left went to the Extra Fund.`
  - The week-start date is the week that closed, formatted `Oct 25,
    2026` (the app's short date style, §4 platform rules). The amount
    is the surplus released to the fund for that close
    (`fund_available_cents` after the run is not the right number —
    the sender must use the per-run released surplus; if the function
    cannot report it, the body falls back to the no-amount form).
- **Deep link.** Home — the week view (`week` in the web app). Tapping
  opens Home showing the new current week.
- **Payload data.** `{ "type": "week_closed", "household_id": "<uuid>",
  "week_start": "2026-10-26", "weeks_closed": 1,
  "screen": "week" }`

### N2 — New Purchase Synced

- **Exact trigger.** Either of these, per household, per run:
  - `plaid-sync` returns `added > 0` — new bank transactions were
    inserted (`supabase/functions/plaid-sync/index.ts`, `added`
    counts rows whose upsert result was `'added'`). This is the
    authoritative path: the purchase is confirmed by the bank.
  - `gmail-poll` returns `stored > 0` — new Amex Large Purchase alert
    emails were parsed and stored as provisional transactions
    (`supabase/functions/gmail-poll/index.ts`, `totals.stored`).
- **Who receives it.** Every member of that household.
- **Dedupe rule (important — read this before building the sender).**
  The same real purchase can arrive twice: first as a provisional row
  from the email alert, then as the authoritative row from Plaid
  (the plaid-sync matcher merges it into the provisional row by
  canonical hash instead of duplicating it). A household must not get
  two notifications for one purchase. Rule: the sender records every
  notification it sends in `push_deliveries` (see §6) keyed by
  `purchase:<transaction_id>`; before sending, it checks the key.
  - Gmail-poll sends only if no delivery exists for that transaction
    id.
  - Plaid-sync sends only if no delivery exists for that transaction
    id **and** the row was not already notified via its provisional
    form — the merge path carries the provisional row's id forward,
    so the key matches.
  - Net effect: the first source to report the purchase notifies;
    the second source stays silent. In practice the email usually
    wins (it arrives first) and the Plaid confirmation stays silent.
- **Coalescing rule.** One notification per sync run, however many
  purchases arrived in that run. Never one per purchase.
- **Exact copy.**
  - Title: `New Purchase`
  - Body (1 purchase, bank-confirmed):
    `$12.34 at Amazon — added to this week.`
  - Body (1 purchase, email alert only — bank has not confirmed it yet):
    `$12.34 at Amazon — waiting for the bank to confirm it.`
  - Body (2–5 purchases in one run):
    `3 new purchases, $45.67 in total — added to this week.`
  - Body (more than 5 in one run):
    `6 new purchases, $120.00 in total — added to this week.`
  - Merchant is the stored display merchant, amount is the purchase
    amount. Refunds, card payments, and cashback never trigger N2
    (they are not purchases; plaid-sync's `added` can include them,
    so the sender must count only rows with `kind = 'charge'` —
    the sender filters, it does not trust the raw `added` count).
- **Deep link.** Transactions — the purchases list (`purchases` in the
  web app). Tapping opens Transactions, newest first.
- **Payload data.** `{ "type": "new_purchase", "household_id": "<uuid>",
  "transaction_id": "<uuid>", "count": 1, "screen": "purchases" }`
  (`transaction_id` is the newest purchase in the run; `count` is the
  number of new purchases in the run.)

### N3 — Fund Request Waiting

- **Exact trigger.** A row is inserted into `fund_requests` with
  `status = 'pending'`. Today that insert happens directly from the
  client (`live.js`, fund-request form submit: `supabase.from(
  'fund_requests').insert({ household_id, requested_by, amount_cents,
  note, status: 'pending' })`). There is no Edge Function in the
  create path, and no database trigger sends anything today.
- **Who receives it.** Admins of that household only — the people who
  can approve or decline. A member who makes a request does not get
  notified about their own request. (In the current two-person
  household that means: the admin, when the member asks. If the admin
  makes a request themselves, no notification is sent — there is no
  other admin to tell.)
- **Exact copy.**
  - Title: `Fund Request Waiting`
  - Body (with a note):
    `Shuki asked for $50.00 from the Extra Fund. "New tires."`
  - Body (no note):
    `Shuki asked for $50.00 from the Extra Fund. Tap to review.`
  - The name is the requester's display name (first name, as the app
    shows member names). The amount is `amount_cents` formatted.
- **Deep link.** Funds — the fund-request list on the Funds page
  (`money` view in the web app). Tapping opens Funds scrolled to the
  pending request.
- **Payload data.** `{ "type": "fund_request", "household_id": "<uuid>",
  "request_id": "<uuid>", "screen": "money" }`
- **Send path (v1 decision).** The native client calls the new
  `push-notify` function (§5) immediately after a successful
  fund-request insert, passing `{ type: "fund_request", request_id }`.
  The server re-reads the request, verifies the caller is a member of
  that household and the request is still `pending`, then notifies
  the household's admins. A database trigger (`fund_requests` insert
  → `pg_net` → `push-notify`) is the more reliable long-term path —
  it would also cover requests created from the web app — but it is
  **not** v1: it needs new SQL and a service-key call from the
  database, and this design ships no SQL. Web-created requests simply
  do not notify in v1; the web client adds the same call later.
  (Approval and decline do **not** notify in v1 — see §7.)

## 2. Permission flow

1. **When to ask: after first sign-in, NOT at first launch.** The
   prompt appears once the user has signed in (or created/joined a
   household) and the Home screen has loaded. Asking at first launch —
   before the user knows what the app is — is the way to get a
   permanent "no".
2. **What the user sees first: one plain sentence, then the system
   prompt.** A small in-app explanation on first sign-in (not a custom
   pre-prompt dialog that duplicates the system one — a single line
   under the Home content or as part of the post-sign-in flow):
   `Get a heads-up when a week closes or a new purchase comes in.`
   Then the iOS system permission prompt (`UNUserNotificationCenter
   requestAuthorization(options: [.alert, .sound])`).
3. **If the user allows it:** register for remote notifications
   immediately (§3).
4. **If the user declines it:** nothing happens. No second prompt, no
   banner, no badge, no nagging on later launches. The only trace is
   a single row in Settings (see 5 below) that states the fact and
   offers the way back.
5. **Settings row (the only in-app notification UI in v1).**
   Settings → `Notifications` row showing `On` or `Off`. Tapping it
   when off opens the iOS Settings app for OnBudget
   (`UIApplication.openSettingsURLString`) — that is the only path
   back after a decline. When on, tapping it does nothing (or shows
   the same row as informational — no toggle). There is deliberately
   **no in-app on/off switch that pretends to control the system
   setting**: an in-app toggle that cannot actually disable the
   system permission would be a lie.
6. **Re-asking.** Never automatic. If the user turns notifications on
   in iOS Settings later, the app registers the token on next launch
   (see §3, step 4) with no prompt.
7. **One device, one decision.** Permission is per device. A user with
   an iPhone and an iPad answers separately on each.

## 3. APNs registration flow (client → server)

1. App calls `UNUserNotificationCenter.current().requestAuthorization`
   (after first sign-in, §2).
2. On grant, app calls `UIApplication.shared.registerForRemoteNotifications()`.
3. iOS returns a device token via
   `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
   The app converts it to a lowercase hex string. The raw `Data` is
   never logged, never shown, never pasted anywhere.
4. The app sends the token to the backend with the user's JWT:
   `POST /functions/v1/register-push-token` with body
   `{ "device_token": "<hex>", "platform": "ios", "environment":
   "production" }`. (The function name is a proposal for the backend
   workstream; see §5. `environment` is `"production"` for TestFlight
   and App Store builds, `"sandbox"` for development builds — the
   server must send to the matching APNs endpoint, or delivery fails
   silently.)
5. The server upserts the token into `push_tokens` (see §4) and
   returns `{ ok: true }`. The client stores nothing locally except a
   flag that registration was attempted for this token, so it can
   re-register cheaply on next launch if the token changed.
6. On every app launch (signed in), if the system authorization is
   `.authorized`, the app calls `registerForRemoteNotifications()`
   again — iOS may rotate the token at any time, and re-registering
   is free. The upsert makes this idempotent.
7. On sign-out, the app calls `POST /functions/v1/register-push-token`
   with `{ "device_token": "<hex>", "unregister": true }` (best
   effort, fire-and-forget) so the device stops receiving that
   user's household notifications. The server also deletes tokens
   when the user deletes their account (§5, account deletion).
8. Failures are silent to the user: a failed registration is logged
   and retried on next launch. Notifications are a convenience, never
   a blocker — the app works fully without them.

## 4. Token storage — proposed `push_tokens` table (DESIGN ONLY)

> **No SQL is written or applied by this document.** The table below
> is a design for the backend workstream to implement (with its own
> migration, grants, and tests). Do not create it from this text
> without that workstream's review.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK, default `gen_random_uuid()` | |
| `household_id` | `uuid` → `households(id)` | The household the token belongs to. A user in two households has one row per household. |
| `user_id` | `uuid` → `auth.users(id)` | Owner of the device token. |
| `device_token` | `text`, not null | APNs hex token. Never logged, never returned to any client. |
| `platform` | `text`, default `'ios'` | `'ios'` in v1. |
| `environment` | `text`, default `'production'` | `'sandbox'` or `'production'` — must match the build that registered it. |
| `created_at` / `updated_at` / `last_seen_at` | `timestamptz` | `last_seen_at` refreshes on each re-register, so dead tokens can be pruned. |
| Unique | `(user_id, device_token)` | One row per user per device. Re-register is an upsert. |

**RLS (proposed):**

- A signed-in member may `INSERT` / `SELECT` / `UPDATE` / `DELETE`
  rows where `user_id = auth.uid()` **only** — and may never select
  another user's `device_token`. (Selecting your own token back is
  harmless but pointless; the client never needs to read it.)
- An admin may **not** read other members' tokens. Admins do not send
  notifications; the server does.
- The service role (Edge Functions) has full access — it is the only
  reader of `device_token` values, for sending.
- The `register-push-token` function verifies the caller's JWT and
  that the caller belongs to `household_id` before upserting.
  A token for a household the caller is not a member of is rejected.

**Companion table — `push_deliveries` (dedupe, proposed):**

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `household_id` | `uuid` | |
| `event_key` | `text` | e.g. `purchase:<transaction_id>`, `week:<week_start>`, `fund_request:<request_id>`. Unique per household. |
| `sent_at` | `timestamptz` | |
| Unique | `(household_id, event_key)` | Insert-if-absent before sending; a conflict means "already sent, skip". |

Rows older than 90 days may be pruned; the keys are only needed to
suppress duplicates inside a sync/email overlap window.

## 5. Server sending design

### 5.1 New function: `push-notify` (proposed, backend workstream builds it)

One small Edge Function owns all APNs traffic. The three event
sources call it; they do not each implement APNs themselves.

- **Auth:** service-key bearer for server-to-server calls
  (`week-close`, `plaid-sync`, `gmail-poll` calling it internally);
  user JWT for the client-initiated fund-request call (§1, N3).
- **Input:** `{ "type": "week_closed" | "new_purchase" |
  "fund_request", "household_id": "<uuid>", ...event fields }`.
  The function re-reads the underlying data (week-close payload,
  transaction rows, fund-request row) from the database and
  **derives the copy and the recipient list itself** — it never
  trusts the caller's title/body/recipient list. A client can only
  say "a fund request happened"; the server decides who hears about
  it and what it says.
- **Recipients:** resolved from `household_members` at send time:
  - `week_closed`, `new_purchase`: all members of the household.
  - `fund_request`: members with `role = 'admin'`, excluding the
    requester.
- **Tokens:** `SELECT device_token, environment FROM push_tokens
  WHERE household_id = ? AND user_id IN (<recipients>)`.
- **Send:** one HTTP/2 POST per token to
  `https://api.push.apple.com/3/device/<token>` (production) or
  `https://api.sandbox.push.apple.com/3/device/<token>` (sandbox,
  per the token's `environment` — never mixed). Headers:
  `authorization: bearer <APNs JWT>`, `apns-topic: <bundle id>`,
  `apns-push-type: alert`, `apns-priority: 10`,
  `apns-collapse-id: <household_id>:<type>`. Body:
  `{ "aps": { "alert": { "title": "...", "body": "..." },
  "sound": "default" }, "data": { ... } }`.
  No `badge` in v1 (no server-side unread count exists; a wrong
  badge is worse than none). No `mutable-content`, no attachments.
- **APNs JWT:** signed with ES256 from the .p8 key, header
  `{ "alg": "ES256", "kid": "<key id>" }`, payload
  `{ "iss": "<team id>", "iat": <now> }`, valid 1 hour, cached and
  re-signed on expiry. The .p8 contents live only as a Supabase
  secret — never in the repo, never in a chat message, never in a
  screenshot.
- **Response handling (per token):**
  - `200` — delivered to Apple (not a guarantee the user sees it).
  - `410` or `400` with `BadDeviceToken` / `Unregistered` — delete
    the token row immediately. A dead token that is never pruned
    gets retried forever.
  - `429` / `500` / `503` — log and drop. No retry queue in v1; the
    next event is the retry. A notification is a heads-up, not a
    guaranteed delivery.
  - Any other `400` — log the reason, drop the token only if the
    reason names the token.
- **Logging:** log `type`, `household_id`, token count, and per-token
  HTTP status only. Never log device tokens, notification bodies with
  merchant names, or amounts beyond what the household already stores.

### 5.2 Where each send is triggered (exact change list)

| Event | Change | When it runs |
|---|---|---|
| Week closed | In `week-close`, after the successful payload is built: if `weeks_closed > 0`, call `push-notify` with `{ type: "week_closed", household_id, weeks_closed, week_start }`. The call is best-effort and must never fail the close — a push failure is logged, the close still returns 200. | On every week-close run that actually closes a week. Today that is the admin app-load call; a future scheduled close gets it free. |
| New purchase (bank) | In `plaid-sync`, after the successful return is built: if any newly added row has `kind = 'charge'`, call `push-notify` with `{ type: "new_purchase", household_id, transaction_ids: [...] }`. `push-notify` applies the §1 dedupe check and sends one summary. | Every `plaid-sync` run — manual Sync press, the `hourly-plaid-sync` cron job (hourly, `supabase/server-sync-cron.sql`), and Plaid webhook arrivals. |
| New purchase (email) | In `gmail-poll`, after the successful return is built: if `totals.stored > 0`, call `push-notify` with `{ type: "new_purchase", household_id, transaction_ids: [...] }` (same dedupe key space as the bank path). | Every `gmail-poll` run — manual "Check email now", and the `five-minute-gmail-poll` cron job (every 5 minutes). |
| Fund request | Native client calls `push-notify` after a successful `fund_requests` insert (§1, N3). No change to `plaid-sync`/`gmail-poll`/`week-close` for this event. | On fund-request creation from the native app only in v1. |

**No new scheduled job is needed in v1.** The existing cron jobs
already drive the two sync paths:

- `hourly-plaid-sync` — `0 * * * *` → `POST /functions/v1/plaid-sync`
  with `{ household_id }` per household (service-key bearer).
- `five-minute-gmail-poll` — `*/5 * * * *` →
  `POST /functions/v1/gmail-poll` with `{ household_id }` per
  household (service-key bearer).

Both are defined in `supabase/server-sync-cron.sql` (placeholders
only — the filled-in copy lives in the project's database, never in
the repo). The send hooks sit inside the functions those jobs already
call, so no cron change, no new job, and no new secret is needed for
scheduling. The only new secrets are the APNs ones (§5.3).

**What the sender needs (owner-supplied — see §9):** the APNs .p8
key, its key id, the Apple Team ID, and the bundle id. All four are
set as Supabase secrets by the owner (or by the backend workstream
with the owner pasting the values in person — the .p8 contents must
never pass through chat, a file, or a screenshot).

### 5.3 Secrets the server needs (names only — values are never in the repo)

| Secret name (proposed) | What it is | Where it comes from |
|---|---|---|
| `APNS_KEY_P8` | The .p8 private-key file contents (one line, `-----BEGIN PRIVATE KEY-----…`) | Apple Developer account → Certificates, Identifiers & Profiles → Keys → create a key with Apple Push Notifications service (APNs) enabled → download the .p8 **once** (Apple shows it only once). **Owner item.** |
| `APNS_KEY_ID` | The 10-character key id shown next to the key in the Developer portal | Same key as above. **Owner item.** |
| `APNS_TEAM_ID` | The 10-character Team ID | Apple Developer account → Membership details. **Owner item.** |
| `APNS_BUNDLE_ID` | The app's bundle id, e.g. `com.onbudget.app` (final value set by the scaffold workstream) | Xcode project / App ID. Must match the App ID the APNs key is bound to and the `apns-topic` header, or Apple rejects every send. |

## 6. Deep links (notification tap → screen)

The native app routes on the `data.screen` field in the payload
(`userInfo` in `UNUserNotificationCenterDelegate`):

| `screen` | Native screen | Web equivalent |
|---|---|---|
| `week` | Home (current week) | `showView('week')` |
| `purchases` | Transactions list | `showView('purchases')` |
| `money` | Funds, fund-request list | `showView('money')` |

Rules: tapping a notification when the app is closed opens the app
to that screen (cold start via launch options). Tapping when the app
is open navigates to that screen, replacing the current view — the
same as tapping the tab. If the user is signed out when the tap
arrives (account deleted, session expired), the app opens to sign-in
and drops the deep link — it never shows household data to a signed-out
user. If the household in the payload is not the signed-in user's
household (stale token after leaving a household), the deep link is
dropped. A notification received while the app is in the foreground
shows as a banner (`.banner` presentation) and tapping it navigates
the same way.

## 7. What is NOT in v1

- **No rich media.** No images, no attachments, no `mutable-content`.
- **No reply actions.** No "Approve" / "Decline" buttons on the fund
  request notification — approving money from a lock-screen button
  is a judgment call that belongs inside the app, on the Funds page.
  (Approval/decline notifications are also out of v1: the requester
  finds out by opening the app, as on the web today.)
- **No notification settings screen.** The web app has no notification
  setting at all (verified: zero matches for "notification" in
  `live.js` at v66), and v1 does not invent one. There is one
  Settings row (§2.5) that reflects the system state and links to iOS
  Settings — that is the whole of the UI. No per-type toggles
  (week-closed on/off, purchases on/off), no quiet hours, no sounds
  choice.
- **No badge counts.** No server-side unread tracking exists; the
  payload carries no `badge`.
- **No critical alerts, no time-sensitive interruption level.** All
  three are ordinary informational alerts.
- **No notification history inside the app.** The Activity page is the
  record of what happened; notifications are not stored or listed.
- **No web push.** This design is APNs for the native iOS app only.
  The PWA gets nothing.
- **No per-device targeting UI.** The server sends to all of a user's
  registered devices; there is no "send to iPhone only" option.

## 8. Client skeleton (Swift) — CODE BLOCK ONLY, not files on disk

> The scaffold branch was not up when this document was written, so
> there is no `OnBudgetKit` package to compile against. The skeleton
> below is the exact code the client workstream should place under
> `ios-clone/OnBudgetKit/Sources/Notifications/` once the scaffold
> lands, wired into the app target and the API client. It is not
> compiled, not tested, and must be reviewed against the scaffold's
> real API client before use. Do not treat this block as delivered
> code.

```swift
// OnBudgetKit/Sources/Notifications/PushNotifications.swift
import UserNotifications
import UIKit

/// Owns the APNs permission prompt, device-token registration, and
/// notification-tap routing for OnBudget v1. No notification is ever
/// fabricated locally: this type only registers the device and routes
/// taps. Sending is entirely server-side (see APNS_DESIGN.md §5).
public final class PushNotifications: NSObject, UNUserNotificationCenterDelegate {

    public static let shared = PushNotifications()

    /// Set by the app target: resolves a `screen` string from a
    /// notification payload ("week" / "purchases" / "money") to the
    /// app's navigation. Kept as a closure so this kit has no
    /// dependency on the app's router.
    public var routeToScreen: ((String) -> Void)?

    /// Set by the app target: the API client call that registers (or
    /// unregisters) a device token with the backend
    /// (`POST /functions/v1/register-push-token`, §3).
    public var registerToken: ((String, Bool) async -> Void)?

    private override init() { super.init() }

    /// Ask for permission. Call exactly once, after first sign-in
    /// (§2) — never at first launch, never again after a decline.
    public func requestPermissionAfterSignIn() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            // Already decided (allowed or denied): respect it, do not re-ask.
            return settings.authorizationStatus == .authorized
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            return granted
        } catch {
            return false
        }
    }

    /// Re-register on launch when already authorized (tokens rotate).
    /// Call from app launch, only when signed in (§3 step 6).
    public func reregisterIfAuthorized() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Called from AppDelegate
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func didRegister(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Never log the token.
        await registerToken?(hex, false)
    }

    /// Called from AppDelegate on registration failure. Silent: push is
    /// a convenience, never a blocker (§3 step 8).
    public func didFailToRegister(error: Error) async {
        // Log the failure (no token involved) and retry on next launch.
    }

    /// Best-effort unregister on sign-out (§3 step 7).
    public func unregister(deviceTokenHex hex: String) async {
        await registerToken?(hex, true)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Foreground: show a banner, so a purchase that lands while the
        // app is open is still visible (§6).
        return [.banner, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let screen = response.notification.request.content.userInfo["screen"] as? String
        guard let screen else { return }
        await MainActor.run { routeToScreen?(screen) }
    }
}
```

```swift
// OnBudgetKit/Sources/Notifications/PushSettingsRow.swift (sketch —
// adapt to the scaffold's Settings screen; the row reflects the system
// state and links to iOS Settings when off, §2.5. There is no in-app
// on/off switch.)
import SwiftUI
import UIKit

public struct PushSettingsRow: View {
    @State private var authorized = false

    public var body: some View {
        Button {
            if !authorized {
                // Only path back after a decline: the iOS Settings app.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } label: {
            HStack {
                Text("Notifications")
                Spacer()
                Text(authorized ? "On" : "Off")
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorized = (status == .authorized)
    }
}
```

```swift
// App target — AppDelegate hookup (sketch). The API client call the
// skeleton expects:
//
//   POST {supabaseURL}/functions/v1/register-push-token
//   Authorization: Bearer <user JWT>
//   Body: { "device_token": "<hex>", "platform": "ios",
//           "environment": "production" | "sandbox" }
//   Unregister: same call with { "unregister": true }.
//
// func application(_ application: UIApplication,
//     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
//     Task { await PushNotifications.shared.didRegister(deviceToken: deviceToken) }
// }
//
// func application(_ application: UIApplication,
//     didFailToRegisterForRemoteNotificationsWithError error: Error) {
//     Task { await PushNotifications.shared.didFailToRegister(error: error) }
// }
```

## 9. Owner items (notifications)

These are the things only the owner can supply or decide. Nothing in
§5 can be built or tested without items 1–3.

1. **Apple Developer Program — $99/year, owner's account and payment.**
   Needed for the APNs key, the bundle id / App ID, and TestFlight.
   (Also listed in `APP_STORE_PLAN.md`.)
2. **APNs .p8 key + key id + team id** — from the owner's Apple
   Developer account (Certificates, Identifiers & Profiles → Keys;
   Membership for the Team ID). The .p8 downloads **once**; if it is
   lost, a new key must be created and the old one revoked. The owner
   pastes the values in person (or into the Supabase dashboard
   secrets) — they must never go through chat, email, a file, or a
   screenshot.
3. **Bundle id** — final value (e.g. `com.onbudget.app`) is set by the
   scaffold workstream and confirmed by the owner; it must match the
   App ID the APNs key is bound to.
4. **Name/trademark clearance for "OnBudget"** — `tmsearch.uspto.gov`.
   The name check is crowded and USPTO status is NOT verified
   (see `APP_STORE_PLAN.md` §1). This gates the bundle id and the
   App Store name, so it should be settled before the APNs key is
   bound to a bundle id.
5. **Screenshots sign-off** — on a real device, with test data
   (see `APP_STORE_PLAN.md` §5).
6. **Lawyer review of privacy/terms** — already owed on the web side.
   The published policy must gain a device-token paragraph before
   submission (see `APP_STORE_PLAN.md` §2.4) — that edit rides on the
   lawyer review, not on this design.

## 10. Test plan (no backend data needed for this document; for the build)

1. **Sandbox first.** Development build → sandbox APNs → token
   registers in `push_tokens` with `environment = 'sandbox'` →
   trigger each event from a test household → notification arrives.
2. **Each trigger once, from the real path:** close a week in a test
   household (admin app-load close); add a purchase via Plaid sandbox
   sync; add one via a test Gmail alert; create a fund request as the
   test member and confirm only the test admin's device buzzes.
3. **Dedupe proof:** one purchase that arrives by email and then by
   Plaid produces exactly one notification.
4. **Decline path:** deny permission on a test device → no prompt ever
   reappears → Settings row reads `Off` → tapping it opens iOS
   Settings.
5. **Dead-token pruning:** delete the app from a test device, trigger
   an event, confirm the 410 response deletes the token row.
6. **TestFlight (production APNs):** repeat 2–3 on a TestFlight build
   with a test household before external testing.
7. **Never** tested against the live household, and never with the
   owner's real purchase data.
