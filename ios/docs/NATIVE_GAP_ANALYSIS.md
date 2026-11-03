# Native specification gap analysis

Reviewed November 3, 2026 (America/New_York), on `ios-native-rebuild` at application
commit `1d66a0f2c0750297f040fe1835108416880c138d` (includes `17601f5`).
This review changes documentation only. No build, production read/write, staging
connection, Supabase edit, workflow change, signing, deployment or spending occurred.

## Evidence, precedence and status meaning

Sources: the full [FINAL PDF][spec] (20 pages, including the page 9 state diagram),
the complete [HANDOFF.md][handoff] including its evening addendum, and the native
source/test files cited below. Existing backend source is reference material only;
its presence and handoff's historical live reports do not verify native integration.

Verified build: [run 41648851937][run], **SUCCESS, attempt 1**. SwiftUI app,
WidgetKit extension and test targets compiled; the automated simulator test step
passed. The build used synthetic/mock data only. Source defines 36 core and two
UI tests; console-reported counts were not independently downloaded. Do not turn
successful compilation or two smoke tests into a claim of complete product behavior.

Every requirement below receives one of these statuses, scoped to its row:

- **IMPLEMENTED**: the named bounded native capability actually executes, with
  source/test evidence. This never implies a connected household workflow.
- **PARTIAL**: working local pieces or UI exist, but required effects/coverage are
  absent. A functioning form returning a receipt is still partial product behavior.
- **MISSING**: no native implementation for the required behavior; documentation,
  DTOs, protocol names or explanatory text alone do not count.
- **BLOCKED**: connected verification or enablement requires an approval, external
  configuration, account/capability, or unresolved product/API decision. This does
  not mean the corresponding server feature is absent, or that Xcode is blocked.

Precedence: FINAL financial rules, documented later owner decisions, then current
explicit user safeguards. The PDF's v2 cover is stale; its refund-restoration
sections govern. Later decisions preserve open signup/email confirmation off,
reusable non-expiring code-only invitations, personal Gmail OAuth replacing the
forwarding plan, bank-only native launch until Gmail verification, admin-only bank
management/manual sync, blank adjustment reasons allowed, split remainder closed,
fund-first refund ordering and restoration through the last completed week.
These are settled requirements, not questions to ask again. Native implementation
is now authorized despite the older handoff's “native last” scheduling note.

## 1. Screens and complete user workflows

The implementation is more than static drawings: navigation, filtering, input
validation, file parsing/export and receipt generation run. However, every financial
view uses [Fixtures.snapshot()][fixtures]. [MockHouseholdService.submit][service]
only validates selected inputs, records a receipt/audit event and tracks some request
decisions privately; it does not persist/mutate purchase, fund, request or savings
records. [HouseholdStore][store] refreshes the same fixtures after actions.

