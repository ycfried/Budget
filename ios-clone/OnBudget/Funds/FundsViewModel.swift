import Foundation
import SwiftUI
import OnBudgetKit

/// View model for the Funds tab, the Review area, and Trash
/// (live web v66, CLONE_SPEC §§9, 11).
///
/// The server is authoritative for every figure: week math comes from
/// compute-week (not used here), fund/charity figures are display
/// aggregations over rows the server computed (`FundSummary` /
/// `CharitySummary`), and every refusal is shown through
/// `OnBudgetError.displayMessage` — the specific refusals keep their
/// plain text; raw server text is mapped to a generic line, never
/// shown (owner report, Nov 11, 2026).
///
/// TWO SERVER DEFECTS that affected these screens were fixed live
/// in web PR #62 (Nov 9, 2026) and the native was built to the
/// intended behaviour from the start, so no clone change was needed:
/// 1. Merged duplicates now record `pre_exclusion_state` and can be
///    restored from Trash. 2. Held refunds are released on
///    `status='held'` (the CHECK's releasable state); this UI still
///    treats `held` AND `pending` as releasable so a legacy 'pending'
///    row, if one ever appears, is not stranded. A server refusal
///    surfaces verbatim in an alert.
@MainActor
public final class FundsViewModel: ObservableObject {
    public let context: FundsContext

    // MARK: - Load state

    @Published public var isLoading = false
    /// Which action is in flight (per-row busy state + double-tap guard).
    @Published public var busyAction: String?
    @Published public var toast: Toast?
    @Published public var alertTitle: String?
    @Published public var alertMessage: String?

    // MARK: - Fund balances

    @Published public var fundSummary: FundSummary?
    @Published public var fundError: String?

    // MARK: - Top-ups (admin, read-only history)

    @Published public var topups: [FundTopup] = []
    @Published public var topupsError: String?

    // MARK: - Charity

    @Published public var charitySummary: CharitySummary?
    @Published public var charitySettings: CharitySettings?
    @Published public var charityError: String?
    @Published public var charityIncome: [CharityIncome] = []
    @Published public var charityIncomeError: String?

    // MARK: - Fund requests

    @Published public var fundRequests: [FundRequest] = []
    @Published public var fundRequestsError: String?

    // MARK: - Savings (read-only)

    @Published public var savings: [SavingsLedgerEntry] = []
    @Published public var savingsError: String?

    // MARK: - Review (admin)

    @Published public var restorations: [RestorationEntry] = []
    @Published public var restorationsError: String?
    @Published public var heldRefunds: [HeldRefund] = []
    @Published public var heldError: String?
    @Published public var pendingDuplicates: [DuplicateCandidate] = []
    @Published public var duplicateTransactions: [UUID: Transaction] = [:]
    @Published public var duplicatesError: String?
    @Published public var resolvedDuplicates: [DuplicateCandidate] = []
    @Published public var resolvedError: String?
    @Published public var refundSuggestions: [RefundSuggestion] = []
    @Published public var hasUnlinkedRefunds = false
    @Published public var refundLinksError: String?

    // MARK: - Transactions (whole history, for Trash / charity / suggestions)

    @Published public var allTransactions: [Transaction] = []
    @Published public var transactionsError: String?

    // MARK: - Allowance (Temporary Allowance preview)

    @Published public var baseAllowanceCents: Int?
    @Published public var allowanceExplicitlySet = false
    /// Non-nil when the base allowance failed to load, so the
    /// Temporary Allowance form can say so with a retry instead of
    /// showing a bare amount field with no preview (F-P2-14).
    @Published public var allowanceError: String?

    /// Client key for the in-flight top-up, reused across retries of
    /// the same attempt (idempotency — live.js:4638-4640).
    private var topupClientKey: String?

    public init(context: FundsContext) {
        self.context = context
    }

    // MARK: - Derived

    /// Review badge count: pending held refunds + pending duplicate
    /// pairs + refund-link suggestions (spec §9.2).
    public var reviewCount: Int {
        pendingHeldRefunds.count + pendingDuplicates.count + refundSuggestions.count
    }

