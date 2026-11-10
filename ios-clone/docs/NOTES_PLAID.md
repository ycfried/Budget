# Notes — Plaid LinkKit wiring (Nov 9–10, 2026)

Work log for the LinkKit wiring; `PLAID_INTEGRATION.md` is the
current-status doc. Do not edit `PROGRESS.md` (coordinator
consolidates).

## Branch / commits

- Branch `ios-clone-v66/plaid-linkkit`, off `origin/ios-clone`.
- Commit `1c8f75c` "Wire Plaid LinkKit 7 (session API) into the
  OnBudget clone" and `e12d8a1` "Add Plaid Sandbox UI test + test
  identifiers + docs" (rebased onto `419b36e`, the Gmail + Past
  Weeks/Activity tip — see below).
- Worktree: `~/workspace/ios-clone-plaid`. Sibling worktrees were
  NOT touched.

## What changed (vs d1d18a0)

- `ios-clone/OnBudget.xcodeproj/project.pbxproj` (+25 lines):
  `XCRemoteSwiftPackageReference` for
  `https://github.com/plaid/plaid-link-ios-spm.git`
  (upToNextMajorVersion, minimum 7.0.0); `XCSwiftPackageProductDependency`
  for product `LinkKit`; LinkKit in the OnBudget target's
  `packageProductDependencies` + Frameworks phase (app target
  ONLY); new file refs for `PlaidLinkKitLauncher.swift`.
  Hand-edited (no Xcode here); verified locally by brace/paren
  balance, duplicate-definition check, and every 24-hex reference
  resolving (127/127 after the rebase).
- `ios-clone/OnBudget/Settings/PlaidLinkKitLauncher.swift` (new):
  `PlaidLinkKitLauncher: PlaidLinkLauncher` on the LinkKit 7
  session API. See `PLAID_INTEGRATION.md` for the exact calls.
- `ios-clone/OnBudget/AppShellView.swift`: `SettingsView(...,
  plaidLauncher: PlaidLinkKitLauncher())`.
- `ios-clone/OnBudget/Settings/ConnectedAccountsView.swift`:
  header comment updated (SDK now linked); `PlaidLinkError` gained
  `.presentationUnavailable`; `bank.connect` / `bank.sync`
  accessibility identifiers on the two buttons (for the UI test).
  Token fetch, guard, and exchange code untouched.
