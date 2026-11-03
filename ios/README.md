# OnBudget native iOS — isolated sample build

Genuine SwiftUI app and WidgetKit extension. All data is synthetic. There is no
Supabase SDK, URLSession transport, live endpoint, integration credential, account
login, or financial engine in the native target. The fixed financial responses
are display fixtures; sample transaction/request actions update in-memory records and attributable
state history without recalculating balances. Policy/fund/savings actions remain
intent-only previews until server authority is available. This is not a connected,
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

## Compile and simulator-test on an existing Mac

The real Xcode project and shared scheme are now checked in. The first build needs
Xcode 16.4 with the installed iOS 18.5 runtime; it does **not** need XcodeGen,
Homebrew, third-party packages, signing or an Apple account.

```sh
# Repository root, branch ios-native-rebuild, on an existing authorized Mac:
bash ios/scripts/macos_simulator_test.sh
```

This validates the project, runs core tests, creates its own temporary iPhone 16
simulator, builds app/widget/UI tests, executes UI tests, then removes only that
simulator. Local reports remain in ignored ios/CloudResults/. It never downloads
runtimes, signs, archives, uploads or connects to a provider. Preserve/remove old
result bundles explicitly before another local run. The script fails on Linux.

For interactive use, open `ios/OnBudget.xcodeproj`, choose OnBudget and an installed
iOS simulator. All bundle IDs are sample placeholders. Signing and App Groups
remain unconfigured. An App Store icon is still missing; in-app branding uses the
unchanged owner mark. Actual Xcode compilation remains unverified here.

`project.yml` remains the reproducible source for project metadata. If source
membership or configuration changes, regenerate on an existing Mac with XcodeGen
2.42.0 (`xcodegen generate --spec ios/project.yml` from root), then review the PBX
and plist differences and run the project validator. No generator install is
needed for ordinary builds. See docs/REVIEW_6b625b7.md for local generation evidence.

The cloud build remains documentation only under docs/CLOUD_BUILD_DRAFT.md.
Activation needs a specific owner-approved exception for one workflow file outside
ios/ and one free standard-runner push-triggered build; main stays untouched.

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
overspending, offline read-only behavior, a failing refresh, and safe retry after a
committed sample action loses its response. Transient messages
use the owner's blue, four-second bottom toast. All action forms are sample-only.
Do not enter actual passwords, invite codes, account details, or financial data.
Gmail connect is intentionally absent, preserving the later launch decision.

See `PROGRESS.md`, `docs/REQUIREMENTS.md`, `docs/BACKEND_CONTRACTS.md`, and
`docs/CLOUD_BUILD_DRAFT.md` for validation, parity gaps and the inactive CI proposal.

## Offline milestone M1

Typed states distinguish provisional/bank pending/posted/review/excluded/reversed/
voided/quarantined and retain unknown server values. Purchase details refresh by
identity and show original amount plus attributable state history. Manual entries,
CSV sample rows, review/exclude/restore/reclassification/void and request decisions
update local records. Manual void retains history; it does not claim to implement
the existing backend deletion policy. Known provider events are injected through a
mock-only test interface; no SDK or account is connected.

Retrying the same operation does not duplicate a saved action. Identical-looking
CSV rows stay distinct; separate imports are not auto-matched/deduplicated. Negative
CSV credits require classification rather than being assumed to be refunds. No
restoration, allocation, savings, week-close or budget engine is implemented.
All financial summary/ledger/closed-week/restoration values remain literal fixtures.
See docs/IMPLEMENTATION_PLAN.md for remaining milestones and approval gates.
