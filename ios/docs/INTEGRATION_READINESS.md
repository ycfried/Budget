# Native integration readiness review

Reviewed November 3, 2026 on `ios-native-rebuild`, source baseline `5f73bce`.
This is repository analysis, not a deployed API audit or authorization to connect.
No production/staging data, dashboard, credentials or provider was accessed. No
schema, function, workflow, setting or application code was changed.

Sources read: complete [FINAL specification](../../Household_Budget_Spec_FINAL.pdf),
[HANDOFF including addendum](../../HANDOFF.md), [gap analysis](NATIVE_GAP_ANALYSIS.md),
[implementation plan](IMPLEMENTATION_PLAN.md), [M2 contracts](M2_CONTRACTS.md), and
checked-in web/server/native sources cited below. The original gap inventory is
historical; M1/M2 updates supersede its old mock/contract descriptions.

Status applies to each specifically named contract, not the entire feature:

- **VERIFIED EXISTING**: concrete checked-in implementation/caller found. Does not
  mean deployed, correctly migrated, tested in staging or connected from Swift.
- **PROPOSED**: a recommended native/server contract or staging test, not an endpoint.
- **MISSING**: no adequate implementation found in the inspected repository.
- **OWNER DECISION REQUIRED**: product semantics or explicit external authorization
  cannot be chosen by implementation alone. Combined labels separate existing
  behavior from the missing extension.

Readiness verdict: ready to design isolated staging, **not ready to enable connected
financial writes**. M2's typed envelopes and mock UUID replay are client foundations;
existing RPCs do not implement their general durable operation-ID contract.

## Later owner authorization — preparation for existing household

The owner subsequently authorized real-household authentication/read preparation,
with an explicit stop before the first live connection and a separate specific
plan/approval before any financial write test. That direction supersedes this
review's staging-only prerequisite for the chosen existing-household read path;
it does not authorize unrestricted production changes. See
[FIRST_LIVE_CONNECTION.md](FIRST_LIVE_CONNECTION.md) for the exact pending
connection plan. The source findings, missing server contracts and financial
write safeguards below remain applicable. No staging project is required or
created for this preparation, and none of the existing genuine records may be
modified merely for testing.

## 1. Exact existing entry points and gaps

Paths below are relative to a future explicitly approved project origin. No origin
or key is supplied here. PostgREST RPCs use POST `/rest/v1/rpc/<name>` with named JSON
arguments; table reads use GET `/rest/v1/<relation>` with select/filter/order/range.
Edge functions use POST `/functions/v1/<name>` unless stated otherwise. User paths
use a validated user bearer token plus project public API key where required;
no service-role credential belongs in the app. HTTP method/path details for Auth
are the standard Supabase Auth surface reflected by JS SDK calls, not a custom
server implemented in this repository; validate the staging SDK/version contract.

### Identity and household

| Contract | Status | Evidence and exact shape / gap |
|---|---|---|
| Signup, login | VERIFIED EXISTING (web SDK caller) | `POST /auth/v1/signup` email/password; `POST /auth/v1/token?grant_type=password` email/password. [live.js](../../live.js) `signUp`/`signInWithPassword`; min password 8. No native adapter. Signup ON, confirm email OFF are settled handoff decisions. |
| Refresh, identity, logout | VERIFIED EXISTING (SDK use), PROPOSED native lifecycle | `POST /auth/v1/token?grant_type=refresh_token`, `GET /auth/v1/user`, `POST /auth/v1/logout`; web uses getSession/getUser/signOut. Swift secure persistence, rotation races, revocation and logout scope require staging verification. |
| Recovery and password update | VERIFIED EXISTING (web SDK caller); PROPOSED native callback | `POST /auth/v1/recover` with email and approved redirect; `PUT /auth/v1/user` password in recovery/auth session. [live.js](../../live.js), [reset.html inline module](../../reset.html). Existing web redirect success is historical; a native allowlisted recovery callback/PKCE handling is not configured. |
| Membership and settings read | VERIFIED EXISTING | GET household_members (caller user_id), households (membership household ID); role, display_name, base_allowance_cents, invite_code, fund_shortfall_cents. [schema.sql](../../supabase/schema.sql), [fix-membership-policy.sql](../../supabase/fix-membership-policy.sql), [01-invite-codes.sql](../../supabase/01-invite-codes.sql). Caller cannot choose its role. |
| Create | VERIFIED EXISTING | RPC `create_household()` -> household UUID, creator admin; rejects existing membership. Use [01-invite-codes.sql](../../supabase/01-invite-codes.sql), not older create-household variants as a deployment recipe. |
| Join | VERIFIED EXISTING | RPC `join_household_by_code(code text)` -> UUID or NULL for invalid code; errors for throttling/already-member. [n13-invite-rate-limit.sql](../../supabase/n13-invite-rate-limit.sql). Codes reusable/nonexpiring; UUID join removed. Generic invalid-code UI must handle NULL as failure, not success. |
| Delete account | VERIFIED EXISTING; OWNER DECISION REQUIRED for ownership | `/functions/v1/delete-account`, no caller-selected user ID; `{deleted:true}` or error. [handler](../../supabase/functions/delete-account/index.ts) removes own memberships, then empty households, then own Auth user, using server-only admin credentials. Multi-step, not atomic; ownership/partial recovery below. |

