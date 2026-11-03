# Source decisions and parity record

Read in full before implementation: HANDOFF.md including evening addendum and
Household_Budget_Spec_FINAL.pdf (20 pages, extracted locally). Also inspected
live.js/live.html, engine contracts and relevant Supabase functions/SQL locally.
Source base: current main `1ab8c9a`. No production inspection was performed.

## Decisions preserved

- FINAL refund restoration, not carried refund credit. The PDF's v2 cover is stale.
- Server remains the only financial authority. Swift formats returned cents;
  no debt, surplus, restoration, close, release or allocation engine is ported.
- America/New_York, Sunday–Saturday; 28-day open window; pending surplus seven
  days after actual close. Dates remain date-only, not device-local midnight.
- Later handoff decisions: restoration through last completed week, fund-first
  ordering, posted refunds only, excess held, shortfall offsets, held release to
  spendable surplus, incoming debt D label, payment/cashback excluded.
- Split remainder closed, not re-approvable; blank reasons allowed. Server must
  enforce insufficient-fund override reasons. Device does not decide fund balances.
- Open signup/email-confirmation off supersedes PDF's closed-signup wording.
  Native auth screens are disconnected previews, not a change to Auth settings.
- Reusable/non-expiring code-only invitations, throttled by server; no UUID join.
- Admin-only bank linking, manual sync, policy and financial administration.
- Personal Gmail OAuth supersedes dedicated forwarding; native launch hides Gmail
  connect until verified. Only interfaces and fail-closed mocks are added.
- Owner's blue #2f6bff, compact native forms, hero sync action, four-second blue
  toasts with white text. Existing owner S mark copied, never redesigned.
- Latest user authorization supersedes historical “native last” and phase-by-phase
  implementation approval requirements. Live account/production safeguards remain.

## Implemented as native sample interfaces

Authentication forms and role entry; dashboard and freshness; transaction list,
search/state/card/month filters, sorting and load-more; detail/actions/manual entry;
Files CSV preview with quoted fields, errors and explicit confirmation; Extra Fund
summary, request/approve/split/decline/allocation forms; held/restoration views;
savings four-number display, movement/balance forms; history with CSV sharing;
settings/onboarding previews; audit and receipts for both roles; source-health and
bank integration interface; widgets and minimal shared snapshot boundary.

Financial fixtures never update after sample actions. Receipt history is the
observable output. Real onboarding, session persistence, mutations, matching,
and provider flows are not implemented or represented as connected behavior.

## Unresolved owner/backend decisions (do not choose financial rules silently)

1. PDF requires reversibility for all adjustments, but existing backend lacks a
   uniform reversal contract. Do not invent native reversal writes.
2. PDF defaults allowance changes to future-effective; existing set_base_allowance
   RPC has no effective-date parameter. Current sample form flags this. A connected
   implementation must await an approved effective-date contract/decision.
3. Existing compute-week returns incoming debt but no outgoing-debt field; web
   derives a displayed outgoing value that needs review against server semantics.
   Native response keeps outgoing debt optional; literal display fixtures include
   it, but a future adapter must not invent a Swift budget formula.
4. Spec's review/state-history/merchant-rules/quarantine and transfer lifecycle exceed
   current API coverage. UI can show prepared data; backend additions are a separate
   approval task. Review-flag actions currently generate only a sample receipt.
5. Apple account ownership, distribution, minimum supported devices, App Group,
   signing and cloud-runner budget require owner review; placeholders are not
   registered capabilities.

## Production issues carried forward, not changed

Week-close multi-write atomicity; Plaid hash-match query eligibility and silent
skip errors; absent refund purchase links; inconsistent SQL bootstrap/schema
inventory; audit action text writable; deletion partial failure/admin succession;
OAuth hardcoded web return/state consumption; webhook dedupe collisions; bounded
client sums; older docs contradict later handoff. Handoff reports several fixes
and historical live proofs; none is independently revalidated here.

## Release acceptance still outstanding

All 36 PDF acceptance cases must be mapped to actual staging/server/device tests.
Core tests here cover client input/display/mock contracts, not financial engine or
RLS correctness. Production rollback/recovery, provider verification, real native
callbacks, two-device parity, accessibility inspection, signing, store icon,
privacy/support/legal materials, and a shadow run remain release requirements.
