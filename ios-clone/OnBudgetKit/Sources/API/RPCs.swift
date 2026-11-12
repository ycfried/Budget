// OnBudgetKit — RPCs.swift
//
// One typed Swift function per RPC the live app calls, over PostgREST
// (`POST <base>/rest/v1/rpc/<name>` with a JSON body of the exact
// parameter names from the SQL). Parameter names matter: PostgREST
// matches RPC arguments by name.
//
// Every function carries the server's refusal text through unchanged
// (see Errors.swift): admin-only, the 35-day week lock, "cannot
// restore: no prior state recorded", "held refund already resolved".
//
// RPCS THE LIVE APP DOES **NOT** CALL — deliberately absent here:
//   * `add_temp_increase`, `attest_savings`, `record_savings_entry`,
//     `approve_fund_request` — no call sites in live.js AND their
//     EXECUTE grants were REVOKED live Nov 9, 2026
//     (`supabase/p2-revoke-dead-rpcs.sql`, applied live, step 10).
//     A call now fails with a permission error. Live replacements:
//     `setWeeklyAllowanceOverride` (temp box), `approveAndAllocate`
//     (fund approval), savings is read-only in the live app.
//   * `auto_link_refund`, `link_refunds_to_purchase` — granted to
//     `service_role` ONLY (`refund-linking.sql:192,245`); the browser
//     client cannot call them (live.js:2512, 2750). Refunds link by
//     hand via `linkRefund`.
//   * `get_plaid_ciphertext`, `update_plaid_sync` — service-role only
//     (`07-service-rpc-access.sql`). Only plaid-sync calls them.
//   * `rotate_household_ingest_secret` — no client call site; the
//     documented manual rotation path, not an app flow.
//   * `log_webhook_event` — service-role only; only plaid-webhook
//     calls it.
//   * `generate_invite_code`, `_caller_display_name`,
//     `_same_normalized_merchant`, `force_audit_actor`,
//     `stamp_allowance_set_at`, `validate_fund_request_txn` —
//     helpers/triggers, never called by a client.
//
// A note on `approve_and_allocate`: `04-admin-rpcs.sql` defines it
// with unprefixed args (`request_id, amount_cents, override_reason`),
// but the CANONICAL definition (per `test/p1-fixes-audit-r2.test.mjs`
// and `approve-ambiguity-fix.sql`) uses `p_request_id, p_amount_cents,
// p_override_reason` — and live.js calls it with the `p_` names.
// This client uses the `p_` names, matching the live calls.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - RPC transport

/// PostgREST RPC calls. Constructed by `SupabaseClient` (which
/// supplies the token provider); screens never build one directly.
/// `call` is generic over the decoded return; `callVoid` is for
/// `returns void` functions (empty/204 body = success).
public struct RPCClient {
    public let configuration: SupabaseConfiguration
    public let tokenProvider: () async throws -> String
    private let transport: HTTPTransport