### Financial reads

| Contract | Status | Existing route/data and missing portion |
|---|---|---|
| Week summary | VERIFIED EXISTING | `/functions/v1/compute-week` `{household_id, week_start?}` -> direct eight-field JSON described in section 4. Membership checked. [handler](../../supabase/functions/compute-week/index.ts). Not an M2 result envelope. |
| Purchases, detail, search/export | VERIFIED EXISTING base read; PROPOSED complete paging contract | GET transactions, filtered by household/id/date/card/source/kind/state, stable order plus ID tie-breaker and ranges/cursor. Row columns from [schema](../../supabase/schema.sql), [linkage migration](../../supabase/restoration-snapshots.sql), [prior-state patch](../../supabase/n4-pre-exclusion-state.sql), [payment-kind.sql](../../supabase/payment-kind.sql). Stable cursor/search/full export semantics must be specified and tested; web limits are not completeness guarantees. |
| Requests | VERIFIED EXISTING | GET fund_requests, household-scoped; pending/approved/split/declined, amount_cents, transaction_id nullable, requested_by, decided_by/at nullable, remainder_cents. [04-admin-rpcs.sql](../../supabase/04-admin-rpcs.sql). Decline patch does not populate decided_by/at: null must remain null. |
| Fund ledger, releases, shortfall | VERIFIED EXISTING rows; MISSING full server aggregate | GET fund_ledger, surplus_releases, households.fund_shortfall_cents. [fund-ledger.sql](../../supabase/fund-ledger.sql), [restoration-snapshots.sql](../../supabase/restoration-snapshots.sql). Web sums these client-side; native may not copy its financial reductions. |
| Savings | VERIFIED EXISTING rows; MISSING server reconciliation summary/lifecycle | GET savings_ledger (kind, amount_cents, attested_by, note, actual_balance_cents nullable, created_at); plaid_accounts provides bank metadata/balance where available. [live-savings-rpc.sql](../../supabase/live-savings-rpc.sql), [plaid-accounts.sql](../../supabase/plaid-accounts.sql). Missing confirmed lifecycle/interest/outside aggregate contract. |
| History/audit | VERIFIED EXISTING rows; MISSING complete revision API | GET week_closes, surplus_releases, audit_log, temp_increases. Closed policy snapshots exist; full attributable correction/reversal history, source events and coherent revision pagination do not. No `week_snapshots` creation found; handoff notes drift. |
| Restoration/held | VERIFIED EXISTING | GET restoration_entries and held_refunds, household-scoped. Exact fields in section 4; [restoration-snapshots.sql](../../supabase/restoration-snapshots.sql). Web hides card for members although RLS permits their household reads; native should honor settled member visibility. |
| Consistent complete financial snapshot | PROPOSED; MISSING server entry point | A versioned read endpoint/RPC joining canonical server summaries, revisions and per-section availability; proposed fields below. No invented endpoint name is asserted to exist. |

### User financial mutations

All listed RPCs below return SQL void (not an operation receipt). The client must
read canonical state after success. Table INSERT routes return representation only
when requested; web audit inserts are separate requests, not atomic receipts.

