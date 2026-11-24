import Foundation
import SwiftUI
import OnBudgetKit

/// View model for the Transactions screens (list, filters, detail,
/// actions, Add Purchase / Add Donation, Trash).
///
/// Wiring — every call goes through the typed `OnBudgetKit` API client:
/// - List: `client.postgrest.transactionsPage(householdId:pageSize:)`
///   (fetch `limit + 1`; the probe row proves whether older rows exist).
/// - Manual sync (everyone, build 64 F-19): Plaid bank
///   (`client.functions.plaidSyncAllowingPartialFailure(householdId:)`)
///   AND Gmail email (`client.functions.gmailPoll(householdId:)`,
///   best-effort), one combined toast, then the list reloads.
/// - Charity: `client.rpcs.markTransactionCharity(pTransactionId:)`.
/// - Reclassify: `client.rpcs.reclassifyTransaction(txnId:newKind:reason:)`.
/// - Link / unlink refund: `client.rpcs.linkRefund(pRefundId:pPurchaseId:)`
///   / `client.rpcs.unlinkRefund(pRefundId:)`; candidates are read with
///   `client.postgrest.refundLinkCandidates(...)`.
/// - Delete (hand-written, permanent): `client.rpcs.deleteTransaction(pTransactionId:)`.
/// - Exclude (bank/email/file → Trash): `client.rpcs.excludeTransaction(txnId:reason:)`.
/// - Restore from Trash: `client.rpcs.restoreTransaction(txnId:)` —
///   or `forceRestoreTransaction(txnId:)` for a bank-dropped row
///   with no snapshot, only after the Trash confirm popup
///   (build 44, change 2).
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

    /// The household's custom fund names (build 43, owner Nov 17,
    /// 2026 — item 16, fund rename propagation): the `fund_names`
    /// map, synced from `appState.fundNames` by the owning view
    /// (TransactionsView). [:] means the defaults. Every
    /// user-facing string below reads through the helpers, never a
    /// hardcoded default name.
    public var fundNames: [String: String] = [:]

    /// The funds' CURRENT display names (build 43, item 16).
    public var fundName: String { FundSectionID.fund.displayName(customNames: fundNames) }
    public var charityName: String { FundSectionID.charity.displayName(customNames: fundNames) }
    public var debtName: String { FundSectionID.debt.displayName(customNames: fundNames) }

    // MARK: - List state

    /// Rows fetched so far, date desc, append-only: the first load
    /// fetches `pageSize` rows; each Load More appends the next
    /// `pageSize` via `offset` (owner, Nov 15, 2026 — the list
    /// loads 25 per page). Filters apply client-side to everything
    /// loaded, so a filter/search/sort change needs no refetch and
    /// no reset — the list re-filters from the rows already here.
    public private(set) var loadedPage: [Transaction] = []
    public private(set) var loadState: LoadState<[Transaction]> = .idle
    /// Per-page fetch size: 25 (was 100 — the list loaded everything
    /// at once, which is why it felt slow). Load More appends the
    /// next 25; it never refetches what is already loaded.
    public private(set) var pageSize: Int = 25
    /// True exactly when the probe row came back on the latest fetch
    /// (older rows exist on the server).
    public private(set) var hasMore: Bool = false
    /// The expense just tagged from the Actions sheet (build 67,
    /// owner Nov 23, 2026): `tagExpense` sets this to the created
    /// expense so the owning view can open the expense editor for
    /// it once the Actions sheet has dismissed. Nil otherwise;
    /// the editor clears it on dismiss.
    public var taggedExpense: RecurringExpense?
    /// Week mode (build 52, owner Nov 20, 2026): the list arrived
    /// from the Spending card / Weekly sheet for ONE week, so the
    /// whole week is loaded at once (no Load More), pre-filtered
    /// to spending, and the header count/total reflect the full
    /// week — the same whole-history principle as the Tzedaka $37
    /// fix. Cleared by "Clear Search and Filters" (back to the
    /// normal paged list).
    public private(set) var isWeekMode: Bool = false
    /// Tzedaka mode (build 65, owner Nov 23, 2026): the list
    /// arrived from the Home Tzedaka sheet, so the full history is
    /// loaded at once (no Load More), pre-filtered to the Tzedaka
    /// rows behind the sheet's numbers — gifts given plus income
    /// rows that accrued charity — all time, not one week. The
    /// accrual ids live in `filters.tzedakaAccrualIds`. Cleared by
    /// "Clear Search and Filters" and by any filter change (back
    /// to the normal paged list), like week mode.
    public private(set) var isTzedakaMode: Bool = false
    /// A Load More fetch is in flight: the button disables while
    /// appending so a double-tap cannot fire two appends. The
    /// existing rows stay visible — Load More never blanks the list.
    public private(set) var isLoadingMore: Bool = false
    /// Whether the $375 schema-default allowance was ever explicitly
    /// set — the sync button is primary blue only when it was set.
    /// Build 53 (owner, Nov 21, 2026 — the refresh-button flash):
    /// nil while the state is UNKNOWN, so the button never shows
    /// the "not set" grey on first paint for a household whose
    /// allowance IS set. The view treats nil like set (Home does
    /// the same, `allowanceSet != false`).
    public private(set) var allowanceSet: Bool?
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
    /// When the last sync (manual or automatic) STARTED (build 69,
    /// owner Nov 24, 2026 — auto-sync on open): the auto-sync
    /// throttle reads it, so opening the page re-syncs at most
    /// once per 5 minutes. Set at the start of every sync, so a
    /// failed sync still counts as "tried recently" and never
    /// retries on every tab switch.
    public private(set) var lastSyncAt: Date?

    /// Alert-style failures (the web's soft-red `showAlert`): title +
    /// server message, shown verbatim.
    public var alertTitle: String?
    public var alertMessage: String?
    public var showAlert: Bool = false

    /// Trash row awaiting force-restore confirmation (build 44,
    /// change 2): a row with NO `pre_exclusion_state` snapshot —
    /// the bank dropped it, so the normal restore has no prior
    /// state to put back. Set by `restore(_:)` (pre-check) or by
    /// the cannot-restore refusal; TrashView shows the confirm
    /// popup from this and calls `forceRestore(_:)` on confirm.
    /// Nil means no popup. Dismissing the popup nils this.
    public var pendingForceRestoreTransaction: Transaction?

    public let toastManager = ToastManager()

    /// Build 64 (C-5): the app-shell toast sink. The shell
    /// (TransactionsView) wires this to `AppViewModel.showToast`,
    /// so confirmations render at app-shell level — ABOVE a
    /// presented sheet — instead of underneath it, where the
    /// local `toastManager` toast would be hidden by the Actions
    /// / export cover. Nil (e.g. in tests, or before the view
    /// wires it) falls back to the local `toastManager`, which
    /// TransactionsView renders with the shared top
    /// `.toastOverlay`. Every action confirmation in this file
    /// goes through `confirm`, never straight to `toastManager`.
    public var appToast: ((String, ToastStyle.Kind) -> Void)?

    /// Fire a C-5 confirmation — success or failure — via the
    /// app-shell toast when wired, else the local toast manager.
    private func confirm(_ message: String, kind: ToastStyle.Kind) {
        if let appToast {
            appToast(message, kind)
        } else {
            toastManager.show(message, kind: kind)
        }
    }

    /// `confirm` for a plain failure message (kind `.error`).
    private func confirmError(_ message: String) {
        confirm(message, kind: .error)
    }

    /// Fire a C-5 confirmation from a view that owns no toast
    /// state of its own (e.g. the Actions sheet's designate
    /// success, which used to call `toastManager.show` directly
    /// and so rendered underneath the sheet). Same funnel as
    /// `confirm`: app-shell toast when wired, local toast
    /// manager otherwise.
    public func showConfirmation(_ message: String, kind: ToastStyle.Kind) {
        confirm(message, kind: kind)
    }

    /// A failed action: the C-5 failure confirmation (app-shell
    /// toast) AND the detailed alert the sheet shows. The toast
    /// is the transient confirmation the owner asked for ("the
    /// success/failure toasts never landed"); the alert stays
    /// because it carries the title + full message on the sheet.
    private func fail(title: String, message: String) {
        confirm(message, kind: .error)
        showAlert(title: title, message: message)
    }

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    // MARK: - Persistence keys (live.js localStorage keys)

    private static let sortKey = "hb-tx-sort"
    private static let monthKey = "hb-tx-month"
    private static let cardKey = "hb-tx-card"
    /// Last-4s added from the Card / Account dropdown (owner,
    /// Nov 15, 2026) — per household, survives restarts.
    private static let customCardsKeyPrefix = "hb-custom-cards-"

    /// Last-4s the user typed in from the Card / Account dropdown.
    /// The dropdown's options are the union of the linked accounts
    /// (`institutionBySuffix`), the suffixes in the loaded page, and
    /// these custom additions.
    public private(set) var customCardSuffixes: [String] = []

    /// Default card for a new manual row: the first connected
    /// account (lowest mask, stable order), Cash ("0000") when none
    /// is known yet.
    public var defaultCardSuffix: String {
        institutionBySuffix.keys.sorted().first ?? "0000"
    }

    /// The Card / Account dropdown options (suffix, label): Cash
    /// first, then every known suffix — linked accounts labelled
    /// with their institution ("Chase ••1005"), the rest bare
    /// ("••1005").
    public var cardAccountOptions: [(suffix: String, label: String)] {
        var suffixes = Set(institutionBySuffix.keys)
        suffixes.formUnion(cardsPresent)
        suffixes.formUnion(customCardSuffixes)
        suffixes.insert("0000")
        return suffixes.sorted().map { suffix in
            if suffix == "0000" { return (suffix, "Cash") }
            if let name = institutionBySuffix[suffix] { return (suffix, "\(name) ••\(suffix)") }
            return (suffix, "••\(suffix)")
        }
    }

    /// Add a hand-typed last-4 from the dropdown: exactly 4 digits,
    /// deduped, persisted per household. Returns false when the value
    /// is not 4 digits (the form shows its own error then).
    @discardableResult
    public func addCustomCardSuffix(_ suffix: String) -> Bool {
        guard suffix.count == 4, suffix.allSatisfy(\.isNumber) else { return false }
        if customCardSuffixes.contains(suffix) { return true }
        customCardSuffixes.append(suffix)
        UserDefaults.standard.set(
            customCardSuffixes,
            forKey: Self.customCardsKey(for: householdId)
        )
        return true
    }

    private static func customCardsKey(for householdId: UUID) -> String {
        customCardsKeyPrefix + householdId.uuidString
    }

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
        customCardSuffixes = UserDefaults.standard.stringArray(
            forKey: Self.customCardsKey(for: householdId)
        ) ?? []
    }

    // MARK: - Derived list

    /// The filtered, sorted rows actually shown (excluded rows never
    /// appear here). Filters apply client-side to everything loaded
    /// so far — the page is the loaded set, not a slice of it.
    /// Build 58 (owner, Nov 22, 2026): the shown rows are also
    /// collapsed by dedupe_hash (TransactionDedupe.byHash), so two
    /// rows for one purchase — the same alert ingested twice, or a
    /// bank+email pair the merge has not processed yet — never show
    /// as two rows. The count line and the list total use these
    /// rows, so a duplicate cannot double-count on screen either.
    public var shownTransactions: [Transaction] {
        TransactionDedupe.byHash(filters.apply(to: loadedPage))
    }

    /// Trashed rows, from the same load as Transactions (live.js §11).
    public var trashTransactions: [Transaction] {
        loadedPage.filter(\.isInTrash)
    }

    public var monthsPresent: [String] {
        TransactionFilters.months(in: loadedPage)
    }

    public var cardsPresent: [String] {
        TransactionFilters.cards(in: loadedPage)
    }

    /// The count line (live.js:863-886, wording per owner Nov 12,
    /// 2026 — "Total", not "Total shown"): "`N` transactions ·
    /// Total `$X`" (owner, Nov 16, 2026 — build 40: the older-rows
    /// tail is gone; the line is just the count and the total).
    /// On failure the line is empty — the error box below
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
        let total = TransactionFilters.shownTotal(
            for: shown,
            status: filters.status,
            linkedRefundAmounts: isWeekMode ? hiddenLinkedRefundAmounts : [:]
        )
        // A negative net total is money in overall, so it reads
        // "+$X" (MoneyFormat.netTotalText); the line stays muted —
        // the total is a summary, not a row. Owner, Nov 16, 2026
        // (build 40): the older-rows tail ("of loaded transactions
        // — tap Load more for older ones") is gone — the line is
        // just the count and the total, centered (see
        // TransactionsView.countLine).
        return "\(shown.count) transactions · Total \(MoneyFormat.netTotalText(cents: total))"
    }

    /// The shown charges that have a linked refund (build 52 —
    /// week mode): the row shows a "Refunded" mark and the total
    /// nets the refund out. Computed from the loaded rows — the
    /// week's rows plus the refunds from the week start onward in
    /// week mode, so a refund from a later week still marks its
    /// charge. Only the shown charges are returned; a refund
    /// pointing at a row that is not shown marks nothing. Build
    /// 53 (audit C6): the netting lives in OnBudgetKit
    /// (WeekTransactionsNetting) so the week's total has unit
    /// tests.
    public var refundedChargeIds: Set<UUID> {
        WeekTransactionsNetting.refundedChargeIds(loaded: loadedPage, shown: shownTransactions)
    }

    /// Refund amounts linked to the shown charges, for refunds
    /// that are NOT themselves in the shown list (build 52 — week
    /// mode): the list is spending-only, so a linked refund is
    /// not a row, but the week's total must still net it out.
    /// Keyed by the charge's id. Only refunds not in `shown` are
    /// included — a refund that IS shown is already subtracted by
    /// `shownTotal`'s refund arm, so nothing is subtracted twice.
    /// Empty outside week mode: the normal list total is a display
    /// sum over the shown rows only (existing rule).
    private var hiddenLinkedRefundAmounts: [UUID: Int] {
        guard isWeekMode else { return [:] }
        // Build 53 (audit C6): the netting lives in OnBudgetKit
        // (WeekTransactionsNetting) so the week's total has unit
        // tests.
        return WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loadedPage, shown: shownTransactions)
    }

    /// Whether the viewer has any action on a row (live.js:982):
    /// admin sees Actions on every row; a member only Extra Fund on
    /// charges.
    public func hasActions(for transaction: Transaction) -> Bool {
        if isAdmin { return true }
        return transaction.kind == .charge && !transaction.isInTrash
    }

    // MARK: - Loading

    /// First load / pull-to-refresh / retry / after a mutation.
    /// Fetches the first page (offset 0, `pageSize` rows) and
    /// REPLACES the loaded set — a refresh starts from the top.
    /// In WEEK mode (build 52) it fetches the week's rows
    /// server-side date-range filtered (build 53, audit C6 — the
    /// old whole-history fetch is gone; the export path keeps
    /// `allTransactions`, which genuinely needs it), plus the
    /// refunds dated from the week start onward, so a refund that
    /// posts in a later week still marks / nets its charge.
    /// A failed read is an error state, never a silent empty list
    /// or an endless spinner (the web app has a live "Loading…"
    /// hang; the clone must not copy it). Requests time out at 30s
    /// server-side in the client.
    public func load() async {
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.loadState = .loading
            do {
                if self.isWeekMode {
                    let fromDate = self.filters.fromDate
                    let toDate = self.filters.toDate
                    let merged: [Transaction]
                    if fromDate.isEmpty || toDate.isEmpty {
                        // Build 64 (F-27): week mode WITHOUT
                        // bounds is an error, never a whole-history
                        // fetch — the old fallback re-read the
                        // entire history precisely when something
                        // else had already gone wrong (audit C6
                        // fixed the normal path; this was the
                        // remaining hole). The list shows the
                        // error state with a retry instead.
                        self.loadedPage = []
                        self.hasMore = false
                        self.loadState = .failed(.unknown("The week's dates are missing, so the week could not be loaded. Pull to refresh and try again."))
                        return
                    } else {
                        let rows = try await self.client.postgrest.transactionsInDateRange(
                            householdId: self.householdId, fromDate: fromDate, toDate: toDate
                        )
                        let refunds = try await self.client.postgrest.refundsFromDate(
                            householdId: self.householdId, fromDate: fromDate
                        )
                        // A refund dated inside the week is already
                        // in `rows` — only the out-of-week ones are
                        // added. Merged in date-desc order (the same
                        // order transactionsPage returns), so leaving
                        // week mode keeps the normal paged shape by
                        // taking the first page.
                        let refundIds = Set(rows.map(\.id))
                        let extraRefunds = refunds.filter { !refundIds.contains($0.id) }
                        merged = (rows + extraRefunds).sorted {
                            ($0.date, $0.createdAt) > ($1.date, $1.createdAt)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.loadedPage = merged
                    self.hasMore = false
                    self.loadState = .loaded(merged)
                } else if self.isTzedakaMode {
                    // Build 65: Tzedaka mode loads the FULL history
                    // at once (all time, no Load More) — the
                    // Tzedaka rows span the whole history, and a
                    // first page could miss older income/gifts.
                    let all = try await self.client.postgrest.allTransactions(
                        householdId: self.householdId
                    )
                    guard !Task.isCancelled else { return }
                    self.loadedPage = all
                    self.hasMore = false
                    self.loadState = .loaded(all)
                } else {
                    let (rows, hasMore) = try await self.client.postgrest.transactionsPage(
                        householdId: self.householdId,
                        pageSize: self.pageSize,
                        offset: 0
                    )
                    guard !Task.isCancelled else { return }
                    self.loadedPage = rows
                    self.hasMore = hasMore
                    self.loadState = .loaded(rows)
                }
                // Best-effort extras (allowance flag for the sync
                // button, institution map for bank icons) run
                // DETACHED, not awaited here (owner, Nov 16, 2026 —
                // build 38): awaiting them inside this task kept the
                // pull-to-refresh spinner stuck above the already
                // loaded list whenever either was slow — the refresh
                // must return the moment the rows are set. They fill
                // in behind the list when they arrive.
                Task { [weak self] in
                    guard let self else { return }
                    await self.loadAllowanceState()
                    await self.loadInstitutionMap()
                }
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

    /// Load More: appends the next `pageSize` rows (offset =
    /// rows already loaded) and never refetches what is here —
    /// the old "raise the limit and reload everything" re-read
    /// the whole list on every tap. The existing rows stay visible
    /// while the next page loads (the list is not blanked); a
    /// failed append keeps the rows and the button, so the user
    /// can retry. A double-tap while appending is ignored.
    public func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (rows, hasMore) = try await client.postgrest.transactionsPage(
                householdId: householdId,
                pageSize: pageSize,
                offset: loadedPage.count
            )
            loadedPage.append(contentsOf: rows)
            self.hasMore = hasMore
            loadState = .loaded(loadedPage)
        } catch let error as OnBudgetError {
            confirmError(error.displayMessage)
        } catch {
            confirmError(OnBudgetError.displayMessage(for: error))
        }
    }

    /// Search is debounced 250ms. Searches loaded transactions
    /// only — filtering is client-side over the rows already
    /// loaded, so a new search needs no refetch and no page reset.
    public func applySearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.filters.search = text
        }
    }

    /// "Clear Search and Filters": resets every filter to default and
    /// re-renders (live.js:1033-1042). Also bumps `searchResetNonce`
    /// so the visible search box clears with the filters (T-P1-1) —
    /// the Past Weeks and Home-row jumps call this first, so they
    /// clear the box too. Filtering is client-side over the rows
    /// already loaded, so clearing needs no refetch — EXCEPT when
    /// leaving WEEK mode (build 52): the week's rows (plus the
    /// later refunds pulled in for the netting) are in `loadedPage`,
    /// so the list goes back to the normal paged shape by keeping
    /// the first page (same date-desc order as `transactionsPage`)
    /// and restoring `hasMore` — no refetch.
    public func clearSearchAndFilters() {
        let wasWeekMode = isWeekMode
        let wasTzedakaMode = isTzedakaMode
        isWeekMode = false
        isTzedakaMode = false
        filters = TransactionFilters()
        persistFilters()
        searchResetNonce += 1
        if wasWeekMode || wasTzedakaMode {
            let all = loadedPage
            loadedPage = Array(all.prefix(pageSize))
            hasMore = all.count > pageSize
            loadState = .loaded(loadedPage)
        }
    }

    /// Past Weeks / Weekly-sheet jump (live.js:3457-3500): show only
    /// the Sun–Sat week starting `weekStart`, pre-filtered to
    /// SPENDING, with the FULL week loaded at once (build 52,
    /// owner Nov 20, 2026 — the Spending card's "Show
    /// Transactions" only loaded a page, so the header count/total
    /// changed on every Load More). The shell clears
    /// `pendingWeekFilter` once consumed. Async: it fetches the
    /// week's rows server-side date-range filtered (build 53,
    /// audit C6 — the old whole-history fetch is gone), plus the
    /// refunds from the week start onward for the netting, so the
    /// header count/total reflect the full week from the start.
    /// The filter reset is inlined here (not via
    /// `clearSearchAndFilters`) so leaving week mode does not
    /// fight entering it.
    public func applyWeekFilter(weekStart: String) async {
        filters = TransactionFilters()
        persistFilters()
        searchResetNonce += 1
        filters.fromDate = weekStart
        filters.toDate = MoneyFormat.weekEndString(weekStart: weekStart) ?? weekStart
        filters.status = .spending
        filterChanged()
        isWeekMode = true
        await load()
    }

    /// Tzedaka-sheet jump (build 65, owner Nov 23, 2026): show
    /// the rows behind the Tzedaka sheet's numbers — gifts given
    /// (kind .charity) PLUS income rows that accrued charity —
    /// all time, with the FULL history loaded at once (no Load
    /// More), like week mode. The income rows are identified by
    /// the active `charity_income` rows' `transactionId`
    /// (`activeCharityIncome` fetches all pages, no cap — the
    /// 50-row `charityIncomeHistory` would silently drop older
    /// income). A failed accrual read falls back to gifts only
    /// (empty id set) rather than failing the whole list. The
    /// shell clears `pendingTzedakaFilter` once consumed.
    public func applyTzedakaFilter() async {
        let accrualIds: Set<UUID>
        do {
            let income = try await client.postgrest.activeCharityIncome(householdId: householdId)
            accrualIds = Set(income.compactMap(\.transactionId))
        } catch {
            accrualIds = []
        }
        filters = TransactionFilters()
        persistFilters()
        searchResetNonce += 1
        filters.status = .tzedaka
        filters.tzedakaAccrualIds = accrualIds
        filterChanged()
        isTzedakaMode = true
        await load()
    }

    /// Recent-row jump (live.js:1040-1110): clear search/filters
    /// first, then expand the row — when it is in the loaded page.
    /// Otherwise the shell's exact toast: the row is not loaded yet.
    public func applyTransactionJump(_ id: UUID) {
        clearSearchAndFilters()
        if loadedPage.contains(where: { $0.id == id }) {
            expandedTransactionId = id
        } else {
            confirm("That transaction is not in the loaded list — tap Load more for older ones.", kind: .info)
        }
    }

    /// Apply a filter change (status / month / card / week / dates /
    /// bounds / sort). Client-side only — no refetch; the list
    /// re-filters from the rows already loaded. Build 53 (audit
    /// C7): changing a filter LEAVES week mode — isWeekMode was
    /// sticky (only clearSearchAndFilters cleared it), so a filter
    /// change inside the week view kept the week list and the week
    /// total. Leaving week mode restores the normal paged shape
    /// (first page of the loaded rows), the same as
    /// clearSearchAndFilters. applyWeekFilter calls this BEFORE
    /// setting isWeekMode = true, so entering week mode is
    /// unaffected; the Filters sheet's Cancel does NOT call this
    /// (it restores the snapshot and persists only), so a Cancel
    /// leaves the list — including week mode — unchanged.
    public func filterChanged() {
        if isWeekMode || isTzedakaMode {
            isWeekMode = false
            isTzedakaMode = false
            let all = loadedPage
            loadedPage = Array(all.prefix(pageSize))
            hasMore = all.count > pageSize
            loadState = .loaded(loadedPage)
        }
        persistFilters()
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
            // treatment); a failed read leaves it unknown (nil),
            // which the view renders like set — the common case —
            // instead of flashing the "not set" grey.
            allowanceSet = nil
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

    // MARK: - Export (build 45, Nov 18, 2026)

    /// The rows an export covers, fetched whole first: the list
    /// page only ever holds the rows loaded so far (25 at a time),
    /// so an export of the loaded page alone would silently miss
    /// the rows the user never tapped Load More for. The full
    /// history (~90 rows) is fetched in the background, then the
    /// active filters apply for the filtered scope, or nothing
    /// applies for Export all. Read-only — it never changes
    /// transactions. A failed fetch throws: a partial export must
    /// never present itself as the whole history.
    public func fetchExportRows(scope: TransactionExportScope) async throws -> [Transaction] {
        let all = try await client.postgrest.allTransactions(householdId: householdId)
        switch scope {
        case .all:
            return all
        case .filtered:
            return filters.apply(to: all)
        }
    }

    /// The household name for the PDF header (`appState.
    /// householdName` is the first source — the view passes it
    /// when it has it; this is the fallback when it is nil).
    public func fetchHouseholdName() async -> String? {
        try? await client.postgrest.householdName(householdId: householdId)
    }

    // MARK: - Manual sync (everyone, bank + email)

    /// `runBankSync` (live.js:2842-2874): one sync at a time; a repeat
    /// tap while syncing is ignored. Then the list reloads.
    /// Build 64 (F-19, owner Nov 23, 2026): the sync button syncs
    /// EVERYTHING — Plaid bank AND Gmail email — and is open to
    /// members, not just admins (the old `isAdmin` guard meant
    /// members never saw a sync button, and the old path never
    /// pulled Gmail). ONE combined toast covers both halves, via
    /// the app-shell toast (`confirm` → `AppState.showToast`).
    /// The email half is best-effort: a failed email check never
    /// fails the bank sync, it just adds a line to the toast.
    /// The server auth relax (F-19, build 64: members may trigger
    /// a sync too, not just admins) is DEPLOYED (PR #102, Nov 24,
    /// 2026 — plaid-sync v27, gmail-poll v22). A member's sync
    /// works now; the 403 fallback below stays as a safety net
    /// and shows as one plain line ("Sync isn't available for
    /// members yet…"), never the server's 403 text.
    ///
    /// Build 69 (owner, Nov 24, 2026 — auto-sync on open):
    /// `quiet` runs the same sync without any toast — for the
    /// automatic sync on page open, so the list just updates and
    /// a failed auto-sync stays silent (the manual Sync control
    /// still shows its error). `lastSyncAt` is set at the start
    /// of every sync, manual or automatic.
    public func runSync(quiet: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncAt = Date()
        defer { isSyncing = false }
        // Bank half: the existing Plaid sync. A 403 here is the
        // pre-deploy server (auth relax not live yet) — plain
        // words, no reload, no technical text.
        let outcome: EdgeFunctionsClient.PlaidSyncOutcome
        do {
            outcome = try await client.functions.plaidSyncAllowingPartialFailure(householdId: householdId)
        } catch let error as OnBudgetError {
            if !quiet {
                if case .adminOnly = error {
                    confirm("Sync isn't available for members yet — the server update is still on its way. Try again later.", kind: .error)
                } else if case .forbidden = error {
                    confirm("Sync isn't available for members yet — the server update is still on its way. Try again later.", kind: .error)
                } else {
                    confirmError(error.displayMessage)
                }
            }
            return
        } catch {
            if !quiet { confirmError(OnBudgetError.displayMessage(for: error)) }
            return
        }
        // Email half: best-effort Gmail poll alongside the bank
        // sync. A throw here never fails the sync — the toast just
        // says the email check didn't run.
        let emailText: String?
        do {
            let poll = try await client.functions.gmailPoll(householdId: householdId)
            let (text, isError) = EmailCheckMessage.text(
                topLevelError: nil,
                firstConnectionError: poll.firstError?.error,
                stored: poll.stored,
                duplicates: poll.duplicates,
                quarantined: poll.quarantined,
                unparseable: poll.unparseable,
                stale: poll.stale,
                minutesSincePreviousPoll: poll.minutesSincePreviousPoll
            )
            // Only mention email when it added something or
            // failed — a quiet "0 added" line adds nothing.
            emailText = (isError || poll.stored > 0) ? text : nil
        } catch {
            emailText = "Email check didn't run — bank sync still finished."
        }
        // ONE combined toast for both halves.
        let bankText: String
        let bankKind: ToastStyle.Kind
        switch outcome {
        case .success(let result):
            if result.noBankConnected == true {
                bankText = "No bank connection yet — connect a bank account first."
                bankKind = .error
            } else {
                bankText = "Bank sync complete: \(result.added) new, \(result.updated) updated."
                bankKind = .success
            }
        case .partial(let partial):
            let names = partial.failedInstitutions.isEmpty
                ? partial.failedItems.joined(separator: ", ")
                : partial.failedInstitutions.joined(separator: ", ")
            bankText = "Sync finished, but \(names) failed — \(partial.result.added) new, \(partial.result.updated) updated."
            bankKind = .error
        }
        // ONE combined toast for both halves — unless quiet (the
        // automatic sync): then the list just updates, silently.
        if !quiet {
            if let emailText {
                confirm("\(bankText) \(emailText)", kind: bankKind)
            } else {
                confirm(bankText, kind: bankKind)
            }
        }
        await load()
    }

    /// Auto-sync on open (build 69, owner Nov 24, 2026): the
    /// Transactions page syncs itself when it appears (Plaid +
    /// Gmail, same `runSync` as the manual control — and members
    /// too, now the F-19 server relax is deployed), so family
    /// members see the latest transactions without tapping Sync.
    /// Throttled to once per 5 minutes — a manual sync counts
    /// too — and quiet: no toast on success or failure, the list
    /// just updates. The manual Sync control is unchanged.
    public func autoSyncIfNeeded() async {
        if isSyncing { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < 300 { return }
        await runSync(quiet: true)
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
            confirm(
                "Marked as charity gift: \(TransactionFormatting.amountDisplay(for: transaction).text) to \(TransactionFormatting.displayMerchant(transaction.merchant)).",
                kind: .success
            )
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            if error == .sessionExpired {
                loadState = .failed(error)
            }
            fail(title: "Could Not Mark as \(charityName)", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Mark as \(charityName)", message: OnBudgetError.displayMessage(for: error))
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
            confirm("Transaction reclassified.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Reclassify", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Reclassify", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    // MARK: - Recurring expenses (build 67, owner Nov 23, 2026)

    /// Tag a money-out transaction as a recurring Expense (the
    /// Actions sheet's Expense row, after the reclassify reason).
    /// The RPC reclassifies to kind 'expense' (admin only, 35-day
    /// lock, same guards as reclassify) and creates the expense
    /// row at Monthly — name and amount prefilled from the
    /// transaction, exactly what the server stored. Returns the
    /// created expense so the caller can open the editor for it;
    /// nil when the tag failed (the error is already shown).
    /// The list reloads, so the week figures drop the expense
    /// from spending at once (Home and Transactions read the
    /// same total — the F-1 rule). No toast here: the editor
    /// opening IS the confirmation.
    public func tagExpense(_ transaction: Transaction, reason: String) async -> RecurringExpense? {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can tag transactions as expenses.")
            return nil
        }
        do {
            let expenseId = try await client.rpcs.tagTransactionExpense(
                pTransactionId: transaction.id, pFrequency: .monthly, pReason: reason)
            await reloadAfterMutation()
            return RecurringExpense(
                id: expenseId, householdId: householdId, transactionId: transaction.id,
                name: transaction.merchant, amountCents: transaction.amountCents, frequency: .monthly)
        } catch let error as OnBudgetError {
            fail(title: "Could Not Tag as Expense", message: error.displayMessage)
            return nil
        } catch {
            fail(title: "Could Not Tag as Expense", message: OnBudgetError.displayMessage(for: error))
            return nil
        }
    }

    /// Save the expense editor's changes (name / amount /
    /// frequency) for one expense. Edits the expense row only —
    /// the linked transaction's own amount is never touched.
    public func updateExpense(_ expense: RecurringExpense, name: String, amountCents: Int, frequency: ExpenseFrequency) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can edit expenses.")
            return false
        }
        do {
            try await client.rpcs.updateRecurringExpense(
                pExpenseId: expense.id, pName: name, pAmountCents: amountCents, pFrequency: frequency)
            confirm("Expense saved.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Save Expense", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Save Expense", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Remove one expense: deletes the expense row AND reclassifies
    /// the linked transaction back to 'charge', so it counts as
    /// weekly spending again.
    public func removeExpense(_ expense: RecurringExpense) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can remove expenses.")
            return false
        }
        do {
            try await client.rpcs.removeRecurringExpense(pExpenseId: expense.id, pReason: "")
            confirm("Expense removed — the transaction counts as a purchase again.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Remove Expense", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Remove Expense", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Rename merchant (build 30, teachable rules). Teaches a rule
    /// from this transaction's spelling and renames every matching
    /// row, old and new. Admin only; applies to every kind.
    /// `fixedKind` is a `TransactionKind` raw value (charge /
    /// refund / fund_charge / payment / cashback / charity /
    /// transfer / income) or nil for name-only.
    public func renameMerchant(_ transaction: Transaction, to displayName: String, fixedKind: String?, matchType: String = "exact") async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can rename merchants.")
            return false
        }
        do {
            let renamed = try await client.rpcs.renameTransactionAndApplyRule(
                pTransactionId: transaction.id,
                pDisplayName: displayName,
                pFixedKind: fixedKind,
                pMatchType: matchType
            )
            confirm(
                renamed == 1
                    ? "Renamed 1 transaction."
                    : "Renamed \(renamed) transactions.",
                kind: .success
            )
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Rename", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Rename", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// The merchant rule already matching this transaction's bank
    /// name, if any (build 47 — the rename popup pre-fills from
    /// it: the stored display name, match type and bank name). A
    /// failed rules read is not an error here — the popup just
    /// opens with the defaults (no rule, Exact, the row's own
    /// bank name).
    public func existingMerchantRule(for transaction: Transaction) async -> MerchantRule? {
        guard let rules = try? await client.postgrest.merchantRules(householdId: householdId) else {
            return nil
        }
        return MerchantDisplayName.matchingRule(for: transaction.merchant, rules: rules)
    }

    /// Extra Fund request for a charge (live.js:3834-3861). Refuses
    /// charity rows and non-charges with the web's exact wording,
    /// and any amount above the charge itself (T-P2-6 — the fund
    /// covers a charge, never more than it).
    public func requestExtraFund(for transaction: Transaction, amountCents: Int) async -> Bool {
        if transaction.kind == .charity {
            showAlert(title: "Does Not Qualify", message: "\(charityName) gifts cannot be covered by the \(fundName).")
            return false
        }
        if transaction.kind != .charge {
            showAlert(
                title: "Does Not Qualify",
                message: "Only a charge can be covered by the \(fundName). This row does not count toward weekly spending, so there is nothing for the fund to cover."
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
                action: "\(fundName) request created",
                detail: "Requested \(TransactionFormatting.formatCents(amountCents)) for \(TransactionFormatting.displayMerchant(transaction.merchant))."
            )
            confirm("\(fundName) request sent.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Send Request", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Send Request", message: OnBudgetError.displayMessage(for: error))
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
                confirm("Transaction deleted.", kind: .success)
            } else {
                try await client.rpcs.excludeTransaction(txnId: transaction.id, reason: reason)
                confirm("Moved to trash bin.", kind: .success)
            }
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Delete", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Delete", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Exclude a row from the spending math WITHOUT reclassifying
    /// it (build 50, owner Nov 20, 2026): the owner had to misuse
    /// "Transfer" to get a row out of the math because there was
    /// no Exclude. Same server call as Delete for a bank/email row
    /// (`exclude_transaction` → Trash, restorable, admin only,
    /// 35-day lock) — the kind stays what it is and the merchant
    /// stays visible. A hand-entered row is excluded the same way
    /// (to Trash, restorable), not permanently deleted.
    public func exclude(_ transaction: Transaction, reason: String) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can exclude transactions.")
            return false
        }
        do {
            try await client.rpcs.excludeTransaction(txnId: transaction.id, reason: reason)
            confirm("Transaction excluded.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Exclude", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Exclude", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Restore a trashed row (live.js:1190). Restores the stored
    /// `pre_exclusion_state`; refuses with "cannot restore: no prior
    /// state recorded" when none was recorded — that text is carried
    /// through unchanged.
    ///
    /// Build 44, change 2 — PRE-CHECK, not error-driven: the Trash
    /// row already carries `preExclusionState` (decoded from the
    /// `*` list load, same load as `trashTransactions`), so a NULL
    /// snapshot is known BEFORE any RPC call. A nil snapshot sets
    /// `pendingForceRestoreTransaction` and TrashView shows the
    /// confirm popup directly — no wasted restore call, no failure
    /// alert flashed first. The error-driven fallback below covers
    /// only stale data (a snapshot present at load, gone by the
    /// time the server looks).
    public func restore(_ transaction: Transaction) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can restore transactions.")
            return false
        }
        if transaction.preExclusionState == nil {
            pendingForceRestoreTransaction = transaction
            return false
        }
        do {
            try await client.rpcs.restoreTransaction(txnId: transaction.id)
            await appendAudit(
                action: "Transaction restored",
                detail: "\(TransactionFormatting.displayMerchant(transaction.merchant)) returned to the week."
            )
            confirm("Transaction restored.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            if case .cannotRestore = error {
                pendingForceRestoreTransaction = transaction
                return false
            }
            fail(title: "Could Not Restore", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Restore", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    /// Force-restore a bank-dropped Trash row (build 44, change 2):
    /// called only from the Trash confirm popup, after the admin
    /// confirmed the bank really still holds the money. Calls
    /// `force_restore_transaction`, which restores the row as
    /// verified with source='restored'. The normal `restore(_:)`
    /// path is untouched — rows WITH a snapshot never reach here.
    public func forceRestore(_ transaction: Transaction) async -> Bool {
        guard isAdmin else {
            showAlert(title: "Admin Only", message: "Only the admin can restore transactions.")
            return false
        }
        do {
            try await client.rpcs.forceRestoreTransaction(txnId: transaction.id)
            await appendAudit(
                action: "Transaction force-restored",
                detail: "\(TransactionFormatting.displayMerchant(transaction.merchant)) returned to the week as verified (bank-dropped row)."
            )
            confirm("Transaction restored.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Restore", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Restore", message: OnBudgetError.displayMessage(for: error))
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
            confirm("Refund linked to its purchase.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Link Refund", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Link Refund", message: OnBudgetError.displayMessage(for: error))
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
            confirm("Refund unlinked.", kind: .success)
            await reloadAfterMutation()
            return true
        } catch let error as OnBudgetError {
            fail(title: "Could Not Unlink Refund", message: error.displayMessage)
            return false
        } catch {
            fail(title: "Could Not Unlink Refund", message: OnBudgetError.displayMessage(for: error))
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
            confirm("Transaction added.", kind: .success)
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
            confirm(
                "Donation recorded: \(TransactionFormatting.formatCents(amountCents)) to \(TransactionFormatting.displayMerchant(merchant)).",
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