    /// Held rows still awaiting a decision. The live CHECK stores
    /// `held`; the pre-fix web code stored `pending` — both mean
    /// "awaiting decision" and both get a Release button.
    public var pendingHeldRefunds: [HeldRefund] {
        heldRefunds.filter { $0.status == "held" || $0.status == "pending" }
    }

    /// Trash rows: excluded rows only, from the same load as
    /// Transactions (spec §11).
    public var trashRows: [Transaction] {
        allTransactions.filter { $0.isInTrash }
    }

    /// Shortfall-first split preview for a top-up amount (informational
    /// only — the server split from `add_fund_money` is authoritative).
    /// Returns (covered owed back, added to fund, owed back after).
    public func topupPreview(amountCents: Int) -> (covered: Int, added: Int, after: Int)? {
        guard let shortfall = fundSummary?.shortfallCents else { return nil }
        let covered = min(amountCents, shortfall)
        return (covered: covered, added: amountCents - covered, after: shortfall - covered)
    }

    // MARK: - Refresh

    /// Loads every section. Each section fails independently (a failed
    /// read is an error state, never a silent empty list or stale
    /// numbers — spec §0.3): failed fund/charity data is cleared.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await loadTransactions()
        await loadFund()
        await loadTopups()
        await loadCharity()
        await loadRequests()
        await loadSavings()
        await loadReview()
        await loadAllowance()
    }

    private func loadTransactions() async {
        do {
            allTransactions = try await context.client.postgrest.fetchAllPages(
                PostgrestQuery(
                    table: "transactions",
                    columns: "*",
                    filters: [.householdId(context.householdId), .onOrAfterNov1()],
                    orders: [PostgrestOrder("date", ascending: false)]
                )
            )
            transactionsError = nil
        } catch {
            allTransactions = []
            transactionsError = userMessage(for: error)
        }
    }

    private func loadFund() async {
        do {
            let ledger = try await context.client.postgrest.fundLedger(householdId: context.householdId)
            let releases = try await context.client.postgrest.surplusReleases(householdId: context.householdId)
            let shortfall = try await context.client.postgrest.fundShortfallCents(householdId: context.householdId)
            fundSummary = FundSummary.compute(ledger: ledger, releases: releases, shortfallCents: shortfall)
            fundError = nil
        } catch {
            fundSummary = nil
            fundError = "Could not load fund balances. Try again."
        }
    }

    private func loadTopups() async {
        guard context.isAdmin else { topups = []; topupsError = nil; return }
        do {
            topups = try await context.client.postgrest.fundTopups(householdId: context.householdId)
            topupsError = nil
        } catch {
            topups = []
            topupsError = "Could not load money added. Try again."
        }
    }

    private func loadCharity() async {
        do {
            let income = try await context.client.postgrest.activeCharityIncome(householdId: context.householdId)
            let settings = try await context.client.postgrest.charitySettings(householdId: context.householdId)
            let given = try await context.client.postgrest.verifiedCharityGiftAmounts(householdId: context.householdId)
            let defaultRate = settings?.defaultRateBp ?? 1000
            let charityRows = allTransactions.filter { $0.kind == .charity && !$0.excluded && $0.date >= MoneyFormat.dataFloor }
            // Given counts only verified gifts; pending gifts count once
            // they post (live.js:3814-3820). Committed sums each ACTIVE
            // income row at that row's own rate.
            charitySummary = CharitySummary(
                committedCents: income.filter { $0.status == "active" }.reduce(0) { $0 + $1.committedCents },
                givenCents: given.reduce(0, +),
                pendingGiftCents: charityRows.filter { $0.state == .provisional }.reduce(0) { $0 + $1.amountCents },
                defaultRateBp: defaultRate
            )
            charitySettings = settings
            charityError = nil
        } catch {
            charitySummary = nil
            charitySettings = nil
            charityError = "Could not load charity. Try again."
        }
        guard context.isAdmin else { charityIncome = []; charityIncomeError = nil; return }
        do {
            charityIncome = try await context.client.postgrest.charityIncomeHistory(householdId: context.householdId)
            charityIncomeError = nil
        } catch {
            charityIncome = []
            charityIncomeError = "Could not load income. Try again."
        }
    }

    private func loadRequests() async {
        do {
            fundRequests = try await context.client.postgrest.fundRequests(householdId: context.householdId)
            fundRequestsError = nil
        } catch {
            fundRequests = []
            fundRequestsError = "Could not load fund requests. Try again."
        }
    }

    private func loadSavings() async {
        do {
            savings = try await context.client.postgrest.savingsLedger(householdId: context.householdId)
            savingsError = nil
        } catch {
            savings = []
            savingsError = "Could not load savings. Try again."
        }
    }

    private func loadReview() async {
        guard context.isAdmin else {
            restorations = []; heldRefunds = []; pendingDuplicates = []
            duplicateTransactions = [:]; resolvedDuplicates = []; refundSuggestions = []
            return
        }
        await loadRestorationsAndHeld()
        await loadDuplicates()
        await loadRefundSuggestions()
    }

    private func loadRestorationsAndHeld() async {
        do {
            restorations = try await context.client.postgrest.restorationEntries(householdId: context.householdId)
            restorationsError = nil
        } catch {
            restorations = []
            restorationsError = "Could not load restorations. Try again."
        }
        do {
            heldRefunds = try await context.client.postgrest.heldRefunds(householdId: context.householdId)
            heldError = nil
        } catch {
            heldRefunds = []
            heldError = "Could not load held refunds. Try again."
        }
    }

    private func loadDuplicates() async {
        do {
            let candidates = try await context.client.postgrest.pendingDuplicateCandidates(householdId: context.householdId)
            pendingDuplicates = candidates
            duplicatesError = nil
            let ids = Array(Set(candidates.flatMap { [$0.canonicalTransactionId, $0.duplicateTransactionId] }))
            if !ids.isEmpty {
                // `*`: Transaction has non-optional fields a narrow
                // column list cannot decode (same reason as refundRows).
                let rows: [Transaction] = try await context.client.postgrest.fetch(
                    PostgrestQuery(
                        table: "transactions",
                        columns: "*",
                        filters: [.in("id", ids.map { $0.uuidString })]
                    )
                )
                duplicateTransactions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            } else {
                duplicateTransactions = [:]
            }
        } catch {
            pendingDuplicates = []
            duplicateTransactions = [:]
            duplicatesError = "Could not load possible duplicates. Try again."
        }
        do {
            resolvedDuplicates = try await context.client.postgrest.resolvedDuplicateCandidates(householdId: context.householdId)
            resolvedError = nil
        } catch {
            resolvedDuplicates = []
            resolvedError = "Could not load resolved duplicates. Try again."
        }
    }

    private func loadRefundSuggestions() async {
        do {
            let refunds = allTransactions.filter {
                $0.kind == .refund && $0.originalPurchaseId == nil && !$0.excluded
                    && $0.state != .excluded && $0.state != .reversed
            }
            hasUnlinkedRefunds = !refunds.isEmpty
            let purchases = allTransactions.filter {
                ($0.kind == .charge || $0.kind == .fundCharge) && !$0.excluded
                    && $0.state != .excluded && $0.state != .reversed
            }
            let aliases = try await context.client.postgrest.merchantAliases(householdId: context.householdId)
            let dismissals = (try? await context.client.postgrest.refundLinkDismissals(householdId: context.householdId)) ?? []
            var linkedTotals: [UUID: Int] = [:]
            for row in allTransactions where row.kind == .refund {
                if let purchaseId = row.originalPurchaseId, !row.excluded,
                   row.state != .excluded, row.state != .reversed {
                    linkedTotals[purchaseId, default: 0] += abs(row.amountCents)
                }
            }
            refundSuggestions = RefundSuggestions.compute(
                refunds: refunds, purchases: purchases,
                aliases: aliases, dismissals: dismissals, linkedTotals: linkedTotals
            )
            refundLinksError = nil
        } catch {
            refundSuggestions = []
            refundLinksError = "Could not load refund link suggestions. Try again."
        }
    }

    private func loadAllowance() async {
        do {
            let allowance = try await context.client.postgrest.householdAllowance(householdId: context.householdId)
            baseAllowanceCents = allowance.baseAllowanceCents
            allowanceExplicitlySet = allowance.allowanceExplicitlySet
            allowanceError = nil
        } catch {
            baseAllowanceCents = nil
            allowanceExplicitlySet = false
            allowanceError = "Could not load your current allowance. Try again."
        }
    }

    /// Retry just the allowance load (Temporary Allowance error state).
    public func reloadAllowance() async {
        await loadAllowance()
    }

    // MARK: - Errors / toasts

    public func userMessage(for error: Error) -> String {
        OnBudgetError.displayMessage(for: error)
    }

    private func fail(title: String, error: Error) {
        alertTitle = title
        alertMessage = userMessage(for: error)
    }

    private func succeed(_ message: String) {
        toast = Toast(message: message, kind: .success)
    }

    /// Runs an action with the double-tap guard: the submit button is
    /// disabled before any awaited network call (spec §2.3).
    private func guarded(_ key: String, title: String = "Could Not Complete", work: () async throws -> Void) async {
        guard busyAction == nil else { return }
        busyAction = key
        defer { busyAction = nil }
        do {
            try await work()
        } catch {
            fail(title: title, error: error)
        }
    }

    // MARK: - Add Money (top-up, admin only)

    /// Shortfall-first top-up via `add_fund_money`. The server split is
    /// authoritative; the client preview is informational only. The
    /// client key is reused across retries of the same attempt.
    /// Returns true only when the save committed, so the form can
    /// clear and close on success — a failed save must leave the
    /// typed input in place (F-P1-3/F-P1-4).
    public func addTopup(amountCents: Int, note: String) async -> Bool {
        guard busyAction == nil else { return false }
        busyAction = "topup"
        defer { busyAction = nil }
        if topupClientKey == nil { topupClientKey = UUID().uuidString }
        do {
            let result = try await context.client.rpcs.addFundMoney(
                pHouseholdId: context.householdId,
                pAmountCents: amountCents,
                pNote: note,
                pClientKey: topupClientKey ?? UUID().uuidString
            )
            topupClientKey = nil
            succeed("Top-up saved: \(MoneyFormat.formatCents(result.shortfallCoveredCents)) covered owed back, \(MoneyFormat.formatCents(result.fundAddedCents)) added to fund.")
            await refresh()
            return true
        } catch {
            fail(title: "Could Not Save Top-Up", error: error)
            return false
        }
    }

    // MARK: - Use Fund Money (admin only)

    /// Direct fund spend via `allocate_fund`. On "insufficient fund"
    /// the caller offers the typed-reason override path and retries
    /// with `overrideReason` — this method surfaces the
    /// `.insufficientFund` case to the caller instead of alerting, so
    /// the view can present that sheet (live.js:4677-4684).
    public func allocateFund(amountCents: Int, note: String, overrideReason: String?) async throws {
        try await context.client.rpcs.allocateFund(
            pHouseholdId: context.householdId,
            pAmountCents: amountCents,
            pNote: note,
            pOverrideReason: overrideReason
        )
        succeed("Fund spending recorded.")
        await refresh()
    }

    // MARK: - Ask for Fund Money (all roles)

    /// Inserts a pending `fund_requests` row; audits
    /// "Extra Fund request created" (best-effort — a blocked audit
    /// insert must not fail the request itself).
    /// Returns true only when the request was sent, so the caller
    /// clears the typed input on success only (F-P1-4).
    public func createFundRequest(amountCents: Int, note: String, transactionId: UUID?) async -> Bool {
        var succeeded = false
        await guarded("request", title: "Could Not Send Request") {
            _ = try await context.client.postgrest.createFundRequest(
                householdId: context.householdId,
                requestedBy: context.userId,
                amountCents: amountCents,
                note: note,
                transactionId: transactionId
            )
            do {
                let name = (try? await context.client.getUser())?.displayName ?? "Household member"
                try await context.client.postgrest.appendAudit(AuditLogInsert(
                    householdId: context.householdId,
                    actor: context.userId,
                    actorName: name,
                    action: "Extra Fund request created",
                    detail: "\(MoneyFormat.formatCents(amountCents)) requested."
                ))
            } catch {
                // Audit is best-effort only.
            }
            succeeded = true
            succeed("Request sent.")
            await refresh()
        }
        return succeeded
    }

    /// Approve (in full or as a split) via `approve_and_allocate`.
    /// Throws `.insufficientFund` so the view can offer the
    /// typed-reason override retry (live.js:1256-1262).
    public func approveRequest(_ request: FundRequest, amountCents: Int, overrideReason: String?) async throws {
        try await context.client.rpcs.approveAndAllocate(
            pRequestId: request.id,
            pAmountCents: amountCents,
            pOverrideReason: overrideReason
        )
        await refresh()
    }

    public func declineRequest(_ request: FundRequest) async {
        await guarded("decline-\(request.id.uuidString)", title: "Could Not Decline") {
            try await context.client.rpcs.declineFundRequest(pRequestId: request.id)
            await refresh()
        }
    }

    // MARK: - Charity Income & Rate (admin only)

    public func setDefaultRate(basisPoints: Int) async {
        await guarded("rate", title: "Could Not Save Rate") {
            try await context.client.rpcs.setCharityDefaultRate(
                pHouseholdId: context.householdId, pRateBp: basisPoints
            )
            succeed("Default charity rate saved: \(MoneyFormat.formatRateBp(basisPoints))% for future incomes.")
            await refresh()
        }
    }

    /// New income via `record_charity_income`, or a correction via
    /// `correct_charity_income` (append-only reversal + replacement;
    /// the old entry stays, marked reversed).
    /// Returns true only when the save committed, so the caller
    /// clears the typed input on success only (F-P1-4).
    public func saveIncome(
        correcting income: CharityIncome?,
        amountCents: Int,
        date: String,
        sourceLabel: String,
        rateBp: Int?,
        note: String
    ) async -> Bool {
        var succeeded = false
        await guarded("income", title: "Could Not Save Income") {
            let result: CharityIncomeResult
            if let income {
                result = try await context.client.rpcs.correctCharityIncome(
                    pIncomeId: income.id,
                    pAmountCents: amountCents,
                    pIncomeDate: date,
                    pSourceLabel: sourceLabel,
                    pRateBp: rateBp,
                    pNote: note
                )
                succeed("Income corrected — now commits \(MoneyFormat.formatCents(result.committedCents)). The old entry stays, marked reversed.")
            } else {
                result = try await context.client.rpcs.recordCharityIncome(
                    pHouseholdId: context.householdId,
                    pAmountCents: amountCents,
                    pIncomeDate: date,
                    pSourceLabel: sourceLabel,
                    pRateBp: rateBp,
                    pNote: note
                )
                succeed("Income saved — commits \(MoneyFormat.formatCents(result.committedCents)) to charity.")
            }
            succeeded = true
            await refresh()
        }
        return succeeded
    }

    /// Remove the weekly allowance override(s) for the current week
    /// onward (up to 4 weeks — the Temporary Allowance range) via
    /// `remove_weekly_allowance_override`, so the base allowance
    /// applies again for those weeks.
    /// NOTE: until `supabase/remove-weekly-allowance-override.sql`
    /// is applied live the RPC does not exist and this fails with a
    /// plain-language error; nothing is changed.
    public func removeTemporaryAllowance(weeks: Int = 4) async {
        await guarded("remove-temp", title: "Could Not Remove Override") {
            try await context.client.rpcs.removeWeeklyAllowanceOverride(
                pHouseholdId: context.householdId,
                firstWeekStart: MoneyFormat.currentSundayNY(),
                weeks: weeks
            )
            succeed("Weekly allowance override removed — the base allowance applies again.")
            await refresh()
        }
    }

    // MARK: - Review: held refunds

    /// Release a held refund via `resolve_held_refund`
    /// (`p_action='release'`). Web PR #62 fixed the server live
    /// Nov 9, 2026: the releasable state is `status='held'`
    /// (matching the live held_refunds CHECK); the repo copy of the
    /// function in `supabase/merged-audit-held-release-atomic.sql`
    /// is synced to that fix on this branch. The earlier "LIVE
    /// DEFECT" note claiming the server still expects 'pending'
    /// was stale — this branch's SQL copy predated the PR #62 merge,
    /// not a live refusal. A server refusal still surfaces verbatim
    /// in an alert. Live verification in the test household is still
    /// owed (no live check was possible from here).
    public func releaseHeldRefund(_ held: HeldRefund) async {
        await guarded("release-\(held.id.uuidString)", title: "Could Not Release") {
            try await context.client.rpcs.resolveHeldRefund(
                pHeldId: held.id, pAction: .release, pNote: ""
            )
            await refresh()
        }
    }

    // MARK: - Review: duplicates

    /// Merge (Same Purchase) or separate via
    /// `resolve_duplicate_candidate`. Merge keeps the canonical row
    /// and excludes the duplicate — it NEVER deletes a row.
    public func resolveDuplicate(
        _ candidate: DuplicateCandidate,
        action: DuplicateResolutionAction,
        rememberAlias: Bool
    ) async {
        await guarded("dedupe-\(candidate.id.uuidString)", title: "Could Not Resolve") {
            try await context.client.rpcs.resolveDuplicateCandidate(
                pCandidateId: candidate.id,
                pAction: action,
                pNote: "",
                pRememberAlias: rememberAlias
            )
            await refresh()
        }
    }

    public func reopenDuplicate(_ candidate: DuplicateCandidate) async {
        await guarded("reopen-\(candidate.id.uuidString)", title: "Could Not Reopen") {
            try await context.client.rpcs.reopenDuplicateCandidate(pCandidateId: candidate.id)
            await refresh()
        }
    }

    // MARK: - Review: refund links

    public func linkRefund(_ suggestion: RefundSuggestion) async {
        await guarded("link-\(suggestion.id)", title: "Could Not Link") {
            _ = try await context.client.rpcs.linkRefund(
                pRefundId: suggestion.refund.id,
                pPurchaseId: suggestion.purchase.id
            )
            succeed("Refund linked to its purchase.")
            await refresh()
        }
    }

    /// Dismissals stick — a dismissed pair is never suggested again.
    /// There is NO undismiss: a wrongly dismissed pair can still be
    /// hand-linked from Actions → Link to Purchase.
    public func dismissSuggestion(_ suggestion: RefundSuggestion) async {
        await guarded("dismiss-\(suggestion.id)", title: "Could Not Dismiss") {
            try await context.client.rpcs.dismissRefundLinkSuggestion(
                pRefundId: suggestion.refund.id,
                pPurchaseId: suggestion.purchase.id
            )
            await refresh()
        }
    }

    // MARK: - Trash

    /// Restore via `restore_transaction`: returns the row to its stored
    /// prior state (verified / provisional / reversed). A NULL
    /// prior-state snapshot refuses with "cannot restore: no prior
    /// state recorded", surfaced verbatim.
    public func restoreTransaction(_ transaction: Transaction) async {
        await guarded("restore-\(transaction.id.uuidString)", title: "Could Not Restore") {
            try await context.client.rpcs.restoreTransaction(txnId: transaction.id)
            succeed("Transaction restored.")
            await refresh()
        }
    }

    // MARK: - Temporary Allowance (admin only)

    /// The amount is a NEW TOTAL weekly allowance, REPEATING each week
    /// for the chosen 1–4 weeks — not a total split across weeks
    /// (owner, Nov 4). One `set_weekly_allowance_override` row per
    /// week via the kit's multi-week helper; never `add_temp_increase`
    /// (revoked live Nov 9, 2026).
    /// Returns true only when the override was set, so the caller
    /// clears the typed input on success only (F-P1-4).
    public func setTemporaryAllowance(newTotalCents: Int, weeks: Int) async -> Bool {
        var succeeded = false
        await guarded("temp", title: "Could Not Set Allowance") {
            try await context.client.rpcs.setWeeklyAllowanceOverride(
                pHouseholdId: context.householdId,
                firstWeekStart: MoneyFormat.currentSundayNY(),
                pAllowanceCents: newTotalCents,
                weeks: weeks
            )
            succeeded = true
            succeed("Weekly allowance set to \(MoneyFormat.formatCents(newTotalCents)) for \(weeks) week(s).")
            await refresh()
        }
        return succeeded
    }
}