| Intent and exact existing contract | Status / source |
|---|---|
| Manual purchase: POST `/rest/v1/transactions`, body household_id, date, merchant, amount_cents, card_suffix, source=`manual`, state=`provisional`, kind=`charge`, dedupe_hash | VERIFIED EXISTING [live.js](../../live.js) manual form and [02 hardening](../../supabase/02-rls-hardening.sql). Member/admin allowed. Missing stable intent RPC and atomic audit. |
| CSV: same table INSERT, array of rows; source=`csv`, state=`provisional`, kind inferred by web sign, dedupe_hash | VERIFIED EXISTING web path. MISSING robust import batch/server matcher/row outcomes API. Native must not adopt sign-only refund classification or content-only dedupe as authoritative. |
| Request: POST `/rest/v1/fund_requests` household_id, requested_by, transaction_id optional, amount_cents, note, status=`pending` | VERIFIED EXISTING [live.js](../../live.js), hardening policy/trigger. No financial allocation until approval. |
| Approve: RPC `approve_and_allocate(request_id uuid, amount_cents integer, override_reason text)` | VERIFIED EXISTING [04](../../supabase/04-admin-rpcs.sql). Names have **no p_ prefix**; live caller matches. Older fund-ledger signature is superseded. Explicit JSON null for override_reason if absent. |
| Decline: RPC `decline_fund_request(p_request_id uuid)` | VERIFIED EXISTING [08-decline-fix.sql](../../supabase/08-decline-fix.sql), not earlier unconditional-audit implementation. |
| Direct fund use: RPC `allocate_fund(p_household_id uuid, p_amount_cents integer, p_note text, p_override_reason text)` | VERIFIED EXISTING [04](../../supabase/04-admin-rpcs.sql). No transaction-ID argument; cannot pretend it implements a purchase-linked split. |
| Exclude: RPC `exclude_transaction(txn_id uuid, reason text)`; restore: `restore_transaction(txn_id uuid)` | VERIFIED EXISTING [n4 patch](../../supabase/n4-pre-exclusion-state.sql). Preserves original prior state on repeated exclusion; NULL legacy prior state uses server date fallback. Native must not invent its own fallback. |
| Reclassify: RPC `reclassify_transaction(txn_id uuid, new_kind text, reason text)` | VERIFIED EXISTING [05](../../supabase/05-transaction-mutation-rpcs.sql); checked-in body allows charge/refund/fund_charge/payment/cashback. Check actual installed body in staging. |
| Manual removal: RPC `delete_transaction(p_transaction_id uuid)` | VERIFIED EXISTING [04](../../supabase/04-admin-rpcs.sql). Admin/manual-only physical DELETE plus audit; **not** M1's mock void. Terminal-history policy requires resolution before exposing connected removal. |
| Base allowance: RPC `set_base_allowance(p_household_id uuid, p_cents integer)` | VERIFIED EXISTING [04](../../supabase/04-admin-rpcs.sql), no effective date or version. |
| Temporary increase: RPC `add_temp_increase(p_household_id uuid, p_week_start date, p_amount_cents integer, p_note text)` | VERIFIED EXISTING [live-temp-increases.sql](../../supabase/live-temp-increases.sql); appends positive increment. |
| Savings balance observation: RPC `attest_savings(p_household_id uuid, p_actual_balance_cents integer, p_note text)` | VERIFIED EXISTING [live-savings-rpc.sql](../../supabase/live-savings-rpc.sql); inserts zero-movement adjustment with observed balance. |
| Savings movement observation: RPC `record_savings_entry(p_household_id uuid, p_kind text, p_amount_cents integer, p_note text)` | VERIFIED EXISTING [savings-movements.sql](../../supabase/savings-movements.sql); transfer_in/withdrawal/interest only, positive amount. Native mock adjustment intent is not an accepted movement kind. Never initiates money movement. |
| Held resolution: RPC `resolve_held_refund(p_held_id uuid, p_action text, p_note text)` | VERIFIED EXISTING [restoration-snapshots.sql](../../supabase/restoration-snapshots.sql); release / write_off / resolve; admin/pending-only. Release credits spendable surplus shortfall-first, settled owner decision. |
| Review flag/confirm, quarantine approve/void, refund linking, adjustment/ledger/savings/policy reversals, merchant rules | MISSING supported native command contracts. Mock actions do not establish endpoints. PROPOSED audited server commands after product/API review. |

### Connection and server-only surfaces

