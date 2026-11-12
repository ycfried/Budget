import Foundation
import SwiftUI
import OnBudgetKit

/// View model for the Transactions screens (list, filters, detail,
/// actions, Add Purchase / Add Donation, Trash).
///
/// Wiring — every call goes through the typed `OnBudgetKit` API client:
/// - List: `client.postgrest.transactionsPage(householdId:pageSize:)`
///   (fetch `limit + 1`; the probe row proves whether older rows exist).
/// - Manual sync (admin only): `client.functions.plaidSyncAllowingPartialFailure(householdId:)`.
/// - Charity: `client.rpcs.markTransactionCharity(pTransactionId:)`.
/// - Reclassify: `client.rpcs.reclassifyTransaction(txnId:newKind:reason:)`.
/// - Link / unlink refund: `client.rpcs.linkRefund(pRefundId:pPurchaseId:)`
///   / `client.rpcs.unlinkRefund(pRefundId:)`; candidates are read with
///   `client.postgrest.refundLinkCandidates(...)`.
/// - Delete (hand-written, permanent): `client.rpcs.deleteTransaction(pTransactionId:)`.
/// - Exclude (bank/email/file → Trash): `client.rpcs.excludeTransaction(txnId:reason:)`.
/// - Restore from Trash: `client.rpcs.restoreTransaction(txnId:)`.
/// - Extra Fund request: `client.postgrest.createFundRequest(...)`.
/// - Manual purchase: `client.postgrest.insertTransactions([ManualTransactionInsert])`.
/// - Donation: `client.rpcs.recordCharityGift(...)` (8-arg, idempotent
///   via `p_client_key`; dedupe hash carries a fresh nonce per submit).
/// - Allowance-set state (sync-button treatment):
///   `client.postgrest.householdAllowance(householdId:)`.
///
/// Server refusals are shown through `error.displayMessage` — the
/// specific refusals (week-locked, admin-only, …) keep their plain
/// text; raw server/transport text is mapped to a generic line, never
/// shown (owner report, Nov 11, 2026). Two server defects that affected these
/// screens were fixed live in web PR #62 (Nov 9, 2026) and the native
/// was built to the intended behaviour from the start, so no clone
/// change was needed: (1) merged duplicates now record
/// `pre_exclusion_state` and can be restored from Trash; (2) held
/// refunds release on `status='held'`. A refusal surfaces verbatim.
///
/// All figures displayed are server figures; the client never
/// recomputes week math. The list total is a display sum over the
/// shown rows only (see `TransactionFilters.shownTotal`).
@MainActor
@Observable
public final class TransactionsViewModel {

    // MARK: - Identity (supplied by the app shell — Auth/Home own them)

    public let client: SupabaseClient
    public let householdId: UUID
    public let isAdmin: Bool
    public let currentUserId: UUID?
    /// Called when the list load fails with a dead session — the shell
    /// signs the user out to the sign-in panel ("Sign In Again").
    public var onSignInAgain: (() -> Void)?

    // MARK: - List state

    /// Raw loaded page (up to `pageSize` rows, date desc). Filters
    /// apply client-side; Trash rows live here too.
    public private(set) var loadedPage: [Transaction] = []
    public private(set) var loadState: LoadState<[Transaction]> = .idle
    /// Page size: 100, +100 per Load More tap (live.js `txLimit`).
    public private(set) var pageSize: Int = 100
    /// True exactly when the probe row came back (older rows exist).
    public private(set) var hasMore: Bool = false
    /// Whether the $375 schema-default allowance was ever explicitly
    /// set — the sync button is primary blue only when it was set.
    public private(set) var allowanceSet: Bool = false
    /// Card suffix → institution name (best-effort, for bank icons —
    /// the same map Home builds in `refresh()`). Nil suffixes fall
    /// back to the merchant icon.
    public private(set) var institutionBySuffix: [String: String] = [:]

    public var filters = TransactionFilters()
    /// Bumped whenever the search box must clear with the filters
    /// (T-P1-1): the box is local @State in TransactionsView, so the
    /// view watches this and clears it — the box and the list can
    /// never disagree after a clear, a Past Weeks jump, or a Home
    /// row jump.
    public var searchResetNonce: Int = 0
    public var expandedTransactionId: UUID?
    public var isSyncing: Bool = false
    public var isSaving: Bool = false

