# Prepared interfaces — no connection authorized

No URL, token, SDK or HTTP transport is compiled into the app. Implementing a
staging adapter requires explicit approval. Production remains forbidden.
Do not solve an API gap by editing supabase/ in this branch.

| Operation | Existing interface | Adapter requirements |
|---|---|---|
| Weekly display | compute-week POST household_id, optional week_start | Typed eight-field WeekResponse, accepts direct/result wrapper; never send D/T/refund-credit inputs |
| Authentication | Supabase email/password/recovery/updateUser | Keychain-backed session, expiry handling, native recovery links; currently form preview only |
| Household | create_household; join_household_by_code(code) | NULL join is failure, codes private, one household, server roles |
| Purchases | transactions household-scoped reads/inserts | Paging, provisional manual/CSV, integer cents; preserve unknown states visibly |
| Exclusion | exclude_transaction(txn_id,reason); restore_transaction(txn_id) | Admin RPC; restore previous state, never infer posted on client |
| Classification | reclassify_transaction(txn_id,new_kind,reason) | charge/refund/fund_charge; no direct table UPDATE |
| Manual delete | delete_transaction(p_transaction_id) | Admin/manual only, confirm and audit |
| Fund requests | fund_requests INSERT pending | Caller/request/household validation on server |
| Approval | approve_and_allocate(request_id,amount_cents,override_reason) | Current names have no p_ prefix; split remainder closed |
| Decline | decline_fund_request(p_request_id) | Pending-only, server authority |
| Allocation | allocate_fund(p_household_id,p_amount_cents,p_note,p_override_reason) | Balance/override/retry semantics from server |
| Allowance | set_base_allowance(p_household_id,p_cents) | Future-effective rule unresolved; do not implement calculation locally |
| Temp increase | add_temp_increase(p_household_id,p_week_start,p_amount_cents,p_note) | Server scope/effect preview required |
| Savings | attest_savings; record_savings_entry | Explicit existing p_ arguments, no money movement, authoritative summaries needed |
| Held refund | resolve_held_refund(p_held_id,p_action,p_note) | release offsets shortfall then credits fund on server |
| History/audit | week_closes, surplus_releases, audit_log reads | Full pagination and server snapshots, never replay finance on device |
| Bank | plaid-link/exchange/sync/disconnect/webhook-register | Native Link SDK; server tokens only; admin authority |
| Email | gmail-oauth-start/callback/poll/disconnect | Deferred native launch; native callback contract absent, no live grants |
| Delete account | delete-account with user JWT | Confirm, partial-failure recovery, admin succession; sample clears local session only |

Planned integration protocols `BankLinking` and `EmailConnecting` currently always
throw unavailable. No real token, consent URL, or public-token placeholder is used.
Native custom URL is a sample Home route only, not an authentication callback.

The service is injected behind HouseholdService. Mock permission/idempotency tests
are useful client regressions, NOT proof of real RLS or financial posting. Mock
financial actions only record receipts; they do not mutate canonical values.