| Entry point / exact body | Status and boundary |
|---|---|
| POST plaid-link `{household_id}` -> link_token, expiration | VERIFIED EXISTING [handler](../../supabase/functions/plaid-link/index.ts), admin-only. MISSING native return/update-mode contract; no existing-item update argument observed. Deferred provider approval. |
| POST plaid-exchange `{household_id, public_token, institution_name?}` -> item_id, connected | VERIFIED EXISTING [handler](../../supabase/functions/plaid-exchange/index.ts), admin-only, access token encrypted server-side. No operation-ID exchange replay contract. |
| POST plaid-sync `{household_id}` -> added, updated, reversed, skipped, items, connected_items, skipped_disconnected, truncated, optional no_bank_connected | VERIFIED EXISTING [handler](../../supabase/functions/plaid-sync/index.ts). User JWT admin-only; privileged scheduled path server-only. Counts are not financial summary or proof of complete sync when truncated. |
| POST plaid-disconnect `{household_id, plaid_item_id}` -> disconnected, plaid_item_id, optional already_disconnected | VERIFIED EXISTING [handler](../../supabase/functions/plaid-disconnect/index.ts). Admin-only; external remove/local mark can fail separately. |
| GET plaid_items_public, plaid_accounts, email_connections_public | VERIFIED EXISTING safe metadata surfaces; [vault](../../supabase/03-plaid-vault.sql), [Gmail schema](../../supabase/gmail-oauth.sql). Do not fetch token vault/base tables. |
| POST gmail-oauth-start (admin household derived from JWT; no household argument) -> auth_url; POST gmail-disconnect `{household_id,connection_id}` -> disconnected, connection_id | VERIFIED EXISTING [start](../../supabase/functions/gmail-oauth-start/index.ts), [disconnect](../../supabase/functions/gmail-disconnect/index.ts). Gmail connect remains hidden until verification; native return contract MISSING. No real OAuth in initial staging. |
| GET gmail-oauth-callback with provider code/state | VERIFIED EXISTING server callback [handler](../../supabase/functions/gmail-oauth-callback/index.ts). Not a native user write API; provider redirects/TTL/single-use need later approved test. |
| POST week-close `{household_id}` | VERIFIED EXISTING [handler](../../supabase/functions/week-close/index.ts), admin JWT check. Performs writes; **never call as a read/refresh substitute**. PROPOSED restricted staging harness/scheduled orchestration; not a member phone reset job. |
| gmail-poll, ingest-amex-alert, plaid-webhook, plaid-webhook-register; vault get_plaid_ciphertext/update_plaid_sync/log_webhook_event; update_fund_shortfall | VERIFIED EXISTING infrastructure, **not normal native APIs**. See named functions, [07](../../supabase/07-service-rpc-access.sql), [reaudit](../../supabase/reaudit-n2-n3.sql), [04](../../supabase/04-admin-rpcs.sql). Final grants/auth must be inspected in staging. No phone secrets, cursor mutation, webhook registration or direct shortfall editing. |

## 2. Authentication, roles and RLS

**VERIFIED EXISTING:** household predicates restrict reads; 01 removes direct join,
02 revokes client ledger/close/release/transaction UPDATE, 03 removes vault reads,
04/05/n4 enforce admin RPC checks, 07/reaudit revoke privileged RPC execution.
Membership fix avoids recursive policy. RLS and SQL grants are both necessary;
never restore broad client grants to make a failing native request work.

**VERIFIED EXISTING limitation:** transaction INSERT policy constrains membership,
source manual/csv and provisional state, but does not itself express all intended
admin-only CSV/kind/amount/allocation invariants. UI role hiding is insufficient.
Audit actor trigger attributes caller, but membership-scoped direct INSERT still
permits arbitrary action/detail text (handoff residual N5). Treat text as attributed
claims, not canonical evidence of a financial event. Members read their own audit,
financial rows and restoration/held rows; admin-only writes are checked server-side.
**MISSING:** no two-member maximum enforcement was found in checked-in join/schema
code; reusable invitation alone does not cap membership. One-household RPC checks
also require concurrency tests (membership primary key is household+user, not
user alone). Inspect any staged constraints/triggers before claiming either limit.

**PROPOSED:** native tokens in Keychain, single refresh coordinator, no credentials
in widgets/UserDefaults/logging; derive membership/role from validated identity,
revalidate after foreground/403/household changes, clear caches and pending intents
on logout/identity switch. Carry household IDs as filters, never as authorization.
Reject anonymous, foreign household, role tampering, privileged vault reads, forged
source/posted/allocation fields and cross-household FK links through direct API
and RPC tests. Error bodies may contain untrusted/sensitive details: sanitized UI,
no raw server/provider/mail/token logging. Version/error adapters must handle Edge
`{error:string}` plus HTTP status and PostgREST error objects; M2's structured error
envelope is **PROPOSED**, not interchangeable with existing responses.

## 3. Idempotency and retry per mutation

**MISSING:** universal server operation UUID, payload binding, durable receipt,
status lookup and retention contract. Every financial write below needs this
review before automatic retry; the current native app has **no automatic retry**.
Transport cancellation/timeout/5xx does not prove rollback. Even a refresh showing
an expected value may be another actor's write, not proof of this intent.

