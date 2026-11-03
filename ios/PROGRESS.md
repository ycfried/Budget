# OnBudget iOS progress

Updated November 3, 2026 (America/New_York). Work branch: `ios-native-rebuild`.
Main baseline: `1ab8c9acd1e4df0e4f4e65e34d8540de90dfb419`.

## Verified Xcode simulator result

- GitHub Actions run: [41648851937](https://github.com/ycfried/Budget/actions/runs/41648851937).
- Tested commit: `1d66a0f2c0750297f040fe1835108416880c138d`, including AppIcon fix `17601f5`.
- Result: **SUCCESS, attempt 1**.
- Xcode simulator compilation and test step: **PASSED**.
- The SwiftUI application, WidgetKit extension, and test targets built successfully.
- Automated simulator tests passed. The unchanged script selects Xcode 16.4 and an
  iPhone 16 / iOS 18.5 simulator, with signing disabled, and requires a positive UI
  pass count with zero failed or skipped UI tests.
- The source at that commit defines 36 core test methods and two UI test methods.
  The core suite succeeded; exact console-reported counts were not independently
  downloaded. Detailed web logs require authentication and API access was blocked.
  GitHub reported all job steps successful and no public failure annotations.
- **Synthetic/mock data only. No production integration was verified.** No staging
  environment, real authentication, financial records or provider accounts were used.
- The run completed within the 25-minute job limit. It was not retried.

Xcode compilation and simulator testing are **verified**, not blocked or unrun.
That evidence applies to the tested commit and sample workflow; it does not prove
complete specification coverage, device signing, connected behavior or store readiness.
No additional cloud build is authorized. The new offline milestone below has local
unit-test evidence only; its UI changes have not been compiled with the Apple SDK.

## Implemented foundation

- Native Swift 6/SwiftUI application, checked-in Xcode project and shared scheme;
  local OnBudgetCore package without remote dependencies or a network transport.
- Owner branding, unchanged owner mark and an AppIcon catalog; four-tab navigation
  with Savings, History, Connections and Settings & audit under More.
- Typed integer-cent/date input, DTOs, search/filter/sort logic, CSV preview parser
  and history export serializer, with focused automated core tests.
- Fixed synthetic dashboard, purchases, fund, savings, history, source-health and
  restoration/held-refund views. Sample scenarios exercise negative balance,
  offline and failing-read presentation.
- Role-aware action forms and confirmations, in-memory receipt/audit recording,
  mock permission/idempotency guards, stale snapshot retention and sign-out cleanup.
- Native Files CSV picker/export interfaces; actual import persistence and matcher
  decisions are absent. The simulator smoke suite does not exercise the Files flows.
- WidgetKit small/medium views, minimal snapshot model, freshness/privacy labels
  and Home deep link. Shared App Group cache behavior is not verified/configured.
- Observable-store tests cover failed submission/retry, offline writes, cleanup,
  read recovery and late completion after sign-out. UI smoke tests exercise sample
  admin navigation and sample member approval-control visibility.

## Functionality that remains a prototype

`MockHouseholdService` now owns mutable synthetic purchases and requests. Manual
entries, CSV sample rows, review/exclusion/restore/reclassification/void, request
creation and decisions visibly update those records and their local history.
Financial dashboard/fund/savings/closed-week/restoration/held totals stay fixed.
Allocation/policy/savings/held-release forms still record intents only. In-memory
role/idempotency guards are not server/RLS verification.
Authentication, household create/join, password recovery/change and account deletion
are disconnected interfaces. Clearing the sample session does not delete an account.
Bank/Gmail interfaces fail closed; Gmail connect is intentionally hidden per handoff.

All product-level gaps, source citations, statuses, dependencies and acceptance
criteria are in [NATIVE_GAP_ANALYSIS.md](docs/NATIVE_GAP_ANALYSIS.md).

## Validation boundaries

| Capability | Current evidence | Still outstanding |
|---|---|---|
| Native compilation and simulator smoke tests | SUCCESS, run 41648851937, attempt 1 | Broader screen/workflow/accessibility and device coverage |
| Core logic | Prior Linux run: 36 tests, zero failures; cloud core command also succeeded | Network/contract/server tests and richer malformed/concurrency cases |
| App/widget/test project configuration | Generated project, metadata/source checks; now compiled by Xcode | Distribution signing, identifiers and entitlement review |
| Shared widget data and timelines | Widget target compiled; snapshot model has core tests | App Group configuration, rendered widget/timeline/privacy/device tests |
| Supabase/Auth/RLS/integrations | **Not integrated or verified natively** | Explicitly approved synthetic staging environment and adapters |
| Financial rules | No Swift financial engine; literal display fixtures | Server-authoritative end-to-end acceptance and reconciliation |
| TestFlight/App Store/physical phones | Not attempted | Owner-approved Apple account, signing, distribution and release qualification |

The earlier Linux Observation linker issue was local tooling history, not a current
Xcode blocker. Actual Apple compilation subsequently passed in the verified run.

## Workflow and protection record

- The initial native milestone was `6b625b7`; project preparation was `714a96e`.
  The first cloud attempt failed; `17601f5` added the missing AppIcon catalog before
  the separately approved successful run above.
- The one existing restricted workflow was created earlier by explicit exception
  and remains unchanged. Simulator execution requires the special approved commit
  prefix. This documentation update uses a normal message and does not authorize
  or request a simulator build. GitHub may record a skipped workflow evaluation.
- Current offline implementation and documentation changes stay under `ios/`. Main, web application,
  Supabase, other workflows, settings and deployment integrations are untouched.
- No production access, signing, deployment, purchases or additional builds.
  Future build executions require separate approval.

## Outstanding decisions and approvals

1. Explicit synthetic-only staging connection approval; production stays forbidden.
2. Future-effective allowance/temporary-override behavior and complete reversal API;
   outgoing-debt response and transaction-state mapping need agreed contracts.
3. Apple account/app identifier ownership, distribution path, App Groups and device
   signing require separate approval; the simulator success supplies no such authority.
4. Gmail verification/consent or live bank connection needs its own approval. Preserve
   bank-only native launch until the documented Gmail verification gate is satisfied.
5. Any backend changes, workflow changes, new cloud build, spending or production
   operations remain outside the current authorization.

## Offline milestone M1 — stateful workflows (after 3db3e5f)

Plan: [IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md). This milestone follows
the FINAL state diagram and later owner decisions without a Swift financial engine.

- Typed transaction states distinguish provisional, bank pending, posted, review,
  excluded, reversed, voided and quarantined; unknown state/kind strings survive.
  Legacy row DTOs map verified to posted and bank provisional to pending without
  date-based promotion. Restores use the explicit pre-exclusion state.
- Manual entry/CSV import append synthetic records; identical-looking rows stay
  distinct. The same operation ID replays once; different imports are not matched.
  Negative CSV credits are unclassified/review items, never presumed refunds.
- Review/quarantine approval, reclassification, exclusion/restore and manual void
  update records and attributable state history. Manual void retains the record;
  it is not a new backend deletion policy. Provider-only test hooks can model
  pending/posting/removal and original-versus-posted amounts; no real provider runs.
- Fund requests appear in queues and full/split/decline decisions close them;
  closed split remainder and concurrent one-winner decisions are tested. Only the
  request remainder changes arithmetically; no fund balances/allocations are computed.
- Purchase details resolve current records by ID, show original amounts/history,
  and offer role/state-appropriate actions. Filters cover all typed states; empty,
  opening/cleanup and keyboard-dismissal behavior and accessibility labels improved.
- Lost-response scenario saves once and retries the same operation ID; conflicting
  reuse is rejected. Logout clears domain, audit and operation state and blocks
  reentry until cleanup completes. Failed forms retain input.
- Transport-free contracts include unknown-safe legacy row decoding and the
  required explicit null override_reason RPC argument. No networking was added.

Validation: 64 local XCTest core tests passed, zero failures (Swift 6.1.2 Linux);
final serialization check is included in the final recorded rerun. UI/Widget Swift
syntax parsing and PBX/source/plist graph validation passed. No Xcode, simulator or
cloud build was run for these changes. The earlier Apple simulator PASS remains
valid for 1d66a0f only. Public compiler tooling was restored and signature-verified
for local tests; no application/backend/provider services were connected.

Still synthetic: every session/user/household, purchase/request/history event,
financial summary, sync status and provider transition. Nothing is persisted across
sample sign-out. No matcher, refund linkage, refund restoration, weekly accounting,
fund/savings engine, RLS, real Auth or integration is implemented in Swift.

Next safe milestone: M2 typed intent/response/error and per-source read contracts,
followed by richer offline fixtures and coverage. Staging, policy/reversal/summary
contracts, Apple capabilities/signing and any new cloud build remain separately
gated. No approval is needed to reconsider already-settled financial rules.

## M2 — offline contracts and failure recovery (November 3, 2026)

Implemented transport-independent Codable operation envelopes, typed partial weekly
responses, explicit missing/null/value fields, structured unknown attributes/error
codes, strict integer cents and matching write acknowledgement IDs. The complete
legacy weekly decoder now rejects error/success ambiguity. Source freshness has
known and unknown wire states, preserves nullable/absent raw timestamps without
inventing age defaults, and is typed in sample source presentation.

Separated sample login/scenario controls from the read/write repository protocol.
The sample store retains stable IDs for multiple interleaved unresolved intents,
publishes typed write/failure state, never retries automatically, handles cancellation
without promising rollback, keeps cancelled reads read-only, and clears operation
state on logout. The mock checks task cancellation before atomic mutation. No
financial engine, monetary summary mutation, transport or real integration added.

Verified locally using Swift 6.1.2 on Linux: **82 XCTest core tests passed, 0 failed**
(64 existing + 18 new). New coverage includes missing/null/zero, unknown fields,
malformed/fractional/overflow cents, envelope errors/ambiguity, operation correlation,
typed request round-trip, source states/timestamps, interleaved lost-response replay,
cancellation before mutation and after simulated commit, cancelled read recovery.
Apple App/Widget Swift syntax parse, PBX/project/static metadata validation and
`git diff --check` passed. Safety scan passed before push. These are local checks,
not Xcode type checking, simulator execution, signing or distribution validation.
The historical simulator PASS remains run 41648851937 at commit 1d66a0f; no cloud
build was triggered for M1/M2 and this revision is not claimed Xcode-validated.

All records, credentials interfaces and financial snapshots remain synthetic.
M2 offline foundations are implemented; real API compatibility remains unverified.
See docs/M2_CONTRACTS.md for protocol boundaries, numeric representation limits,
manual retry semantics and deferred durable intent/reconciliation work. M3 identity,
M4 full server snapshots and M5 persistent intents remain incomplete. Approval is
required before staging/service access or another cloud build. Outstanding API and
product decisions remain command/envelope/idempotency/reconciliation contracts,
source timestamp/state semantics, complete financial/provenance payloads,
future-effective policy/reversals, refund links and admin departure/deletion policy.
No production, staging, Supabase, bank, Gmail or Apple service was connected.

## Integration readiness documentation review (November 3, 2026)

Added docs/INTEGRATION_READINESS.md from FINAL/HANDOFF and checked-in server/web/native
sources. It distinguishes verified source implementations from proposed/missing
contracts and owner decisions, inventories exact RPC names/arguments and auth/RLS,
records per-mutation retry risks, financial payload gaps, legacy state/null linkage,
policy/deletion conflicts, and proposes isolated staging acceptance gates.
Documentation only: no backend edits, service/data access, provisioning or build.
Local verification: documentation relative-link check, diff scope/whitespace review
and credential-pattern safety scan passed before push. No runtime tests rerun for
this review; M2's 82 local core passes and historical simulator SHA remain unchanged.

## Existing-household authentication/read preparation (November 3, 2026)

Owner now authorizes real-data preparation but explicitly requires approval before
first live connection and a separate specific plan before any financial write.
This supersedes the older staging-only gate for the selected read path, not the
production/backend/workflow/build safeguards. No live connection occurred.

Implemented NativeReadClient with Auth password grant, validated user/membership,
explicit household selection, session restore/coalesced refresh and local cleanup;
Keychain vault source (WhenUnlockedThisDeviceOnly, nonsynchronizing); guarded
URLSession executor with closed default, exact-origin/read-route allowlist and
redirect denial; strict pagination/household response checks and partial server
weekly DTOs; independent read-only store/native connection inspector. Runtime
configuration is absent and app composition stays locked; no real credential
entry is enabled. No real data can enter the writable sample service or widgets.

Added docs/FIRST_LIVE_CONNECTION.md listing exact Auth/compute/table endpoints,
columns, credential handling, privileges, Auth-session side effects, initial
45-request read window, stop/recovery limits and the separate financial-write gate.
No financial mutation/RPC/provider/deletion/week-close API is exposed. No Swift
financial calculations were added. Existing missing server financial aggregates
remain unavailable; row amounts and incoming debt never substitute for full totals.

Verified locally: **108 XCTest core tests passed, 0 failed** using Swift 6.1.2 Linux
(82 existing + 26 new). Tests use invented responses only: closed executor, request
shape/permissions, privileged-key rejection, identity/household/unknown-role checks,
null/unknown fields, range completeness, every read relation, sanitized HTTP errors,
cancellation, concurrent refresh coalescing, corrupt-session cleanup, saved-session origin binding, failed refresh summary removal and late-login
logout isolation. Enabled executor policy is tested without executing its requests.
App/Widget/Keychain Swift syntax parse, project/PBX graph/static metadata validation,
documentation link checks, diff whitespace/scope and credential-pattern scan passed.
SwiftPM emitted non-writable user cache warnings; compilation/tests completed.

These are not live Auth/RLS/API tests. Apple-only Keychain code and updated SwiftUI
have not been compiled or run with Xcode; prior run 41648851937 still applies only
to 1d66a0f. No cloud build/signing/deployment was triggered. All observed runtime
records are synthetic. Signup/recovery/create/join, full connected dashboard,
consistent server aggregates, durable intent reconciliation and financial writes
remain incomplete. Secure owner credential entry/build execution and the specific
first-connection approval are needed next; never ask for a password/token in chat.
No Supabase code/schema, web, workflow, deployment setting or main was changed.

## Approved read window — prerequisite enforcement (November 3, 2026)

Owner approved the FIRST_LIVE_CONNECTION.md Auth/read-only window; do not ask for
that same approval again. Configuration verification, secure owner-controlled
login and final network review are mandatory prerequisites. No live request was
sent, no public project key/config copied, no actual credential requested/entered,
and no build/signing/deployment/backend/provider action occurred.

Reviewed current composition: no runtime project configuration or enabled client;
login form stays locked. Exact project/public key is NOT verified and the secure
login route is NOT READY. An interactive owner/trusted-friend Mac simulator or a
separately approved native device route is needed. GitHub CI cannot provide secure
interactive password entry on an iPhone; a compilation pass is not that route.
See docs/LOGIN_ROUTE_STATUS.md for evidence, configuration method, execution-route
options and a concrete optional one-run simulator validation proposal (not active).
The owner has been asked which interactive route is available; no answer assumed.

Added ReadValidationWindow to guarded dispatch: exact bodies/query fields, selected
columns/household filters/order, initial 0–99 range, one password grant/refresh/week
read/collection page, max 15 identity + 15 membership reads, total max 46 including
optional refresh. Counts consumed atomically before dispatch; rejected/concurrent
replays stop the window. Transport/HTTP/cancellation/decoder/store validation
errors stop further live requests. No reset, retry or pagination loop. Collection
selection now only clears local rows; extra-page buttons removed for this window.
Added a locked-login UI test source; it has NOT been executed.

Local verification: **116 core XCTest tests passed, zero failures** on Swift 6.1.2
Linux (108 existing + 8 request-window tests). Tests exercise exact full window,
per-resource/Auth limits, forbidden methods/paths/body fields, wildcard/duplicate
query rejection, extra pages, explicit permanent stop and concurrent admission.
No enabled network executor is executed by tests. Apple App/Widget/UI-test syntax
parse, project graph checks, documentation links, whitespace/scope and credential
pattern scan passed. These are not Xcode, Keychain, live Auth/RLS or device results.
All runtime test data remain synthetic; no financial calculations or write APIs
were added. All edits remain under ios/. Any new simulator build needs separate
approval; the existing read-window approval does not authorize one.

## One authorized fixture-only simulator validation — trigger record

Owner explicitly approved exactly one additional run of the existing restricted
workflow, max 25 minutes, unsigned, fixtures only, no uploads/signing/live requests,
workflow modifications or retries. Application baseline is 251be1b; this trigger
changes this progress record only. Default live composition remains locked and
has no runtime project configuration/credentials. This is not approval for a live
connection or financial writes. Actual completed-run evidence is recorded below.
No branch push will occur while the job is running, preserving the approved SHA.


## Authorized simulator run 41689326270 — FAILED, no retry

- Run: https://github.com/ycfried/Budget/actions/runs/41689326270
- Job: https://github.com/ycfried/Budget/actions/runs/41689326270/job/126103436266
- Exact approved trigger SHA: `c35910d8ba4e758a111700addd717c7ed020ed8c`.
  Application code baseline: `251be1b73da166f11fc9308ee2f512afdd41d70f`;
  trigger changes only this documentation. One prefix commit/push was issued.
- Final GitHub conclusion: **FAILURE**. Public run duration: 27 seconds;
  simulator job: 21 seconds, within the existing 25-minute maximum.
- Set up job and checkout: **SUCCESS**. Combined “Validate, compile and test
  synthetic app” step: **FAILURE**, started 2026-11-03 17:58:46 UTC and completed
  17:58:47 UTC. Exact exposed annotation: **“Process completed with exit code 134.”**
  Post-checkout and job cleanup: SUCCESS.
- Compilation result (updated from owner-retrieved full log): **NOT STARTED**.
  The original report could not identify the failing command from its annotation;
  the owner subsequently confirmed the version-check abort before Swift package
  or Xcode app/WidgetKit/test compilation. See confirmed root cause below.
- Test result (updated): **NOT STARTED**. No core or simulator/UI tests executed
  in this run. Earlier 116 Linux test passes are separate evidence; earlier
  successful simulator run 41648851937 applies only to its old SHA.
- Additional warning: checkout targets deprecated Node.js 20 and GitHub forces
  Node.js 24. Checkout itself passed; this warning is not a verified cause of the
  validation failure. No workflow/action version changes were made.
- Evidence access limitation: public run/job HTML exposes final conclusion,
  step conclusions/timestamps and annotations, but says “Sign in to view logs”.
  Official step/run log URLs returned 404 anonymously; `gh api` metadata access
  was denied by this environment's network policy. Console logs/xcresult bundles
  and exact failing subprocess were not available. No credentials were extracted,
  authentication bypass attempted, or artifacts uploaded. The owner subsequently
  retrieved the existing full log and supplied the confirmed root cause below;
  no additional build was needed to identify it.
- Safety: workflow unchanged, standard configured GitHub-hosted macOS runner,
  unsigned fixture-only composition with no project credentials or live executor.
  No live/backend/provider/financial operation, main/web/Supabase/settings edit,
  signing, distribution, upload or paid-service activation was performed.
- No retry/replacement run was requested or triggered. Authorization for this
  execution is consumed. Any future build needs new approval. This follow-up
  documentation commit uses a normal message and cannot pass the simulator job's
  approved-prefix gate. First-live-connection prerequisites remain unresolved.

Documentation follow-up verification: changed-file list limited to ios/PROGRESS.md,
workflow diff unchanged, whitespace and credential-pattern safety scan passed.
Local runtime tests were not rerun for this documentation-only follow-up.


## Confirmed Xcode version-check abort and local script fix

Owner retrieved the full log of run 41689326270 and confirmed the failing command
at original ios/scripts/macos_simulator_test.sh line 21:
`xcodebuild -version | head -n 1 | /usr/bin/grep -qx 'Xcode 16.4'`.
`head` closes its pipe after the first line while Xcode is still writing; Xcode
throws **NSFileHandleOperationException: Broken pipe** and aborts with exit 134.
**App/core compilation and tests never started.** This supersedes the original
annotation-only uncertainty; no application compile/test failure was established.
The checkout Node.js deprecation warning was not this failure's cause.

Fixed only the version validation: capture complete `xcodebuild -version` output
once in a task-specific shell variable, print the captured output, and compare its
first line exactly to Xcode 16.4 using Bash parameter expansion. No early-closing
pipe, duplicate Xcode invocation, fallback version or download. Existing `set -e`
still propagates a failed version command, instead of accepting its partial output.
Workflow, build commands, financial/app code, live configuration and permissions
are unchanged.

Added scripts/test_macos_version_check.py. It extracts the actual script version
block and substitutes a local synthetic xcodebuild executable. **4 regression
tests passed**: over-1-MB multi-write output fully drained with final marker and
one invocation; wrong version rejection; exact first-line matching including four
invalid variants; nonzero producer status preserved despite valid-looking output.
No Xcode, simulator, provider or live network request is executed by these tests.

Other verified local checks: **116 Swift core XCTest tests passed, 0 failures**;
`bash -n`, static PBX/project validation, `git diff --check`, branch/changed-file
scope and credential-pattern safety scan passed. Swift tests are Linux/fixture
results, not validation of the script on macOS or a new Apple compilation.
No cloud build/retry/signing/deployment or financial-data access occurred.
Only the simulator script, its regression check and this progress document changed,
all under ios/ on ios-native-rebuild. Ordinary commit message only; any new
simulator execution still requires separate explicit approval. Stopped after fix.
Authorized fixture-only simulator validation of 971903a; no live access.