| ID / requirement (spec reference) | Status | Actual implementation evidence | Gap and acceptance criterion |
|---|---|---|---|
| S01 Native app shell and navigation (B6–B7) | IMPLEMENTED | [OnBudgetApp][app], [RootView][components], [UI smoke tests][ui] | Native SwiftUI, no web wrapper; tested sample navigation. Broader navigation/deep-link coverage is separate. |
| S02 Sign in, signup, reset-password request | PARTIAL | [AuthenticationView][auth], [Credentials][values] | Only local email/password-length validation and sample role buttons. Implement Auth requests, errors, loading and recovery delivery in approved staging. |
| S03 Persistent login, expiry/refresh, account switching/logout | PARTIAL | [Session][models-values], [HouseholdStore.signOut][store] | In-memory sample identity/logout works; no token/session persistence or revocation. Acceptance: relaunch/expiry/logout cannot leak another session's data. |
| S04 Create/join household; two-person membership (A1) | PARTIAL | [SettingsView][settings], [MockHouseholdService.openSample][service] | Name/code inputs produce explanatory messages, not membership. Replace role selection with server membership; test two accounts, duplicate join, capacity and isolation. |
| S05 Invite sharing and server throttling | MISSING | [SettingsView][settings] only explains code semantics | No server invite read/copy/share or invalid/limited join outcomes. Acceptance: admin shares private code; member joins through server; brute-force/capacity behavior tested. |
| S06 Home balances, allowance, spending, incoming/outgoing debt, increments, days left (B7) | PARTIAL | [DashboardView][home], [Dashboard/WeekResponse][models], [fixtures][fixtures] | All figures/days are literal fixtures. Fetch authoritative snapshot/time; unavailable fields must remain unavailable rather than be derived financially in Swift. |
| S07 Negative balance and pending-refund exclusion display | PARTIAL | [DashboardView][home], overspent fixture in [Fixtures][fixtures] | Display works; no connected calculation or scenario proof. Accept returned negative values and excluded pending-refund amounts without recomputation. |
| S08 Home freshness/status immediately beneath balance | PARTIAL | [DashboardView][home], [FreshnessView][components] | Fixed estimate/time plus separate source cards; no live source-age warning policy. Acceptance: bank/email/CSV ages persist and become stale visibly as time passes, including paused/expired feeds. |
| S09 Transaction search, state/week/month/card/classification/refund/review filtering and sorting | IMPLEMENTED | [PurchaseQuery/PurchaseFilter][models], [TransactionsView][transactions], [query tests][contract-tests] | Functional over loaded records only. Does not establish server-wide search or correct classification. |
| S10 Transaction history completeness/pagination | PARTIAL | [TransactionsView.pageSize][transactions] | “Load more” only increases a local prefix; eight fixture purchases do not exercise large paging. Add stable server cursors and complete-list tests. |
| S11 Purchase detail: original/posted amounts, corrections, match evidence and state history (B3–B4/B7) | PARTIAL | [PurchaseDetailView][transactions], [Purchase][models] | Basic amount/source/state/allocation and synthetic provenance string. No original merchant/amount, correction chain, linked refund or real event history. |
| S12 Manual provisional purchase by either role (A1/B2) | PARTIAL | [ActionEditor.manual][editor], [ManualPurchase][models], [service receipts][service] | Validation executes, but no purchase is added. Acceptance: insert provisional row, reread it on two devices, reconcile later without duplicates. |
| S13 Flag, confirm or void a review item; seven-day unconfirmed alert queue (A1/B3) | PARTIAL | Flag form in [PurchaseDetailView][transactions]; fixed needsReview in [fixtures][fixtures] | Flag only creates a receipt; no aging, persistent flags, confirm/void queue or evidence. Acceptance: server flags at seven days, stays counted until a valid resolution. |
| S14 Exclude/restore/reclassify (A7) | PARTIAL | [ActionEditor][editor], [TransactionChange/validate][service] | Forms/mock guards only; no row changes or previous-state restoration. Must call role-checked RPCs and display authoritative post-action state. Blank reasons remain allowed per handoff. |
| S15 Manual deletion and reversal of adjustments (A1/B5) | PARTIAL | Manual-only button/guard in [transactions][transactions]/[service][service] | No actual delete/reversal. Clarify spec append-only/reversible adjustments versus current manual-delete contract; never delete bank history on client. |
| S16 Native Files CSV selection/preview/error handling | PARTIAL | [TransactionsView.fileImporter][transactions], [CSVImport][csv], [CSVTests][csv-tests] | Parser/size/UTF-8 checks and preview are real; Files-provider cancellation, security scope and read errors lack simulator/device workflow coverage. |
| S17 Confirm import, deduplicate overlaps, match existing rows, report result (B2–B3) | PARTIAL | [CSVImport][csv], [HouseholdAction.csv][service] | Confirmation records a receipt; no import, reconciliation, batch ID or persisted row outcomes. Acceptance: repeat/overlap imports do not double-count; ambiguous identical purchases remain distinct. |
| S18 Extra Fund totals and ledger (A5/B7) | PARTIAL | [FundView][fund], [FundSummary][models] | Fixed available/pending/released/spent/adjustment/shortfall records, no authoritative ledger paging or reversal detail. |
| S19 Request fund use, linked purchase/note, admin queue | PARTIAL | [FundView][fund], [ActionEditor.request][editor] | No new request appears or notifies admin; validate linked household/purchase and requested amount server-side. |
| S20 Approve/full or partial split/decline | PARTIAL | [FundView][fund], [MockHouseholdService.validate][service] | Mock rejects over-approval/repeated decisions and closed split requests; request views and fund remain fixed. Acceptance: one atomic server decision/allocation/audit under concurrency, remainder closed as decided. |
| S21 Direct admin allocation and normal/fund purchase split | PARTIAL | [ActionEditor.allocate][editor], [HouseholdAction.allocate][service] | Amount/note form has no transaction identifier or per-purchase split editor. Need approved transaction-allocation contract, full/split linkage and audited reversal. |
| S22 Insufficient fund block and reasoned override | PARTIAL | Override field in [ActionEditor][editor] | Mock does not compare availability or require a reason when short. Server must enforce, return explainable denial, and audit override; never implement a fund engine in Swift. |
| S23 Restoration history and held-refund release | PARTIAL | [FundView][fund], fixed [LedgerRecord/HeldRefund][models] | Sample history/release receipt only; no purchase linkage, simulation breakdown, debt detail fields or resolution mutation. Acceptance: server exactly-once posting; held release applies shortfall first. |
| S24 Savings four-number reconciliation and suggestion (A6) | PARTIAL | [SavingsView][savings], [SavingsSummary][models] | Fixed fund/earned-not-transferred/actual/interest-and-movements plus explanatory suggestion. No server summaries, bank balance or separately reconciled interest/outside items. |
| S25 Savings balance attestation and movement recording | PARTIAL | [ActionEditor.attest/savings][editor] | Records receipts only. Acceptance: admin attests confirmed movement, both users reread it, normal spending never changes. |
| S26 Transfer initiated/pending/posted/reversed/unmatched lifecycle | MISSING | [SavingsKind][service] has types only, no lifecycle | Add read-only movement states, classification and source/attestation evidence; intent must not confirm a transfer. No transfer execution. |
| S27 Weekly history and revised/locked/release state | PARTIAL | [HistoryView][savings], [HistoryWeek][models] | Two fixed weeks and revision note; no full historical server query, locked indicator or revision trail. |
| S28 Owner history CSV file export | PARTIAL | [HistoryDocument][savings], [HistoryExport][widget-model], [export test][contract-tests] | Real CSV serialization/fileExporter plumbing; only fixture data and no Files end-to-end proof. Verify complete server history, content and export failure/cancel on device. |
| S29 Allowance change, future effective date and preview | PARTIAL | [SettingsView][settings], [ActionEditor.allowance][editor] | Current amount/confirmation only; no effective date, server preview or save. Contract decision D2 below blocks connected behavior. |
| S30 Temporary overrides with preview/reversal | PARTIAL | [ActionEditor.temporary][editor] | Amount/note only; no explicit week/effective range, impact preview, listing, expiry or reverse action. Acceptance: server-controlled effect cannot rewrite locked policies. |
| S31 Full household audit for both roles | PARTIAL | [SettingsView][settings], [AuditEvent][models], [mock events][service] | Fixture event plus local receipt events; no immutable attributable server events, complete paging, financial before/after or reversal links. |
| S32 Change password, delete account and sign out | PARTIAL | [SettingsView][settings], [HouseholdStore][store] | Password length check; “Clear sample” only clears memory/cache. No Auth mutation, identity confirmation, server deletion/revocation or shared-household ownership policy. |
| S33 Bank connect/reconnect/update, sync, account list and disconnect | PARTIAL | [ConnectionsView][settings], [BankLinking/UnconnectedIntegrations][service] | Connect/disconnect throw unavailable; sync returns a sample receipt. No SDK, account list, Link result exchange, update mode or server status. |
| S34 Gmail connect/reconnect/check/disconnect | BLOCKED | Hidden consent in [ConnectionsView][settings]; [EmailConnecting][service] | Preserve bank-only launch until verification; later approved OAuth callbacks/token lifecycle and source state must be implemented. No mailbox access now. |
| S35 Privacy, support and account documentation | PARTIAL | [SettingsView][settings], [privacy manifest][privacy] | Placeholder copy/manifest, no approved public policy/support/terms routes or release disclosures. Verify manifest reasons/SDK disclosures before release. |
| S36 Branding, accessible native interaction | PARTIAL | [components][components], owner mark/[AppIcon][icon], [editor][editor] | Native labels, type styles, blue four-second toast and icon exist; VoiceOver, large text, contrast, keyboard/focus, motion and device layouts need targeted validation. |