| Mutation | VERIFIED EXISTING protection / replay behavior | Required safe contract (PROPOSED unless noted) |
|---|---|---|
| Manual / CSV insert | Unique household+dedupe_hash; web hash uses content, collapses identical genuine rows; no batch receipt. | Stable intent/batch/row IDs, reference-aware server matcher, preserve identical real purchases, overlap report and atomic batch or explicit per-row results. Reconcile lost response before resending; conflict is not automatically successful import. |
| Fund request create | Random server ID; no operation uniqueness. Repeat can create another request. | Operation-keyed create and returned request ID. |
| Approve / legacy approve_fund_request delegate | Household/request locks; pending-only; replay raises, cannot allocate twice on same decided request. | Same operation returns original amount/status/ledger/audit IDs; different payload conflict; distinguish someone else's decision. Legacy delegate is not the preferred native entry point. |
| Decline | Conditional pending update, FOUND check; second attempt errors without false audit. | Same-operation receipt/reconciliation; canonical decider/timestamp must be supplied rather than invented. |
| Direct allocation | Household lock prevents concurrent stale fund check, but each repeat inserts another debit. | Atomic operation-key ledger/audit pair; never blind retry. |
| Exclude | n4 preserves pre-exclusion state; repeat can add another audit. | Explicit expected revision/state and operation receipt; terminal protections. |
| Restore | Requires excluded; repeat errors. Legacy NULL may promote by date server-side. | Same-operation acknowledgement and explicit durable prior-state migration policy; no native date promotion. |
| Reclassify | Admin/allowed-kind checks, repeated update/audit; no intent identity. | Version precondition and atomic receipt/audit; preserve prior classification. |
| Manual delete | Row removed once; repeat not-found; not a reversible tombstone. | OWNER DECISION REQUIRED on void/history/reversal; operation-keyed command, no not-found-as-success shortcut. |
| Base allowance | Reassigns scalar; repeat can create audit again; concurrent policy changes can be overwritten. | Effective-dated policy, expected version, preview/reversal and operation receipt; scalar equality is not idempotency. |
| Temporary increase | Each call appends a positive row; replay doubles increase. | Atomic unique intent, effective week and reversal linkage. |
| Savings movement / balance attestation | Each call appends; movement replay duplicates recorded cash; attestation replay creates another observation. | Stable movement/attestation IDs, explicit observation provenance, duplicate receipt, lifecycle and reversal. No transfers initiated. |
| Held resolution | Checks pending, but SELECT has no FOR UPDATE and final UPDATE has no pending predicate. Sequential repeat errors; concurrent calls can both credit. | Lock/serialize held row and household shortfall; atomic unique operation/effect and receipt with resolution amounts/ledger IDs; competing action conflict. MISSING concurrency protection in inspected body. |
| Week-close / release / restoration | Unique household/week and refund-entry constraints, conditional release claim; multiple database requests, partial commits possible. | Restricted server orchestration, resumable run ID/phase outcome, concurrency/fault testing; no phone blind retry. Existing handler can return 500 with completed counters plus restoration error. |
| Refund linking / financial reversals | MISSING supported commands. | Audited expected-revision command and one compensating effect per operation; never local totals or direct row patch. |

**PROPOSED common receipt:** operation_id, household scope, actor binding, command
and canonical payload fingerprint, committed revision, resource/ledger/audit IDs,
server time and succeeded/rejected/in_progress/unknown outcome. Atomically bind
identity+household+operation to payload/effects; reject different payload replay;
authorize receipt lookup, define retention/expiry and replay after expiry. Keep
pending IDs through app termination/session-safe reconciliation; show unresolved
intent rather than silently create a replacement. This requires separately
approved backend work; adding an ignored JSON UUID to current RPCs achieves none
of it. Read retries may be bounded/cancellable with backoff; permission/validation
errors do not retry. Writes reconcile the same ID, never regenerate on timeout.

Connection mutations also need separate replay review: exchange can consume a
public token; disconnect can remove externally before local status changes; sync
has cursor/matcher replay but may truncate or partly commit. Account deletion
can partly remove membership before Auth deletion. None inherits financial
exactly-once semantics from an HTTP method or the M2 mock.

## 4. Financial summary contract: render only

**VERIFIED EXISTING compute-week fields (direct object):** week_start,
base_available_cents, temp_cents, carried_debt_cents, charges_cents,
available_cents, week_locked, pending_refund_excluded_cents. `carried_debt_cents`
is incoming **D**, per later owner ruling, not residual or outgoing debt. Request
D/T/legacy-credit overrides are ignored. No computed_at, version, outgoing debt,
fund/savings aggregate or source freshness is returned. Do not extend this strict
eight-field endpoint without coordinating its existing consumers.

**VERIFIED EXISTING historical rows:** week_closes stores outgoing_debt_cents,
surplus_cents and historical policy/late-adjustment snapshots; these do not supply
a current-week outgoing-debt endpoint. restoration_entries stores id,
household_id, week_start, purchase_transaction_id nullable, refund_transaction_id,
restored_surplus_cents, debt_reduction_cents, fund_credit_cents, created_at;
refund_transaction_id unique. held_refunds includes held_cents/status,
purchase/refund IDs, resolution_note, created_at/resolved_at. These are outcomes,
not instructions for Swift to rerun restoration.

