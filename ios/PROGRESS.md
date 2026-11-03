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
