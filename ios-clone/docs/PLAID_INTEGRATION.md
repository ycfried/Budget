# Plaid Link integration — wired (LinkKit 7.x)

Status (Nov 9–10, 2026): **wired end-to-end in the clone; simulator
proof running in CI.** The Connect flow is fully built and the real
SDK launcher is in place — see below. Nothing is faked.

## What is wired

`ios-clone/OnBudget/Settings/ConnectedAccountsView.swift`:

- **Already Connected? guard** — `PostgrestClient.activePlaidItems`
  + `plaidAccounts`, lines in the web's `describeConnection` shape
  ("Institution — Account ••mask, …"), Confirm "Connect Anyway",
  Cancel is the safe path. A failed read fails OPEN.
- **Token fetch** — `EdgeFunctionsClient.plaidLink(householdId:)`
  (`plaid-link` Edge Function). Failure toast: "Could not start the
  bank connection: `<error>`. If it says "not configured," the bank
  connection is not set up on the server yet."
- **Exchange** — `EdgeFunctionsClient.plaidExchange(householdId:publicToken:institutionName:)`
  (`plaid-exchange`). Toasts: connected → "Connected. Tap "Sync
  Transactions" to pull transactions." (+ reload); duplicate →
  "This bank is already connected — the duplicate connection was
  removed. Past transactions stay."; failure → "Connection could not
  be finished: `<error>`". Link exit with an error → "Bank
  connection closed: `<message>`".
- **Seam** — `PlaidLinkLauncher` protocol + `PlaidLinkOutcome`
  (`.success(publicToken:institutionName:)` /
  `.exited(errorMessage:)`). `ConnectedAccountsView` takes a
  `plaidLauncher:`.

`ios-clone/OnBudget/Settings/PlaidLinkKitLauncher.swift` (new, Nov 9):

- **Real launcher** — `PlaidLinkKitLauncher: PlaidLinkLauncher`,
  backed by the official SDK, LinkKit **7.x session API**:
  `LinkTokenConfiguration(token:onSuccess:onExit:onEvent:onLoad:)` →
  `Plaid.createPlaidLinkSession(configuration:)` → `session.open(using:
  .viewController(topViewController))`. The session is retained on
  the launcher until onSuccess / onExit fires. On success it returns
  `.success(publicToken: success.publicToken, institutionName:
  success.metadata.institution?.name)`; on exit it returns
  `.exited(errorMessage: exit.error?.localizedDescription)` — `nil`
  for a plain cancel, so the view shows nothing.
- **Wiring** — `AppShellView` passes `PlaidLinkKitLauncher()` into
  `SettingsView(plaidLauncher:)`; `SettingsView` forwards it to
  `ConnectedAccountsView`. `PlaidLinkNotLinkedLauncher` remains only
  as the default for call sites with no SDK session.
- **SPM** — `https://github.com/plaid/plaid-link-ios-spm.git`,
  Up to Next Major Version from 7.0.0 (latest verified 7.3.0,
  Oct 27, 2026), product `LinkKit`, app target only. The CI script
  runs `xcodebuild -resolvePackageDependencies` before
  build-for-testing (which uses `-disableAutomaticPackageResolution`),
  so no committed `Package.resolved` is needed.
  `scripts/validate_project.py` allows exactly this one remote
  package and asserts LinkKit is on the app target only.
- **No `-ObjC` flag**: the current Plaid iOS docs do not require it
  for the Swift SPM integration, and LinkKit 7's core module is
  Swift-only. If a future link error says otherwise, add it then.
- **No `WKWebView` wrapper** around Plaid Link: the clone is real
  SwiftUI + the official SDK, per the brief.

## API correction (Nov 9, 2026)

The brief for this work assumed the old Handler API
(`LinkKit.Configuration`, `LinkKit.createLink`). LinkKit 7 removed
it: "LinkKit 7 moves Swift integrations from Handler-based APIs to
session-based APIs" (Plaid docs, "Link - iOS"; migration guide
`plaid/plaid-link-ios/v7-migration-guide.md`). The implementation
follows the current docs, not the brief. CI build-for-testing is
the type-check for this (no Xcode on the Linux VM).