| Required display payload | Status / required semantics |
|---|---|
| Complete current week | PROPOSED; MISSING server payload: existing fields plus outgoing_debt_cents, base allowance/policy version, computed_at, household timezone, revision/as-of and completeness. No inference of outgoing debt from negative available. |
| Extra Fund | PROPOSED; MISSING aggregate: earned, pending release, released, spent, adjustments/reversals/restorations, available, shortfall separately, held totals separately; release schedule and server reconciliation provenance. Agree cumulative versus period semantics; do not sum paginated ledger on phone. |
| Savings | PROPOSED; MISSING aggregate: fund available, earned_not_yet_transferred, actual_balance nullable with bank/attested provenance/time, confirmed net transfers excluding interest, interest/outside amounts, unmatched rows and movement states initiated/pending/posted/reversed/unmatched. Null actual balance is not zero, intent is not confirmation. |
| Restoration detail | VERIFIED EXISTING row outcomes; PROPOSED complete audit payload with original policy/input references, simulation horizon, refund totals/restored increments, surplus/debt/fund components, shortfall offset and held disposition. No raw mailbox evidence. |
| Cross-section consistency | PROPOSED shared snapshot/revision or explicit independent as-of/per-section errors. Failure/unknown/schema fallback must not become a zero/empty healthy balance. Pagination includes completeness/cursor. Integer cents with SQL integer bounds validated; native Int64 support does not expand server range. |

All authoritative calculations stay in existing server engine/close/restoration
paths. Preserve $375 Sunday–Saturday America/New_York, original purchase date,
28-day open window, seven days from actual close, locked-history immutability,
shortfall-first credits, no automatic budget-to-fund clawback and no interest
spendability. Restoration uses original inputs through **last completed week**,
posted-only incremental/refund-capped effects, fund-first split ordering,
temporary-covered portion restoring nothing, excess held. No superseded refund
credit balance and no competing Swift formula. Existing server fallback reads can
hide schema gaps; staging must prove required schema exists rather than accept
fallback zeros as completeness. Web's client fund/savings reductions are evidence
of missing server payloads, not reusable native accounting code.

## 5. Source times, freshness, states and linkage

| Contract | Status and boundary |
|---|---|
| Date/time | VERIFIED EXISTING date-only transactions.date and UTC created_at; plaid_items_public.last_sync_at, email_connections_public.last_poll_at/status/last_error. MISSING complete source purchase/authorization/receipt/ingest/post times, timezone/precision/date_uncertain and original amount/event trail. Receipt/import time never substitutes for purchase time. |
| Freshness | M2 SourceFreshnessResponse is PROPOSED client DTO: missing/null and unknown strings preserved. MISSING common server freshness response/thresholds, last attempt versus last successful sync, partial/truncated/backlog state and schema version. Proposed server-computed state with observed_at/last_success_at/last_attempt_at and sanitized error; unknown/future clock values never default fresh. |
| Persisted state mapping | VERIFIED EXISTING base schema provisional/verified/excluded/reversed; bank pending also provisional. Native maps verified to posted, Plaid provisional to pending for display. MISSING reliable pending provenance after cross-source merge and persisted review/quarantine/void transition/event contracts. Native eight-state mock is not a database migration. Preserve unknown states and deny unsafe actions until mapped. |
| Prior exclusion state | VERIFIED EXISTING n4 nullable pre_exclusion_state; legacy server fallback differs from native mock's fail-closed restore. OWNER DECISION REQUIRED to resolve ambiguity for native writes without erasing history or silently promoting pending refunds. |
| Refund linkage | VERIFIED EXISTING nullable original_purchase_id plus provider pending/transaction IDs. Plaid sync deliberately sets original_purchase_id NULL (settled owner decision 10); pending_transaction_id links authorization/posting, not refund-to-purchase. Never infer a refund from an arbitrary negative amount, cashback/payment or merchant/amount alone. |
| Linked-refund completion | MISSING audited link/correction/review endpoint; OWNER DECISION REQUIRED whether/when to supersede the documented NULL-link deferral for native completeness. Preserve NULL until then; expose unlinked state and server fallback provenance, do not manufacture restoration eligibility. |
| Multi-source matching | VERIFIED EXISTING canonical hashes/provider ID matching paths, but identical-purchase, tip/hold, eligibility and overlapping CSV guarantees require staged tests. MISSING complete source-event/match confidence/correction API. Server decides matches/ambiguity and state; phone only submits evidence and renders decisions. |

## 6. Effective policy, reversals and deletion ownership

- **VERIFIED EXISTING:** set_base_allowance updates the current household scalar;
  closed snapshots retain B/T, but open unsnapshotted computations can see the new
  scalar. add_temp_increase accepts a week date with no complete native effective-
  date/preview contract. FINAL future-effective default is settled; the missing
  detail is which boundary/current-week behavior and how to present its impact.
