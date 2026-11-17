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
                    FieldLabel("Source (for example, Paycheck)", required: true)
                    TextField("", text: $sourceText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sourceText) { _, newValue in
                            if newValue.count > 80 { sourceText = String(newValue.prefix(80)) }
                        }
                }
                FundsMoneyField("Amount", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Date")
                    DateField(date: $incomeDate)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Rate % (blank = default)")
                    TextField("", text: $rateOverrideText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Note")
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

// MARK: - Add to Charity (manual top-up, admin only)
//
// Build 39 (owner, Nov 16, 2026): the owner decides to give an
// amount (e.g. $25) and adds it by hand to the available charity
// balance. Build 40 (owner, Nov 16, 2026): the button opens a
// POPUP (sheet) to fill out the amount — the inline $ field +
// button in the detail is gone ("This button should bring up a
// popup to fill out."). The button keeps its label (with the
// fund's CURRENT name, e.g. "Add to Tzedaka"), full-width,
// primary blue, and stays primary blue vs the grey "Record
// Income" below it. The popup has the amount field + Add/Cancel;
// validation lives INSIDE the popup (amount must be above $0.00 —
// the error shows in the popup in plain language and the popup
// does not close on a bad amount). On success the popup closes,
// the field clears and the view model refreshes, so the new
// Available shows on Funds, Home and the widget from the same
// server source (record_charity_income, 100% rate override,
// source "Manual add"). The 10% default rate, the Record Income
// flow and Given/Pending are untouched.

public struct AddToCharitySection: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// The fund's CURRENT display name (e.g. "Tzedaka" when
    /// renamed) — the button and the popup title use it, so the
    /// action reads with the name the owner chose.
    public let fundName: String
    @State private var showPopup = false

    public init(viewModel: FundsViewModel, fundName: String) {
        self.viewModel = viewModel
        self.fundName = fundName
    }

    public var body: some View {
        FundsPrimaryButton("Add to \(fundName)", isBusy: viewModel.busyAction == "add-charity", isLarge: true) {
            showPopup = true
        }
        .accessibilityIdentifier("funds.addToCharity")
        .sheet(isPresented: $showPopup) {
            AddToCharitySheet(
                viewModel: viewModel,
                fundName: fundName,
                onClose: { showPopup = false }
            )
            .presentationSizing(.fitted)
        }
    }
}

/// The Add to Charity popup (owner, Nov 16, 2026 — build 40):
/// an amount field + Add/Cancel, in the rename sheet's style
/// (iPad 600pt centred, 17pt). Validation lives here: the amount
/// must be above $0.00 — empty / zero / negative shows a
/// plain-language error INSIDE the popup and the popup stays open
/// (the field keeps the typed input). On success the popup closes,
/// the field clears, and the Available balance updates everywhere.
public struct AddToCharitySheet: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let fundName: String
    public var onClose: () -> Void
    @State private var amountText = ""
    @State private var addError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: FundsViewModel, fundName: String, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Add to \(fundName)"), onClose: onClose)
            DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
            if let addError {
                FundsErrorBox(addError)
            }
            HStack(spacing: 12) {
                FundsPrimaryButton("Add", isBusy: viewModel.busyAction == "add-charity") {
                    add()
                }
                FundsTertiaryButton("Cancel") { onClose() }
            }
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // rename sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private func add() {
        guard let cents = MoneyFormat.parseDollarsStrict(amountText), cents > 0 else {
            addError = "Enter an amount above $0.00."
            return
        }
        addError = nil
        Task {
            // Clear only on success — on failure the typed input
            // stays beside the error (F-P1-4).
            if await viewModel.addToCharity(amountCents: cents) {
                amountText = ""
                onClose()
            }
        }
    }
}

// MARK: - Record a Transaction (cash given off-card, admin only)
//
// Build 40 (owner, Nov 16, 2026): the owner gives charity in CASH
// and wants to take it off what he owes — Available decreases,
// Given increases, Total (committed) unchanged — WITHOUT creating a
// transaction row (cash is not traceable as a bank/email transaction
// and would confuse the transaction history). The gift IS recorded
// on the charity fund and appears in the Charity Activity &
// Transactions feed. The button opens a POPUP (sheet, like the Add
// to Charity popup: iPad 600pt, 17pt) with an amount field + an
// a note + Record/Cancel. Validation lives INSIDE the popup:
// the amount must be above $0.00 and must not exceed the Available
// balance (the RPC refuses when it would take Available below $0) —
// the error shows in the popup in plain language and the popup does
// not close on a bad amount. On success the popup closes, the field
// clears, and the balances update everywhere (record_charity_cash_gift).
// The button and the popup title use the fund's CURRENT name (e.g.
// "Record a Transaction to Tzedaka").