## 2. Synthetic dependencies and the real integration boundary

| Requirement / dependency | Status | Evidence, limit and completion criterion |
|---|---|---|
| Explicit synthetic identity and fixed financial snapshots | IMPLEMENTED | [Fixtures][fixtures], [MockHouseholdService][service], [SampleNotice][components] clearly label invented data. Preserve isolation from authenticated builds. Fixtures are independent display examples, not a self-consistent full ledger. |
| Stateful household workflows | MISSING | [service][service] records action labels/receipts, not domain mutations. Even valid approval/decline leaves the pending request in the returned fixture list; its internal decided set only prevents a repeated action. Implement against server truth after approval; a stronger mock may exercise state transitions without calculating finance. |
| Network transport/Supabase adapter | MISSING | [Package.swift][package] has no remote SDK; [BackendContracts][contracts] contains only compute/approval request DTOs and week decoding. Need typed repositories, HTTP/RPC errors, cancellation, retries with stable operation IDs, bounded payloads and environment configuration. |
| Synthetic staging connection and integration testing | BLOCKED | User approval is required before connection. No production URL or credentials should be copied from root configuration. Acceptance: approved project allowlist, separate users/data, fail-closed environment selection. |
| Auth session vs household membership boundary | MISSING | [Session][models-values] carries chosen role/name only, no authenticated identity/household ID. [HouseholdService][service] mixes sample entry/scenarios with reads/writes. Separate demo control from future auth/household services; derive roles from server. |
| DTO/schema fidelity | PARTIAL | [models][models] use app-specific nested Money objects, generic strings and synthetic IDs; they are not direct table-row adapters. Validate snake_case, amounts, nullable/unknown states, timestamps, enums, IDs and server response versions in contract tests. |
| Authoritative summary completeness | BLOCKED | [WeekResponse/Dashboard][models] keep outgoing debt optional; existing [compute-week][compute] contract has no outgoing-debt field. Agree a server-returned display contract, as well as fund/savings aggregates, days left and timestamps. Do not derive finance in Swift. |
| Operational data model inventory (B5) | BLOCKED | The following spec tables/concepts need an approved staging schema/API inventory. Root SQL patches and [backend interface notes][backend-notes] are references, not deploy parity proof. No SQL is applied in this task. |

B5 inventory to map, without requiring the spec's exact physical table names:

- Household/memberships, historical budget policies/temporary overrides and financial weeks.
- Source events, transactions, matches, transaction-state history and original evidence.
- Append-only ledger entries, allocations, requests, week-close runs and surplus releases.
- Bank accounts/Plaid items and savings reconciliation/movement lifecycle.
- Source health, CSV import batches/row outcomes, quarantine items and merchant rules.
- Device registrations, notification preferences/quiet hours and backup-run evidence.

Native [models][models] cover simplified purchases, requests, ledger/history/audit and
source health only; there are no repositories for the above inventory. Missing
source-event/provenance/currency/account/time-precision fields are important data
gaps, not permission to create a competing native accounting schema.

## 3. Financial rules: all authoritative execution stays outside Swift

