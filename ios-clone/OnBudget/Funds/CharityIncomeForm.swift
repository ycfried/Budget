import SwiftUI
import OnBudgetKit

// MARK: - Charity Income & Rate (admin only — spec §9.3)
//
// "Admin only. Nothing is pulled in automatically."
// Charity is 10% on money actually received + manually entered amounts,
// from November 2026; no pre-November entries. Transfers, refunds,
// reimbursements, loans, and Extra Fund top-ups must NOT auto-accrue —
// this form records income by hand only; it never offers a transaction
// as charity income.
//
// Default rate: changeable, future-only unless correcting an old income.
// Per-single-transaction override REPLACES the default (never stacks).
// All changes are audited server-side.

public struct CharityIncomeForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// When non-nil the form corrects this entry instead of adding one.
    /// Owned by the parent (FundsView) so the Correct button in Fund
    /// Activity can open this form prefilled.
    @Binding public var correcting: CharityIncome?
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}

    @State private var sourceText = ""
    @State private var amountText = ""
    @State private var incomeDate = Date()
    @State private var rateOverrideText = ""
    @State private var note = ""
    @State private var fieldError: String?

    public init(viewModel: FundsViewModel, correcting: Binding<CharityIncome?>, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self._correcting = correcting
        self.onClose = onClose
    }

    private var defaultRateBp: Int { viewModel.charitySettings?.defaultRateBp ?? 1000 }
    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }
    private var overrideBp: Int? {
        rateOverrideText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : MoneyFormat.parseRatePercent(rateOverrideText)
    }
    private var effectiveRateBp: Int { overrideBp ?? defaultRateBp }

    private var previewText: String {
        guard let cents = amountCents, cents > 0 else { return "Enter an amount to see what it commits." }
        // Round HALF-UP, matching the server (r13-charity.sql:180,228)
        // and the model (Models.swift:925): (amount × rate + 5000) /
        // 10000. Truncating was off by 1¢ whenever the remainder hit
        // 5000 (e.g. $10.05 at 10% commits $1.01, not $1.00).
        let committed = Int((Int64(cents) * Int64(effectiveRateBp) + 5000) / 10_000)
        if overrideBp != nil {
            return "This commits \(MoneyFormat.formatCents(committed)) at \(MoneyFormat.formatRateBp(effectiveRateBp))% — this entry only (the default rate for future incomes is unchanged)."
        }
        return "This commits \(MoneyFormat.formatCents(committed)) at \(MoneyFormat.formatRateBp(effectiveRateBp))% — the default rate, applied to this entry."
    }

    private var modeText: String {
        correcting == nil
            ? "Adding new income."
            : "Correcting an earlier entry — saving reverses it and adds a replacement. The old entry stays, marked reversed."
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 16) {
                FundsHeading("Charity Income & Rate")
                FundsMuted("Admin only. Nothing is pulled in automatically.")
                Text("Current default rate: \(MoneyFormat.formatRateBp(defaultRateBp))%.")
                    .font(.system(size: 15))
                FundsMuted("Change the default rate in Default Charity Rate under Charity on the Funds page. A change affects future incomes only.")

                Divider()

                Text("Record Income")
                    .font(.system(size: 17, weight: .bold))
                Text(modeText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source (for example, Paycheck)")
                        .font(.system(size: 14, weight: .semibold))
                    TextField("", text: $sourceText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sourceText) { _, newValue in
                            if newValue.count > 80 { sourceText = String(newValue.prefix(80)) }
                        }
                }
                FundsMoneyField("Amount ($)", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date")
                        .font(.system(size: 14, weight: .semibold))
                    DateField(date: $incomeDate)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rate % (blank = default)")
                        .font(.system(size: 14, weight: .semibold))
                    TextField("", text: $rateOverrideText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note (optional)")
                        .font(.system(size: 14, weight: .semibold))
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                HStack(spacing: 12) {
                    FundsPrimaryButton("Save Income", isBusy: viewModel.busyAction == "income") {
                        saveIncome()
                    }
                    if correcting != nil {
                        FundsTertiaryButton("Cancel Correction") {
                            correcting = nil
                            clearIncomeFields()
                        }
                    } else {
                        FundsTertiaryButton("Cancel") {
                            clearIncomeFields()
                            onClose()
                        }
                    }
                }
                // While correcting, Cancel Correction reverts to add
                // mode; this quiet Cancel closes the form outright
                // (kept off the button row so the two cancels never
                // sit next to each other in the same treatment).
                if correcting != nil {
                    FundsQuietButton("Cancel") {
                        correcting = nil
                        clearIncomeFields()
                        onClose()
                    }
                }
            }
        }
        .onAppear {
            if let correcting { prefill(correcting) }
        }
        .onChange(of: correcting) { _, newValue in
            if let newValue { prefill(newValue) } else { clearIncomeFields() }
        }
    }

    private func prefill(_ income: CharityIncome) {
        sourceText = income.sourceLabel
        amountText = String(format: "%.2f", Double(income.amountCents) / 100.0)
        incomeDate = MoneyFormat.date(from: income.incomeDate) ?? Date()
        rateOverrideText = MoneyFormat.formatRateBp(income.rateBp)
        note = income.note
    }

    private func clearIncomeFields() {
        sourceText = ""
        amountText = ""
        incomeDate = Date()
        rateOverrideText = ""
        note = ""
        fieldError = nil
    }

    private func saveIncome() {
        let source = sourceText.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else {
            fieldError = "Enter a source for this income."
            return
        }
        guard let cents = amountCents, cents > 0 else {
            fieldError = "Enter a valid amount."
            return
        }
        let dateString = MoneyFormat.dateString(from: incomeDate)
        guard dateString >= MoneyFormat.dataFloor else {
            fieldError = "Charity starts November 2026 — income before then cannot accrue."
            return
        }
        if !rateOverrideText.trimmingCharacters(in: .whitespaces).isEmpty, overrideBp == nil {
            fieldError = "Enter a rate between 0 and 100, or leave it blank for the default."
            return
        }
        fieldError = nil
        Task {
            // Clear only on success — on failure the typed input
            // (and the correction, if any) stays beside the error
            // (F-P1-4).
            if await viewModel.saveIncome(
                correcting: correcting,
                amountCents: cents,
                date: dateString,
                sourceLabel: source,
                rateBp: overrideBp,
                note: note.trimmingCharacters(in: .whitespaces)
            ) {
                correcting = nil
                clearIncomeFields()
            }
        }
    }
}

