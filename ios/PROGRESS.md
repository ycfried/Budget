# OnBudget iOS progress

Updated November 2, 2026 (America/New_York). Branch: `ios-native-rebuild`.
Base: current main `1ab8c9acd1e4df0e4f4e65e34d8540de90dfb419`.

## Initial milestone (6b625b7)

- Read the complete handoff (including addendum), FINAL PDF, current native-facing
  web/API implementation; documented precedence and genuine unresolved contracts.
- Standalone Swift 6 core package without third-party dependencies or networking.
- Native SwiftUI app foundation, owner branding, four-tab navigation and More routes.
- Explicit sample admin/member sessions and disconnected auth/reset/signup forms.
- Dashboard with literal financial DTOs, negative state, source freshness, hero
  sync preview, offline/error scenarios, retry and read-only stale display.
- Transactions: search/filter/sort/load-more, detail, provisional manual entry,
  review/exclude/restore/classify/delete interfaces with confirmation.
- CSV Files picker with access scoping/read errors/2 MB limit, preview and confirm;
  quoted commas/quotes/multiline fields, date/cents validation and per-row errors.
  No local financial matching/deduplication; preserves identical purchases.
- Extra Fund summary/ledger, requests, approve/split/decline/allocation interfaces,
  override-reason input, restoration history and held-release confirmation.
- Savings four-number view, balance/movement record forms (never transfer money).
- Weekly history, revisions, release state and native CSV file export.
- Settings, onboarding/password/delete previews, role-aware actions, audit visible
  to both users; generation guards and cache cleanup on sample sign-out.
- Fail-closed Plaid/Gmail protocols; no native Gmail consent action per handoff.
- WidgetKit small/medium source, minimal cache, timestamp/staleness/privacy support,
  Home deep link, and empty state without configured App Group.
- XcodeGen specification for app/widget/UI-test targets; signing disabled. Existing
  S mark copied unchanged. Privacy manifest prepared for shared UserDefaults use.
- XCTest core suites, two XCUITest scenarios, safety scanner and inactive cloud
  macOS build proposal stored as documentation only.

## Cloud-preparation milestone

- Audited all 37 files in 6b625b7: every change is under ios/. Full review and
  remaining functional gaps recorded in docs/REVIEW_6b625b7.md.
- Generated and checked in actual OnBudget.xcodeproj/shared scheme plus explicit
  app/widget Info.plists. Cloud runner needs no generator/package installation.
- Corrected UI-test plist generation, consistent version metadata, extension API
  restrictions and disabled signing; validated real PBX references/source graph.
- Moved observable app state into the core package, added five lifecycle tests,
  fixed signed-out writes/entry races and prevented failed forms from dismissing.
- Added native week/classification filters and calendar-only date-boundary tests.
- Made blue transient notifications dismissible/accessible in modal action forms.
- Prepared a macOS-only unsigned simulator test script with exact toolchain/runtime,
  isolated simulator cleanup, failure exit statuses and positive UI-test counts.
- Researched official GitHub pricing and runner availability. Repo reports public;
  standard macOS compute is free. Proposed run skips private repos, larger runners,
  artifact upload and caches. No account billing/settings/production accessed.
- Corrected dispatch proposal: GitHub requires its workflow on default branch.
  New inactive Markdown candidate uses ios-native-rebuild push plus explicit marker.
  Owner approval required for ONE workflow-file exception and ONE free build.

## Validation

| Check | Result | Evidence / limits |
|---|---|---|
| Swift core compilation and unit tests | PASS (final run: 36 tests, 0 failures) | Verified official Swift 6.1.2 Linux toolchain; no package dependencies |
| SwiftUI/widget/UI-test Swift syntax parse | PASS (final sources) | swiftc -frontend -parse only; not Apple SDK typechecking |
| XcodeGen input | PASS generated PBX graph/source/plist inspection | Generated with pinned XcodeGen locally; PBX graph/plists parsed and validated, no Apple SDK build |
| Credential and branch/path scan | PASS pre-commit scan | Pattern scan plus changed-file review; repeat before push |
| Xcode iOS compilation and simulator tests | BLOCKED / unrun | This environment is Linux; Xcode unavailable; no cloud job activated |
| Widget App Group/device behavior | BLOCKED / unrun | No Apple capabilities configured or registered |
| Supabase/RLS/provider/native callback tests | BLOCKED / unrun | No staging connection approved; production forbidden |
| Device signing/TestFlight/App Store | NOT ATTEMPTED | No Apple actions or paid services authorized |

Toolchain was downloaded to /tmp, verified by detached signature against Swift's
release key published in the official website repository, then executed. The
GPG key identity came from that official repository, not a local trust assignment.
Core tests are XCTest; the runner's separate “0 tests” Swift Testing line does not
replace the XCTest count.

Linux lifecycle tests exercise the same state logic without Apple Observation
notifications (the downloaded toolchain's Linux Observation library failed linking).
Core Observation macro expansion passed a separate availability-branch typecheck;
actual Apple SDK/UI compilation remains unverified until Xcode compiles it. This does
not hide a passed iOS check: iOS compilation and simulator testing remain BLOCKED.

## Honest functional boundary

This is an implemented native sample client, not a connected production app.
Sample actions validate roles/inputs and return idempotent in-memory audit receipts.
They do not mutate transactions or recalculate fixed financial summaries. Forms
say this explicitly. Auth/create/join/password/deletion are interface previews;
real sessions and backend persistence are not implemented. No mock pass proves RLS.

## Next work and blockers

1. Obtain approval for the documented branch-only cloud-build exception, then compile app/widget/UI
   targets using the checked-in project, resolve Apple-SDK type issues, run simulator tests and accessibility
   checks. macOS build workflow remains inactive until separately approved.
2. Review App Group/signing/account ownership and use the friend's existing tools
   only after authorization; no capability or paid service was activated here.
3. Owner decisions needed before connected implementation: future-effective
   allowance API, outgoing-debt display contract, comprehensive reversal interface.
   These do not block mock/native interface work.
4. A separately approved staging environment is required for Supabase adapter,
   Keychain sessions, auth callbacks, actual mutations, source sync, refund/role/
   concurrency integration tests and cross-device parity. Do not request prod.
5. Native Link SDK and approved sandbox consent flows, Gmail verification, full
   API/state-history parity, release icon/legal/support materials, security and
   recovery checks, shadow run and signed release remain outstanding.

All new changes still reside under ios/. No existing web/backend/workflow/settings modified; no production calls, deploys,
Apple submissions, paid activations or real account consents. Do not call this
App Store ready or claim an iOS build until actual Xcode/device evidence exists.
