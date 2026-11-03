# Native implementation plan

November 3, 2026. Branch: ios-native-rebuild. Baseline: 3db3e5f.
Read the complete FINAL PDF (including state diagram), full HANDOFF/addendum,
PROGRESS and NATIVE_GAP_ANALYSIS before implementation. The gap analysis remains
an inventory at its reviewed commit; milestone updates below supersede its old
receipt-only descriptions only where new source/tests demonstrate behavior.

## Rules that remain settled

One server authority; no budget/refund/week-close/fund calculation engine in Swift.
Use integer cents and household date semantics. Preserve refund restoration through
the last completed week, posted-only credit, fund-first ordering, capped incremental
refunds and held excess/shortfall handling on the server. Preserve reusable code-only
invites, closed split remainder, allowed blank adjustment reasons, admin-only bank
management/manual sync, open signup/email-confirmation-off and deferred native Gmail
connect until verification. Do not ask the owner to reconsider these decisions.

All changes stay inside ios/. No workflow/settings/main/web/Supabase changes,
real data/provider access, staging connection, signing, deployment, PR or spending.
Normal commit messages only; never use the simulator workflow's approved prefix.
The earlier simulator PASS applies to its tested SHA, not automatically to new code.

## Offline milestone 1 — this implementation phase (highest priority)

Dependencies: existing local core package, fixtures and service injection. No network
adapter or external service connection. Local compiler/test tooling is not an app
integration. No cloud build is authorized.

1. Add typed transaction state/kind values with unknown-value preservation and a
   deliberate legacy wire mapping. Keep provisional and bank-pending distinct;
   model posted/review/excluded/reversed/voided/quarantined, prior exclusion state,
   original amount and attributable transition history. No accounting eligibility
   totals are computed by the model. Unknown/ambiguous legacy rows remain visible.
2. Make the mock actor own synthetic purchases/requests and transition history.
   Add manual purchases, CSV rows, review flags, exclusion/restore/reclassification,
   manual voiding, pending request creation/approval/split/decline. Validate target
   identity/role/state and keep all mutations atomic within the actor. Financial
   dashboard/fund/savings/closed-week/restoration amounts remain literal fixtures.
3. Preserve all identical-looking CSV rows; replay the same operation ID once.
   Do not pretend a local hash matcher is authoritative. Defer distinct-batch
   overlap/cross-source matching and refund posting to server integration.
4. Keep stateful changes visible in current detail screens/queues, show original
   amounts and state history, retain failed forms, support accessible actions,
   distinguish provisional/pending/review/terminal filters and empty states.
5. Improve in-memory retry identity, error feedback, busy/read-only guards and
   sign-out/late-result cleanup. Fail-closed typed interfaces have no transport.

Acceptance/tests: table-driven known/unknown/legacy decoding and invalid transition
cases; admin/member checks; exact prior-state restoration (including pending
refunds); manual/CSV observable mutation and replay; duplicate-looking rows remain
separate; partial approval closes remainder; concurrent decisions produce one
winner; errors leave data unchanged; sign-out resets domain/audit/idempotency state;
all monetary summary fixtures are identical before/after every tested action.
Run local Swift core tests and UI syntax/static project checks if tooling permits.
Do not trigger Xcode/cloud tests; explicitly mark new UI compilation unverified.

## Prioritized remaining milestones