    public init(
        configuration: SupabaseConfiguration,
        tokenProvider: @escaping () async throws -> String,
        transport: HTTPTransport
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    /// Build the POST request for an RPC call. Pure (no network) so
    /// tests can assert on the RPC name and the exact parameter names.
    public func makeRequest(name: String, params: [String: Any]) throws -> URLRequest {
        let url = configuration.restBaseURL
            .appendingPathComponent("rpc")
            .appendingPathComponent(name)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        // Authorization is attached by `send` (it needs a fresh token).
        request.httpBody = try JSONSerialization.data(withJSONObject: params, options: [])
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await tokenProvider()
        var authed = request
        authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await transport.send(authed)
    }

    /// Call an RPC that returns a JSON value.
    public func call<T: Decodable>(name: String, params: [String: Any]) async throws -> T {
        let request = try makeRequest(name: name, params: params)
        let (data, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the result of \(name).")
        }
    }

    /// Call an RPC that returns `void` (empty body on success).
    public func callVoid(name: String, params: [String: Any]) async throws {
        let request = try makeRequest(name: name, params: params)
        let (data, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        // PostgREST answers a void RPC with an empty body (204 or an
        // empty 200). Any body is ignored — success is the status.
        _ = data
    }

    /// Call an RPC that returns a single scalar (uuid / jsonb).
    /// `jsonb` results decode as `T`; a `uuid` result decodes as `UUID`.
    public func callScalar<T: Decodable>(name: String, params: [String: Any]) async throws -> T {
        try await call(name: name, params: params)
    }

    /// Call an RPC that returns a nullable scalar — `join_household_by_code`
    /// returns NULL for an invalid code instead of raising (it logs the
    /// failed attempt first; `n13-invite-rate-limit.sql`). A JSON `null`
    /// decodes here as `nil`, not an error.
    public func callOptionalScalar<T: Decodable>(name: String, params: [String: Any]) async throws -> T? {
        let request = try makeRequest(name: name, params: params)
        let (data, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        let whitespace: [UInt8] = [0x20, 0x09, 0x0A, 0x0D]
        let trimmed = data.filter { !whitespace.contains($0) }
        if trimmed.isEmpty || trimmed == Data("null".utf8) { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the result of \(name).")
        }
    }
}

// MARK: - Transaction mutations

extension RPCClient {
    /// `reclassify_transaction(txn_id, new_kind, reason)` — admin only,
    /// 35-day lock (`refund-classification-income-kind.sql:55-85`).
    /// Valid kinds: charge, refund, fund_charge, payment, cashback,
    /// transfer, income, charity. The UI must NOT send `charity` here —
    /// charity goes through `markTransactionCharity` (live.js:3937-3942).
    public func reclassifyTransaction(
        txnId: UUID, newKind: TransactionKind, reason: String
    ) async throws {
        try await callVoid(name: "reclassify_transaction", params: [
            "txn_id": txnId.uuidString,
            "new_kind": newKind.rawValue,
            "reason": reason,
        ])
    }

    /// `exclude_transaction(txn_id, reason)` — move a row to Trash.
    /// Admin only, 35-day lock (`n4-pre-exclusion-state.sql:79-106`).
    /// Bank/email/file rows are never truly erased (the bank would
    /// re-sync them); hand-entered rows are deleted instead — see
    /// `deleteTransaction`.
    public func excludeTransaction(txnId: UUID, reason: String) async throws {
        try await callVoid(name: "exclude_transaction", params: [
            "txn_id": txnId.uuidString,
            "reason": reason,
        ])
    }

    /// `restore_transaction(txn_id)` — bring a Trash row back, restoring
    /// its pre-exclusion state (`n4-pre-exclusion-state.sql:187-233`).
    /// Admin only, 35-day lock. Fails with
    /// "cannot restore: no prior state recorded" when no prior state
    /// was recorded — that text is carried through unchanged.
    public func restoreTransaction(txnId: UUID) async throws {
        try await callVoid(name: "restore_transaction", params: [
            "txn_id": txnId.uuidString,
        ])
    }

    /// `delete_transaction(p_transaction_id)` — permanently delete a
    /// HAND-ENTERED purchase only (`delete-transaction-rpc.sql:21-56`).
    /// Admin only, 35-day lock. Bank records must be moved to Trash
    /// instead ("only hand-entered purchases can be deleted; bank
    /// records must be removed from the budget instead").
    public func deleteTransaction(pTransactionId: UUID) async throws {
        try await callVoid(name: "delete_transaction", params: [
            "p_transaction_id": pTransactionId.uuidString,
        ])
    }

    /// `mark_transaction_charity(p_transaction_id)` — mark a charge as
    /// a charity gift (`pending-charity-mark.sql` / `r13-charity.sql`).
    /// Admin only. Only a charge; only pending or posted; not excluded;
    /// no fund allocation; date ≥ 2026-11-01; 35-day lock. A pending
    /// gift counts toward Given only once it posts.
    public func markTransactionCharity(pTransactionId: UUID) async throws {
        try await callVoid(name: "mark_transaction_charity", params: [
            "p_transaction_id": pTransactionId.uuidString,
        ])
    }
}

// MARK: - Refund linking

extension RPCClient {
    /// `link_refund(p_refund_id, p_purchase_id)` — link a refund to its
    /// purchase by hand (`refund-linking.sql:254-310`). Admin only.
    /// The server enforces: same household, same card, purchase on or
    /// before the refund, refund fits in what the purchase has left
    /// to refund. Returns the linked purchase id. Already-linked
    /// refunds must be unlinked first.
    @discardableResult
    public func linkRefund(pRefundId: UUID, pPurchaseId: UUID) async throws -> UUID {
        try await callScalar(name: "link_refund", params: [
            "p_refund_id": pRefundId.uuidString,
            "p_purchase_id": pPurchaseId.uuidString,
        ])
    }

    /// `unlink_refund(p_refund_id)` (`refund-linking.sql:319-348`).
    /// Admin only. Refused when the refund already restored a week,
    /// or when it has a pending held amount.
    public func unlinkRefund(pRefundId: UUID) async throws {
        try await callVoid(name: "unlink_refund", params: [
            "p_refund_id": pRefundId.uuidString,
        ])
    }

    /// `dismiss_refund_link_suggestion(p_refund_id, p_purchase_id)`
    /// (`refund-link-dismissals.sql:39-60`). Admin only. Dismissals
    /// stick — a dismissed pair is never suggested again.
    public func dismissRefundLinkSuggestion(pRefundId: UUID, pPurchaseId: UUID) async throws {
        try await callVoid(name: "dismiss_refund_link_suggestion", params: [
            "p_refund_id": pRefundId.uuidString,
            "p_purchase_id": pPurchaseId.uuidString,
        ])
    }
}

// MARK: - Duplicates

extension RPCClient {
    /// `resolve_duplicate_candidate(p_candidate_id, p_action, p_note,
    /// p_remember_alias)` (`dedupe-review-queue.sql:93-176`).
    /// `p_action` is `merge` or `separate`; `p_remember_alias`
    /// records the merchant spelling pair when merging. Admin only;
    /// the candidate must still be pending. There is no bulk merge —
    /// merging is a judgment call per pair (live.js:1959-1967).
    public func resolveDuplicateCandidate(
        pCandidateId: UUID,
        pAction: DuplicateResolutionAction,
        pNote: String,
        pRememberAlias: Bool
    ) async throws {
        try await callVoid(name: "resolve_duplicate_candidate", params: [
            "p_candidate_id": pCandidateId.uuidString,
            "p_action": pAction.rawValue,
            "p_note": pNote,
            "p_remember_alias": pRememberAlias,
        ])
    }

    /// `reopen_duplicate_candidate(p_candidate_id)`
    /// (`dedupe-reopen.sql:23-39`). Admin only. A `separate` pair can
    /// be reopened; a `merged` pair is undone from Trash, not by
    /// reopening ("a merged pair is undone from Trash, not by
    /// reopening").
    public func reopenDuplicateCandidate(pCandidateId: UUID) async throws {
        try await callVoid(name: "reopen_duplicate_candidate", params: [
            "p_candidate_id": pCandidateId.uuidString,
        ])
    }
}

// MARK: - Held refunds

extension RPCClient {
    /// `resolve_held_refund(p_held_id, p_action, p_note)`
    /// (`merged-audit-held-release-atomic.sql:31-97`). Admin only;
    /// the held refund must still be pending — a second resolution
    /// fails with "held refund already resolved", carried through
    /// unchanged. The live UI only sends `release` (live.js:1855).
    public func resolveHeldRefund(
        pHeldId: UUID,
        pAction: HeldRefundAction,
        pNote: String
    ) async throws {
        try await callVoid(name: "resolve_held_refund", params: [
            "p_held_id": pHeldId.uuidString,
            "p_action": pAction.rawValue,
            "p_note": pNote,
        ])
    }
}

// MARK: - Extra Fund

extension RPCClient {
    /// `approve_and_allocate(p_request_id, p_amount_cents,
    /// p_override_reason)` — approve a fund request, in full or as a
    /// split (`approve-ambiguity-fix.sql:39-117`). Admin only; the
    /// request must be pending; `amount` must be positive and ≤ the
    /// requested amount. When the fund does not cover the amount the
    /// server raises "insufficient fund: available N cents" — the
    /// caller then retries with a typed `p_override_reason`, which is
    /// logged (live.js:1256-1262). A split leaves `remainder_cents`
    /// unapproved; the remainder needs a new request.
    public func approveAndAllocate(
        pRequestId: UUID,
        pAmountCents: Int,
        pOverrideReason: String?
    ) async throws {
        var params: [String: Any] = [
            "p_request_id": pRequestId.uuidString,
            "p_amount_cents": pAmountCents,
        ]
        // PostgREST matches by name; an explicit JSON null carries the
        // "no override" case exactly as live.js sends it.
        params["p_override_reason"] = pOverrideReason ?? NSNull()
        try await callVoid(name: "approve_and_allocate", params: params)
    }

    /// `decline_fund_request(p_request_id)` (`08-decline-fix.sql:13-30`).
    /// Admin only; an already-decided request raises
    /// "request already decided".
    public func declineFundRequest(pRequestId: UUID) async throws {
        try await callVoid(name: "decline_fund_request", params: [
            "p_request_id": pRequestId.uuidString,
        ])
    }

    /// `allocate_fund(p_household_id, p_amount_cents, p_note,
    /// p_override_reason)` — record fund spending directly
    /// (`fund-ledger.sql:152-170`). Admin only; same insufficient-fund
    /// + typed-override rule as `approveAndAllocate` (live.js:4677-4684).
    public func allocateFund(
        pHouseholdId: UUID,
        pAmountCents: Int,
        pNote: String,
        pOverrideReason: String?
    ) async throws {
        var params: [String: Any] = [
            "p_household_id": pHouseholdId.uuidString,
            "p_amount_cents": pAmountCents,
            "p_note": pNote,
        ]
        params["p_override_reason"] = pOverrideReason ?? NSNull()
        try await callVoid(name: "allocate_fund", params: params)
    }

    /// `add_fund_money(p_household_id, p_amount_cents, p_note,
    /// p_client_key)` — manual Extra Fund top-up (`r12-add-money.sql`).
    /// Admin only. Shortfall-first split, server-side: the top-up
    /// covers the fund shortfall first, the remainder increases
    /// spendable Available. Returns the split; `replayed: true`
    /// means this `p_client_key` was already used and the stored
    /// split was returned with no money moved. A retry of the same
    /// user action MUST reuse the same client key (live.js:4638-4640).
    public func addFundMoney(
        pHouseholdId: UUID,
        pAmountCents: Int,
        pNote: String,
        pClientKey: String
    ) async throws -> AddFundMoneyResult {
        try await call(name: "add_fund_money", params: [
            "p_household_id": pHouseholdId.uuidString,
            "p_amount_cents": pAmountCents,
            "p_note": pNote,
            "p_client_key": pClientKey,
        ])
    }

    /// `update_fund_shortfall(household_id, shortfall_cents)`
    /// (`update-fund-shortfall.sql:55-71`). Admin only; the shortfall
    /// must be non-negative. NOTE: the live UI never calls this — the
    /// shortfall is maintained server-side by `add_fund_money` and
    /// week-close. Included because the brief lists it; screens
    /// should not call it in normal flows.
    public func updateFundShortfall(householdId: UUID, shortfallCents: Int) async throws {
        try await callVoid(name: "update_fund_shortfall", params: [
            "household_id": householdId.uuidString,
            "shortfall_cents": shortfallCents,
        ])
    }

    /// `set_account_nickname(p_household_id, p_plaid_item_id,
    /// p_plaid_account_id, p_card_suffix, p_nickname)`
    /// (`r3-account-nicknames.sql:32-34`). Admin only. Pass `nil`
    /// for `p_nickname` to clear it; names are capped at 40 chars
    /// by the UI (live.js:1463).
    public func setAccountNickname(
        pHouseholdId: UUID,
        pPlaidItemId: String,
        pPlaidAccountId: String,
        pCardSuffix: String?,
        pNickname: String?
    ) async throws {
        var params: [String: Any] = [
            "p_household_id": pHouseholdId.uuidString,
            "p_plaid_item_id": pPlaidItemId,
            "p_plaid_account_id": pPlaidAccountId,
        ]
        params["p_card_suffix"] = pCardSuffix ?? NSNull()
        params["p_nickname"] = pNickname ?? NSNull()
        try await callVoid(name: "set_account_nickname", params: params)
    }
}

// MARK: - Allowances

extension RPCClient {
    /// `set_base_allowance(p_household_id, p_cents)`
    /// (`live-admin-rpcs.sql:71-82`). Admin only; non-negative.
    /// Applies from the current week onward; it does not rewrite
    /// closed weeks (live.js:4583-4602).
    public func setBaseAllowance(pHouseholdId: UUID, pCents: Int) async throws {
        try await callVoid(name: "set_base_allowance", params: [
            "p_household_id": pHouseholdId.uuidString,
            "p_cents": pCents,
        ])
    }

    /// `set_weekly_allowance_override(p_household_id, p_week_start,
    /// p_allowance_cents)` (`weekly-allowance-override.sql:79-101`).
    /// Admin only; `p_week_start` must be a Sunday; the allowance
    /// must be zero or positive. The amount is a NEW TOTAL weekly
    /// allowance for that week (not an extra on top of base). A
    /// stored close snapshot still wins over a later override.
    public func setWeeklyAllowanceOverride(
        pHouseholdId: UUID,
        pWeekStart: String,
        pAllowanceCents: Int
    ) async throws {
        try await callVoid(name: "set_weekly_allowance_override", params: [
            "p_household_id": pHouseholdId.uuidString,
            "p_week_start": pWeekStart,
            "p_allowance_cents": pAllowanceCents,
        ])
    }

    /// The Temporary Increase box (live.js:4555-4588): the new total
    /// repeats for `weeks` (1–4) consecutive Sunday weeks, one
    /// override row per week. Stops at the first failure and throws
    /// it — earlier weeks may already be written, exactly as the
    /// web client behaves.
    public func setWeeklyAllowanceOverride(
        pHouseholdId: UUID,
        firstWeekStart: String,
        pAllowanceCents: Int,
        weeks: Int
    ) async throws {
        let count = min(4, max(1, weeks))
        guard let first = Self.sunday(from: firstWeekStart) else {
            throw OnBudgetError.validationFailed("week_start must be a Sunday date (YYYY-MM-DD)")
        }
        for index in 0..<count {
            let weekStart = Self.dateString(from: first.addingTimeInterval(TimeInterval(index * 7 * 24 * 3600)))
            try await setWeeklyAllowanceOverride(
                pHouseholdId: pHouseholdId, pWeekStart: weekStart, pAllowanceCents: pAllowanceCents
            )
        }
    }

    private static func sunday(from dateString: String) -> Date? {
        // Week dates are plain calendar dates (no time, no zone).
        // Parse and take the weekday in UTC: parsing as UTC midnight
        // and then asking a US-zone calendar for the weekday would
        // shift the day back by 5 hours (Nov 8 00:00 UTC is Nov 7
        // 19:00 in New York — a Saturday). en_US_POSIX keeps the
        // "yyyy-MM-dd" parse stable across locales (notably Linux).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: dateString) else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        guard weekday == 1 else { return nil } // 1 = Sunday
        return calendar.startOfDay(for: date)
    }

    private static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

// MARK: - Charity

extension RPCClient {
    /// `set_charity_default_rate(p_household_id, p_rate_bp)`
    /// (`r13-charity.sql:126-149`). Admin only; 0–10000 bp
    /// (10000 = 100%). Future income only, unless explicitly
    /// correcting an old income.
    public func setCharityDefaultRate(pHouseholdId: UUID, pRateBp: Int) async throws {
        try await callVoid(name: "set_charity_default_rate", params: [
            "p_household_id": pHouseholdId.uuidString,
            "p_rate_bp": pRateBp,
        ])
    }

    /// `record_charity_income(p_household_id, p_amount_cents,
    /// p_income_date, p_source_label, p_rate_bp, p_note)`
    /// (`r13-charity.sql:151-190`). Admin only; amount positive;
    /// date ≥ 2026-11-01; rate 0–10000 bp (nil = household default).
    /// Returns the income id, the rate applied, and the committed cents.
    public func recordCharityIncome(
        pHouseholdId: UUID,
        pAmountCents: Int,
        pIncomeDate: String,
        pSourceLabel: String,
        pRateBp: Int?,
        pNote: String
    ) async throws -> CharityIncomeResult {
        var params: [String: Any] = [
            "p_household_id": pHouseholdId.uuidString,
            "p_amount_cents": pAmountCents,
            "p_income_date": pIncomeDate,
            "p_source_label": pSourceLabel,
            "p_note": pNote,
        ]
        params["p_rate_bp"] = pRateBp ?? NSNull()
        return try await call(name: "record_charity_income", params: params)
    }

    /// `correct_charity_income(p_income_id, p_amount_cents,
    /// p_income_date, p_source_label, p_rate_bp, p_note)`
    /// (`r13-charity.sql:194-239`). Admin only; the old income must
    /// still be active. Reverses the old row and inserts the corrected
    /// one. Returns the new income id, rate, and committed cents.
    public func correctCharityIncome(
        pIncomeId: UUID,
        pAmountCents: Int,
        pIncomeDate: String,
        pSourceLabel: String,
        pRateBp: Int?,
        pNote: String
    ) async throws -> CharityIncomeResult {
        var params: [String: Any] = [
            "p_income_id": pIncomeId.uuidString,
            "p_amount_cents": pAmountCents,
            "p_income_date": pIncomeDate,
            "p_source_label": pSourceLabel,
            "p_note": pNote,
        ]
        params["p_rate_bp"] = pRateBp ?? NSNull()
        return try await call(name: "correct_charity_income", params: params)
    }

    /// `record_charity_gift(p_household_id, p_merchant, p_amount_cents,
    /// p_date, p_card_suffix, p_note, p_dedupe_hash, p_client_key)`
    /// (`r13-charity.sql:255-317` / `r13-gift-idempotency.sql`).
    /// Admin only; amount positive; date ≥ 2026-11-01; suffix exactly
    /// 4 digits. `p_dedupe_hash` is SHA-256 hex of
    /// `"charity|\(date)|\(merchant)|\(amount)|\(suffix)|\(nonce)"`
    /// with a fresh UUID nonce per submit (live.js:4296); `p_client_key`
    /// is a UUID reused across retries of the same attempt
    /// (live.js:4299-4301). `replayed: true` means the gift was
    /// already recorded under that key.
    public func recordCharityGift(
        pHouseholdId: UUID,
        pMerchant: String,
        pAmountCents: Int,
        pDate: String,
        pCardSuffix: String,
        pNote: String,
        pDedupeHash: String,
        pClientKey: String
    ) async throws -> CharityGiftResult {
        try await call(name: "record_charity_gift", params: [
            "p_household_id": pHouseholdId.uuidString,
            "p_merchant": pMerchant,
            "p_amount_cents": pAmountCents,
            "p_date": pDate,
            "p_card_suffix": pCardSuffix,
            "p_note": pNote,
            "p_dedupe_hash": pDedupeHash,
            "p_client_key": pClientKey,
        ])
    }

    /// Convenience: build the gift dedupe hash for one submit, with a
    /// fresh nonce (live.js:4293-4296). The nonce is returned so the
    /// caller can keep it with the attempt for a retry.
    public static func charityGiftDedupeHash(
        date: String, merchant: String, amountCents: Int, cardSuffix: String
    ) -> (hash: String, nonce: String) {
        let nonce = UUID().uuidString
        let hash = SHA256.hex("charity|\(date)|\(merchant)|\(amountCents)|\(cardSuffix)|\(nonce)")
        return (hash, nonce)
    }
}

// MARK: - Household & members

extension RPCClient {
    /// `create_household(p_name)` (`signup-display-name.sql:102-143`).
    /// Returns the new household id. The caller must not already be
    /// in a household ("already in a household"). The name is REQUIRED
    /// by the app (live.js:2650-2660) — pass a non-empty name, max 80
    /// chars. NOTE: the older no-arg `create_household()` is
    /// superseded; live.js passes `{p_name}` (live.js:2661).
    public func createHousehold(pName: String) async throws -> UUID {
        try await callScalar(name: "create_household", params: ["p_name": pName])
    }

    /// `join_household_by_code(code)` (`n13-invite-rate-limit.sql:90-142`).
    /// Returns the household id, or nil when the code is invalid (the
    /// function logs the failed attempt and returns NULL instead of
    /// raising). The caller shows the same generic message either way:
    /// "Check the invite code and try again" (live.js:2706). Too many
    /// failed attempts raise "too many failed join attempts, try again
    /// later" (5/hour, all three buckets) — mapped to `.rateLimited`.
    public func joinHouseholdByCode(code: String) async throws -> UUID? {
        try await callOptionalScalar(name: "join_household_by_code", params: ["code": code])
    }

    /// `list_household_members()` (`signup-display-name.sql:207-236`).
    /// Every member of the CALLER's own household, in join order.
    /// Returns no full email — only `emailPrefix` as a name fallback.
    /// A caller in no household gets zero rows, never an error.
    public func listHouseholdMembers() async throws -> [MemberListRow] {
        try await call(name: "list_household_members", params: [:])
    }

    /// `remove_household_member(p_user_id)`
    /// (`household-roles-owner.sql` §3). OWNER ONLY since the Nov 11,
    /// 2026 roles decision; own household only; never yourself
    /// ("you cannot remove yourself"). The PR #57 "never the last
    /// admin" guard is gone: only the owner removes members, and the
    /// owner is always admin-capable, so no removal can strand the
    /// household without an admin.
    public func removeHouseholdMember(pUserId: UUID) async throws {
        try await callVoid(name: "remove_household_member", params: [
            "p_user_id": pUserId.uuidString,
        ])
    }

    /// `set_household_member_role(p_user_id, p_role)`
    /// (`household-roles-owner.sql` §4). Promote member -> admin
    /// (owner or admin may do it); demote admin -> member (OWNER
    /// ONLY). Refuses the owner's role, your own role, and roles
    /// outside 'admin'/'member'. Idempotent: already-that-role is a
    /// silent success.
    public func setHouseholdMemberRole(pUserId: UUID, pRole: HouseholdRole) async throws {
        try await callVoid(name: "set_household_member_role", params: [
            "p_user_id": pUserId.uuidString,
            "p_role": pRole.rawValue,
        ])
    }
}
