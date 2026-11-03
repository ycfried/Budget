# First live connection: preparation and approval boundary

November 3, 2026. Baseline: integration review at 2383ffc. This document records
**preparation only; no live request has been made**. The owner's latest instruction
allows preparation for their real household, superseding earlier staging-only
requirements for this specific direction. It still requires approval immediately
before the first connection and a separate exact plan before any financial write.
Other source/production/build safeguards remain in force.

## What is prepared

- [NativeReadClient](../Sources/OnBudgetCore/NativeReadClient.swift): password sign-in,
  server identity validation, explicit household membership, session restoration,
  coalesced refresh, local sign-out, server week DTO and explicit paged record reads.
- [GuardedReadTransport](../Sources/OnBudgetCore/GuardedReadTransport.swift): ephemeral
  URLSession, exact origin and method/path allowlist, no cookies/credential cache,
  redirects refused, TLS verification left enabled, request/resource timeouts,
  cancellation, no automatic application retries, sanitized status errors.
- [KeychainSessionVault](../Sources/OnBudgetCore/KeychainSessionVault.swift): session
  access/refresh tokens only, device-only WhenUnlocked accessibility, no iCloud,
  passwords, widgets or UserDefaults. Saved sessions are bound to the exact origin;
  changing configuration cannot forward saved tokens to another project. A separate
  memory vault is for fixture tests.
- [NativeReadStore](../Sources/OnBudgetCore/NativeReadStore.swift) and separate native
  connection view in [AuthenticationView](../App/AuthenticationView.swift): loading,
  error feedback, explicit membership selection, server weekly amounts and paged
  records. This never passes real data to writable MockHouseholdService or widgets.

**Disabled now:** app creates NativeReadStore without a client, supplies no project
configuration, and does not enable the guarded executor. No real-credential form
is shown. The default core transport also rejects all requests. There is no URL
probe, SDK startup, token restoration or background request. An approval boolean
in the executor is a development gate, not an authentication/RLS security boundary;
only an explicitly reviewed composition change after approval may set it true.

The connection view is a read inspector, not a completed production dashboard.
It displays raw server row amounts and weekly available/incoming debt; it never
computes current outgoing debt, fund entitlement, savings reconciliation, refund
restoration or week close. Existing sample tabs remain clearly synthetic and
separate. Missing aggregate APIs are not replaced with sums of paginated rows.

## Destination, credentials and permissions

**Exact destination identity:** the existing Supabase project origin recorded in
[HANDOFF.md section 2](../../HANDOFF.md), subject to owner confirmation at connection.
Do not copy it into source/docs, infer a different project, or import web config.
The reviewed relative endpoints below are appended only to that confirmed HTTPS
origin, with no alternate host/port, redirects, fallback or provider destination.
The runtime origin/public key must be supplied outside version control; no endpoint
or actual configuration value is committed in this preparation.

| Credential | Source / storage | Permission and side effect |
|---|---|---|
| Project public publishable/anon key | Owner-confirmed public app configuration, runtime injection; redacted descriptions. Modern secret keys and non-anon JWT-shaped project keys are rejected. | Project routing/public API access, not service-role access; user JWT/RLS still required. Public key alone does not authorize household data. Never substitute a service-role key to fix 403s. |
| Household user's email/password | Owner enters directly into an approved native sign-in screen; never chat, repo, tool arguments, screenshot, fixture, logs or agent-visible credential dump. | Password grant creates an Auth session; may update last-sign-in/security logs and consume Auth quotas. Password not persisted; form clears after submission/disappearance. This is not a financial write, but is a live Auth side effect requiring first-connection approval. |
| Access/refresh tokens | Issued by existing Auth; Keychain under an app-specific read-only namespace when approved composition is wired. No token values in reports. | Bearer inherits user's existing admin/member privileges. Refresh rotates/renews session and may update Auth logs; no role is requested or elevated. No narrower server read-only role is assumed to exist. |
| Production service/admin, bank, Gmail, ingestion, Apple credentials | **Not needed, not requested, never used.** | No elevated grants, provider calls, signing or account-setting changes. |

There is no secure credential-entry surface enabled or validated on an Apple build
for this revision. Do not ask the owner to paste a password/token into chat or use
the cloud shell as a substitute. A later approved native build/device route or
separately reviewed secure test harness is needed to execute owner-entered login.
No build/signing permission is implied by approving the endpoint plan.