The native code must display server results and submit intent. [Money/PurchaseDate][values]
perform input/formatting/calendar filtering only. [WeekResponse][models] is a DTO;
[Fixtures][fixtures] hardcodes amounts. **Do not port the engine into Swift.**
Existing reference implementations are [engine.mjs][engine], [compute-week][compute],
[week-close][close] and [restoration.mjs][restoration]. Their native end-to-end
verification is **BLOCKED** on approved staging, even where historical JS tests exist.

| Rule (FINAL A2–A7) | Status for native end-to-end behavior | Required server acceptance |
|---|---|---|
| One $375 shared Sun–Sat allowance; household purchase/authorization date, New York timezone and DST | BLOCKED | Two users see one server week; authorization/import dates cannot shift it. Calendar filtering tests do not prove booking. |
| Base absorbs incoming debt first; carried debt, capacity, covered charges, new debt and outgoing debt | BLOCKED | All A3 worked examples match server snapshots; incoming D label is not confused with residual carried debt. |
| Temporary increments cover only current excess charges; cannot pay prior debt or earn surplus | BLOCKED | Unused increment expires without credit; earlier debt and historical snapshots stay correct. |
| Available may be negative; C is eligible net charges floored at zero | BLOCKED | Server handles allocations/exclusions/refunds; device never recomputes C or available. |
| Sunday idempotent close, ledger posting and historical policy snapshots | BLOCKED | Repeat/concurrent close produces one durable effect, including recovery after partial failure. |
| Surplus pending seven days from actual close, then exactly-once release | BLOCKED | Late close does not skip pending window; replay cannot mint funds. |
| Recompute open weeks for 28 days, including downstream weeks | BLOCKED | Deterministic results and visible revisions; later allowance changes preserve booked policy. |
| Locked late charge posts current adjustment with true purchase date, no historical edits | BLOCKED | Current adjustment appears once; locked history unchanged. |
| Already-released surplus reduction, zero fund floor and separate shortfall | BLOCKED | $75 released/$60 spent/$50 reduction yields $0 fund/$35 shortfall; next release offsets it, never normal-budget clawback. |
| Refund follows original normal/fund/split allocation; posted only | BLOCKED | Pending or removed refunds do not restore; fund purchase credits fund; fund-first split ordering per handoff. |
| Locked refund restoration through last completed week using original inputs | BLOCKED | Read-only simulation changes only refunded purchase's charge; current restoration shows surplus credit and debt reduction. No old refund-credit model. |
| Incremental partial refunds, replay safety, cap and shortfall-first credit | BLOCKED | Sum/order of partial refunds cannot double-credit or exceed refund; excess held pending admin review; held release follows later owner decision. |
| Extra Fund only released entitlement and explicit admin-approved allocation | BLOCKED | Overspending never automatically consumes fund; full/split approval atomic and insufficient-fund override requires reason/audit. |
| Savings transfers/withdrawals are not spending or earnings; interest/outside cash separate | BLOCKED | All A6 examples reconcile, intent never confirms a transfer, unmatched money stays classified separately. |
| Fees/advances/subscriptions/reimbursements count normally unless admin excludes; cashback/payment excluded from spending | BLOCKED | Classification and server state determine math; card payments are not refunds. |
| Attributable reversible adjustments, immutable ledger and concurrent constraints | BLOCKED | Same-household role checks, reversing entries and database uniqueness/serialization verified directly. |

Refund-restoration subcase checklist (FINAL page 17): each remains **BLOCKED** for
native/server integration. Require fixtures and approved server tests for: $475
purchase/$150 late refund with later debt absorbed ($150 surplus/$0 debt cut), the
same with debt outstanding ($50 surplus/$100 debt cut), full $300 restoration,
$100 temporary-covered portion restoring $0, direct $60 fund refund, $35 shortfall
before $50 restoration ($15 spendable), $500 refund against $475 purchase ($25
held), duplicate event no-op, $100 then $200 partials equal one $300 refund, reverse
partial order, pending-to-posted timing, removed pending refund no trace, full replay
and read-only snapshots, and later allowance changes not rewriting old restoration.
Existing [JS engine tests][engine-tests] are reusable server evidence, not new native
passes; no tests were rerun for this documentation task.

## 4. Security, state machine, Gmail, banking and synchronization