    /// Alert-style failures (the web's soft-red `showAlert`): title +
    /// server message, shown verbatim.
    public var alertTitle: String?
    public var alertMessage: String?
    public var showAlert: Bool = false

    public let toastManager = ToastManager()

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    // MARK: - Persistence keys (live.js localStorage keys)

    private static let sortKey = "hb-tx-sort"
    private static let monthKey = "hb-tx-month"
    private static let cardKey = "hb-tx-card"

    public init(
        client: SupabaseClient,
        householdId: UUID,
        isAdmin: Bool,
        currentUserId: UUID? = nil
    ) {
        self.client = client
        self.householdId = householdId
        self.isAdmin = isAdmin
        self.currentUserId = currentUserId
        if let savedSort = UserDefaults.standard.string(forKey: Self.sortKey),
           let sort = TransactionSort(rawValue: savedSort) {
            filters.sort = sort
        }
        if let savedMonth = UserDefaults.standard.string(forKey: Self.monthKey) {
            filters.month = savedMonth
        }
        if let savedCard = UserDefaults.standard.string(forKey: Self.cardKey) {
            filters.card = savedCard
        }
    }

    // MARK: - Derived list

    /// The filtered, sorted rows actually shown (excluded rows never
    /// appear here). The page is the first `pageSize` rows of the
    /// fetched page (live.js: `all` = fetched rows sliced to
    /// `txLimit`); filters then apply client-side to that page.
    public var shownTransactions: [Transaction] {
        filters.apply(to: Array(loadedPage.prefix(pageSize)))
    }

    /// Trashed rows, from the same load as Transactions (live.js §11).
    public var trashTransactions: [Transaction] {
        Array(loadedPage.prefix(pageSize)).filter(\.isInTrash)
    }

    public var monthsPresent: [String] {
        TransactionFilters.months(in: Array(loadedPage.prefix(pageSize)))
    }

    public var cardsPresent: [String] {
        TransactionFilters.cards(in: Array(loadedPage.prefix(pageSize)))
    }

    /// The count line (live.js:863-886, wording per owner Nov 12,
    /// 2026 — "Total", not "Total shown"): "`N` transactions ·
    /// Total `$X`" (+ the older-rows suffix when the probe row came
    /// back). On failure the line is empty — the error box below
    /// already says it (T-P2-11: one failure message, not two
    /// stacked). The min>max text outranks a zero total.
    public var countLine: String {
        if case .failed = loadState {
            return ""
        }
        if filters.amountRangeInvalid {
            return "Minimum amount is above the maximum amount — change one of them to see transactions."
        }
        let shown = shownTransactions
        if shown.isEmpty, filters.isSearchOrFilterActive {
            return "No matching transactions — try a different search, or clear the search and filters."
        }
        let total = TransactionFilters.shownTotal(for: shown, status: filters.status)
        let suffix = hasMore ? " · of loaded transactions — tap Load more for older ones" : ""
        // A negative net total is money in overall, so it reads
        // "+$X" (MoneyFormat.netTotalText); the line stays muted —
        // the total is a summary, not a row.
        return "\(shown.count) transactions · Total \(MoneyFormat.netTotalText(cents: total))\(suffix)"
    }

    /// Whether the viewer has any action on a row (live.js:982):
    /// admin sees Actions on every row; a member only Extra Fund on
    /// charges.
    public func hasActions(for transaction: Transaction) -> Bool {
        if isAdmin { return true }
        return transaction.kind == .charge && !transaction.isInTrash
    }

    // MARK: - Loading