## Verification

- **CI (this run):** `testPlaidSandboxConnect` in
  `ios-clone/OnBudgetUITests/OnBudgetUITests.swift` — fresh
  sign-up, CREATE a fresh household (the account is its admin),
  Settings → Bank Connection → Connect New Account. HARD assertion:
  the Plaid Link sheet opens (a Link webview appears within 90s).
  Then a best-effort Sandbox drive (First Platypus Bank,
  `user_good` / `pass_good` — Plaid's public Sandbox credentials):
  each step proceeds only if its element is found, screenshots
  record how far it got. If the drive completes, the test also
  asserts the "Connected" toast, Sync Transactions finishing
  ("Last synced"), and transaction rows appearing.

## Run 42746242404 diagnosis (Nov 10, 2026) — sheet never visible, test failed on a screenshot

- **What happened:** TEST BUILD SUCCEEDED, kit 118/118,
  SmokeTests 6/6, UI 2/3. `testPlaidSandboxConnect` failed after
  687s. The Link webview existed in the AX tree ~2s after tapping
  Connect, but the `plaid-04-link-open` screenshot still showed
  Settings ("Connecting…") 8s later — the sheet never became
  visible. Every existence poll on the webview's descendants then
  blocked ~60s on a snapshot of the WebContent process, and the
  recorded failure was `attachScreenshot` itself
  (`OnBudgetUITests.swift:583`, `app.screenshot()` — "Failed to
  get matching snapshot ... XCTPerformOnMainRunLoop work timed out
  after 60.0s"), after the drive had already returned its
  diagnostic outcome.
- **What changed (branch `ios-clone-v66/plaid-gmail-fix`):**
  screenshots go through `XCUIScreen.main.screenshot()` (no AX
  snapshot, so a wedged webview can no longer fail the test from
  a screenshot); the drive probes presentation FIRST (Settings
  still visible 30s after the webview appeared →
  `.sheetNotPresented`, without touching the webview interior)
  and polls the first pane in short 5s slices over several
  plausible queries (search text field / search field /
  already-listed Platypus button) instead of one 60s blind wait;
  `PlaidLinkKitLauncher` now logs LinkKit `onEvent`/`onLoad` via
  `os_log` (subsystem `com.onbudget.app`, category `PlaidLink`)
  so the next run's xcresult diagnostics can tell "Link never
  opened/loaded" from "Link loaded but the sheet never
  presented".
- **Still open:** whether the sheet never presented (app/LinkKit
  presentation) or the page never loaded (Plaid CDN / simulator
  slowness) — one run is not enough to tell, and the app's Link
  wiring is not proven wrong (token fetch worked, the webview
  appeared, `present()` was in flight). Needs the next CI run's
  Link event logs + XCUIScreen screenshots. Also observed in the
  same run: ~60s of main-thread non-idle after tapping Profile
  before Settings appeared — the test survived it; cause not yet
  diagnosed (needs the app's syslogs).
- **Still needs a real device / owner run:** a full Sandbox
  connect on a physical device (simulator proof covers the sheet
  opening and, if the drive completes, the whole flow), and any
  OAuth bank (see below).

## Known limitation: OAuth banks need a redirect URI

The `plaid-link` Edge Function creates tokens with
`products: ['transactions']`, `country_codes: ['US']` and **no
`redirect_uri`**. That is fine for Sandbox non-OAuth institutions
(First Platypus Bank) and for the web flow's non-OAuth banks, but
Plaid's iOS docs require `redirect_uri` in `/link/token/create`
for OAuth, and OAuth return needs a Universal Link (associated
domains entitlement + `apple-app-site-association` on a domain the
owner controls). Until that is set up, OAuth banks (e.g. Chase)
will not complete on iOS. That is a backend + App Store follow-up,
not an app-code change: no Edge Function changes were made here.

## Deliberately NOT done here

- No committed `Package.resolved` (CI resolves instead).
- No new UI-test target (the existing `OnBudgetUITests` target
  hosts the Plaid test) and no test-host changes.
- No changes to main, web files, SQL, Edge Functions, or
  production Supabase. Test backend only; never the real
  household, never real Plaid items.