- **OWNER DECISION REQUIRED:** choose effective week/time for new base policy and
  permitted override week selection; preview/confirmation and reversal behavior
  when affected periods are open versus locked. **PROPOSED:** immutable policy
  versions and server impact preview, expected revision, compensating reversal
  linking original actor/reason/operation; no history rewriting or Swift replay.
- **MISSING:** general reversal APIs despite ledger `reversal` kind and spec right
  to reverse adjustments. Specify allocation/request reversal, temporary grant
  cancellation, savings correction and held-resolution correction; a negative new
  intent is not an acceptable invented reversal. Blank ordinary reasons remain
  allowed; insufficient-fund override still needs typed nonblank reason.
- **VERIFIED EXISTING:** manual DELETE conflicts with retained Voided/history
  requirement. **OWNER DECISION REQUIRED:** keep connected removal unavailable
  until an approved server history-preserving command/mapping is agreed; do not
  silently call delete while labeling it Void.
- **VERIFIED EXISTING:** account deletion can leave a spouse as the sole member
  with no explicit promotion; FK references (requests/audit/temp/savings etc.) can
  obstruct Auth deletion and multi-step cleanup can partly commit. Handoff's
  one-member throwaway test does not prove two-user admin departure, integration
  revocation or retention. **OWNER DECISION REQUIRED:** block admin departure
  until transfer versus approved successor, shared financial/audit retention and
  attribution anonymization, empty-household cleanup, server provider disconnection
  and recoverable partial deletion. This cannot be settled by clearing a native
  session or assuming cascades delete only appropriate records.

## 7. Proposed synthetic-only staging and acceptance matrix

Entire setup is **PROPOSED / OWNER DECISION REQUIRED for creation/connection**.
Nothing was provisioned. No production clone/export, keys, data, provider item,
OAuth consent, cron configuration or production deployment integration may be reused.

1. Owner approves an isolated project/account, region, allowed test identities,
   quota/cost ceiling (no payment method/paid activation), allowed setup actions
   and cleanup owner. If free capacity is unavailable, stop rather than upgrade.
2. Inventory SQL definitions into an explicit reviewed dependency order and compare
   installed schema/grants/RPC signatures inside staging only after approval.
   Do not apply historical patches alphabetically: old grant/policy/function
   definitions can undo hardening. Include constraints, triggers, default privileges,
   restoration snapshots and separate server engine copies; hash/compare copies.
   Any setup/backend code/deployment requires separate explicit authorization and
   a staging-only location/process; this review authorizes none outside ios/.
3. Seed invented admin/member household A, admin/member household B and unjoined
   user using generated synthetic IDs. No real addresses, card data or invite codes
   in fixtures/reports. Use isolated test mail sink or approved synthetic inbox;
   initial tests require no external bank/Gmail/provider. Disable provider paths,
   production network destinations, cron and webhook registrations by default.
4. Native future build must fail closed to allowlisted staging project identity,
   use separate config/storage namespace and no production fallback/sample-to-real
   switch. Server keys only in staging server secret storage. Session/public config
   handling must be reviewed; no service key/client-bundled credentials or filled
   secrets in repo/CI logs. Test harness denies outbound provider network.
5. First phase: Auth/RLS and existing reads with unavailable mutations explicitly
   gated. Second: approve server contract fixes before financial writes/retry tests.
   Provider sandbox, native recovery redirects, Apple capability/cloud builds are
   separate later approvals; initial staging approval includes none automatically.
6. Deterministic server clock/time fixtures in isolated harness; controlled replay,
   reset/snapshot and staging restore only. Capture sanitized assertions, schema/
   function versions and test SHA, not financial records/tokens. Teardown staging
   identities/data per approved retention; leave production untouched.

All rows below are **PROPOSED tests, NOT RUN**. Existing 82 Linux core passes are
mock/decoder tests, not staging results. Historical simulator run 41648851937 at
1d66a0f verifies that SHA only; no build is requested or triggered here.