## Exact request allowlist and side effects

All paths below are relative to the confirmed origin. Read requests include project
public `apikey` and user bearer where appropriate. No request body/headers/raw
server error, record values or identifiers are logged. No refresh-on-401 retry or
financial retry queue is present. Unknown/missing/null values remain explicit.

| Method / endpoint | Exact request contract | Side effects / permitted result |
|---|---|---|
| POST `/auth/v1/token?grant_type=password` | JSON email/password; project public key. | Creates user session; returns access_token, refresh_token, expires_at and user.id. Current decoder requires these fields; actual Auth response must be validated, never fabricate expiration. |
| POST `/auth/v1/token?grant_type=refresh_token` | JSON refresh_token; public key. | Session renewal/rotation. Concurrent readers share one in-flight renewal. Lost refresh acknowledgement is not retried automatically; may require owner sign-in again. |
| GET `/auth/v1/user` | User bearer/public key, no body. | Validates identity against Auth; no financial mutation. Local session and response user IDs must agree. |
| GET `/rest/v1/household_members` | select=household_id,user_id,role,display_name; user_id=eq.<validated caller UUID>. | Read membership only; unknown role retained but cannot authorize reads. Household selection explicit; no create/join/invite request. |
| POST `/functions/v1/compute-week` | JSON household_id and optional week_start. No D/T/financial overrides. | Checked-in function performs reads and existing server-engine computation only. Eight-field response, no week-close or ledger write. Real deployed behavior is not independently verified by repository analysis. |
| GET `/rest/v1/<relation>` | Exact relation/column lists below, own household filter, stable created_at.asc,id.asc, Range-Unit items, Range 0–99 initially, Prefer count=exact. | Database reads only; may consume database/Edge quotas and appear in server access logs. No provider fetch/sync; no automatic advancement beyond one page. |

Allowed relations and selected columns (implementation source is authoritative):

| Relation | Column selection |
|---|---|
| households | id,name,base_allowance_cents,fund_shortfall_cents,created_at; filter id=eq.<household UUID> |
| transactions | id,household_id,date,merchant,amount_cents,card_suffix,source,state,kind,excluded,pre_exclusion_state,original_purchase_id,fund_allocation_cents,late,created_at |
| fund_requests | id,household_id,transaction_id,requested_by,amount_cents,note,status,decided_by,decided_at,remainder_cents,created_at |
| fund_ledger | id,household_id,kind,amount_cents,week_start,request_id,note,created_by,created_at |
| savings_ledger | id,household_id,kind,amount_cents,attested_by,note,actual_balance_cents,created_at |
| week_closes | id,household_id,week_start,surplus_cents,outgoing_debt_cents,base_allowance_cents,temp_increase_cents,late_adjustment_cents,created_at |
| surplus_releases | id,household_id,week_start,surplus_cents,released_cents,status,release_date,created_at |
| restoration_entries | id,household_id,week_start,purchase_transaction_id,refund_transaction_id,restored_surplus_cents,debt_reduction_cents,fund_credit_cents,created_at |
| held_refunds | id,household_id,refund_transaction_id,purchase_transaction_id,held_cents,status,resolution_note,resolved_at,created_at |
| audit_log | id,household_id,actor,actor_name,action,detail,created_at |
| temp_increases | id,household_id,week_start,amount_cents,note,created_by,created_at |
| plaid_items_public | id,household_id,institution_name,status,last_sync_at,created_at; no token/cursor |
| plaid_accounts | id,household_id,name,mask,type,subtype,updated_at,created_at; existing metadata, no provider call |

Except households, all relation filters are household_id=eq.<selected UUID>.
Every returned row is checked for that household identity. No select=* or vault/
mailbox table access. Per-page total/range must be explicit and internally consistent;
unknown count or malformed range fails closed. Counts/ranges do not establish a
consistent multi-request financial snapshot. Concurrent record changes can affect
offset pagination; do not use pages as a complete financial export or ledger audit.

**Excluded entirely:** all `/rest/v1/rpc/*`; POST/PATCH/DELETE tables; signup,
password recovery/update, server logout/revoke, household create/join, account
 deletion, held resolution/fund release, week-close, bank link/exchange/sync/
disconnect, Gmail functions/OAuth, webhook changes, cron, backend settings or schema.
Only Auth grants and compute-week may use POST in the guarded transport. A user
admin token remains powerful server-side, so the allowlist is defense in depth;
request substitution/untrusted transport implementations must never be enabled.

