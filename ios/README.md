# OnBudget native iOS — isolated sample build

Genuine SwiftUI app and WidgetKit extension. All data is synthetic. There is no
Supabase SDK, URLSession transport, live endpoint, integration credential, account
login, or financial engine in the native target. The fixed financial responses
are display fixtures; sample write actions record receipts/audit events in memory
without recalculating balances or changing transactions. This is not a connected,
signed, or App Store ready application.

## Repository safety

Work only on `ios-native-rebuild`, starting from main at
`1ab8c9acd1e4df0e4f4e65e34d8540de90dfb419`. Everything added is under `ios/`.
Do not edit existing web files, `supabase/`, `.github/workflows/`, settings,
Pages, or deployment integrations. No staging connection without owner approval.
No production access, Apple submissions, paid services, or credentials.

Use this task's existing checkout; do not create a worktree unless requested.
Before each push, run `python3 ios/scripts/check_safety.py` from the repository
root, review the changed-file list and staged diff, and push only the explicit
`HEAD:refs/heads/ios-native-rebuild` ref. Do not open a PR targeting main.

## Run core tests (Linux or macOS)

Requires Swift 6.0+:

```sh
cd ios
swift test --jobs 4
```

No package downloads are required. The package contains values, DTOs, fixtures,
mock service, input parsing, display filtering, widget snapshot model, and tests.
It deliberately excludes Apple UI targets so its tests can run on Linux.

## Build the sample app on an existing Mac

Requires Xcode 16+ with iOS SDK/simulator and XcodeGen already installed. Installing
paid tools or activating Apple/cloud services is not part of this change.

```sh
cd ios
xcodegen generate --spec project.yml
xcodebuild -list -project OnBudget.xcodeproj
xcodebuild -showdestinations -project OnBudget.xcodeproj -scheme OnBudget
```

Choose an installed iOS 17+ simulator UUID from that output:

```sh
xcodebuild -project OnBudget.xcodeproj -scheme OnBudget \
  -destination 'platform=iOS Simulator,id=REPLACE_WITH_INSTALLED_UUID' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project OnBudget.xcodeproj -scheme OnBudget \
  -destination 'platform=iOS Simulator,id=REPLACE_WITH_INSTALLED_UUID' \
  -derivedDataPath DerivedData -resultBundlePath /tmp/OnBudget-UI.xcresult \
  CODE_SIGNING_ALLOWED=NO test-without-building
```

The checked-in `project.yml` creates separate app, widget, and UI-test targets,
using the local OnBudgetCore package. Generated Xcode project/plists are ignored.
Core unit tests run with `swift test`; the app scheme runs the UI tests separately.
All identifiers are `example.onbudget.sample` placeholders, signing disabled.
No Apple team or entitlements are provisioned. An App Store icon is still needed;
the existing owner mark is copied unchanged for in-app branding.

## Widgets

Small and medium WidgetKit views show a timestamp and privacy-sensitive amounts.
Without approved App Group entitlements they show “No shared snapshot”. App and
extension need the same approved App Group identifier in `OnBudgetAppGroup` and
matching entitlements before shared data works on device. No identifiers are
registered here. The app clears its shared snapshot on sample sign-out/deletion.
The widget deep link opens Home; it carries no IDs, balances, or session secrets.

## Explore

Select sample admin or sample member. More contains Savings, Weekly history,
Connections, and Settings & audit. Change scenarios in Settings to inspect
overspending, offline read-only behavior, and a failing refresh. Transient messages
use the owner's blue, four-second bottom toast. All action forms are sample-only.
Do not enter actual passwords, invite codes, account details, or financial data.
Gmail connect is intentionally absent, preserving the later launch decision.

See `PROGRESS.md`, `docs/REQUIREMENTS.md`, `docs/BACKEND_CONTRACTS.md`, and
`docs/CLOUD_BUILD_DRAFT.md` for validation, parity gaps and the inactive CI proposal.