| Priority / milestone | Offline work allowed now | External or decision dependency | Acceptance and tests |
|---|---|---|---|
| P0 M2 Read/write contracts and failure recovery | Typed transport-free DTOs, explicit result/error/unknown states, stable operation IDs; separation of sample controls from production services; adverse fixtures and cancellation tests | Approved staging/API inventory before transport is connected | Decoder fixtures, nil/unknown/wire-value tests, interrupted/duplicate/lost-response scenarios, no secret or production fallback |
| P0 M3 Identity and household onboarding (S02–S05/S32) | Auth/session service interfaces, form validation, onboarding state machine, secure-storage abstraction and logout isolation tests | Explicit staging approval; account deletion/admin succession contract | Signup/login/recovery/expiry/logout/create/join via staging, two-member limits, native callback replay and direct cross-household/RLS denial |
| P0 M4 Server read models (S06–S11/S18/S24/S27/S31) | Snapshot freshness/loading/partial-error models, paging/search contracts, source provenance and correction presentation | Server summary/state mapping decision; staging Auth and repositories | Both clients show same complete paginated server snapshots; no device-calculated finance; DST/unknown/null/source-age cases |
| P0 M5 Persistent intents and reconciliation (S12–S23/S25/S29–S30) | Stateful synthetic workflows, typed command results, reversal/preview UI scaffolding once contract settled | Approved RPC/write contracts, stable idempotency, future-effective policy/reversal decisions | Manual/import/request/approve/decline/held/savings/settings readback, audited transitions, concurrent RPC and partial-failure tests |
| P0 M6 Financial and matcher acceptance | Reuse all A3/A6/page-17 server fixture descriptions; native render-only contract assertions; no Swift finance engine | Approved server test environment; any backend changes are separate authorization | All 36 FINAL acceptance cases mapped to actual outcomes, financial replay/atomicity/shortfall/late/refund/policy cases; identical purchases and tip/hold/cursor ordering |
| P1 M7 Savings/history/audit completeness (S24–S31) | Movement lifecycle, revision/provenance views, CSV export validation, review/merchant-rule model scaffolding | Server movement/summary/reversal/source-event APIs | Four-number reconciliation, unmatched/pending/reversed transfers, full append-only attributable history, complete export and Files UI tests |
| P1 M8 Native connections and sync (S33–S34) | Unavailable/cancel/expiry mocks, source health coordinator, update-mode interfaces | Separate approved provider sandbox/consent; reviewed SDK; Gmail verification/return contract | Native Link exchange/reconnect/disconnect; read-only scope; scheduled/webhook cursor replay and app-closed ingestion; Gmail stays hidden until gate satisfied |
| P1 M9 Offline/widgets/privacy | Cold offline-cache abstraction, stale timeline entries, redacted display/deep-link models, purge tests; improve widget views | App Group/device/capability approval; connected identity/snapshots | No stale writes, per-session cache isolation, all widget families/timestamps/privacy after refresh denied, logout/household changes clear both processes |
| P1 M10 Accessibility/navigation/quality | VoiceOver labels/order, Dynamic Type layouts, focus/reduced-motion/keyboard support, test identifiers; broaden UI test source | New simulator execution requires approval; device validation separate | Automated and device coverage for every screen, import/export, recovery, long lists, destructive confirmation and partial failures; performance budgets measured |
| P2 M11 Optional notifications | Preference/quiet-hour/digest models, canonical-event dedupe and denial fixtures | APNs/capability/service approval, server event IDs | No duplicate alert/Plaid notifications; quiet hours/timezone/revocation; no notifications execute accounting |
| Release M12 Qualification/distribution | Runbooks, release checklist, legal/support placeholders, evidence matrix | Owner Apple identity/distribution/signing; legal/name review, approved backups/shadow run | Device/two-user/staging parity, recovery and incident drill, two-week comparison with differences explained and owner acceptance; signed release only after specific approval |

M1 and M2 can advance independently of staging. M3–M6 require identity, agreed
contracts and approved staging in that order. M7–M10 depend on complete snapshots
and write results for end-to-end closure. M11 is optional/post-MVP. Production
rollout is not an automatic consequence of completing any milestone.

## Decisions/approvals genuinely outstanding

- Approve a separate synthetic-only staging connection and allowed project/identities;
  never production access. Backend edits/deployments require separate authorization.
- Agree future-effective allowance/override week selection, previews and reversals;
  server outgoing-debt/fund/savings response completeness, durable state mapping,
  refund-link resolution and admin-departure/deletion ownership policy.
- Approve any additional cloud build, Apple account/capability/signing/device work,
  provider consent/verification, notifications service, spending and final release.

None of these prevents M1 offline work. This milestone's richer state transitions
are explicitly mock-only interaction behavior, not approval to write production
states or alter existing backend rules.

## M1 completion record

Implemented typed states/kinds and legacy-row DTOs; mutable mock transactions,
requests and attributable history; prior-state restoration; mock-only provider
posting/removal/correction; separate provisional/pending filters; safe operation
replay/lost-response retry and logout reset; current detail/queue readback.
64 local core tests pass; Apple source syntax and project graph checks pass.
No new Apple SDK/simulator build is claimed. Financial summaries remain fixed.
Remaining M1-adjacent work (persistent cache, full match provenance, seven-day
server aging, production state mapping) proceeds under the dependent milestones,
not by inventing a local financial engine.

## M2 offline completion record

Transport-free typed/nullable contracts, unknown values, conservative explicit
retry/cancellation states, per-unresolved-intent IDs, sample-control separation and
source freshness are implemented. 82 local XCTest tests pass; no new Xcode run.
See M2_CONTRACTS.md and PROGRESS.md for evidence and boundaries. Deployed API
compatibility and durable/server reconciliation remain dependent M3–M5 work.