| Requirement (A1/B2–B6) | Status | Evidence / missing work / acceptance |
|---|---|---|
| Keychain session storage, secure token refresh/revocation | MISSING | [Credentials][values] and sample session remain in memory; no Keychain implementation. Store session secrets securely; purge on logout/delete/identity change; never use UserDefaults for tokens. |
| Backend authorization and household isolation | BLOCKED | [mock role tests][service-tests] test an actor, not HTTP/RLS. Use admin/member/anonymous/second-household identities against staging, including direct forbidden writes and cross-household links. |
| Signup policy, password reset/change, recovery callbacks | PARTIAL | [auth][auth]/[settings][settings] preview forms only. Preserve later signup/email decisions; add server errors, recovery session handling, allowlisted native callback and replay/cancellation tests. |
| Household/invite abuse prevention | BLOCKED | Verify server two-user/one-household limits, code-only joins, rate limits under concurrency and generic failure responses. Do not revert to UUID joins or expire codes silently. |
| Account deletion and admin departure | BLOCKED | UI only clears sample state. Need approved deletion/ownership succession policy, integration revocation, shared-data preservation and partial-failure recovery; test throwaway staging accounts. |
| Financial connections read-only; no money movement | IMPLEMENTED | [HouseholdAction][service]/[UI][settings] contain recording/attestation only; no transfer/payment API or SDK is present. Revalidate this boundary when adding providers. |
| No secrets/raw mail in native bundle/logs | PARTIAL | [package][package], [contracts][contracts], [safety scanner][safety], [privacy manifest][privacy] support current synthetic isolation. No connected logging/redaction policy, crash-report audit or release-bundle security review yet. |
| Optional biometric unlock | MISSING | No LocalAuthentication implementation; optional enhancement, not a substitute for server auth. Requires privacy/session policy and device tests. |
| Six-state transaction machine (B4 diagram) | PARTIAL | [Purchase.stateLabel][models] maps provisional→Pending, verified→Posted, reversed→Reversed; separate excluded/review flags. Provisional vs bank Pending is conflated; Quarantined/Voided are absent; Needs review is not a server transition/history. Agree a lossless mapping before integration. |
| Canonical multi-source matcher and original evidence (B3) | MISSING | [CSV parser][csv] deliberately does not dedupe; [Purchase][models] lacks full currency/account/time/source evidence. Native must expose server decisions/ambiguity queue, not merge by amount alone. |
| Identical real purchases, hold/tip changes, delayed posting and partial refunds | BLOCKED | Need server matcher cases, correction detail, pending_transaction_id handling and explicit refund purchase linkage. [Plaid sync source][plaid-sync] intentionally leaves original_purchase_id null; do not invent linkage. |
| Quarantine review and merchant normalization rules | MISSING | No quarantine/merchant-rule native models/screens/actions. Add server-backed approve/reject evidence and audited rules without replacing original merchant. |
| UTC source timestamps, precision/timezone and date_uncertain | PARTIAL | [PurchaseDate][values] validates date-only values; [Purchase][models] has no source timestamps/uncertainty. Preserve purchase/authorization dates, never substitute email receipt or import time. |
| Native Plaid Link SDK and server exchange/update/disconnect | MISSING | [BankLinking][service] is a protocol, not the SDK. Add reviewed/pinned dependency and cancellation/expiry/update-mode handling; keep access tokens/encryption keys server-side. |
| Plaid consent and sandbox/staging verification | BLOCKED | Requires specific approval; no real accounts/credentials. Transactions only; verify coverage and additional-card attribution rather than assume mask identifies person. |
| Gmail verification and consent | BLOCKED | [ConnectionsView][settings] correctly hides connect. Later approval must preserve readonly scope/server encryption, state TTL/single use and native-safe callback. Testing-mode token expiry/reconnect must be visible; public verification requirements remain external. |
| Gmail parsing authenticity/replay/quarantine | BLOCKED | Server-only path, not a native mailbox parser. Reuse approved redacted alert fixtures and fail-closed sender/DKIM+SPF rules per handoff; never read general mailbox or follow mail links. |
| Scheduled sync/webhooks/cursor recovery | BLOCKED | [bankSync][service] is a sample receipt, not sync. Test added/modified/removed pages, cursor failure/replay, event authenticity/dedupe, cron failure and app-closed ingestion in approved staging. Do not rely on phone background execution. |
| Realtime/cross-device refresh and conflict resolution | MISSING | [store][store] refreshes one fixed snapshot; no subscription, foreground refresh coordinator, version/cursor merge or cross-device update. Server decides conflicts and financially authoritative ordering. |
| Source status, reconnect, stale feed and partial sync failures | PARTIAL | [SourceHealth][models]/[FreshnessView][components] render literal status/stale flags; no feed-age computation or durable per-source progress. Acceptance includes Gmail expiry, bank disconnection, zero-account/partial/truncated sync without false success. |

The [backend interface inventory][backend-notes] identifies existing RPC/function
names. It does not supply a connected adapter. Risks for approved later assessment
include multi-write week-close atomicity, hash-match eligibility/silent skipped
writes, refund linkage, audit-text provenance, webhook dedupe and schema drift.
No production severity/closure is revalidated here. Historical handoff proofs
(password reset/deletion/backup/Gmail/cron) must not be presented as native proof.

## 5. Widgets, notifications, offline behavior and errors

