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
                FundsMuted("Change the default rate in Funds & Charity Rules on the Funds page. A change affects future incomes only.")

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
                    DatePicker("", selection: $incomeDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
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
// "`Source` · `$X` on `Mon D, YYYY` at `R`% → commits `$Y` · note" +
// " (Reversed — replaced)" for reversed rows; active rows get a
// Correct button (opens the income form prefilled).

public struct CharityIncomeHistory: View {
    @ObservedObject public var viewModel: FundsViewModel
    @Binding public var correcting: CharityIncome?
    @Binding public var openIncomeForm: Bool

    public init(viewModel: FundsViewModel, correcting: Binding<CharityIncome?>, openIncomeForm: Binding<Bool>) {
        self.viewModel = viewModel
        self._correcting = correcting
        self._openIncomeForm = openIncomeForm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Charity Income")
                .font(.system(size: 17, weight: .bold))
            if let error = viewModel.charityIncomeError {
                FundsErrorBox(error)
            } else if viewModel.charityIncome.isEmpty {
                FundsMuted("No income recorded yet.")
            } else {
                ForEach(viewModel.charityIncome) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.sourceLabel) · \(MoneyFormat.formatCents(row.amountCents)) on \(MoneyFormat.fmtLong(row.incomeDate)) at \(MoneyFormat.formatRateBp(row.rateBp))% → commits \(MoneyFormat.formatCents(row.committedCents))\(row.note.isEmpty ? "" : " · \(row.note)")\(row.status == "reversed" ? " (Reversed — replaced)" : "")")
                                .font(.system(size: 14))
                        }
                        Spacer()
                        if row.status == "active" {
                            FundsSmallTertiaryButton("Correct") {
                                correcting = row
                                openIncomeForm = true
                            }
                        }
                    }
                    if row.id != viewModel.charityIncome.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Money Added history (Fund Activity, admin only — spec §9.2)
//
// "`$X` · `Mon D, YYYY` · `$Y` covered owed back · `$Z` added to fund ·
// Owed back after `$W` · note".

public struct FundTopupsHistory: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Money Added")
                .font(.system(size: 17, weight: .bold))
            if let error = viewModel.topupsError {
                FundsErrorBox(error)
            } else if viewModel.topups.isEmpty {
                FundsMuted("No money added yet.")
            } else {
                ForEach(viewModel.topups, id: \.clientKey) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MoneyFormat.formatCents(row.amountCents))
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(row.createdAt.map { MoneyFormat.displayDay($0) } ?? "") · \(MoneyFormat.formatCents(row.shortfallCoveredCents)) covered owed back · \(MoneyFormat.formatCents(row.fundAddedCents)) added to fund · Owed back after \(MoneyFormat.formatCents(row.shortfallAfterCents))\(row.note.isEmpty ? "" : " · \(row.note)")")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                    if row.clientKey != viewModel.topups.last?.clientKey {
                        Divider()
                    }
                }
            }
        }
    }
}