## Proposed first live validation window — approval pending

1. Confirm origin/public key belongs to the existing owner-approved project and
   approve the Auth side effects/read list above. No credential values in approval.
2. Separately review/configure the native executor and Keychain namespace after
   approval, and establish an owner-controlled credential-entry/execution route.
   Do not auto-run a cloud build or change Apple/server redirect configuration.
3. One owner-initiated sign-in, GET identity and membership; stop for unexpected
   identity/household/role. No join/create if membership is missing. Do not report
   household IDs or transaction contents in chat/commits.
4. Read the current week once and at most one initial 100-row page per listed
   relation, each only on explicit user/test action. The implementation revalidates
   identity/membership per read. Initial full inspection ceiling: 45 HTTP requests
   (3 initial Auth/membership, 3 week, 13 × 3 relation reads); at most one session
   renewal if needed, then stop. No automatic retry, pagination loop or polling.
5. Validate shapes, server integer cents/nulls, role/household isolation and range
   completeness. Compare displayed **server** values to the owner's existing view
   without changing either app's data; missing aggregates remain unavailable.
   Record only sanitized statuses/counts/schema findings and pass/fail, not actual
   financial rows, amounts, emails, tokens or identifying evidence in repository.
6. Clear local session/visible records afterwards. This does not revoke the server
   Auth session; revocation/logout-server API is outside this first allowlist. If
   a sign-in response is lost or refresh becomes uncertain, stop and ask for an
   Auth recovery/revocation plan rather than repeat automatically.

Stop on 401/403, unexpected schema/role/project, missing membership, rate limit,
service error, ambiguous freshness or any apparent non-read financial effect.
No compensating financial writes are allowed. The permission window above does
not promise zero quota use or operational risk; no paid service is activated.
Ephemeral URLSession buffers a response before the 2 MB acceptance check; it is
not a streaming download cap. Use bounded pages, timeouts and no automatic loops.

## Financial validation limits and separate write-test gate

Existing backend gaps remain: no current outgoing-debt field in compute-week,
no complete server Extra Fund/savings aggregates, null Plaid original_purchase_id,
legacy state/restore fallback, absent general idempotency/operation lookup and
reversals. Bank metadata schema has no actual savings-balance column; an attested
balance is distinguishable from a bank-reported balance. Native must not label
attestation as bank truth or sum rows to bridge missing summaries. Backend fixes
remain separately prohibited until specifically approved.

**No financial write plan is submitted for execution in this phase.** No test record
has been created/selected on the live backend. Real data permission does not make
synthetic purchases harmless: provisional charges affect budget/debt/surplus and
can cascade into history. An exclusion/restoration or DELETE is not a guaranteed
rollback. Existing genuine transactions must never be modified for testing.

Before proposing the first financial write test, prepare a separate reviewable
plan with: exact reserved test record/operation IDs (sensitive identifiers via an
approved private channel), initial read-only baseline, exact endpoint/body and actor,
server-engine preview of current/downstream/locked-week/fund/savings effects,
isolation from close/release jobs, server-supported reversal or isolated scope,
post-test canonical/audit comparison, duplicate prevention and lost-response lookup,
abort conditions and approved recovery operator. If existing APIs cannot ensure
those properties, the write test remains blocked; do not infer success from a
matching balance or retry append-only RPCs. No deletion, fund release, week close,
banking/Gmail change or irreversible operation is covered by this approval request.

## Evidence and remaining gates

See PROGRESS.md for executed local counts. Fixture HTTP transport tests cover
request shape, identity/role checks, null/unknown payloads, page completeness,
forbidden routes, cancellation, refresh, local cleanup and default closed state.
They do not contact any origin. Guarded transport policy tests never execute an
enabled network request. Keychain code is Apple-only and not runtime tested on
Linux. Apple Swift syntax/static project checks are not Xcode compilation.

Before actual owner-data validation: explicit first-connection approval, confirmed
runtime config, reviewed guarded composition and secure owner credential entry.
Before calling this native build validated: separate approved Apple build/device
execution. Before connected financial actions: separately approved exact write
plan and supported reconciliation/recovery contracts. No approval already given
is reopened: real-data direction is accepted; only the user's expressly required
first-connection and specific-write gates remain.