| Requirement (B6–B7) | Status | Evidence and acceptance criterion |
|---|---|---|
| WidgetKit target and small/medium layouts | PARTIAL | [Widget source][widget] compiled in the successful run; minimal amount/freshness/privacy views exist. No rendered widget-family tests or actual home-screen installation proof. |
| Minimal shared App Group cache | BLOCKED | [WidgetCache][cache] and [provider][widget] support it, but both [Info.plists][app-info]/[widget plist][widget-info] have empty group IDs and no entitlements. Current widget has no shared snapshot. Separate approved capability setup/device test needed. |
| Timestamp, stale label, no “live” promise | PARTIAL | [WidgetSnapshot.isStale][widget-model] and [widget][widget] use one-hour/future-time checks at entry generation. A single entry can cross its stale deadline before iOS refreshes it; add/test a future stale timeline entry, DST/clock/refresh denial and privacy redaction. |
| Widget Home deep link and cache purge | PARTIAL | [RootView][components]/[WidgetCache][cache]/[store][store] support sample Home and cleanup callback. Callback has unit evidence; no cross-process/App Group/real-session or URL-injection test. |
| Optional push events: purchase, low/negative balance, reset, release, sync failure | MISSING | No UserNotifications/APNs client, server dispatcher, device registration or permissions. Post-MVP optional per spec; owner approval before Apple capability/service enablement. |
| Per-user immediate/digest choices, quiet hours, email/Plaid push dedupe | MISSING | No preferences UI/model or canonical-event delivery policy. Accept denial/revocation, quiet-hour/timezone changes and one push per matched purchase. |
| Offline read-only last-known values | PARTIAL | [store][store]/[store tests][store-tests] retain the previous in-memory snapshot after simulated failure and deny writes. No reachability, encrypted durable cache, cold-launch offline mode or real network failure tests. |
| Device cannot overwrite canonical state offline | BLOCKED | Current service cannot write anywhere, so sample safety is structural. Connected validation needs staging tests, stable operation IDs, no stale balance payloads and server conflict resolution. |
| Loading/error/retry/cancellation and lost responses | PARTIAL | [store][store], [editor][editor], [components][components] handle sample errors, resubmission and stale completion. No HTTP status mapping, token-expiry recovery, persisted idempotency, request cancellation or per-section partial failure. Each UI submit currently generates a new UUID. |
| Sample receipt reliability | PARTIAL | Forms preserve input on submit failure; [FundView][fund] clears decline selection regardless of success, and approval list stays fixed. Correct retry UX and authoritative post-write refresh before connected release. |
| Four-second blue transient feedback and accessibility | PARTIAL | [ToastOverlay][components]/[notify][store] implement shared brand feedback; no automated timing/announcement/large-text/modal interaction tests. Persistent stale errors are distinct from transient toasts. |
| Privacy and data isolation on logout/household change | PARTIAL | [store tests][store-tests] exercise local cleanup/late-read guard. Need cold launch, cache protection, app-switcher/widget privacy and multiple real identities. |

## 6. Acceptance coverage: all 36 FINAL tests

These are requirement statuses, not fabricated pass/fail test executions. The
successful native smoke run covers a small subset. Native core permission tests
call a mock actor; [server engine tests][engine-tests] are not staging/API tests.
All acceptance gates below require their own recorded results before closure.

| FINAL # | Requirement | Status | Existing native evidence and remaining gate |
|---|---|---|---|
| 1 | Both users share one weekly allowance | BLOCKED | Shared fixture is not shared persistence; verify two approved staging accounts. |
| 2 | Exactly-once Sunday reset including DST | BLOCKED | Date/filter core tests only; verify scheduled server close and replay. |
| 3 | $400 spend → $25 debt → next available $350 | BLOCKED | Server A3 fixture test; no native financial calculation or connected proof. |
| 4 | $800 spend carries debt without phantom surplus | BLOCKED | Server multiweek fixture/replay must feed native snapshots. |
| 5 | $300 spend → delayed $75 fund; unchanged next base | BLOCKED | Verify pending release, not just fixed FundView numbers. |
| 6 | Fund consumed only by allocation/approved request | PARTIAL | Mock role guard; no money movement or canonical ledger assertion. |
| 7 | Member denied through UI and direct API | PARTIAL | [UI tests][ui]/[mock role tests][service-tests] cover sample controls/actor; real API/RLS denial missing. |
| 8 | Unused increment earns no fund credit | BLOCKED | Server fixture and integration required. |
| 9 | Increment cannot repay prior debt | BLOCKED | Server fixture and historical snapshot proof required. |
| 10 | Pending seven days; release once | BLOCKED | Server time-controlled/retry/concurrency test required. |
| 11 | Repeated close does not duplicate entries | BLOCKED | Durable database uniqueness/atomicity, not mock UUID receipts. |
| 12 | Open late charge recomputes downstream and shows revision | PARTIAL | History revision text exists; no actual recompute or revision trail. |
| 13 | Locked corrections affect current week, history unchanged | BLOCKED | Approved server data/snapshot assertions required. |
| 14 | Released reduction creates $35 shortfall in worked case | BLOCKED | Fund/shortfall labels only; server end-to-end worked example required. |
| 15 | Refund original allocation/restoration, no duplicate credit | BLOCKED | See all page-17 subcases in section 3; synthetic restoration view does not prove them. |
| 16 | Saturday/Sunday purchases booked correctly | PARTIAL | [date/query tests][contract-tests]/[values tests][values-tests] cover calendar boundaries, not provider timestamp booking. |
| 17 | Duplicate alert makes one provisional row | BLOCKED | Native has no ingestion; approve server matcher/replay tests. |
| 18 | Alert matched to Plaid/CSV stays one purchase | BLOCKED | No import/matcher adapter; test cross-source ordering and identities. |
| 19 | Alert arriving after authoritative row does not duplicate | BLOCKED | Test reversed arrival order server-side. |
| 20 | Two identical real purchases remain distinct | PARTIAL | [CSV test][csv-tests] preserves duplicate-looking preview rows; server identity matching unverified. |
| 21 | $40 authorization → $48 shows correction | MISSING | No correction/event detail model or native presentation. |
| 22 | Plaid-only/CSV-only purchase enters without an alert | PARTIAL | Source fixtures/CSV parser only; ingestion/import persistence missing. |
| 23 | Seven-day provisional flagged, never silently deleted | PARTIAL | Fixed review flag/filter; no timed transition/confirm/void workflow. |
| 24 | Overlapping CSV import safely repeated | PARTIAL | Parser/confirmation only; no durable batch dedupe or server outcome. |
| 25 | Suspicious/ambiguous mail fails closed | BLOCKED | Gmail server helpers exist historically; native connection and quarantine resolution not verified. |
| 26 | Forged sender/failed authentication rejected | BLOCKED | Server DKIM/SPF and ingest signature/replay tests in approved environment. |
| 27 | Plaid removed handled without double count | PARTIAL | Reversed fixture label tested; no live/sandbox event application. |
| 28 | Disconnected bank warns while email continues | BLOCKED | Unavailable integration mocks do not prove independent feed recovery. |
| 29 | Savings A6 examples, transfers/interest not double-counted | BLOCKED | Four fixed numbers/forms only; server lifecycle/reconciliation required. |
| 30 | No transfer/payment action anywhere | IMPLEMENTED | Current native [actions][service]/[connections][settings] only record attestations; maintain this prohibition when integrating APIs. No claim of a new live-backend audit. |
| 31 | Widget last-known balance/timestamp, never live | PARTIAL | Widget compiles, model tests exist; App Group and actual rendered/timed behavior unverified. |
| 32 | Offline cannot overwrite canonical state | PARTIAL | [store tests][store-tests] deny sample writes; real persistent cache/network/server conflicts unverified. |
| 33 | Every adjustment attributable/reversible/auditable to both | PARTIAL | In-memory audit visible to both; no server attribution, complete history or reversal. |
| 34 | No secrets/raw email in bundle/logs/crash reports/source | PARTIAL | Current synthetic code and [scanner][safety]; connected SDK/release bundle and crash-output audit still needed. |
| 35 | No live changes without approval | IMPLEMENTED | Current no-transport build and explicit safeguards satisfy this task's boundary. Future approvals remain action-specific. |
| 36 | Nightly backup and proven restore | BLOCKED | Handoff reports an earlier restore, not native operational verification or ongoing nightly evidence. Separate approved recovery/runbook exercise required; no production export now. |