public struct RecordCashGiftSection: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// The fund's CURRENT display name (e.g. "Tzedaka" when renamed).
    public let fundName: String
    @State private var showPopup = false

    public init(viewModel: FundsViewModel, fundName: String) {
        self.viewModel = viewModel
        self.fundName = fundName
    }

    public var body: some View {
        // The Charity card now stacks THREE full-width buttons
        // (Add to Charity / Record a Transaction / Record Income). The
        // standing no-adjacent-same-color rule (Nov 4, 2026) puts
        // pale #bfdbfe as the middle tier of a three-button row, so
        // this middle button is PALE — blue, pale, grey, no two
        // adjacent share a color — and isLarge so all three are the
        // same size (17pt, full width).
        FundsPaleButton("Record a Transaction", isLarge: true) {
            showPopup = true
        }
        .accessibilityIdentifier("funds.recordCashGift")
        .sheet(isPresented: $showPopup) {
            RecordCashGiftSheet(
                viewModel: viewModel,
                fundName: fundName,
                onClose: { showPopup = false }
            )
            .presentationSizing(.fitted)
        }
    }
}

/// The Record a Transaction popup (owner, Nov 16, 2026 — build 40): an
/// amount field + a note + Record/Cancel, in the rename
/// sheet's style (iPad 600pt centred, 17pt). Validation lives here:
/// the amount must be above $0.00 and must not exceed the Available
/// balance — empty / zero / negative / over-Available shows a
/// plain-language error INSIDE the popup and the popup stays open
/// (the field keeps the typed input). On success the popup closes,
/// the field clears, and the balances update everywhere.
public struct RecordCashGiftSheet: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let fundName: String
    public var onClose: () -> Void
    @State private var amountText = ""
    @State private var noteText = ""
    @State private var giftError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: FundsViewModel, fundName: String, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.onClose = onClose
    }

    /// The Available charity balance, for the over-Available check
    /// (client-side; the RPC re-checks server-side and refuses too).
    private var availableCents: Int? { viewModel.charitySummary?.remainingCents }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Record a Transaction to \(fundName)"), onClose: onClose)
            if let availableCents {
                FundsMuted("Available to give: \(MoneyFormat.formatCents(availableCents)). The gift comes off Available and goes into Given.")
            }
            DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
            TextField("Note", text: $noteText)
                .font(.system(size: 17))
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 48)
                .autocorrectionDisabled()
            if let giftError {
                FundsErrorBox(giftError)
            }
            HStack(spacing: 12) {
                FundsPrimaryButton("Record", isBusy: viewModel.busyAction == "record-cash-gift") {
                    record()
                }
                FundsTertiaryButton("Cancel") { onClose() }
            }
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // rename sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private func record() {
        guard let cents = MoneyFormat.parseDollarsStrict(amountText), cents > 0 else {
            giftError = "Enter an amount above $0.00."
            return
        }
        if let availableCents, cents > availableCents {
            giftError = "That is more than the \(MoneyFormat.formatCents(availableCents)) available to give."
            return
        }
        giftError = nil
        Task {
            // Clear only on success — on failure the typed input
            // stays beside the error (F-P1-4).
            if await viewModel.recordCharityCashGift(amountCents: cents, note: noteText) {
                amountText = ""
                noteText = ""
                onClose()
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
        /// A cash gift given off-card (build 40, Nov 16, 2026):
        /// recorded on the charity fund, NOT a transaction row.
        case cashGift(CharityCashGift)

        var id: String {
            switch self {
            case .income(let row): return "income-\(row.id.uuidString)"
            case .gift(let tx): return "gift-\(tx.id.uuidString)"
            case .cashGift(let gift): return "cashgift-\(gift.id.uuidString)"
            }
        }

        var sortDate: String {
            switch self {
            case .income(let row): return row.incomeDate
            case .gift(let tx): return tx.date
            case .cashGift(let gift): return gift.giftDate
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
        // Cash gifts given off-card (build 40): recorded on the
        // charity fund, not transaction rows — this feed is their
        // audit trail, so they appear here with the "Cash gift"
        // label.
        items += viewModel.charityCashGifts.map { .cashGift($0) }
        return Array(items.sorted { $0.sortDate > $1.sortDate }.prefix(20))
    }

    private var totalCount: Int {
        viewModel.charityIncome.count + giftTransactions.count + viewModel.charityCashGifts.count
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
                        FundTransactionRow(tx, merchantRules: viewModel.merchantRules)
                    case .cashGift(let gift):
                        cashGiftRow(gift)
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
                Text(TransactionFormatting.displayMerchant(
                    MerchantDisplayName.displayName(for: row.sourceLabel, rules: viewModel.merchantRules)
                ))
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

    /// A cash gift given off-card (build 40, Nov 16, 2026): money
    /// given, so it shows in charity BLUE by kind — the same
    /// treatment as a gift transaction. Minimal overview (label +
    /// amount); the full detail — date, note, "cash, no transaction
    /// row" — expands on tap.
    private func cashGiftRow(_ gift: CharityCashGift) -> some View {
        FundsActivityRow {
            HStack(spacing: 4) {
                Text("Cash gift")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(MoneyFormat.formatCents(gift.amountCents))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.charity)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Given in cash on \(MoneyFormat.fmtLong(gift.giftDate)). No transaction row — cash is not traceable as a bank/email transaction.")
                if !gift.note.isEmpty {
                    Text(gift.note)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
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

    /// The fund-ledger 'allocation' entries (build 40, Nov 16,
    /// 2026): direct fund spending — "Spend from Fund" and cash
    /// spent out of Savings — recorded as negative fund_ledger
    /// rows, NOT transaction rows, so they appear nowhere until now.
    /// Only negative allocations (money out); positive ledger rows
    /// (top-ups, releases) are shown by their own feed items.
    private var fundAllocations: [FundLedgerEntry] {
        viewModel.fundLedger.filter { $0.kind == "allocation" && $0.amountCents < 0 }
    }

    /// One combined feed item. Top-ups sort by their created date;
    /// transactions by their date — both `YYYY-MM-DD` prefixes, so
    /// a plain string sort is newest-first.
    private enum FeedItem: Identifiable {
        case topup(FundTopup)
        case transaction(Transaction)
        /// A fund-ledger 'allocation' (build 40): money spent out of
        /// the fund directly — "Spend from Fund" / cash spent — not
        /// a transaction row.
        case allocation(FundLedgerEntry)

        var id: String {
            switch self {
            case .topup(let row): return "topup-\(row.clientKey)"
            case .transaction(let tx): return "tx-\(tx.id.uuidString)"
            case .allocation(let entry): return "allocation-\(entry.id?.uuidString ?? "\(entry.createdAt ?? "")-\(entry.amountCents)-\(entry.note)")"
            }
        }

        var sortDate: String {
            switch self {
            case .topup(let row): return String(row.createdAt?.prefix(10) ?? "")
            case .transaction(let tx): return tx.date
            case .allocation(let entry): return String(entry.createdAt?.prefix(10) ?? "")
            }
        }
    }

    private var feed: [FeedItem] {
        var items: [FeedItem] = viewModel.topups.map { .topup($0) }
        items += fundTransactions.map { .transaction($0) }
        // Fund-ledger allocations (build 40): direct fund spending
        // — "Spend from Fund" and cash spent out of Savings — which
        // are NOT transaction rows, so this feed is their audit
        // trail.
        items += fundAllocations.map { .allocation($0) }
        return Array(items.sorted { $0.sortDate > $1.sortDate }.prefix(20))
    }

    private var totalCount: Int {
        viewModel.topups.count + fundTransactions.count + fundAllocations.count
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
                        FundTransactionRow(tx, merchantRules: viewModel.merchantRules)
                    case .allocation(let entry):
                        allocationRow(entry)
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
        // prefix under the shared kind rule (inflowDisplay) — but
        // only once it is CONFIRMED. A pending top-up is not in
        // checking yet, so it reads in ink with a Pending tag, not
        // green (build 41 — pending top-ups, owner Nov 17, 2026).
        let display = TransactionFormatting.inflowDisplay(cents: row.amountCents)
        return FundsActivityRow {
            HStack(spacing: 4) {
                Text(display.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(row.isPending ? DesignTokens.ink : display.color)
                if row.isPending {
                    Text("· Pending")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
        } detail: {
            // The split detail stays muted and plain — its parts are
            // destinations of the top-up, not standalone inflows.
            // A pending row has no split yet (it runs at confirm
            // time): the detail says so and offers the confirm.
            VStack(alignment: .leading, spacing: 6) {
                if row.isPending {
                    Text("Pending — not in checking yet. It does not count toward Available until you confirm it.")
                    Text("\(row.createdAt.map { MoneyFormat.displayDay($0) } ?? "")")
                    if !row.note.isEmpty {
                        Text(row.note)
                    }
                    FundsPrimaryButton("Confirm in Checking", isBusy: viewModel.busyAction == "confirm-topup") {
                        Task { await viewModel.confirmTopup(row) }
                    }
                } else {
                    Text("\(row.createdAt.map { MoneyFormat.displayDay($0) } ?? "") · \(MoneyFormat.formatCents(row.shortfallCoveredCents)) covered owed back · \(MoneyFormat.formatCents(row.fundAddedCents)) added to fund · Owed back after \(MoneyFormat.formatCents(row.shortfallAfterCents))")
                    if !row.note.isEmpty {
                        Text(row.note)
                    }
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    /// A fund-ledger 'allocation' (build 40, Nov 16, 2026): money
    /// spent out of the fund directly — "Spend from Fund" or cash
    /// spent out of Savings. The amount is a negative ledger entry;
    /// it shows as a plain (ink) outflow with a "−" prefix — NOT
    /// green (it is money out, not in) and NOT red (it is a planned
    /// fund use, not an over-budget error). Minimal overview (label
    /// + amount); the full detail — date, note — expands on tap.
    private func allocationRow(_ entry: FundLedgerEntry) -> some View {
        FundsActivityRow {
            HStack(spacing: 4) {
                Text(entry.note.hasPrefix("Cash spent") ? "Cash spent" : "Spent from fund")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text("−\(MoneyFormat.formatCents(-entry.amountCents))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.createdAt.map { MoneyFormat.displayDay($0) } ?? "") · \(MoneyFormat.formatCents(-entry.amountCents)) taken out of the fund.")
                if !entry.note.isEmpty {
                    Text(entry.note)
                }
                Text("No transaction row — recorded on the fund only.")
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
        }
    }
}