- `ios-clone/OnBudget/HouseholdViews.swift`:
  `household.nameField` / `household.createConfirm` identifiers
  (for the UI test's create-household flow).
- `ios-clone/scripts/validate_project.py`: allows exactly one
  remote package (plaid-link-ios-spm, upToNextMajorVersion,
  minimumVersion 7.0.0), asserts the LinkKit product dep comes
  from it and is on the app target only (not OnBudgetTests).
- `ios-clone/scripts/macos_simulator_test.sh`: added
  `xcodebuild -resolvePackageDependencies` after validation, before
  `xcodebuild -list` — build-for-testing runs with
  `-disableAutomaticPackageResolution`, so without this the new
  remote package would fail to resolve.
- `ios-clone/OnBudgetUITests/OnBudgetUITests.swift`: sign-up steps
  extracted into `signUpFreshAccount()` (shared by both tests);
  new `testPlaidSandboxConnect` (see below).
- `ios-clone/docs/PLAID_INTEGRATION.md`: rewritten to wired status.

## Rebase notes (Nov 10)

First rebase onto `d1d18a0` (sibling's OnBudgetUITests merge):
Rebased onto it: `project.pbxproj`, `AppShellView.swift`, and
`macos_simulator_test.sh` auto-merged; only
`validate_project.py` conflicted (docstring + final print) and
was hand-resolved to keep BOTH sides (3 targets + UITests checks
AND the LinkKit remote-package checks). During the first pbxproj
hand-edit, three blocks were accidentally duplicated by the
append-style edit script (target `packageProductDependencies`,
project `packageReferences`, `E2` product dep); all three were
caught by the local verification pass and collapsed before
committing — the committed pbxproj has no duplicate definitions.
Lesson: for replacement-style pbxproj edits, assert the result
contains the new text exactly once.

Second rebase onto `419b36e` (Gmail callback + Past Weeks /
Activity UI test): only `OnBudgetUITests.swift` conflicted —
both this branch and the Gmail sibling had extracted the sign-up
steps into a helper. Resolved by keeping the sibling's
`signUpAndJoinTestHousehold()` (now delegating its sign-up steps
to this branch's `signUpFreshAccount()`), the sibling's
`testPastWeeksAndActivitySubpages`, and this branch's
`testPlaidSandboxConnect` + Sandbox drive. All three UI tests
share the one sign-up helper; no sign-up steps are duplicated.

## API correction — brief vs reality

The task brief prescribed `LinkKit.Configuration(token:)`,
`LinkKit.createLink(with:)`, and presenting from the top-most
view controller. That API does not exist in LinkKit 7. Verified
against Plaid's live docs ("Link - iOS", crawled Nov 10, 2026)
and the official v7 migration guide
(`plaid/plaid-link-ios/v7-migration-guide.md`): LinkKit 7 is
session-based — `LinkTokenConfiguration(token:onSuccess:onExit:
onEvent:onLoad:)`, `Plaid.createPlaidLinkSession(configuration:)`
(throws), `session.open(using: .viewController(...))` or
`session.sheet()` in SwiftUI. The implementation follows the
docs. Latest verified release 7.3.0 (published Oct 27, 2026);
LinkKit 7.x needs Xcode 16.1+, iOS 15+, Swift ≥ 5.10 — all
satisfied (Xcode 16.4, deployment target iOS 18.0, SWIFT_VERSION
5.0). The `-ObjC` linker flag was NOT added: current Plaid docs
do not require it for Swift SPM, and LinkKit 7's core module is
Swift-only.

## UI test design — why it is shaped this way

- `testPlaidSandboxConnect` creates a FRESH household (the new
  account is its admin) instead of joining Proof Household 2:
  only an admin can connect a bank, and the test admin's password
  is lost. It never touches the real household or real Plaid items.
- HARD bar: the Link sheet opens (webview appears within 90s of
  tapping Connect). That proves SPM resolution, LinkKit linking,
  the session API compiling, the token fetch, and presentation.
- The Sandbox drive after that is best-effort because Plaid owns
  the webview tree: search field → "First Platypus Bank" →
  `user_good` / `pass_good` → Submit → Continue taps → sheet
  closes. Each step proceeds only if its element is found;
  screenshots (`plaid-04` … `plaid-12`) record how far it got,
  and the test still passes on sheet-open alone. If the drive
  completes, the test additionally asserts the "Connected" toast
  (4s auto-dismiss — caught with a 90s `waitForExistence`), Sync
  finishing ("Last synced" line), and transaction rows on the
  Transactions tab. That is the full-connect proof, if it lands.
- No new test target: the sibling's existing `OnBudgetUITests`
  target hosts it; no pbxproj target changes were needed for the
  test itself.
- What CI cannot prove: a physical-device run, OAuth banks (see
  `PLAID_INTEGRATION.md` — no `redirect_uri` in the token, no
  Universal Links yet), and the exact Plaid webview element labels
  if Plaid changes its Link UI (the drive stops at the first
  missing element and the screenshots show where).

## Verification limits (honest)

- No Xcode / `swiftc` on this VM — CI build-for-testing is the
  ONLY type-check for the Swift code, the pbxproj hand-edit, and
  the package resolution. Local checks done: pbxproj balance +
  reference resolution + validator simulation (regex-based, since
  `plutil` is macOS-only), `py_compile` on the validator,
  `bash -n` on the CI script, balanced delimiters + symbol
  presence in the new Swift files.
- The Sandbox drive's webview queries are best guesses from
  Plaid's public Link UI (search field, institution button,
  Username/Password fields, Submit/Continue). If the labels
  differ, the test stops at that step with a screenshot — read
  `plaid-0X` attachments in the CI run to see exactly where.
- `plaid-link` Edge Function was READ ONLY to confirm the token
  shape (products transactions, US, no redirect_uri, env defaults
  to sandbox). No function, SQL, web, or production changes.
