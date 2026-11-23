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
    /// The charity fund's CURRENT display name (build 43, owner Nov
    /// 17, 2026 — item 16): the heading, the rate hint and the
    /// date error read it, never a hardcoded "Charity".
    public let fundName: String
    /// Closes the form back to the Funds list (owned by FundsView).
    public var onClose: () -> Void = {}
    /// Build 65 (owner, Nov 23, 2026 — item 8): called after a
    /// successful save, so a presenter that shows this form as a
    /// step (the + Add sheet) can close itself. Nil by default —
    /// the Funds page keeps its existing behaviour (the form stays
    /// open, cleared, beside the success toast).
    public var onSaved: (() -> Void)? = nil

    @State private var sourceText = ""
    @State private var amountText = ""
    @State private var incomeDate = Date()
    @State private var rateOverrideText = ""
    @State private var note = ""
    @State private var fieldError: String?
    /// Build 46 (owner, Nov 18, 2026 — "even when you go to
    /// correct it.. you can't delete it"): the delete confirm for
    /// the income being corrected — reversing it with no
    /// replacement, beside Cancel.
    @State private var showDeleteConfirm = false
    /// Build 47 (owner, Nov 19, 2026 — page cleanup): the long
    /// explanations live behind ⓘ, not inline — one alert each
    /// for the default-rate note and the correction note.
    @State private var showingRateInfo = false
    @State private var showingCorrectionInfo = false
    /// Build 47 (owner, Nov 19, 2026 — page cleanup): the Note
    /// field stays collapsed until the owner taps to add one —
    /// an empty note took a full row for nothing. True when a
    /// note is prefilled (correcting an entry that has one) or
    /// the owner opened it.
    @State private var showNoteField = false

    public init(viewModel: FundsViewModel, fundName: String, correcting: Binding<CharityIncome?>, onClose: @escaping () -> Void = {}, onSaved: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.fundName = fundName
        self._correcting = correcting
        self.onClose = onClose
        self.onSaved = onSaved
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
            return "This commits \(MoneyFormat.formatCents(committed)) at \(MoneyFormat.formatRateBp(effectiveRateBp))% — this entry only."
        }
        return "This commits \(MoneyFormat.formatCents(committed)) at \(MoneyFormat.formatRateBp(effectiveRateBp))% — the default rate."
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("\(fundName) Income & Rate")
                // Build 47 (owner, Nov 19, 2026 — page cleanup):
                // the "Admin only" line is gone (the form is
                // admin-only by construction) and the
                // change-the-default-rate note lives behind the ⓘ
                // — the current default rate is the fact the owner
                // needs, since the Rate field reads "blank =
                // default".
                HStack(spacing: 6) {
                    Text("Current default rate: \(MoneyFormat.formatRateBp(defaultRateBp))%.")
                        .font(.system(size: 15))
                    Button(action: { showingRateInfo = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About the default rate")
                }

                Divider()

                Text("Record Income")
                    .font(.system(size: 17, weight: .bold))
                // Build 47: adding needs no mode line — the
                // "Record Income" heading and the empty fields
                // already say it. Correcting shows one short line;
                // the reversal detail lives behind the ⓘ.
                if correcting != nil {
                    HStack(spacing: 6) {
                        Text("Correcting an earlier entry.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#6b7280"))
                        Button(action: { showingCorrectionInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About correcting an entry")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Source", required: true)
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
                // Build 47 (owner, Nov 19, 2026 — page cleanup):
                // the Note field stays collapsed until the owner
                // taps to add one — an empty note took a full row
                // for nothing. The capability stays: tap "Add a
                // Note" and the field appears; a prefilled note
                // (correcting an entry that has one) shows the
                // field with the note.
                if showNoteField {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("Note")
                        TextField("", text: $note)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    FundsQuietButton("Add a Note") {
                        showNoteField = true
                    }
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
                        // Build 47 (owner, Nov 19, 2026): just
                        // "Cancel" — "Correction" struck through.
                        // It reverts to add mode; the back button
                        // above the form closes it.
                        FundsTertiaryButton("Cancel") {
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
                if correcting != nil {
                    // Build 47 (owner, Nov 19, 2026 — "even when
                    // you go to correct it.. you can't delete it",
                    // build 46): Delete this income — reverse it
                    // with NO replacement, so a mistaken income
                    // can simply be removed instead of corrected.
                    // The entry stays, marked reversed; its
                    // committed figure drops out of Total. A proper
                    // RED button (FundsDangerButton — the app's
                    // error red #dc2626 on #fef2f2), full-width,
                    // right below the Save/Cancel row — not a quiet
                    // link at the bottom. Two-step confirm, as
                    // before.
                    if showDeleteConfirm {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This reverses the income — the \(MoneyFormat.formatCents(correcting?.committedCents ?? 0)) it committed no longer counts toward \(fundName). The entry stays, marked reversed.")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.ink)
                            HStack(spacing: 12) {
                                FundsDangerButton("Delete Income", isBusy: viewModel.busyAction == "delete-income") {
                                    Task {
                                        guard let income = correcting else { return }
                                        if await viewModel.reverseCharityIncome(income) {
                                            correcting = nil
                                            clearIncomeFields()
                                            onClose()
                                        }
                                    }
                                }
                                .accessibilityIdentifier("funds.confirmDeleteIncome")
                                FundsTertiaryButton("Keep It") {
                                    showDeleteConfirm = false
                                }
                            }
                        }
                    } else {
                        FundsDangerButton("Delete This Income") {
                            showDeleteConfirm = true
                        }
                        .accessibilityIdentifier("funds.deleteIncome")
                    }
                    // Build 47 (owner, Nov 19, 2026 — page
                    // cleanup): the page ends cleanly after the
                    // Delete button. The quiet Cancel that sat
                    // below it read as a stray partial "Cancel"
                    // line with dead space around it — it is gone.
                    // Closing the form is the back button above
                    // it; the row Cancel reverts to add mode.
                }
            }
        }
        .onAppear {
            if let correcting { prefill(correcting) }
        }
        .onChange(of: correcting) { _, newValue in
            if let newValue { prefill(newValue) } else { clearIncomeFields() }
        }
        // Build 47: the long explanations live behind ⓘ, not
        // inline — the default-rate note and the correction note.
        .alert(TitleCase.apply(to: "Default \(fundName) Rate"), isPresented: $showingRateInfo) {
            Button("OK") {}
        } message: {
            Text("Change the default rate in Default \(fundName) Rate under \(fundName) on the Funds page. A change affects future incomes only.")
        }
        .alert("Correcting an Entry", isPresented: $showingCorrectionInfo) {
            Button("OK") {}
        } message: {
            Text("Saving reverses it and adds a replacement. The old entry stays, marked reversed.")
        }
    }

    private func prefill(_ income: CharityIncome) {
        sourceText = income.sourceLabel
        amountText = String(format: "%.2f", Double(income.amountCents) / 100.0)
        incomeDate = MoneyFormat.date(from: income.incomeDate) ?? Date()
        rateOverrideText = MoneyFormat.formatRateBp(income.rateBp)
        note = income.note
        showNoteField = !income.note.isEmpty
    }

    private func clearIncomeFields() {
        sourceText = ""
        amountText = ""
        incomeDate = Date()
        rateOverrideText = ""
        note = ""
        fieldError = nil
        showDeleteConfirm = false
        showNoteField = false
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
            fieldError = "\(fundName) starts November 2026 — income before then cannot accrue."
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
                onSaved?()
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
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(isPresented: $showPopup) {
            AddToCharitySheet(
                viewModel: viewModel,
                fundName: fundName,
                onClose: { showPopup = false }
            )
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
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // full-screen cover — without it the short form
            // centres itself vertically in the full screen.
            Spacer()
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
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(isPresented: $showPopup) {
            RecordCashGiftSheet(
                viewModel: viewModel,
                fundName: fundName,
                onClose: { showPopup = false }
            )
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
                FundsMuted("Available to give: \(MoneyFormat.formatCents(availableCents)). The donation comes off Available and goes into Given.")
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
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // full-screen cover — without it the short form
            // centres itself vertically in the full screen.
            Spacer()
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
    /// Build 46 (owner, Nov 18, 2026): the cash gift whose delete
    /// confirm is open in the feed — one at a time, like the
    /// fund-transaction confirm inside FundTransactionRow.
    @State private var confirmingCashGiftId: UUID?

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
        /// A cash donation given off-card (build 40, Nov 16, 2026):
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
        // Build 55 (owner, Nov 22, 2026): an accrual whose linked
        // transaction is excluded does not appear in this feed —
        // excluded income is not income at all. The server reverses
        // the accrual on exclude; the feed hides the row so it
        // cannot read as live income. (Reversed rows whose
        // transaction is NOT excluded stay visible, marked
        // "(Reversed)" — the audit trail for a reclassification
        // or a correction.)
        var items: [FeedItem] = CharityIncome.visibleIncomeRows(viewModel.charityIncome, allTransactions: viewModel.allTransactions).map { .income($0) }
        items += giftTransactions.map { .gift($0) }
        // Cash gifts given off-card (build 40): recorded on the
        // charity fund, not transaction rows — this feed is their
        // audit trail, so they appear here with the "Cash donation"
        // label.
        items += viewModel.charityCashGifts.map { .cashGift($0) }
        // Build 52 (owner, Nov 20, 2026 — the same pattern as the
        // Transactions week list): the full feed shows at once,
        // no 20-cap and no "Showing the latest 20" note. The rows
        // are already fully loaded in memory (charity income,
        // gifts, cash gifts), so nothing is fetched to show them
        // all — and a header that only reflects the first 20
        // would repeat the week-list mistake.
        return items.sorted { $0.sortDate > $1.sortDate }
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
                        // Build 46 (owner, Nov 18, 2026): Delete
                        // from the feed itself — the gift rows had
                        // no Actions button, so Delete was only
                        // reachable from the Transactions list.
                        FundTransactionRow(
                            tx,
                            merchantRules: viewModel.merchantRules,
                            fundName: viewModel.fundName,
                            isAdmin: viewModel.context.isAdmin,
                            isDeleting: viewModel.busyAction == "delete-fund-tx",
                            onDelete: { tx, reason in
                                await viewModel.deleteFundTransaction(tx, reason: reason)
                            }
                        )
                    case .cashGift(let gift):
                        cashGiftRow(gift)
                    }
                    if index < feed.count - 1 {
                        Divider()
                    }
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
                // Build 48 (owner, Nov 19, 2026 — the Correct
                // button is "tiny pill-shaped"): a proper-size
                // button, not the small in-row style — 15pt
                // semibold, 12pt vertical / 16pt horizontal
                // padding, squarish rounded edges (cornerRadius 10,
                // the no-pills rule). Same grey tertiary fill as
                // the small style, so it introduces no new colour;
                // it is simply big enough to read and tap as a
                // button. This is the app's only Correct button
                // (charity income correction); the other small
                // in-row buttons (Delete, Show More, …) keep the
                // small style.
                Button {
                    correcting = row
                    openIncomeForm = true
                } label: {
                    Text("Correct")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color(hex: "#e5e7eb"))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .accessibilityIdentifier("charity.correctIncomeButton")
            }
        }
    }

    /// A cash donation given off-card (build 40, Nov 16, 2026): money
    /// given, so it shows in charity BLUE by kind — the same
    /// treatment as a gift transaction. Minimal overview (label +
    /// amount); the full detail — date, note, "cash, no transaction
    /// row" — expands on tap. Build 46 (owner, Nov 18, 2026 —
    /// "you can't delete it once it was added"): the detail offers
    /// Delete (admin only, two-step) — this row had NO delete path
    /// at all before, which is what the owner hit. Reversing the
    /// gift takes it out of Given and puts the money back in
    /// Available; the row stays in the audit trail, marked reversed.
    private func cashGiftRow(_ gift: CharityCashGift) -> some View {
        FundsActivityRow {
            HStack(spacing: 4) {
                Text("Cash donation")
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
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Given in cash on \(MoneyFormat.fmtLong(gift.giftDate)). No transaction row — cash is not traceable as a bank/email transaction.")
                    if !gift.note.isEmpty {
                        Text(gift.note)
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
                if viewModel.context.isAdmin, gift.status == "active" {
                    if confirmingCashGiftId == gift.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This removes the cash donation — the money goes back to \(viewModel.charityName) Available. The donation stays in the record, marked reversed.")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.ink)
                            HStack(spacing: 12) {
                                FundsPrimaryButton("Delete", isBusy: viewModel.busyAction == "delete-cash-gift") {
                                    Task {
                                        if await viewModel.deleteCharityCashGift(gift) {
                                            confirmingCashGiftId = nil
                                        }
                                    }
                                }
                                .accessibilityIdentifier("funds.confirmDeleteCashGift")
                                FundsTertiaryButton("Keep It") {
                                    confirmingCashGiftId = nil
                                }
                            }
                        }
                    } else {
                        FundsSmallTertiaryButton("Delete") {
                            confirmingCashGiftId = gift.id
                        }
                        .accessibilityIdentifier("funds.deleteCashGift")
                    }
                }
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
        // Build 52 (owner, Nov 20, 2026 — the same pattern as the
        // Transactions week list): the full feed shows at once,
        // no 20-cap and no "Showing the latest 20" note. The rows
        // are already fully loaded in memory (top-ups, fund
        // transactions, ledger allocations), so nothing is fetched
        // to show them all.
        return items.sorted { $0.sortDate > $1.sortDate }
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
                        // Build 46 (owner, Nov 18, 2026): Delete
                        // from the feed itself, like the charity
                        // feed — these rows had no Actions button.
                        FundTransactionRow(
                            tx,
                            merchantRules: viewModel.merchantRules,
                            fundName: viewModel.fundName,
                            isAdmin: viewModel.context.isAdmin,
                            isDeleting: viewModel.busyAction == "delete-fund-tx",
                            onDelete: { tx, reason in
                                await viewModel.deleteFundTransaction(tx, reason: reason)
                            }
                        )
                    case .allocation(let entry):
                        allocationRow(entry)
                    }
                    if index < feed.count - 1 {
                        Divider()
                    }
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
