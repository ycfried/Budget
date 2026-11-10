# Gmail callback + Past Weeks / Activity navigation — notes (Nov 9, 2026)

Branch: `ios-clone-v66/gmail-callback-nav` → merged into `ios-clone`.
Server diff (prepare only, NOT merged, NOT deployed): branch
`gmail-callback-native-redirect` off main.

## 1. Gmail — URL scheme registration (app side, DONE)

- `onbudget` is registered in the app target via
  `INFOPLIST_KEY_CFBundleURLTypes` (CFBundleURLName
  `com.onbudget.app`, CFBundleURLSchemes `(onbudget)`), in BOTH the
  Debug and Release build configurations of `project.pbxproj`. The
  project uses a generated Info.plist, so this is the only place
  the scheme can be registered — there is no Info.plist file.
- One registration covers both deep links:
  `onbudget://gmail-callback` and `onbudget://reset-password`.
- `ios-clone/scripts/validate_project.py` now asserts the scheme is
  present in every app-target config (a Debug-only registration
  would silently break Release deep links).

## 2. Gmail — in-app handling (DONE)

- `ASWebAuthenticationSession` needs NO forwarding: with
  callbackURLScheme `"onbudget"` it completes on its own once the
  scheme is registered. `GmailOAuthPresenter` is unchanged, and the
  Google consent flow itself is untouched.
- `OnBudgetApp.onOpenURL` now dispatches by host: `gmail-callback`
  → `AppViewModel.handleGmailDeepLink(_:)` (records the outcome in
  the published `gmailCallbackResult`); `reset-password` →
  `handleResetDeepLink` as before. The recorded result covers
  callbacks arriving outside an active session; it toasts nothing
  (the presenter already toasts on the live path, so a stray
  callback must not double-toast).
- The parse lives in the kit (`OnBudgetKit.GmailCallback`, new
  `OnBudgetKit/Sources/OnBudgetKit/GmailCallback.swift`) so the
  existing kit test harness can prove it — the app test bundle has
  no host app and cannot import app-target types.
- The app tells the server it is native: `gmailOAuthStart` gained
  an optional `client` parameter (kit, default nil = web
  behaviour), and `EmailAlertsViewModel` passes `client: "native"`
  on both call sites (first attempt + multi-household retry).

## 3. Gmail — simulator verification (CI)

`ios-clone/scripts/macos_simulator_test.sh`, after
`build-for-testing`, now:

1. Parses the built app's `Info.plist` and asserts `onbudget` is
   in `CFBundleURLTypes` (a plain grep would pass on the bundle id
   `com.onbudget.app` alone, so this parses the plist properly).
2. Installs + launches the app on the simulator and runs
   `xcrun simctl openurl <sim> "onbudget://gmail-callback?gmail=connected"`.
   `simctl openurl` fails when no app handles the URL, so exit 0
   proves the OS routes the scheme to OnBudget.

What this does NOT prove: the full Google consent round-trip. That
needs a real Google account and the not-yet-deployed server redirect
(see §4), so it cannot run on CI. Do NOT attempt a real Gmail
connection from CI.

## 4. Gmail — server side (PREPARED ONLY, do not deploy from here)

Branch `gmail-callback-native-redirect` (off main, unmerged).
See `supabase/functions/NATIVE_GMAIL_REDIRECT.md` on that branch
for the full description. Summary:

- `gmail-oauth-start`: reads the request body's `client` field
  (anything other than exactly `"native"` = web behaviour). For
  native it sends `state = "native:<nonce>"` to Google and stores
  that full string as the `nonce` in `gmail_oauth_states`
  (`nonce` is plain `text`, no format constraint). The household
  still comes from the caller's admin membership, never the body.
- `gmail-oauth-callback`: the redirect target is chosen from the
  returned state — `native:` prefix →
  `onbudget://gmail-callback?gmail=…`, otherwise
  `https://ycfried.github.io/Budget/live.html?gmail=…`. The choice
  applies to every exit path (success and all error pages), and
  the state lookup, single-use delete, 10-minute TTL, token
  exchange, encryption, and audit row are unchanged.
- What it does NOT change: the web flow (no `client` field → bare
  nonce → live.html, exactly as today); the Google Cloud Console
  redirect URI (still the callback function URL); scopes;
  `gmail-oauth-states` schema; any other function.

To ship it (parent): review the branch, merge to main, deploy
`gmail-oauth-start` and `gmail-oauth-callback` (`supabase functions
deploy`), then test a real native connect from a device.

## 5. Gmail — Supabase dashboard steps still owed (parent)

In the Supabase dashboard, for the project:

1. Auth → URL Configuration → Redirect URLs → add
   `onbudget://reset-password`
2. Auth → URL Configuration → Redirect URLs → add
   `onbudget://gmail-callback`

Verbatim values: `onbudget://reset-password`,
`onbudget://gmail-callback`. Until these are added, the
password-reset link cannot open the app (web reset.html remains
the fallback).

## 6. Past Weeks / Activity — subpage wiring (DONE)

- Parent decision implemented: push `PastWeeksView` /
  `ActivityView` as SUBPAGES in the navigation stack (the native
  equivalent of the web's full pages).
- Correction to the brief: neither existing NavigationStack owns
  the Transactions tab — `AppShellView`'s stack is the Settings
  cover and `TransactionsView`'s stack is the Filters sheet. A new
  `NavigationStack` now wraps the Transactions tab in
  `AppShellView` (`transactionsPath: [TransactionsSubpage]`).
  The shell supplies both handlers to `TransactionsView`, so the
  "Past Weeks" and "Activity" links now appear on the Transactions
  page.
- Both subpages share one `HistoryFilterState` owned by the shell
  (same as the web) and one `ToastState`, overlaid on the stack so
  the week-tap toast survives the pop back to the list.
- A Past Week tap pops to the list FIRST and then applies the week
  filter (`historyContext()` overrides `onShowWeekTransactions`);
  otherwise the filtered list would sit hidden under the subpage.
- The system navigation bar is hidden throughout the stack
  (`.toolbar(.hidden, for: .navigationBar)` on root and
  destinations) — each screen renders its own "← Back" button, as
  the web clone does. The Transactions root therefore looks
  unchanged (no new empty bar).
- Correction to the brief: the two screens were NOT presented from
  Settings today — nothing in the app referenced `PastWeeksView` /
  `ActivityView` at all; they were built but unwired. Settings is
  untouched by this change.

## 7. What was verified vs what is still owed

Verified on CI (run id in the landing report):

- `validate_project.py` passes, including the new scheme
  assertion (runs before the build in the simulator script).
- Kit tests pass, including the 5 new `GmailCallbackTests`
  (parser + `client` marker in the `gmail-oauth-start` body).
- App target compiles (`TEST BUILD SUCCEEDED`); app tests pass.
- Built `Info.plist` lists the `onbudget` scheme; `simctl
  openurl` for `onbudget://gmail-callback?gmail=connected`
  exits 0 on the simulator.

Still owed (not verifiable from this VM / CI):

- A real Gmail connect from a device: needs the server branch
  merged + deployed, the dashboard redirect URLs above, and a
  real Google account.
- A UI test tapping "Past Weeks" / "Activity" and asserting the
  push: no UI-test target exists yet in the project (only
  `OnBudgetTests` unit tests + kit tests). Verified instead by CI
  build + a careful read of the navigation wiring. The UI-test
  proof is still owed once a UI-test harness exists.
- No local type-check was possible on this VM (no Swift
  toolchain); CI is the only type-check, as before.