// MARK: - Charity income history (Fund Activity, admin only — spec §9.2)
//
// Build 36 (owner, Nov 16, 2026): "Activity & Transactions" — ONE
// combined feed, newest first: the income events AND the charity
// gift transactions themselves (kind == .charity), capped at 20.
// Overview rows are MINIMAL — source + amount only — and tapping a
// row expands the full detail inline (date, rate, commits, note,
// reversed status). The full sentence per row is gone from the
// overview. Active rows keep their Correct button, in the expanded
// detail (never nested inside the row toggle).

public struct CharityIncomeHistory: View {
    @ObservedObject public var viewModel: FundsViewModel
    @Binding public var correcting: CharityIncome?
    @Binding public var openIncomeForm: Bool

    public init(viewModel: FundsViewModel, correcting: Binding<CharityIncome?>, openIncomeForm: Binding<Bool>) {
        self.viewModel = viewModel
        self._correcting = correcting
        self._openIncomeForm = openIncomeForm
    }

    /// One combined feed item. Both dates are `YYYY-MM-DD`, so a
    /// plain string sort is newest-first.
    private enum FeedItem: Identifiable {
        case income(CharityIncome)
        case gift(Transaction)

        var id: String {
            switch self {
            case .income(let row): return "income-\(row.id.uuidString)"
            case .gift(let tx): return "gift-\(tx.id.uuidString)"
            }
        }

        var sortDate: String {
            switch self {
            case .income(let row): return row.incomeDate
            case .gift(let tx): return tx.date
            }
        }
    }

    /// The charity gift transactions in this feed: verified or
    /// pending gifts, never trash or reversed, November 2026 onward
    /// (the same filter the charity summary uses).
    private var giftTransactions: [Transaction] {
        viewModel.allTransactions.filter {
            $0.kind == .charity && !$0.isInTrash && $0.state != .reversed && $0.date >= MoneyFormat.dataFloor
        }
    }

    private var feed: [FeedItem] {
        var items: [FeedItem] = viewModel.charityIncome.map { .income($0) }
        items += giftTransactions.map { .gift($0) }
        return Array(items.sorted { $0.sortDate > $1.sortDate }.prefix(20))
    }

