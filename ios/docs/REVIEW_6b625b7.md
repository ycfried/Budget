# Read-only audit of first native milestone and corrections

Reviewed November 2, 2026 (America/New_York). Source commit 6b625b7, parent
1ab8c9a (the main tip used to create ios-native-rebuild).

## Boundary verification

`git diff-tree --no-commit-id --name-only -r 6b625b7` lists 37 files, all ios/.
No rename, deletion or modification outside ios/. Main, web, supabase/, existing
workflows, settings and production are untouched. No production access was used.
The safety script checks both committed branch differences and working files.

## Findings and changes in this milestone

| Finding in 6b625b7 | Correction / disposition |
|---|---|
| Only a YAML project specification; actual project/scheme absent | Generated and checked in OnBudget.xcodeproj and shared OnBudget scheme; first cloud build needs no XcodeGen installation |
| No explicit extension-only API restriction | APPLICATION_EXTENSION_API_ONLY=YES for widget |
| Initial generation produced hardcoded version 1.0 while MARKETING_VERSION was 0.1.0 | Both plists use MARKETING_VERSION/CURRENT_PROJECT_VERSION placeholders |
| Ambiguous generated/custom plist ownership | Explicit app/widget plists; UI-test target explicitly generates its own plist |
| XcodeGen's app preset supplied a signing identity | Explicit blank app identity; all targets inherit signing disabled and empty team |
| No lifecycle unit coverage for AppModel | State controller moved into local core package; tests cover offline, denied action/retry, cleanup, recovery and suspended read after sign-out |
| Forms and CSV previews dismissed even after rejected submissions | submit now reports success/failure; failed forms keep input/preview |
| Initial sample entry could be tapped repeatedly during suspension | opening state/generation guard prevents duplicate entry and stale completion |
| canWrite was true without a session | Session and opening state now required |
| Transaction filters omitted week and classification | Added native filters using server-listed weeks and calendar-only bounds, with DST-boundary tests; no budget engine |
| Original manual-dispatch-only cloud idea cannot work reliably without default-branch file | Replaced with documented branch-only, marker-gated push candidate; inactive |

## Static project evidence

Generated using XcodeGen 2.42.0 at upstream commit
82c6ab9bbd5b6075fc0887d897733fc0c4ffc9ab. Its pinned XcodeProj dependency's
legacy Linux random helper conflicts with modern Glibc; local temporary build
qualified that call as SwiftGlibc.arc4random_uniform. No generator/dependency source
is vendored, no expected checksums were changed, and no package verification was
disabled. macOS uses the unmodified upstream tool if regeneration is needed.
The checked-in output was parsed with Foundation's OpenStep plist parser and
validated as an object graph, not merely searched as text.

Validation checks all 3 native targets, every app/widget/UI-test source membership,
local Swift package path, widget embedding under PlugIns, privacy resources in both
products, Info.plist metadata, shared test scheme, disabled signing/no entitlements,
and absence of remote packages or shell build phases.

The official Linux Swift 6.1.2 Observation runtime exposed an unresolved linker
symbol when the store first imported Observation on Linux. The observable macro is
now Apple-only via canImport(SwiftUI); Linux runs the same state/controller logic
without observation notifications. A clean scratch rebuild was used after this
change. Core Observation macro expansion also passed a separate compiler typecheck
using an empty availability-only SwiftUI module to select that conditional branch.
No SwiftUI API was stubbed/typechecked by that probe; actual Apple SDK/UI compilation
remains the Xcode gate.

## Completeness verdict

This remains a synthetic native client, not a connected or production-ready rebuild.
Mock action receipts do not mutate transactions, request views or financial totals.
Auth/create/join/reset/deletion are interface previews. Keychain sessions, native
Plaid SDK, live source operations, native OAuth recovery, server idempotency/RLS,
reversal contracts, full transaction provenance/state history and connected
reconciliation still require approved staging/API work. Gmail remains hidden per
later owner decision. No new Swift budget, refund, close or fund engine is present.

App Groups, shared live widgets, signing profiles, App Store icon/legal/support
materials, two-device behavior and provider consent tests are not complete. No
App Group or Apple account is needed for the first unsigned simulator compile.
App/widget shared cache intentionally remains empty until a later approved
entitlement configuration; the widget empty state itself must compile now.

No remaining compile failure is claimed fixed without evidence: actual SwiftUI,
WidgetKit, FileDocument, observation macros, simulator installation and XCUITest
execution have not yet been tested with Apple's SDK. Linux parse/typecheck/core
unit results and generation do not make this app build-ready.