Additional tests missing from the two UI smoke cases: auth/recovery/deletion,
create/join errors, real write/readback, CSV Files import/export, split/override and
reversal, held refunds, source reconnection, pagination/search across remote pages,
empty/partial/error states, widget installation/timelines, VoiceOver/large text,
network interruption, multi-user concurrency and full two-phone parity.

## 7. Dependencies, order and measurable completion gates

| Order / deliverable | Status | Dependencies and acceptance gate |
|---|---|---|
| 0 Verified native build baseline | IMPLEMENTED | Run 41648851937 succeeds at tested SHA; retain that evidence. No build is requested in this task. It is an unsigned synthetic baseline, not release qualification. |
| 1 Product/API decisions and safe fixture coverage | PARTIAL | This analysis and [contract inventory][backend-notes] exist. Resolve D2–D4; add fixtures for empty/partial states, full transaction provenance, reversals and movement lifecycle without a Swift finance engine. |
| 2 Isolated staging definition and schema/API inventory | BLOCKED | D1 approval. Inventory tables/grants/RPC signatures, synthetic users and recovery policy; prove no production fallback. Any backend edits require a separate task/authorization. |
| 3 Auth/session/household adapter | MISSING | Order 2 plus reviewed/pinned Supabase Swift dependency and Keychain implementation. Acceptance: real staging signup/login/recovery/delete/join, relaunch/expiry, two-user limits, direct API/RLS isolation. |
| 4 Read repositories and financial snapshots | MISSING | Order 3 and complete server summary contract. Acceptance: full paginated purchases/history/audit, server timestamps/source health, typed unknown/null/error states, two clients read identical results. |
| 5 Intent writes/import and audit/readback | MISSING | Orders 3–4, reversal/effective-date decisions. Acceptance: persistent manual/CSV/fund/savings/settings workflows, same-household checks, atomic approvals, stable retry IDs, error recovery and audit before/after; server executes all finance. |
| 6 Financial/matcher acceptance suite | BLOCKED | Approved server environment and orders 4–5; all A3/A6/page-17 cases and FINAL tests 1–29/33 pass or explicitly remain open. Include fault injection and concurrent requests. |
| 7 Native banking and resilient source refresh | BLOCKED | Specific sandbox/provider approval, native SDK, server exchange/update contracts. Acceptance: cancellation/reconnect/disconnect, account attribution caveats, paginated sync/replay, app-closed ingestion and honest stale status. |
| 8 Shared widgets, durable offline cache and device privacy | BLOCKED | Orders 3–4 plus D5 capability approval. Acceptance: widget families render server snapshots, privacy/redaction and logout clear across processes, stale timeline ages correctly, cold offline launch never writes finance. |
| 9 Optional notifications | MISSING | Post-MVP; requires D6, canonical server event IDs, preferences/devices/APNs, quiet hours/digest and dedupe tests. Notification delivery must never execute accounting. |
| 10 Release qualification and shadow run | BLOCKED | Broader native tests, all required feature gates, D5–D7. Physical devices/two accounts, legal/support/privacy/name clearance, signed distribution, incident/recovery runbooks and two-week Amex comparison with every difference explained. Owner accepts report before trusted-balance claim. |