| Gate / scenarios | Acceptance evidence | Dependency |
|---|---|---|
| Isolation/bootstrap | Project allowlist rejects production/misconfiguration; no provider egress, no real data/keys, schema/grant manifest reproducible. | Staging/setup approval first. |
| Auth/session | Signup policy, min password, login/logout, expiry/refresh races, recovery replay/cancellation, identity/cache isolation and deletion failures. | Approved test Auth identities/redirect route. |
| Roles/RLS | Admin/member/anonymous/other-household direct reads/writes/RPCs; foreign request links, forged sources/kinds/allocation, vault and privileged RPC denial; both users read audit. | Installed schema inventory, no UI-only authorization. |
| Household/invites | Two-user maximum under concurrent joins, one-household rule, reusable nonexpiring code-only join; invalid returns NULL, throttling and no UUID path. | Existing contracts staged; concurrency coverage required. |
| Week/policy | FINAL #1–5,8–9,12–13,16; all A3 cases, DST/Sat–Sun booking, outgoing versus incoming debt, partial/null payloads and effective/reversal boundaries. | Summary and policy decisions; server expected outputs only. |
| Fund/close | FINAL #6–7,10–11,14,33; seven days from actual late close, simultaneous approval/allocation, closed split remainder, insufficient fund override, $35 shortfall example, release retry/fault at each write. | Durable mutation/close recovery contracts. |
| Refund restoration | FINAL #15/page17: $475/$150 absorbed debt -> $150 surplus/$0 cut; outstanding -> $50/$100; $300 full; temporary $100 -> $0; fund $60 -> $60; $35 shortfall/$50 -> $15; $500/$475 -> $25 held; partial order/replay, pending removal, original policy, read-only simulation/locked history. | Approved linked synthetic events/horizon; no new Swift engine. |
| Manual/CSV/matcher | FINAL #17–24,27; both source orders, identical genuine rows, repeated overlapping batches, $40->$48 correction, no-alert rows, seven-day review not deletion, removed events; explicit per-row outcomes and unknown credits. | Server matcher/import/state contracts. |
| Retry/fault matrix for every section-3 mutation | Cancel before/after commit, lost acknowledgement, duplicate/concurrent same ID, changed payload, different actor/household, app restart, expired receipt, read-after-write failure; one canonical effect/audit pair or explicit unresolved result. | Atomic IDs/receipt lookup; existing RPCs insufficient for full pass. |
| Savings | FINAL #29–30/A6 entire ordered example; initiated intent not confirmed, imported/attested confirmation, pending/reversed/unmatched, interest/outside separate, nullable actual, correction/replay, no money-moving endpoint. | Reconciliation aggregate/lifecycle/reversal contract. |
| Sources/provider-shaped fixtures | FINAL #25–28,34; forged/ambiguous synthetic mail rejected/quarantined, pending->posted/removed/tips, cursor pages/failures/truncation, disconnected/expired/unknown/future times; secrets/raw mail absent in logs. | Stub providers only initially; external consent separately gated. |
| Read completeness/offline/widget | FINAL #31–32; >page-limit data, stable sorting/export, independent section failures/revisions, stale/future timestamps, cold offline read-only, logout/identity purge; widget consumes server-only snapshot. | Read adapter/cache contracts; Apple widget execution requires later approval. |
| Reversal/deletion/audit | FINAL #33; admin/member visibility, atomic attribution, explicit compensating entries, no false success on partial deletion, two-user admin departure, FK/provider cleanup tests. | Owner policy decisions and approved backend work. |
| Recovery/ops | FINAL #36 synthetic staging backup/restore with exact IDs/counts and replay; no production export. Two-client parity and full 36-case report with gaps marked, not silently passed. | Separate staging recovery scope; no nightly production changes. |

## 8. Minimum decisions and approvals

**To start a limited Auth/read-only staging integration:**

1. **OWNER DECISION REQUIRED — approval:** identify isolated project/allowed synthetic
   identities and authorize creation/configuration/deployment/connection actions
   with zero-paid-service boundary. This must explicitly supersede existing
   prohibition for those staging actions only; production remains forbidden.
2. **OWNER DECISION REQUIRED — scope:** approve Auth/read-only first, keeping financial
   writes and provider paths disabled until their gates pass. Agree native test
   recovery callback ownership/configuration if recovery is included initially.
3. **PROPOSED technical review:** adopt the staged schema/signature/RLS manifest,
   complete read payload design and lossless/error/time/state mapping. These are
   engineering contract reviews, not requests to reconsider settled finance rules.

**Additional gates before complete connected financial workflows:**

4. **OWNER DECISION REQUIRED — product:** effective-week/override/reversal semantics,
   history-preserving manual void versus legacy deletion, admin succession/deletion
   retention and cleanup. Keep ambiguous commands disabled meanwhile.
5. **OWNER DECISION REQUIRED — scope:** retain documented null Plaid refund linkage
   for initial reads or authorize a separately specified server link/review phase;
   no automatic linking is assumed. Approve separately scoped staging backend work
   for summaries, durable idempotency/reconciliation and missing commands after
   their concrete contracts are reviewed.

No need to decide providers, push notifications, App Groups, signing/distribution,
paid plans or another cloud build to perform limited staging API tests. Each of
those remains separately approval-gated later. No live-account access is requested.
