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

    /// The household's custom fund names (build 43, owner Nov 17,
    /// 2026 — item 16, fund rename propagation): the `fund_names`
    /// map, synced from `appState.fundNames` by the owning view
    /// (FundsView; the Actions sheet's throwaway instance gets it
    /// from the sheet's `fundNames`). [:] means the defaults. Every
    /// user-facing string below reads through the helpers, never a
    /// hardcoded default name.
    public var fundNames: [String: String] = [:]

    /// The funds' CURRENT display names (build 43, item 16).
    public var fundName: String { FundSectionID.fund.displayName(customNames: fundNames) }
    public var charityName: String { FundSectionID.charity.displayName(customNames: fundNames) }
    public var debtName: String { FundSectionID.debt.displayName(customNames: fundNames) }
    public var spendingName: String { FundSectionID.spending.displayName(customNames: fundNames) }

    // MARK: - Load state

    @Published public var isLoading = false
    /// True once the four fund cards have all resolved (success or
    /// failure) in the current session — the cards reveal TOGETHER
    /// (owner, Nov 16, 2026 — build 38; hardened Nov 17, 2026 —
    /// build 42). Before that, on the very first load, all four show
    /// skeletons; after it flips, a card shows its value or its
    /// error, never a skeleton. Refreshes keep last-known values on
    /// screen (nothing is cleared at the start), so a refresh never
    /// blanks the page to skeletons. This is the ONE page-ready
    /// gate: every card's `isLoading` is just `!cardsReady` — a
    /// card never reveals on its own data alone, so a fast card
    /// cannot appear while a slow one still shows a skeleton (the
    /// build-41 fault: each card gated on its own data being nil
    /// AND !cardsReady, so the first card to load revealed
    /// immediately). The expanded detail is gated the same way.
    @Published public var cardsReady = false
    /// Which action is in flight (per-row busy state + double-tap guard).
    @Published public var busyAction: String?
    @Published public var toast: Toast?
    @Published public var alertTitle: String?
    @Published public var alertMessage: String?

    // MARK: - Fund balances

    @Published public var fundSummary: FundSummary?
    /// The fund ledger rows (build 40, Nov 16, 2026): the fund's
    /// signed ledger. Stored (not just used for the summary) so the
    /// Activity & Transactions feed can show 'allocation' entries
    /// — cash spent / fund spending — which are NOT transaction rows
    /// and otherwise appear nowhere.
    @Published public var fundLedger: [FundLedgerEntry] = []
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
    /// Cash gifts given off-card (build 40, Nov 16, 2026): recorded
    /// on the charity fund, NOT transaction rows. Their sum is added
    /// to Given in loadCharity(); they also appear in the Charity
    /// Activity & Transactions feed.
    @Published public var charityCashGifts: [CharityCashGift] = []

    // MARK: - Carried Debt fund (build 29)

    /// The repayment rule in effect. Nil until loaded; a missing row
    /// means the default 25% rule. Nil after a failed read (the
    /// tables not applied yet) — the rule editor and the debt
    /// actions hide then, while the balance still shows.
    @Published public var debtRule: DebtRule?
    /// Every debt payment, newest first (all sources).
    @Published public var debtPayments: [DebtPayment] = []
    /// Manual debt changes, newest first (build 41 — Add/Set debt).
    /// Fault-tolerant: the table does not exist until
    /// add-set-debt.sql is applied, so a failed read is an empty
    /// list, never a failed card (same pattern as the cash gifts).
    @Published public var debtAdjustments: [DebtAdjustment] = []
    /// The current week's figures from compute-week: D is
    /// `carriedDebtCents`, P is `debtPaymentCents` (nil on the old
    /// server — then the old display).
    @Published public var debtWeek: WeekResult?
    /// Closed weeks, newest first — "Where it came from".
    @Published public var debtHistory: [WeekClose] = []
    /// Rule rows the audit log recorded ("Debt repayment rule changed").
    @Published public var debtRuleAudit: [AuditLogEntry] = []
    @Published public var debtError: String?

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

    /// Merchant rename rules for this household (build 41 — owner,
    /// Nov 16, 2026: the Activity feeds resolve merchant names at
    /// render time through the same rules the Transactions list gets
    /// from the server rewrite). Loaded best-effort: a failed read
    /// leaves the list empty and the feeds show raw names as they
    /// do today — never an error state, never a blank feed.
    @Published public var merchantRules: [MerchantRule] = []

    // MARK: - Allowance (Temporary Allowance preview)

    @Published public var baseAllowanceCents: Int?
    /// One-time "Top Up Budget" grants to the CURRENT week (build
    /// 43, item 21, Nov 17, 2026): the sum of this week's
    /// `weekly_budget_topups` rows, in cents. Default 0 — including
    /// while the SQL is not applied live yet, when the fetch throws
    /// and the load reads as 0 rather than failing the Spending
    /// card (same fault-tolerant pattern as the cash-gifts load in
    /// `loadCharity`). Shown on the Spending breakdown's "Top Ups"
    /// line, always — even $0.00 — so Base + Top Ups = Total reads
    /// explicitly.
    @Published public var topUpsCents: Int = 0

    /// The Spending breakdown's Temporary Increase/Decrease delta
    /// (build 43, item 21): the override's delta against the stored
    /// base, EXCLUDING the top-ups above — they get their own line,
    /// so counting them here too would double-count. Nil when there
    /// is no override or the delta is 0 (nothing left to explain);
    /// the view shows the row only when this is non-nil.
    public var temporaryAllowanceDeltaCents: Int? {
        WeeklyBudgetTopup.temporaryDeltaCents(
            overrideCents: debtWeek?.overrideCents,
            baseAllowanceCents: baseAllowanceCents,
            topUpsCents: topUpsCents
        )
    }
    @Published public var allowanceExplicitlySet = false
    /// Non-nil when the base allowance failed to load, so the
    /// Temporary Allowance form can say so with a retry instead of
    /// showing a bare amount field with no preview (F-P2-14).
    @Published public var allowanceError: String?

    /// The household's large-purchase threshold, in cents (Nov 16,
    /// 2026 — the Spending fund setting). Nil until loaded, and nil
    /// when the column is not yet migrated; the server defaults it
    /// to $100. The Funds page shows $100.00 when this is nil.
    @Published public var largePurchaseThresholdCents: Int?

    /// This week's effective total allowance (base less this week's
    /// debt payment, plus any temporary amount) — the figure the
    /// Spending face shows. Falls back to the stored base while the
    /// week's figures are still loading.
    public var currentWeekTotalCents: Int? {
        if let week = debtWeek {
            return week.baseAvailableCents + week.tempCents
        }
        return baseAllowanceCents
    }

    /// Best-effort push-notify call (Nov 16, 2026). A notification
    /// must never fail the action that triggered it — failures are
    /// silent. The server re-reads the data and derives copy +
    /// recipients itself; the caller only names the type and event.
    private func notifyPush(_ payload: [String: Any]) async {
        do {
            _ = try await context.client.functions.pushNotify(payload: payload)
        } catch {
            // Silent: the action already succeeded; the push is extra.
        }
    }

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

    // MARK: - Carried Debt fund (build 29)

    /// The current carried-debt balance D, from this week's compute-week.
    public var debtBalanceCents: Int? { debtWeek?.carriedDebtCents }
    /// This week's payment P, from compute-week (nil on the old server).
    public var debtPaymentCents: Int? { debtWeek?.debtPaymentCents }

    /// The rule's preview: the weekly payment and the week-starts-at
    /// figure, from the base only ("Each week $X goes to debt — the
    /// week starts at $Y"). Nil when the base, the balance, or the
    /// rule is unknown. The server's payment is authoritative; this
    /// shares the engine's rule exactly (DebtRule.paymentCents).
    public func debtPaymentPreview() -> (payment: Int, weekStartsAt: Int)? {
        guard let base = baseAllowanceCents, let debt = debtBalanceCents, let rule = debtRule else { return nil }
        let payment = DebtRule.paymentCents(baseCents: base, debtCents: debt, rule: rule)
        return (payment: payment, weekStartsAt: base - payment)
    }

    // MARK: - Refresh

    /// Loads every section. The four fund cards load IN PARALLEL
    /// and reveal TOGETHER (owner, Nov 16, 2026 — build 38): the
    /// old refresh awaited nine loads one after another, so the
    /// cards flipped from skeleton to loaded one by one — and
    /// Spending (#8) and Debt (#9) always came last. Now the card
    /// loads run concurrently, `cardsReady` flips once all four
    /// have resolved, and the cards flip together. Last-known values
    /// stay on screen during a refresh (nothing is cleared at the
    /// start — each load only replaces its summary on success, or
    /// sets its error on failure), so a refresh never blanks the
    /// page to skeletons. The supporting loads ride along
    /// concurrently. A failed read is an error state, never a silent
    /// empty list or stale numbers — spec §0.3.
    ///
    /// Build 42 (owner, Nov 17, 2026): the top-ups load is part of
    /// the gate too, not a supporting load — the Savings card's
    /// Pending figure folds pending top-ups in (see
    /// `savingsPendingCents`), so the card cannot reveal before
    /// they are known. Every load in the gate catches its own
    /// failure (each sets its summary or its error, never throws),
    /// so `cardsReady` still flips when a card errors — a failed
    /// card shows its error box, never a skeleton forever.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // The charity summary derives from the transactions, so
        // that one load goes first — a single call, and everything
        // else starts together after it.
        await loadTransactions()
        // The four card loads + the supporting loads, all at once.
        async let fundLoad: Void = loadFund()
        async let topupsLoad: Void = loadTopups()
        async let charityLoad: Void = loadCharity()
        async let requestsLoad: Void = loadRequests()
        async let savingsLoad: Void = loadSavings()
        async let reviewLoad: Void = loadReview()
        async let allowanceLoad: Void = loadAllowance()
        async let weeklyTopupsLoad: Void = loadWeeklyBudgetTopups()
        async let debtLoad: Void = loadDebt()
        async let merchantRulesLoad: Void = loadMerchantRules()
        // The four cards reveal together once their four loads have
        // resolved (success or failure — a failed card shows its
        // error state, never a lingering skeleton). The top-ups
        // load resolves here too: the Savings Pending figure needs
        // it (build 42). The weekly top-ups load resolves here too
        // (build 43, item 21): the Spending breakdown's "Top Ups"
        // line needs it before the card reveals, so the rows never
        // flash from a $0.00 Top Ups to the real figure.
        await fundLoad
        await topupsLoad
        await charityLoad
        await allowanceLoad
        await weeklyTopupsLoad
        await debtLoad
        cardsReady = true
        // The supporting loads finish in their own time.
        await requestsLoad
        await savingsLoad
        await reviewLoad
        await merchantRulesLoad
    }

    /// Review-only refresh (build 30): the Review page lives on
    /// the Transactions tab now, on its own FundsViewModel instance
    /// owned by the shell. It needs the transactions (refund
    /// suggestions are computed from them) plus the review queues —
    /// not the fund/charity/debt loads. The review actions keep
    /// calling the full `refresh()` above, which still includes
    /// `loadReview()`, so counts stay fresh after every resolve.
    public func refreshReview() async {
        isLoading = true
        defer { isLoading = false }
        await loadTransactions()
        await loadMerchantRules()
        await loadReview()
    }

    /// Merchant rename rules for the Activity feeds (build 41):
    /// best-effort, like the ingestion path — on any error the
    /// feeds proceed with no rules (raw names, as today).
    private func loadMerchantRules() async {
        do {
            merchantRules = try await context.client.postgrest.merchantRules(householdId: context.householdId)
        } catch {
            merchantRules = []
        }
    }

    private func loadTransactions() async {
        do {
            allTransactions = try await context.client.postgrest.fetchAllPages(
                PostgrestQuery(
                    table: "transactions",
                    columns: "*",
                    filters: [.householdId(context.householdId), .onOrAfterNov1()],
                    // `id desc` tiebreaker (Nov 18, 2026 — same fix as
                    // transactionsPage): `date` alone is nondeterministic
                    // and `fetchAllPages` walks by offset, so pages
                    // would shift rows between fetches.
                    orders: [PostgrestOrder("date", ascending: false), PostgrestOrder("id", ascending: false)]
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
            // The three reads are independent — fetch them together
            // (owner, Nov 16, 2026 — build 38: the old sequential
            // awaits made this card slower than it needs to be).
            async let ledger = context.client.postgrest.fundLedger(householdId: context.householdId)
            async let releases = context.client.postgrest.surplusReleases(householdId: context.householdId)
            async let shortfall = context.client.postgrest.fundShortfallCents(householdId: context.householdId)
            let ledgerRows = try await ledger
            fundLedger = ledgerRows
            fundSummary = FundSummary.compute(ledger: ledgerRows, releases: try await releases, shortfallCents: try await shortfall)
            fundError = nil
        } catch {
            fundSummary = nil
            fundLedger = []
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
            // The four reads are independent — fetch them together
            // (owner, Nov 16, 2026 — build 38). The summary derives
            // from the already-loaded transactions (refresh() loads
            // those first).
            async let income = context.client.postgrest.activeCharityIncome(householdId: context.householdId)
            async let settings = context.client.postgrest.charitySettings(householdId: context.householdId)
            async let given = context.client.postgrest.verifiedCharityGiftAmounts(householdId: context.householdId)
            let incomeRows = try await income
            let settingsValue = try await settings
            let givenAmounts = try await given
            // Cash gifts (build 40): fetched separately and
            // fault-tolerant — if the charity_cash_gifts table does
            // not exist yet (the SQL not applied), the fetch throws
            // and the gifts read as empty rather than failing the
            // whole charity summary (the old-server pattern: the
            // card still loads, cash gifts just show as $0 until the
            // migration lands).
            let cashGiftRows: [CharityCashGift]
            do {
                cashGiftRows = try await context.client.postgrest.charityCashGifts(householdId: context.householdId)
            } catch {
                cashGiftRows = []
            }
            let defaultRate = settingsValue?.defaultRateBp ?? 1000
            let charityRows = allTransactions.filter { $0.kind == .charity && !$0.excluded && $0.date >= MoneyFormat.dataFloor }
            // Given counts only verified gifts; pending gifts count once
            // they post (live.js:3814-3820). Committed sums each ACTIVE
            // income row at that row's own rate. Cash gifts given
            // off-card (build 40) are NOT transaction rows, so their
            // sum is added to Given here — Available stays
            // committed − given, Total unchanged.
            charitySummary = CharitySummary(
                committedCents: incomeRows.filter { $0.status == "active" }.reduce(0) { $0 + $1.committedCents },
                givenCents: givenAmounts.reduce(0, +) + cashGiftRows.reduce(0) { $0 + $1.amountCents },
                pendingGiftCents: charityRows.filter { $0.state == .provisional }.reduce(0) { $0 + $1.amountCents },
                defaultRateBp: defaultRate
            )
            charityCashGifts = cashGiftRows
            charitySettings = settingsValue
            charityError = nil
        } catch {
            charitySummary = nil
            charitySettings = nil
            charityCashGifts = []
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
        // Large-purchase threshold (Nov 16, 2026): a separate read,
        // so a missing column (migration not yet applied) fails only
        // this read — nil means the $100 default.
        largePurchaseThresholdCents = try? await context.client.postgrest.householdLargePurchaseThreshold(householdId: context.householdId)
    }

    /// The current week's one-time "Top Up Budget" grants (build 43,
    /// item 21, Nov 17, 2026): the sum of the week's
    /// `weekly_budget_topups` rows. Fault-tolerant like the
    /// cash-gifts load in `loadCharity` — if the table does not exist
    /// yet because `supabase/weekly-budget-topups.sql` is not applied
    /// live, the fetch throws and the sum reads as 0 rather than
    /// failing the Spending card (the breakdown then reads exactly
    /// as it does today). Top-ups are only ever granted to the
    /// current week (`addToBudget` passes `currentSundayNY()`), so
    /// the current Sunday is the week to sum — not `debtWeek`'s
    /// week, which this load runs in parallel with.
    private func loadWeeklyBudgetTopups() async {
        do {
            let rows = try await context.client.postgrest.weeklyBudgetTopups(
                householdId: context.householdId,
                weekStart: MoneyFormat.currentSundayNY()
            )
            topUpsCents = rows.reduce(0) { $0 + $1.amountCents }
        } catch {
            topUpsCents = 0
        }
    }

    /// Retry just the allowance load (Temporary Allowance error state).
    public func reloadAllowance() async {
        await loadAllowance()
    }

    // MARK: - Carried Debt fund (build 29)

    /// Loads the Debt section. The current week's figures are the
    /// core: D is the balance, P is this week's payment. compute-week
    /// answers on the old server too (without debt_payment_cents);
    /// the rule and payments reads need the new tables, so each
    /// fails independently — a failed rule/payments read hides the
    /// editor and the actions, while the balance still shows.
    private func loadDebt() async {
        // WHY DEBT WAS THE BOTTLENECK (owner, Nov 16, 2026 — build
        // 38): this ran FIVE round-trips one after another
        // (computeWeek → debtSettings → debtPayments → weekCloses →
        // audit log), AND refresh() called it last (#9 of 9) — so
        // Debt was always the last card to leave its skeleton. Now
        // all five start together and the load takes the slowest
        // single call, and refresh() runs it in parallel with the
        // other three cards. The failure semantics are unchanged:
        // a computeWeek failure fails the whole load (balance
        // unknown); each detail read still fails independently.
        do {
            async let week = context.client.functions.computeWeek(householdId: context.householdId)
            async let rule = context.client.postgrest.debtSettings(householdId: context.householdId)
            async let payments = context.client.postgrest.debtPayments(householdId: context.householdId)
            async let adjustments = context.client.postgrest.debtAdjustments(householdId: context.householdId)
            async let history = context.client.postgrest.weekCloses(householdId: context.householdId)
            async let audit = context.client.postgrest.auditLogPage(householdId: context.householdId, limit: 100)
            debtWeek = try await week
            debtError = nil
            do { debtRule = try await rule ?? .default } catch { debtRule = nil }
            do { debtPayments = try await payments } catch { debtPayments = [] }
            do { debtAdjustments = try await adjustments } catch { debtAdjustments = [] }
            do {
                debtHistory = try await history.sorted { $0.weekStart > $1.weekStart }
            } catch { debtHistory = [] }
            do {
                debtRuleAudit = try await audit.rows.filter { $0.action == "Debt repayment rule changed" }
            } catch { debtRuleAudit = [] }
        } catch {
            debtWeek = nil
            debtRule = nil
            debtPayments = []
            debtAdjustments = []
            debtHistory = []
            debtRuleAudit = []
            debtError = "Could not load debt. Try again."
            return
        }
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
    /// Total pending top-ups (build 41, Nov 17, 2026): saved but
    /// not yet confirmed in checking. They count for nothing — no
    /// ledger row, no shortfall cover — so the Funds detail shows
    /// this beside Available. Build 43 (owner, Nov 17, 2026 —
    /// "Doesn't show the pending amounts"): Home's expanded
    /// Savings rows now include them too, via
    /// HomeViewModel.pendingTopupsCents.
    public var pendingTopupsCents: Int {
        topups.filter { $0.isPending }.reduce(0) { $0 + $1.amountCents }
    }

    /// The Savings card's Pending figure (build 42, owner Nov 17,
    /// 2026 — the $650 live bug): pending surplus releases + held
    /// weeks (`pendingIncludingHeldCents`) PLUS pending top-ups.
    /// The bug was that the card's Pending row read
    /// `summary.pendingIncludingHeldCents` alone, and pending
    /// top-ups lived only on a separate "Pending Top-Ups" row —
    /// so a $650 pending top-up left Pending at $0.00 and Total at
    /// $0.00. Pending top-ups are real money on its way into the
    /// fund, so they belong in Pending (and therefore in Total),
    /// exactly as the owner reads the card. The separate row is
    /// gone — it would double-present the same $650.
    public var savingsPendingCents: Int {
        (fundSummary?.pendingIncludingHeldCents ?? 0) + pendingTopupsCents
    }

    /// The Savings card's Total figure (build 42): Available +
    /// Pending as defined above — so a $650 pending top-up with
    /// $0 Available reads Total $650.00.
    public var savingsTotalCents: Int {
        (fundSummary?.availableCents ?? 0) + savingsPendingCents
    }

    public func addTopup(amountCents: Int, note: String, confirmed: Bool) async -> Bool {
        guard busyAction == nil else { return false }
        busyAction = "topup"
        defer { busyAction = nil }
        if topupClientKey == nil { topupClientKey = UUID().uuidString }
        do {
            let result = try await context.client.rpcs.addFundMoney(
                pHouseholdId: context.householdId,
                pAmountCents: amountCents,
                pNote: note,
                pClientKey: topupClientKey ?? UUID().uuidString,
                pConfirmed: confirmed
            )
            topupClientKey = nil
            if result.status == "pending" {
                succeed("Top-up saved as pending: \(MoneyFormat.formatCents(result.amountCents)) will count once you confirm it in checking.")
            } else {
                succeed("Top-up saved: \(MoneyFormat.formatCents(result.shortfallCoveredCents)) covered owed back, \(MoneyFormat.formatCents(result.fundAddedCents)) added to fund.")
            }
            await refresh()
            return true
        } catch {
            fail(title: "Could Not Save Top-Up", error: error)
            return false
        }
    }

    /// Confirm a pending top-up in checking (build 41): the
    /// shortfall-first split runs against the current shortfall, so
    /// the split may differ from the preview shown at save time.
    /// Admin-only (the history feed is admin-only already).
    public func confirmTopup(_ row: FundTopup) async -> Bool {
        guard let id = row.id, busyAction == nil else { return false }
        busyAction = "confirm-topup"
        defer { busyAction = nil }
        do {
            let result = try await context.client.rpcs.confirmFundTopup(pTopupId: id)
            succeed("Top-up confirmed: \(MoneyFormat.formatCents(result.shortfallCoveredCents)) covered owed back, \(MoneyFormat.formatCents(result.fundAddedCents)) added to fund.")
            await refresh()
            return true
        } catch {
            fail(title: "Could Not Confirm Top-Up", error: error)
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

    // MARK: - Remove from Savings + Designate as Savings (build 42, owner Nov 17, 2026)
    //
    // The Savings spending waterfall — Available → Pending →
    // Carried Debt — behind "Remove from Savings" and behind
    // designating a charge as Savings. All three steps use existing
    // RPCs only (no new server surface):
    //   1. Available: `allocate_fund` (positive amount → a negative
    //      'allocation' ledger entry; no override, so it can never
    //      take Available below $0).
    //   2. Pending: `confirm_fund_topup` on pending top-ups, oldest
    //      first, then `allocate_fund` for what actually landed in
    //      Available. "Pending" here is the REALIZABLE pending
    //      money — pending top-ups. Pending surplus releases cannot
    //      be pulled forward with any existing RPC (week-close
    //      releases them on schedule), so they are NOT spendable
    //      here; a spend larger than Available + pending top-ups
    //      falls through to debt. Confirming a top-up runs the
    //      standing shortfall-first split against the CURRENT
    //      shortfall, so if money is owed back, part (or all) of a
    //      confirmed top-up covers the shortfall first and only the
    //      remainder becomes spendable — the still-unfunded rest
    //      keeps falling through to the next top-up, then to debt.
    //      A top-up is confirmed whole (there is no partial-confirm
    //      RPC); any confirmed money left over after the spend stays
    //      in Available.
    //   3. Carried debt: `add_debt` for whatever is still unfunded
    //      — the remainder is recorded as carried debt, audited,
    //      and shows on the Debt card; the fund itself is never
    //      taken below $0.
    // Partial coverage splits across the steps in order (Available
    // $50 of a $100 spend: $50 from Available, $50 from Pending;
    // if both are exhausted, the remainder goes to carried debt).
    // There is no rollback: if a later step fails, the earlier
    // steps have already moved money, so the outcome carries the
    // partial split and the caller reports it alongside the error.
    // The waterfall refuses to run when the fund balance or the
    // pending top-ups failed to load — with unknown balances it
    // must not silently route a spend to debt.

    /// One Savings spend, split by source.
    public struct SavingsSpendOutcome {
        public let fromAvailableCents: Int
        public let fromPendingCents: Int
        public let toDebtCents: Int
        /// The failure that stopped the waterfall, if any. Earlier
        /// steps already moved money — there is no rollback — so
        /// the caller reports the partial split with this error.
        public let error: Error?
        public var completed: Bool { error == nil }
        public var totalCents: Int { fromAvailableCents + fromPendingCents + toDebtCents }
    }

    /// The waterfall itself: spends `amountCents` from Savings in
    /// Available → Pending → Carried Debt order. `note` is the
    /// ledger / debt-adjustment note. Returns the split (and the
    /// stopping error, if any) — never toasts or alerts; the
    /// callers do that, so the same core serves both the button
    /// and the transaction designation.
    private func spendFromSavings(amountCents: Int, note: String) async -> SavingsSpendOutcome {
        var fromAvailable = 0
        var fromPending = 0
        var toDebt = 0
        var remainder = amountCents
        func outcome(_ error: Error?) -> SavingsSpendOutcome {
            SavingsSpendOutcome(
                fromAvailableCents: fromAvailable,
                fromPendingCents: fromPending,
                toDebtCents: toDebt,
                error: error
            )
        }
        // Unknown balances must not route a spend to debt by
        // default: a failed fund load reads as $0 Available, and a
        // failed top-ups load reads as $0 Pending.
        guard fundSummary != nil else {
            return outcome(OnBudgetError.validationFailed("Could not load the \(fundName) balance. Try again."))
        }
        // 1. Available.
        let takeAvailable = min(remainder, max(0, fundSummary?.availableCents ?? 0))
        if takeAvailable > 0 {
            do {
                try await context.client.rpcs.allocateFund(
                    pHouseholdId: context.householdId,
                    pAmountCents: takeAvailable,
                    pNote: note,
                    pOverrideReason: nil
                )
                fromAvailable = takeAvailable
                remainder -= takeAvailable
            } catch {
                return outcome(error)
            }
        }
        // 2. Pending top-ups, oldest first.
        if remainder > 0 {
            guard topupsError == nil else {
                return outcome(OnBudgetError.validationFailed("Could not load pending top-ups. Try again."))
            }
            let pending = topups.filter { $0.isPending }.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            for topup in pending {
                guard remainder > 0 else { break }
                guard let id = topup.id else { continue }
                do {
                    let result = try await context.client.rpcs.confirmFundTopup(pTopupId: id)
                    // Only what actually landed in Available (after
                    // the shortfall-first split) is spendable here.
                    let take = min(remainder, result.fundAddedCents)
                    if take > 0 {
                        try await context.client.rpcs.allocateFund(
                            pHouseholdId: context.householdId,
                            pAmountCents: take,
                            pNote: note,
                            pOverrideReason: nil
                        )
                        fromPending += take
                        remainder -= take
                    }
                } catch {
                    return outcome(error)
                }
            }
        }
        // 3. Carried debt for whatever is still unfunded.
        if remainder > 0 {
            do {
                _ = try await context.client.rpcs.addDebt(
                    pHouseholdId: context.householdId, pAmountCents: remainder, pNote: note
                )
                toDebt = remainder
                remainder = 0
            } catch {
                return outcome(error)
            }
        }
        return outcome(nil)
    }

    /// The split as a plain suffix for toasts (" ($50.00 from
    /// Available, $50.00 from Pending)" — empty when the whole
    /// spend came from Available, the unremarkable case).
    private func savingsSplitSuffix(_ outcome: SavingsSpendOutcome) -> String {
        var parts: [String] = []
        if outcome.fromAvailableCents > 0 {
            parts.append("\(MoneyFormat.formatCents(outcome.fromAvailableCents)) from Available")
        }
        if outcome.fromPendingCents > 0 {
            parts.append("\(MoneyFormat.formatCents(outcome.fromPendingCents)) from Pending")
        }
        if outcome.toDebtCents > 0 {
            parts.append("\(MoneyFormat.formatCents(outcome.toDebtCents)) added to carried debt")
        }
        guard parts.count > 1 || outcome.toDebtCents > 0 || outcome.fromPendingCents > 0 else { return "" }
        return " (\(parts.joined(separator: ", ")))"
    }

    /// What already moved before a waterfall failure, in plain
    /// language for the alert ("Removed $50.00 of $100.00 before
    /// it stopped. …") — empty when nothing moved.
    private func partialSavingsMessage(_ outcome: SavingsSpendOutcome, amountCents: Int) -> String {
        guard outcome.totalCents > 0 else { return "" }
        return "Removed \(MoneyFormat.formatCents(outcome.totalCents)) of \(MoneyFormat.formatCents(amountCents)) before it stopped\(savingsSplitSuffix(outcome)). The completed part is recorded — check the \(fundName) Activity feed. "
    }

    /// "Remove from Savings" (build 42): the Savings card's single
    /// remove button. Admin only; the waterfall splits the amount
    /// across Available → Pending → Carried Debt. Returns true
    /// only when the whole amount is accounted for, so the caller
    /// clears the typed input on success only (F-P1-4).
    public func removeFromSavings(amountCents: Int, note: String) async -> Bool {
        guard context.isAdmin else {
            alertTitle = "Admin Only"
            alertMessage = "Only the admin can remove money from \(fundName)."
            return false
        }
        guard amountCents > 0 else {
            alertTitle = "Could Not Remove From \(fundName)"
            alertMessage = "Enter an amount above $0.00."
            return false
        }
        guard busyAction == nil else { return false }
        busyAction = "remove-from-savings"
        defer { busyAction = nil }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let ledgerNote = cleanNote.isEmpty ? "Removed from \(fundName)" : "Removed from \(fundName) — \(cleanNote)"
        let outcome = await spendFromSavings(amountCents: amountCents, note: ledgerNote)
        if let error = outcome.error {
            alertTitle = "Could Not Remove From \(fundName)"
            alertMessage = partialSavingsMessage(outcome, amountCents: amountCents) + userMessage(for: error)
            await refresh()
            return false
        }
        succeed("Removed \(MoneyFormat.formatCents(amountCents)) from \(fundName)\(savingsSplitSuffix(outcome)).")
        await refresh()
        return true
    }

    /// Designate a transaction as a Savings transaction (build 42,
    /// owner Nov 17, 2026). Admin only. Two directions, both
    /// immediate (no pending state) and both written to the fund
    /// ledger / history so they appear in the Savings Activity &
    /// Transactions feed:
    ///   (1) Money-in (income / refund / cashback): `add_fund_money`
    ///       with the toggle ON (confirmed) — the money is already
    ///       in checking, so it counts at once. The client key is
    ///       derived from the transaction id, so retrying the same
    ///       designation replays the stored split instead of
    ///       double-crediting; a replayed result reports the row as
    ///       already designated. The standing shortfall-first split
    ///       applies: if money is owed back, that part covers the
    ///       shortfall first and only the rest raises Available.
    ///       `allocate_fund` cannot express this direction — it
    ///       only ever writes a NEGATIVE ledger entry.
    ///   (2) Charge: the waterfall (`spendFromSavings`) — Available
    ///       first, then Pending top-ups, then carried debt.
    /// The transaction row itself is NOT changed: no existing RPC
    /// both moves fund money and links it to a transaction
    /// (`allocate_fund` takes no transaction id), so the row keeps
    /// its kind — a designated charge still counts toward weekly
    /// spending (compute-week subtracts only
    /// `fund_allocation_cents`, which this does not set). Taking
    /// it out of weekly spending is a separate decision: reclassify
    /// to fund_charge, or cover it through the fund-request approval
    /// path (`approve_and_allocate`, which sets
    /// `fund_allocation_cents`).
    /// Returns a success message for the caller's toast, or nil on
    /// failure (with `alertTitle` / `alertMessage` set, for the
    /// caller to surface — the Actions sheet owns the visible
    /// alert). The fund move has no idempotency key on the charge
    /// path, so a second designation of the same charge would move
    /// the money again; the sheet closes on success, so the action
    /// cannot be tapped twice for one row in practice.
    public func designateTransactionAsSavings(_ transaction: Transaction) async -> String? {
        guard context.isAdmin else {
            alertTitle = "Admin Only"
            alertMessage = "Only the admin can designate transactions as \(fundName)."
            return nil
        }
        let cents = abs(transaction.amountCents)
        guard cents > 0 else {
            alertTitle = "Could Not Designate as \(fundName)"
            alertMessage = "This transaction has no amount to designate."
            return nil
        }
        guard transaction.state != .reversed && !transaction.isInTrash else {
            alertTitle = "Could Not Designate as \(fundName)"
            alertMessage = "A reversed or trashed transaction cannot be designated as \(fundName)."
            return nil
        }
        guard busyAction == nil else { return nil }
        busyAction = "designate-savings"
        defer { busyAction = nil }
        // Fresh fund figures: the waterfall splits on live balances
        // and the pending top-ups list.
        await refresh()
        let merchant = TransactionFormatting.displayMerchant(transaction.merchant)
        let ledgerNote = "\(fundName): \(merchant) — \(transaction.date)"
        if transaction.kind.isMoneyIn {
            do {
                let result = try await context.client.rpcs.addFundMoney(
                    pHouseholdId: context.householdId,
                    pAmountCents: cents,
                    pNote: ledgerNote,
                    pClientKey: "designate-savings-\(transaction.id.uuidString)",
                    pConfirmed: true
                )
                if result.replayed {
                    alertTitle = "Already Designated"
                    alertMessage = "This transaction was already designated as \(fundName)."
                    return nil
                }
                await refresh()
                if result.shortfallCoveredCents > 0 {
                    return "Designated as \(fundName): \(MoneyFormat.formatCents(cents)) in — \(MoneyFormat.formatCents(result.shortfallCoveredCents)) covered owed back, \(MoneyFormat.formatCents(result.fundAddedCents)) added to \(fundName) Available."
                }
                return "Designated as \(fundName): \(MoneyFormat.formatCents(cents)) added to \(fundName) Available."
            } catch {
                fail(title: "Could Not Designate as \(fundName)", error: error)
                return nil
            }
        }
        guard transaction.kind == .charge else {
            alertTitle = "Does Not Qualify"
            alertMessage = "Only a charge or money-in can be designated as \(fundName)."
            return nil
        }
        let outcome = await spendFromSavings(amountCents: cents, note: ledgerNote)
        if let error = outcome.error {
            alertTitle = "Could Not Designate as \(fundName)"
            alertMessage = partialSavingsMessage(outcome, amountCents: cents) + userMessage(for: error)
            await refresh()
            return nil
        }
        await refresh()
        return "Designated as \(fundName): \(MoneyFormat.formatCents(cents)) out of \(fundName)\(savingsSplitSuffix(outcome))."
    }

    // MARK: - Ask for Fund Money (all roles)

    /// Inserts a pending `fund_requests` row; audits
    /// "<fund> request created" with the fund's CURRENT display
    /// name (build 43, item 16 — composed at action time, so a
    /// renamed fund reads with its new name; old rows stay as
    /// recorded). Best-effort — a blocked audit insert must not
    /// fail the request itself.
    /// Returns true only when the request was sent, so the caller
    /// clears the typed input on success only (F-P1-4).
    public func createFundRequest(amountCents: Int, note: String, transactionId: UUID?) async -> Bool {
        var succeeded = false
        await guarded("request", title: "Could Not Send Request") {
            let requestId = try await context.client.postgrest.createFundRequest(
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
                    action: "\(fundName) request created",
                    detail: "\(MoneyFormat.formatCents(amountCents)) requested."
                ))
            } catch {
                // Audit is best-effort only.
            }
            // Fund-request notification (Nov 16, 2026): the server
            // re-reads the request, verifies it is still pending,
            // and notifies the admins (excluding the requester).
            await notifyPush([
                "type": "fund_request",
                "household_id": context.householdId.uuidString,
                "request_id": requestId.uuidString,
            ])
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

    /// Manual top-up to the charity Available balance (owner,
    /// Nov 16, 2026 — build 39): the owner decides to give an
    /// amount (e.g. $25) and adds it by hand. It reuses
    /// `record_charity_income` with a 100% rate override — the
    /// whole amount commits to charity, so Available rises by
    /// exactly the amount. No new server surface and no migration:
    /// the per-income override REPLACES the default (R13), 100% is
    /// inside the legal 0–10000 bp range, and the RPC already
    /// audits the entry (audit_log "Charity income recorded" plus
    /// the income row in the Activity & Transactions feed, source
    /// "Manual add"). It does NOT touch the 10% default rate, the
    /// weekly allowance, or Given/Pending. Returns true only when
    /// the save committed, so the caller clears the typed input on
    /// success only (F-P1-4).
    public func addToCharity(amountCents: Int) async -> Bool {
        var succeeded = false
        await guarded("add-charity", title: "Could Not Add to \(charityName)") {
            let result = try await context.client.rpcs.recordCharityIncome(
                pHouseholdId: context.householdId,
                pAmountCents: amountCents,
                pIncomeDate: MoneyFormat.todayNY(),
                pSourceLabel: "Manual add",
                pRateBp: 10000,
                pNote: ""
            )
            succeed("Added \(MoneyFormat.formatCents(result.committedCents)) to \(charityName).")
            succeeded = true
            await refresh()
        }
        return succeeded
    }

    /// Record a cash gift given off-card (build 40, owner Nov 16,
    /// 2026): the owner gave charity in cash and wants to take it
    /// off what he owes. Available decreases by the amount, Given
    /// increases by it, Total (committed) is unchanged — and NO
    /// transaction row is created (that is the whole point: cash is
    /// not traceable as a bank/email transaction). The gift IS
    /// recorded on the charity fund and appears in the Charity
    /// Activity & Transactions feed. The RPC refuses when the amount
    /// exceeds the Available balance, so the gift can never take
    /// Available below $0. Returns true only when the save committed,
    /// so the caller clears the typed input on success only (F-P1-4).
    public func recordCharityCashGift(amountCents: Int, note: String) async -> Bool {
        var succeeded = false
        await guarded("record-cash-gift", title: "Could Not Record Gift") {
            let result = try await context.client.rpcs.recordCharityCashGift(
                pHouseholdId: context.householdId,
                pAmountCents: amountCents,
                pGiftDate: MoneyFormat.todayNY(),
                pNote: note
            )
            succeed("Recorded a \(MoneyFormat.formatCents(amountCents)) gift. \(MoneyFormat.formatCents(result.remainingCents)) left to give.")
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

    // MARK: - Carried Debt fund (admin only, build 29)

    /// Set the base weekly allowance via `set_base_allowance`
    /// (build 30 — the Budget card moved from Settings to the
    /// Spending fund container). Applies from the current week
    /// onward; closed weeks are never rewritten.
    public func setBaseAllowance(cents: Int) async {
        let oldBaseCents = baseAllowanceCents
        await guarded("base-allowance", title: "Could Not Save Allowance") {
            try await context.client.rpcs.setBaseAllowance(pHouseholdId: context.householdId, pCents: cents)
            // Budget-increased notification (Nov 16, 2026): only
            // when the allowance went UP, never on a decrease. The
            // server verifies the stored base matches the new value.
            if let old = oldBaseCents, cents > old {
                await notifyPush([
                    "type": "budget_increased",
                    "household_id": context.householdId.uuidString,
                    "kind": "base",
                    "old_cents": old,
                    "new_cents": cents,
                    "week_start": MoneyFormat.currentSundayNY(),
                ])
            }
            succeed("Allowance saved.")
            await refresh()
        }
    }

    /// Set the large-purchase threshold via
    /// `set_large_purchase_threshold` (Nov 16, 2026 — the Spending
    /// fund setting). Admin only.
    public func setLargePurchaseThreshold(cents: Int) async {
        await guarded("large-purchase-threshold", title: "Could Not Save Threshold") {
            try await context.client.rpcs.setLargePurchaseThreshold(pHouseholdId: context.householdId, pThresholdCents: cents)
            largePurchaseThresholdCents = cents
            succeed("Large purchase threshold saved.")
            await refresh()
        }
    }

    /// Add to Budget (Nov 16, 2026): a one-time top-up to the CURRENT
    /// week's budget only. The caller passes only the amount; the
    /// server adds it to the week's current total and returns the new
    /// total. Fires the budget-increased notification. Returns true
    /// only on success, so the caller clears the typed input on
    /// success only (like addToCharity).
    public func addToBudget(amountCents: Int) async -> Bool {
        var succeeded = false
        await guarded("add-budget", title: "Could Not Top Up Budget") {
            let newTotalCents = try await context.client.rpcs.addToWeeklyBudget(
                pHouseholdId: context.householdId,
                pWeekStart: MoneyFormat.currentSundayNY(),
                pAmountCents: amountCents
            )
            await notifyPush([
                "type": "budget_increased",
                "household_id": context.householdId.uuidString,
                "kind": "add",
                "old_cents": newTotalCents - amountCents,
                "new_cents": newTotalCents,
                "week_start": MoneyFormat.currentSundayNY(),
            ])
            succeeded = true
            succeed("Added \(MoneyFormat.formatCents(amountCents)). This week's budget is now \(MoneyFormat.formatCents(newTotalCents)).")
            // Build 43, item 21: refresh() reloads the week's
            // top-ups (`loadWeeklyBudgetTopups`), so the Spending
            // breakdown's "Top Ups" line updates without a manual
            // refresh — no separate reload call needed here.
            await refresh()
        }
        return succeeded
    }

    /// Set the repayment rule via `set_debt_repayment_rule`.
    /// Future-only: it applies to the current open week and future
    /// weeks; closed weeks keep their stored payment.
    public func setDebtRule(_ rule: DebtRule) async {
        await guarded("debt-rule", title: "Could Not Save Rule") {
            try await context.client.rpcs.setDebtRepaymentRule(pHouseholdId: context.householdId, rule: rule)
            succeed("\(debtName) repayment rule saved.")
            await refresh()
        }
    }

    /// Pay debt from the Extra Fund via `pay_debt_from_fund`.
    /// Returns the remaining debt in cents. Throws `.insufficientFund`
    /// so the view can offer the typed-reason override retry, like
    /// `allocateFund` — the form surfaces that sheet instead of
    /// alerting. Refused when the amount exceeds the remaining debt
    /// (never silently partial).
    public func payDebtFromFund(amountCents: Int, note: String, overrideReason: String?) async throws -> Int {
        let remaining = try await context.client.rpcs.payDebtFromFund(
            pHouseholdId: context.householdId,
            pAmountCents: amountCents,
            pNote: note,
            pOverrideReason: overrideReason
        )
        succeed("\(debtName) payment recorded — \(MoneyFormat.formatCents(remaining)) left.")
        await refresh()
        return remaining
    }

    /// Clear (erase) the debt balance via `clear_debt`. No money
    /// moves; the RPC audits it. Refused when there is no debt.
    /// Clear carried debt (admin only). `amountCents == nil` clears
    /// ALL of it (build 29 behaviour); a value clears exactly that
    /// much — a partial write-off, audited the same way, NOT a
    /// payment from the Extra Fund (build 30). Returns true only
    /// when the clear committed, so the form can close on success.
    public func clearDebt(amountCents: Int? = nil, note: String = "") async -> Bool {
        guard busyAction == nil else { return false }
        busyAction = "debt-clear"
        defer { busyAction = nil }
        let before = debtBalanceCents ?? 0
        do {
            let cleared = try await context.client.rpcs.clearDebt(
                pHouseholdId: context.householdId, pNote: note, pAmountCents: amountCents
            )
            let remaining = max(0, before - cleared)
            if cleared >= before {
                succeed("\(debtName) cleared — \(MoneyFormat.formatCents(cleared)) erased.")
            } else {
                succeed("Cleared \(MoneyFormat.formatCents(cleared)) — \(MoneyFormat.formatCents(remaining)) of carried debt left.")
            }
            await refresh()
            return true
        } catch {
            fail(title: "Could Not Clear \(debtName)", error: error)
            return false
        }
    }

    /// Add to the carried debt via `add_debt` (build 41 — owner Nov
    /// 17, 2026). Admin only; the RPC records the adjustment and
    /// audits it, and returns the new balance. Returns true only
    /// when the add committed.
    public func addDebt(amountCents: Int, note: String) async -> Bool {
        guard busyAction == nil else { return false }
        busyAction = "debt-add"
        defer { busyAction = nil }
        do {
            let balance = try await context.client.rpcs.addDebt(
                pHouseholdId: context.householdId, pAmountCents: amountCents, pNote: note
            )
            succeed("\(debtName) increased by \(MoneyFormat.formatCents(amountCents)) — now \(MoneyFormat.formatCents(balance)).")
            await refresh()
            return true
        } catch {
            fail(title: "Could Not Add \(debtName)", error: error)
            return false
        }
    }

    /// Set the carried debt to a total via `set_debt` (build 41).
    /// Admin only; the adjustment is the delta against the current
    /// balance, recorded and audited by the RPC, which returns the
    /// new balance. The caller pre-validates that the target differs
    /// from the current balance (the RPC raises on a zero delta).
    public func setDebt(amountCents: Int, note: String) async -> Bool {
        guard busyAction == nil else { return false }
        busyAction = "debt-set"
        defer { busyAction = nil }
        do {
            let balance = try await context.client.rpcs.setDebt(
                pHouseholdId: context.householdId, pAmountCents: amountCents, pNote: note
            )
            succeed("\(debtName) set to \(MoneyFormat.formatCents(balance)).")
            await refresh()
            return true
        } catch {
            fail(title: "Could Not Set \(debtName)", error: error)
            return false
        }
    }

    /// Rename a fund (build 37 — fund rename, owner Nov 16, 2026).
    /// Admin only, server-side. The name is stored exactly as typed
    /// (no Title Case forcing); an empty name resets that fund to
    /// its default. Returns the household's updated fund_names map
    /// on success, so the caller (FundsView) can update the shared
    /// `appState.fundNames` — the ONE source every view reads from.
    /// On failure the plain-language error is set on `alertTitle` /
    /// `alertMessage` and nil is returned.
    public func renameFund(section: FundSectionID, name: String) async -> [String: String]? {
        guard busyAction == nil else { return nil }
        busyAction = "fund-rename"
        defer { busyAction = nil }
        do {
            let names = try await context.client.rpcs.setFundName(
                pHouseholdId: context.householdId, pFundKey: section.rawValue, pName: name
            )
            let shown = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.isEmpty {
                succeed("\(section.displayName) reset to its default name.")
            } else {
                succeed("Fund renamed to \"\(shown)\".")
            }
            return names
        } catch {
            fail(title: "Could Not Rename Fund", error: error)
            return nil
        }
    }

    /// Set a fund's custom icon (build 41 — customizable fund
    /// icons, owner Nov 16, 2026). Mirrors renameFund exactly:
    /// admin only, server-side; an empty icon resets that fund to
    /// its default icon. Returns the household's updated fund_icons
    /// map on success, so the caller (FundsView) can update the
    /// shared `appState.fundIcons` — the ONE source every view
    /// reads from. On failure the plain-language error is set on
    /// `alertTitle` / `alertMessage` and nil is returned.
    public func setFundIcon(section: FundSectionID, icon: String) async -> [String: String]? {
        guard busyAction == nil else { return nil }
        busyAction = "fund-icon"
        defer { busyAction = nil }
        do {
            let icons = try await context.client.rpcs.setFundIcon(
                pHouseholdId: context.householdId, pFundKey: section.rawValue, pIcon: icon
            )
            let shown = icon.trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.isEmpty {
                succeed("\(section.displayName) reset to its default icon.")
            } else {
                succeed("Fund icon changed.")
            }
            return icons
        } catch {
            fail(title: "Could Not Change Fund Icon", error: error)
            return nil
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
        let oldTotalCents = currentWeekTotalCents
        await guarded("temp", title: "Could Not Set Allowance") {
            try await context.client.rpcs.setWeeklyAllowanceOverride(
                pHouseholdId: context.householdId,
                firstWeekStart: MoneyFormat.currentSundayNY(),
                pAllowanceCents: newTotalCents,
                weeks: weeks
            )
            // Budget-increased notification (Nov 16, 2026): only
            // when the new total is HIGHER than this week's current
            // total, never on a decrease. The server verifies the
            // stored override matches the new total.
            if let old = oldTotalCents, newTotalCents > old {
                await notifyPush([
                    "type": "budget_increased",
                    "household_id": context.householdId.uuidString,
                    "kind": "temporary",
                    "old_cents": old,
                    "new_cents": newTotalCents,
                    "week_start": MoneyFormat.currentSundayNY(),
                ])
            }
            succeeded = true
            succeed("Weekly allowance set to \(MoneyFormat.formatCents(newTotalCents)) for \(weeks) week(s).")
            await refresh()
        }
        return succeeded
    }
}