    private var totalCount: Int {
        viewModel.charityIncome.count + giftTransactions.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.charityIncomeError {
                FundsErrorBox(error)
            } else if let transactionsError = viewModel.transactionsError, feed.isEmpty {
                // The gift half of the feed could not load — say so
                // instead of silently showing income only.
                FundsErrorBox(transactionsError)
            } else if feed.isEmpty {
                FundsMuted("No income recorded yet.")
            } else {
                ForEach(Array(feed.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .income(let row):
                        incomeRow(row)
                    case .gift(let tx):
                        FundTransactionRow(tx)
                    }
                    if index < feed.count - 1 {
                        Divider()
                    }
                }
                if totalCount > 20 {
                    FundsMuted("Showing the latest 20 entries.")
                }
            }
        }
    }

    /// Minimal overview (source + amount); the full detail — date,
    /// rate, commits, note, reversed status — expands on tap, with
    /// the Correct action in the expanded detail.
    private func incomeRow(_ row: CharityIncome) -> some View {
        // The income amount is money in: green with a "+" prefix
        // under the shared kind rule (inflowDisplay). The committed
        // figure stays plain — it is an obligation, not an inflow.
        let display = TransactionFormatting.inflowDisplay(cents: row.amountCents)
        return FundsActivityRow {
            HStack(spacing: 4) {
                Text(row.sourceLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(display.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(display.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if row.status == "reversed" {
                    Text("(Reversed)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 2) {
                Text("On \(MoneyFormat.fmtLong(row.incomeDate)) at \(MoneyFormat.formatRateBp(row.rateBp))% → commits \(MoneyFormat.formatCents(row.committedCents)).")
                if !row.note.isEmpty {
                    Text(row.note)
                }
                if row.status == "reversed" {
                    Text("Reversed — replaced by a correction.")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
            if row.status == "active" {
                FundsSmallTertiaryButton("Correct") {
                    correcting = row
                    openIncomeForm = true
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Money Added history (Fund Activity, admin only — spec §9.2)
//
// Build 36 (owner, Nov 16, 2026): "Activity & Transactions" — ONE
// combined feed, newest first: the top-ups AND the transactions
// that touched the Extra Fund (kind == .fundCharge, or any charge
// with fundAllocationCents > 0 — partly covered by the fund),
// capped at 20. Overview rows are MINIMAL — amount only for a
// top-up — and tapping expands the full split detail.

public struct FundTopupsHistory: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    /// The transactions that touched the Extra Fund: spent-from-fund
    /// charges, plus charges partly covered by the fund. Never trash
    /// or reversed, November 2026 onward.
    private var fundTransactions: [Transaction] {
        viewModel.allTransactions.filter {
            ($0.kind == .fundCharge || $0.fundAllocationCents > 0)
                && !$0.isInTrash && $0.state != .reversed && $0.date >= MoneyFormat.dataFloor
        }
    }

    /// One combined feed item. Top-ups sort by their created date;
    /// transactions by their date — both `YYYY-MM-DD` prefixes, so
    /// a plain string sort is newest-first.
    private enum FeedItem: Identifiable {
        case topup(FundTopup)
        case transaction(Transaction)

        var id: String {
            switch self {
            case .topup(let row): return "topup-\(row.clientKey)"
            case .transaction(let tx): return "tx-\(tx.id.uuidString)"
            }
        }

        var sortDate: String {
            switch self {
            case .topup(let row): return String(row.createdAt?.prefix(10) ?? "")
            case .transaction(let tx): return tx.date
            }
        }
    }

    private var feed: [FeedItem] {
        var items: [FeedItem] = viewModel.topups.map { .topup($0) }
        items += fundTransactions.map { .transaction($0) }
        return Array(items.sorted { $0.sortDate > $1.sortDate }.prefix(20))
    }

    private var totalCount: Int {
        viewModel.topups.count + fundTransactions.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.topupsError {
                FundsErrorBox(error)
            } else if feed.isEmpty {
                FundsMuted("No fund activity yet.")
            } else {
                ForEach(Array(feed.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .topup(let row):
                        topupRow(row)
                    case .transaction(let tx):
                        FundTransactionRow(tx)
                    }
                    if index < feed.count - 1 {
                        Divider()
                    }
                }
                if totalCount > 20 {
                    FundsMuted("Showing the latest 20 entries.")
                }
            }
        }
    }

    /// Minimal overview (amount only); the full split detail —
    /// date, covered owed back, added to fund, owed back after,
    /// note — expands on tap.
    private func topupRow(_ row: FundTopup) -> some View {
        // The top-up is money into the fund: green with a "+"
        // prefix under the shared kind rule (inflowDisplay).
        let display = TransactionFormatting.inflowDisplay(cents: row.amountCents)
        return FundsActivityRow {
            Text(display.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(display.color)
        } detail: {
            // The split detail stays muted and plain — its parts are
            // destinations of the top-up, not standalone inflows.
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.createdAt.map { MoneyFormat.displayDay($0) } ?? "") · \(MoneyFormat.formatCents(row.shortfallCoveredCents)) covered owed back · \(MoneyFormat.formatCents(row.fundAddedCents)) added to fund · Owed back after \(MoneyFormat.formatCents(row.shortfallAfterCents))")
                if !row.note.isEmpty {
                    Text(row.note)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
        }
    }
}
