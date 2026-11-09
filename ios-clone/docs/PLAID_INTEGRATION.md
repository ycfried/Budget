# Plaid Link integration — remaining steps

Status (Nov 9, 2026, Settings workstream): **not wired end-to-end.**
The Connect flow is fully built up to the SDK seam and nothing is
faked — see below. This doc is the exact remaining work, for the
coordinator or any agent with an Xcode build to verify against.

## What is already wired

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
  `plaidLauncher:` (default `PlaidLinkNotLinkedLauncher`, which
  throws `PlaidLinkError.sdkNotLinked` — surfaced as an honest error
  toast, never a fake connected state).

## Remaining steps (needs Xcode — cannot be verified on this Linux VM)

1. **Add the official SDK as an SPM dependency in Xcode:**
   File → Add Package Dependencies → URL
   `https://github.com/plaid/plaid-link-ios-spm.git`
   (the small SPM pointer repo Plaid recommends; the main
   `plaid/plaid-link-ios` repo is ~1 GB and SPM downloads its full
   history). Dependency rule: Up to Next Major Version, minimum
   7.0.0 (latest verified release 7.3.0, Oct 27, 2026). Product:
   **LinkKit**. Add LinkKit to the OnBudget app target only.
   Also add the `-ObjC` linker flag if the SDK requires it for the
   SPM build (Plaid's docs note it for SPM).
2. **Implement `PlaidLinkLauncher` with LinkKit** (new file, e.g.
   `OnBudget/Settings/PlaidLinkKitLauncher.swift`):
   - `import LinkKit`
   - Build `LinkKit.Configuration(token: linkToken)` with a
     completion handler; create the handler with
     `LinkKit.createLink(with:)`; present it from the top-most
     view controller (`presentingViewController:`).
   - On success, return `.success(publicToken: success.publicToken,
     institutionName: success.metadata.institution?.name)`.
   - On exit/error, return `.exited(errorMessage:)` with the
     SDK's error message, or `.exited(errorMessage: nil)` for a
     plain user cancel (the view shows nothing for a cancel).
   - Plaid Link handles bank credentials, MFA, and OAuth itself;
     OnBudget never sees credentials.
3. **Wire it in:** pass the real launcher into
   `ConnectedAccountsView(plaidLauncher:)` / `SettingsView`
   from the app coordinator. Delete nothing else — the token fetch,
   guard, and exchange code stays as-is.
4. **Verify on a simulator/device** (test backend only — never the
   real household, never real Plaid items): connect a Plaid Sandbox
   bank, confirm the "Connected. Tap "Sync Transactions"…" toast,
   then Sync Transactions and confirm rows appear. Mark this doc
   done only after that run.

## Deliberately NOT done here

- No `WKWebView` wrapper around Plaid Link web: the clone is real
  SwiftUI + the official SDK, per the brief.
- No dependency entry was hand-edited into
  `OnBudget.xcodeproj/project.pbxproj` for LinkKit: an unverified
  remote-package entry (wrong version rule or product name) would
  break CI resolution, and there is no Xcode here to check it
  against. Step 1 above is a 2-minute Xcode action.