Dependency packages currently installed in the app: only the local OnBudgetCore
library and Apple system frameworks ([Package.swift][package], [project.yml][project]).
Supabase Swift, Plaid Link SDK, APNs/device services and secure session storage are
not present. A package addition is not approval to connect it. iOS minimum is 17;
friend's signing identity/bundle ownership/distribution are not configured. The
AppIcon fix supplies assets, not approved store branding/legal clearance.

## 8. Outstanding owner decisions and approvals

- **D1 — BLOCKED, approval:** explicitly authorize a separate synthetic-only staging
  environment/connection and define allowed project/identities. Never request or
  reuse production credentials. Backend implementation/deployment remains separate.
- **D2 — BLOCKED, product/API decision:** FINAL defaults allowance changes to future
  effectiveness, but current `set_base_allowance` and temporary-increase form lack a
  complete effective-date/preview/reversal contract. Agree dates, historical impact,
  week selection and reversal semantics before connected policy edits.
- **D3 — BLOCKED, API decision:** agree server-returned outgoing debt, complete
  fund/savings summaries and provenance/state mapping. `compute-week`'s eight-field
  response and incoming D label must be preserved; do not invent new Swift formulas.
- **D4 — BLOCKED, product/API decision:** reconcile append-only/reversible accounting
  and six-state spec with legacy manual deletion, excluded/reversed flags and
  review behavior. Define all reversal paths, persistent review/void/quarantine
  transitions, refund-link resolution and admin-departure/account deletion policy.
- **D5 — BLOCKED, approval:** Apple account/app identifier ownership and distribution
  through owner/friend; App Groups, signing and physical-device testing. Neither
  simulator success nor an AppIcon authorizes Apple account changes/submissions.
- **D6 — BLOCKED, later approval:** individual provider sandbox/real consent, Gmail
  verification/reconnect and optional push capability/service. Keep Gmail connect
  hidden for bank-only native launch. Existing handoff decisions are not blanket
  approval to access real accounts from this branch.
- **D7 — BLOCKED, release approval:** legal/privacy/support/name review, backup and
  incident/recovery ownership, shadow-run acceptance and any spending. Prior backend
  reports are historical context; no new production operations are authorized.
- **D8 — BLOCKED, execution approval:** any additional cloud simulator build,
  workflow modification, backend deployment or production action needs its own
  approval. This normal documentation push deliberately lacks the build prefix.

Safe local mock/model/UI improvement work can proceed without reopening settled
financial rules; connection, capability, deployment and spending gates cannot.

## Source references

Links name concrete files/symbols; implementation scope is stated in each row.
Relative links resolve from ios/docs/. Root files are read-only references.

[spec]: ../../Household_Budget_Spec_FINAL.pdf
[handoff]: ../../HANDOFF.md
[run]: https://github.com/ycfried/Budget/actions/runs/41648851937
[app]: ../App/OnBudgetApp.swift
[components]: ../App/Components.swift
[auth]: ../App/AuthenticationView.swift
[home]: ../App/DashboardView.swift
[transactions]: ../App/TransactionsView.swift
[editor]: ../App/ActionEditor.swift
[fund]: ../App/FundView.swift
[savings]: ../App/SavingsHistoryViews.swift
[settings]: ../App/SettingsConnectionsViews.swift
[cache]: ../App/AppModel.swift
[widget]: ../Widget/OnBudgetWidget.swift
[widget-model]: ../Sources/OnBudgetCore/WidgetSnapshot.swift
[models]: ../Sources/OnBudgetCore/Models.swift
[models-values]: ../Sources/OnBudgetCore/Values.swift
[values]: ../Sources/OnBudgetCore/Values.swift
[service]: ../Sources/OnBudgetCore/Service.swift
[store]: ../Sources/OnBudgetCore/HouseholdStore.swift
[fixtures]: ../Sources/OnBudgetCore/Fixtures.swift
[csv]: ../Sources/OnBudgetCore/CSV.swift
[contracts]: ../Sources/OnBudgetCore/BackendContracts.swift
[package]: ../Package.swift
[project]: ../project.yml
[app-info]: ../Configuration/App-Info.plist
[widget-info]: ../Configuration/Widget-Info.plist
[privacy]: ../Resources/PrivacyInfo.xcprivacy
[icon]: ../Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
[ui]: ../UITests/OnBudgetUITests.swift
[values-tests]: ../Tests/OnBudgetCoreTests/ValuesTests.swift
[csv-tests]: ../Tests/OnBudgetCoreTests/CSVTests.swift
[service-tests]: ../Tests/OnBudgetCoreTests/ServiceTests.swift
[store-tests]: ../Tests/OnBudgetCoreTests/HouseholdStoreTests.swift
[contract-tests]: ../Tests/OnBudgetCoreTests/ContractAndDisplayTests.swift
[safety]: ../scripts/check_safety.py
[backend-notes]: BACKEND_CONTRACTS.md
[engine]: ../../engine.mjs
[compute]: ../../supabase/functions/compute-week/index.ts
[close]: ../../supabase/functions/week-close/index.ts
[restoration]: ../../supabase/functions/week-close/restoration.mjs
[plaid-sync]: ../../supabase/functions/plaid-sync/index.ts
[engine-tests]: ../../test/engine.test.mjs