    /// First load / pull-to-refresh / retry. A failed read is an
    /// error state, never a silent empty list or an endless spinner
    /// (the web app has a live "Loading…" hang; the clone must not
    /// copy it). Requests time out at 30s server-side in the client.
    public func load() async {
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.loadState = .loading
            do {
                let (rows, hasMore) = try await self.client.postgrest.transactionsPage(
                    householdId: self.householdId,
                    pageSize: self.pageSize
                )
                guard !Task.isCancelled else { return }
                self.loadedPage = rows
                self.hasMore = hasMore
                self.loadState = .loaded(rows)
                await self.loadAllowanceState()
                await self.loadInstitutionMap()
            } catch let error as OnBudgetError {
                guard !Task.isCancelled else { return }
                self.loadedPage = []
                self.hasMore = false
                self.loadState = .failed(error)
            } catch {
                // Same as the OnBudgetError catch above: a failed load
                // clears the list (PR #64 Fix 2 — a load failure must
                // never leave stale rows on screen).
                guard !Task.isCancelled else { return }
                self.loadedPage = []
                self.hasMore = false
                self.loadState = .failed(.unknown(error.localizedDescription))
            }
        }
        loadTask = task
        await task.value
    }

    /// Every filter / search / sort change is a new list: the page
    /// resets to 100 (live.js `resetTxLimit`). Filtering is
    /// client-side over the loaded page, so this needs no refetch —
    /// the page is re-sliced from the rows already loaded.
    public func resetPage() {
        pageSize = 100
    }

    /// Load More: +100 per tap, then reload (live.js:888-900).
    public func loadMore() async {
        pageSize += 100
        await load()
    }

    /// Search is debounced 250ms; a new search resets the page to 100
    /// (live.js:4490-4497). Searches loaded transactions only.
    public func applySearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.filters.search = text
            self.resetPage()
        }
    }

    /// "Clear Search and Filters": resets every filter to default and
    /// re-renders (live.js:1033-1042). Also bumps `searchResetNonce`
    /// so the visible search box clears with the filters (T-P1-1) —
    /// the Past Weeks and Home-row jumps call this first, so they
    /// clear the box too.
    public func clearSearchAndFilters() {
        filters = TransactionFilters()
        persistFilters()
        resetPage()
        searchResetNonce += 1
    }

    /// Past Weeks / Weekly-sheet jump (live.js:3457-3500): clear
    /// search/filters first, then show only the Sun–Sat week starting
    /// `weekStart`. The shell clears `pendingWeekFilter` once consumed.
    public func applyWeekFilter(weekStart: String) {
        clearSearchAndFilters()
        filters.fromDate = weekStart
        filters.toDate = MoneyFormat.weekEndString(weekStart: weekStart) ?? weekStart
        filterChanged()
    }

    /// Recent-row jump (live.js:1040-1110): clear search/filters
    /// first, then expand the row — when it is in the loaded page.
    /// Otherwise the shell's exact toast: the row is not loaded yet.
    public func applyTransactionJump(_ id: UUID) {
        clearSearchAndFilters()
        if loadedPage.contains(where: { $0.id == id }) {
            expandedTransactionId = id
        } else {
            toastManager.show("That transaction is not in the loaded list — tap Load more for older ones.", kind: .info)
        }
    }

    /// Apply a filter change that resets the page (status / month /
    /// card / week / dates / bounds / sort). Client-side only — no
    /// refetch; the list re-renders from the loaded page.
    public func filterChanged() {
        persistFilters()
        resetPage()
    }

    public func persistFilters() {
        UserDefaults.standard.set(filters.sort.rawValue, forKey: Self.sortKey)
        UserDefaults.standard.set(filters.month, forKey: Self.monthKey)
        UserDefaults.standard.set(filters.card, forKey: Self.cardKey)
    }

    private func loadAllowanceState() async {
        do {
            let allowance = try await client.postgrest.householdAllowance(householdId: householdId)
            allowanceSet = allowance.allowanceExplicitlySet
        } catch {
            // Allowance state is presentation-only (sync-button
            // treatment); a failed read leaves the button grey.
            allowanceSet = false
        }
    }

    /// Suffix → institution map for bank icons (T-P1-2 — the same
    /// derivation Home uses: item → institution name, item → account
    /// mask). Best-effort, never blocks the list: a failed read
    /// leaves rows on their merchant icons.
    private func loadInstitutionMap() async {
        do {
            let pairs = try await client.postgrest.plaidItemInstitutions(householdId: householdId)
            let masks = try await client.postgrest.plaidAccountMasks(
                itemIds: pairs.map(\.itemId))
            var map: [String: String] = [:]
            for (itemId, mask) in masks {
                guard let mask,
                      let pair = pairs.first(where: { $0.itemId == itemId }),
                      let name = pair.institutionName else { continue }
                map[mask] = name
            }
            institutionBySuffix = map
        } catch {
            // Best-effort only: no error state.
        }
    }

    // MARK: - Manual sync (admin only)

    /// `runBankSync` (live.js:2842-2874): one sync at a time; a repeat
    /// tap while syncing is ignored. Then the list reloads.
    public func runSync() async {
        guard isAdmin, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let outcome = try await client.functions.plaidSyncAllowingPartialFailure(householdId: householdId)
            switch outcome {
            case .success(let result):
                if result.noBankConnected == true {
                    toastManager.show("No bank connection yet — connect a bank account first.", kind: .error)
                } else {
                    toastManager.show("Bank sync complete: \(result.added) new, \(result.updated) updated.", kind: .success)
                }
            case .partial(let partial):
                let names = partial.failedInstitutions.isEmpty
                    ? partial.failedItems.joined(separator: ", ")
                    : partial.failedInstitutions.joined(separator: ", ")
                toastManager.show(
                    "Sync finished, but \(names) failed — \(partial.result.added) new, \(partial.result.updated) updated.",
                    kind: .error
                )
            }
        } catch let error as OnBudgetError {
            toastManager.showError(error.displayMessage)
            return
        } catch {
            toastManager.showError(OnBudgetError.displayMessage(for: error))
            return
        }
        await load()
    }

    // MARK: - Row actions

    public func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func appendAudit(action: String, detail: String) async {
        guard let actor = currentUserId else { return }
        let entry = AuditLogInsert(
            householdId: householdId,
            actor: actor,
            actorName: isAdmin ? "Admin" : "Member",
            action: action,
            detail: detail
        )
        // A blocked audit insert must not fail the action it logs.
        try? await client.postgrest.appendAudit(entry)
    }

    private func reloadAfterMutation() async {
        await load()
    }

    /// Mark as Charity (live.js:3813-3832): admin only, charge only,
    /// pending or posted. A pending mark counts toward Given only
    /// once it posts. Refusals surface the server message verbatim.
    public func markAsCharity(_ transaction: Transaction) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can mark transactions as charity.")
            return false
        }
        do {
            try await client.rpcs.markTransactionCharity(pTransactionId: transaction.id)
            toastManager.show(
                "Marked as charity gift: \(TransactionFormatting.amountDisplay(for: transaction).text) to \(TransactionFormatting.displayMerchant(transaction.merchant)).",
                kind: .success
            )
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            if error == .sessionExpired {
                loadState = .failed(error)
            }
            showAlert(title: "Could Not Mark as Charity", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Mark as Charity", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Reclassify ("Other", live.js:3922-3941). Charity is routed to
    /// the guarded mark-as-charity path, never sent to this RPC.
    /// Reason is required.
    public func reclassify(_ transaction: Transaction, to kind: TransactionKind, reason: String) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can reclassify transactions.")
            return false
        }
        if kind == .charity {
            return await markAsCharity(transaction)
        }
        do {
            try await client.rpcs.reclassifyTransaction(txnId: transaction.id, newKind: kind, reason: reason)
            toastManager.show("Transaction reclassified.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            showAlert(title: "Could Not Reclassify", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Reclassify", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Extra Fund request for a charge (live.js:3834-3861). Refuses
    /// charity rows and non-charges with the web's exact wording,
    /// and any amount above the charge itself (T-P2-6 — the fund
    /// covers a charge, never more than it).
    public func requestExtraFund(for transaction: Transaction, amountCents: Int) async -> Bool {
        if transaction.kind == .charity {
            showAlert(title: "Does Not Qualify", message: "Charity gifts cannot be covered by the Extra Fund.")
            return false
        }
        if transaction.kind != .charge {
            showAlert(
                title: "Does Not Qualify",
                message: "Only a charge can be covered by the Extra Fund. This row does not count toward weekly spending, so there is nothing for the fund to cover."
            )
            return false
        }
        guard amountCents <= transaction.amountCents else {
            showAlert(
                title: "Could Not Send Request",
                message: "The request can't be more than the charge (\(TransactionFormatting.amountDisplay(for: transaction).text))."
            )
            return false
        }
        guard let requester = currentUserId else {
            showAlert(title: "Could Not Send Request", message: "Could not send this request. Try again.")
            return false
        }
        do {
            _ = try await client.postgrest.createFundRequest(
                householdId: householdId,
                requestedBy: requester,
                amountCents: amountCents,
                note: "",
                transactionId: transaction.id
            )
            await appendAudit(
                action: "Extra Fund request created",
                detail: "Requested \(TransactionFormatting.formatCents(amountCents)) for \(TransactionFormatting.displayMerchant(transaction.merchant))."
            )
            toastManager.show("Extra Fund request sent.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            showAlert(title: "Could Not Send Request", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Send Request", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Delete (live.js:3942-3970): hand-written rows delete
    /// permanently; bank/email/file rows move to Trash (never a true
    /// erase — the bank would re-sync them).
    public func delete(_ transaction: Transaction, reason: String) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can delete transactions.")
            return false
        }
        do {
            if transaction.source == .manual {
                try await client.rpcs.deleteTransaction(pTransactionId: transaction.id)
                toastManager.show("Transaction deleted.", kind: .success)
            } else {
                try await client.rpcs.excludeTransaction(txnId: transaction.id, reason: reason)
                toastManager.show("Moved to trash bin.", kind: .success)
            }
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            showAlert(title: "Could Not Delete", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Delete", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Restore a trashed row (live.js:1190). Restores the stored
    /// `pre_exclusion_state`; refuses with "cannot restore: no prior
    /// state recorded" when none was recorded — that text is carried
    /// through unchanged. KNOWN LIVE DEFECT: merged duplicates were
    /// excluded without recording `pre_exclusion_state`, so restoring
    /// one always refuses until the server fix lands (branch-only fix
    /// `fix-live-defects-dedupe-held`, awaiting owner approval).
    public func restore(_ transaction: Transaction) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can restore transactions.")
            return false
        }
        do {
            try await client.rpcs.restoreTransaction(txnId: transaction.id)
            await appendAudit(
                action: "Transaction restored",
                detail: "\(TransactionFormatting.displayMerchant(transaction.merchant)) returned to the week."
            )
            toastManager.show("Transaction restored.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            showAlert(title: "Could Not Restore", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Restore", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    // MARK: - Refund linking (live.js:3862-3921)

    /// Candidate purchases for linking a refund by hand: same card,
    /// charges/fund_charges in the 90 days before the refund, not
    /// excluded/reversed; merchant-stem match first (`ilike %stem%`),
    /// fallback to every same-card charge in the window when no name
    /// matches. Reads via `PostgrestClient.refundLinkCandidates`
    /// (fixed Nov 9, 2026 — it used to select 4 columns and decode
    /// full Transaction rows, so this method queried with `*` here).
    public func linkCandidates(for refund: Transaction) async -> [Transaction] {
        let since = RefundLinkCandidates.windowStart(for: refund.date)
        let stem = RefundLinkCandidates.merchantStem(for: refund.merchant)
        do {
            if let stem {
                let stemmed = try await client.postgrest.refundLinkCandidates(
                    householdId: householdId,
                    cardSuffix: refund.cardSuffix,
                    refundDate: refund.date,
                    sinceDate: since,
                    merchantStem: stem
                )
                if !stemmed.isEmpty { return stemmed }
            }
            return try await client.postgrest.refundLinkCandidates(
                householdId: householdId,
                cardSuffix: refund.cardSuffix,
                refundDate: refund.date,
                sinceDate: since,
                merchantStem: nil
            )
        } catch {
            return []
        }
    }

    /// The linked purchase's summary for the unlink sheet (live.js:3867).
    public func linkedPurchaseSummary(for refund: Transaction) async -> (merchant: String, amountCents: Int, date: String)? {
        guard let purchaseId = refund.originalPurchaseId else { return nil }
        do {
            return try await client.postgrest.linkedPurchaseSummary(purchaseId: purchaseId)
        } catch {
            return nil
        }
    }

    public func linkRefund(_ refund: Transaction, to purchase: Transaction) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can link refunds.")
            return false
        }
        do {
            _ = try await client.rpcs.linkRefund(pRefundId: refund.id, pPurchaseId: purchase.id)
            toastManager.show("Refund linked to its purchase.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            showAlert(title: "Could Not Link Refund", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Link Refund", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Unlink a refund (live.js:3862-3875). The server refuses when a
    /// restoration entry already exists ("already restored") — that
    /// refusal surfaces verbatim.
    public func unlinkRefund(_ refund: Transaction) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can unlink refunds.")
            return false
        }
        do {
            try await client.rpcs.unlinkRefund(pRefundId: refund.id)
            toastManager.show("Refund unlinked.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            showAlert(title: "Could Not Unlink Refund", message: error.displayMessage)
            return false
        } catch {
            showAlert(title: "Could Not Unlink Refund", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    // MARK: - Manual add (Purchase / Donation)

    public enum ManualAddOutcome {
        /// Saved (or replayed under the same client key).
        case saved
        /// A row already exists with the same merchant + amount + date.
        case possibleDuplicate
        case failed(OnBudgetError)
    }

    /// The duplicate check before a manual add (live.js:2744-2746):
    /// same merchant + amount + date.
    public func hasPossibleDuplicate(merchant: String, amountCents: Int, date: String) async -> Bool {
        do {
            return try await client.postgrest.hasPossibleDuplicate(
                householdId: householdId,
                merchant: merchant.trimmingCharacters(in: .whitespaces).uppercased(),
                amountCents: amountCents,
                date: date
            )
        } catch {
            return false
        }
    }

    /// Save a hand-entered purchase (live.js:2744-2761): merchant
    /// upper-cased, `source: manual`, `state: provisional`, `kind:
    /// charge`. Purchases-only — no manual-refund flow (owner
    /// decision Nov 3). `force` skips the duplicate check (the user
    /// confirmed "Add Anyway"). Double-tap guard: the caller disables
    /// Save while `isSaving` is true.
    public func savePurchase(
        merchant: String,
        amountCents: Int,
        date: String,
        cardSuffix: String,
        force: Bool = false
    ) async -> ManualAddOutcome {
        guard !isSaving else { return .failed(.unknown("Already saving.")) }
        isSaving = true
        defer { isSaving = false }
        if !force, await hasPossibleDuplicate(merchant: merchant, amountCents: amountCents, date: date) {
            return .possibleDuplicate
        }
        let insert = ManualTransactionInsert(
            householdId: householdId,
            date: date,
            merchant: merchant,
            amountCents: amountCents,
            cardSuffix: cardSuffix
        )
        do {
            _ = try await client.postgrest.insertTransactions([insert])
            await appendAudit(
                action: "Transaction added by hand",
                detail: "\(TransactionFormatting.displayMerchant(merchant)) \(TransactionFormatting.formatCents(amountCents)) on \(TransactionFormatting.fmtLong(date))."
            )
            toastManager.show("Transaction added.", kind: .success)
            await reloadAfterMutation()
            return .saved
        } catch let error as OnBudgetError {
            return .failed(error)
        } catch {
            return .failed(.unknown(error.localizedDescription))
        }
    }

    /// Record a charity gift by hand (live.js:4290-4310):
    /// `record_charity_gift` 8-arg overload, idempotent via
    /// `p_client_key` (a retry reuses the key and replays the original
    /// row; a fresh submit gets a fresh key, so real identical gifts
    /// stay distinct — the Nov 3 TOIREMORG $2 pair ruling). The dedupe
    /// hash carries a per-submit nonce so identical gifts do not
    /// collide. The gift posts as verified (Given) at once.
    public func saveDonation(
        organization: String,
        amountCents: Int,
        date: String,
        cardSuffix: String,
        note: String,
        force: Bool = false
    ) async -> ManualAddOutcome {
        guard !isSaving else { return .failed(.unknown("Already saving.")) }
        isSaving = true
        defer { isSaving = false }
        if !force, await hasPossibleDuplicate(merchant: organization, amountCents: amountCents, date: date) {
            return .possibleDuplicate
        }
        let merchant = organization.trimmingCharacters(in: .whitespaces).uppercased()
        let suffix = cardSuffix.isEmpty ? "0000" : cardSuffix
        let (hash, _) = RPCClient.charityGiftDedupeHash(
            date: date, merchant: merchant, amountCents: amountCents, cardSuffix: suffix
        )
        let clientKey = UUID().uuidString
        do {
            _ = try await client.rpcs.recordCharityGift(
                pHouseholdId: householdId,
                pMerchant: merchant,
                pAmountCents: amountCents,
                pDate: date,
                pCardSuffix: suffix,
                pNote: note,
                pDedupeHash: hash,
                pClientKey: clientKey
            )
            toastManager.show(
                "Gift recorded: \(TransactionFormatting.formatCents(amountCents)) to \(TransactionFormatting.displayMerchant(merchant)).",
                kind: .success
            )
            await reloadAfterMutation()
            return .saved
        } catch let error as OnBudgetError {
            return .failed(error)
        } catch {
            return .failed(.unknown(error.localizedDescription))
        }
    }
}
