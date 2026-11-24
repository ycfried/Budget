import SwiftUI
import OnBudgetKit

/// Compact frequency suffix after an amount (build 68):
/// $7,000/mo, $500/wk — replaces "· Monthly" and "a month".
public extension ExpenseFrequency {
    var shortSuffix: String {
        switch self {
        case .weekly: return "/wk"
        case .monthly: return "/mo"
        case .quarterly: return "/qtr"
        case .yearly: return "/yr"
        }
    }
}

/// Red primary style for the remove confirm (build 68, item 8):
/// remove/delete confirms are #dc2626 on #fef2f2, never blue.
private struct ExpenseDangerButtonStyle: ButtonStyle {
    // NOTE: qualified ButtonStyle.Configuration — OnBudgetKit
    // exports its own `Configuration` enum, so the bare name
    // resolves to that and the style fails to conform.
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(hex: "#dc2626"))
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Color(hex: "#fef2f2"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Recurring Expenses (build 67, owner Nov 23, 2026)
//
// A new "Expense" tag for recurring living costs (HOA, mortgage,
// insurance…), distinct from Purchase, Donation, Income and
// Transfer. Tagging a transaction as an Expense takes it OUT of
// weekly spending — it becomes a fixed cost the Weekly Budget
// Calculator subtracts from income before working out the
// weekly allowance. The list lives here (opened from the Weekly
// Budget sheet's Recurring Expenses row — no new top-level tab);
// the editor opens from a list row, or right after tagging from
// a transaction's Actions sheet.
//
// The views are view-model-agnostic: the caller wires `onSave` /
// `onRemove` to its own view model (the Funds view model from
// the Weekly sheet, the Transactions view model from the list),
// so the editor works identically in both places.

// MARK: - List

/// The full Expenses list: each expense (name, amount,
/// frequency), the monthly total, and the weekly budget impact.
/// Rows are tappable for admins (opens the editor); members see
/// the list read-only — the editor's save/remove RPCs are
/// admin-only on the server, so a member never reaches a failing
/// save.
public struct ExpensesListView: View {
    public let expenses: [RecurringExpense]
    public let isAdmin: Bool
    public let onSave: (RecurringExpense, String, Int, ExpenseFrequency) async -> Bool
    public let onRemove: (RecurringExpense) async -> Bool
    public let onClose: () -> Void
    @State private var selectedExpense: RecurringExpense?
    /// The ⓘ beside "About These Expenses" (build 68, item 14):
    /// the explainer used to sit inline under the list.
    @State private var showAboutInfo = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        expenses: [RecurringExpense],
        isAdmin: Bool,
        onSave: @escaping (RecurringExpense, String, Int, ExpenseFrequency) async -> Bool,
        onRemove: @escaping (RecurringExpense) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.expenses = expenses
        self.isAdmin = isAdmin
        self.onSave = onSave
        self.onRemove = onRemove
        self.onClose = onClose
    }

    /// The monthly cost of all the expenses together — the figure
    /// the Calculator subtracts from income.
    private var monthlyTotalCents: Int {
        expenses.reduce(0) { $0 + $1.monthlyCents }
    }

    /// The weekly cost — the monthly total spread over the plan's
    /// 4.33 weeks per month, before the Calculator's holdback.
    private var weeklyTotalCents: Int {
        expenses.reduce(0) { $0 + $1.weeklyCents }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Recurring Expenses", onClose: onClose)
            // Summary card: the monthly total the Calculator
            // subtracts, and what it works out to per week.
            VStack(spacing: 0) {
                summaryRow(label: "Monthly Total", value: MoneyFormat.formatCents(monthlyTotalCents))
                SheetActionDivider()
                summaryRow(label: "Weekly Impact", value: "About \(MoneyFormat.formatCents(weeklyTotalCents))/wk")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .fundCardShadow()
            if expenses.isEmpty {
                Text("No expenses tagged yet — tag a transaction as an Expense from its Actions to add one.")
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(expenses) { expense in
                        expenseRow(expense)
                        if expense.id != expenses.last?.id {
                            SheetActionDivider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .fundCardShadow()
                HStack(spacing: 6) {
                    Button(action: { showAboutInfo = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About recurring expenses")
                    Text("About These Expenses")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
        .alert("Recurring Expenses", isPresented: $showAboutInfo) {
            Button("OK") {}
        } message: {
            Text("Expenses do not count toward weekly spending — the Weekly Budget Calculator uses them to work out the allowance.")
        }
        .sheet(item: $selectedExpense) { expense in
            ExpenseEditorSheet(
                expense: expense,
                onSave: { name, amountCents, frequency in
                    await onSave(expense, name, amountCents, frequency)
                },
                onRemove: {
                    await onRemove(expense)
                },
                onClose: { selectedExpense = nil }
            )
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
        }
        .padding(.vertical, 10)
    }

    private func expenseRow(_ expense: RecurringExpense) -> some View {
        Button {
            guard isAdmin else { return }
            selectedExpense = expense
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    // Merchant names are ALL CAPS, display-only
                    // (build 65) — expense names come from the
                    // merchant at tag time, so they read the same
                    // way here as in the Transactions list.
                    Text(TransactionFormatting.displayMerchant(expense.name))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(MoneyFormat.formatCents(expense.amountCents))\(expense.frequency.shortSuffix)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    // The monthly figure, when the frequency is
                    // not monthly — so a $480 quarterly row reads
                    // as $160/mo at a glance.
                    if expense.frequency != .monthly {
                        Text("\(MoneyFormat.formatCents(expense.monthlyCents))/mo")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
                if isAdmin {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

/// The expense editor: a fitted sheet with the name and amount
/// prefilled from the transaction, a frequency picker, and a
/// remove option. Edits the expense row only — the linked
/// transaction's own amount is never touched.
public struct ExpenseEditorSheet: View {
    public let expense: RecurringExpense
    public let onSave: (String, Int, ExpenseFrequency) async -> Bool
    public let onRemove: () async -> Bool
    public let onClose: () -> Void
    @State private var name: String
    @State private var amountText: String
    @State private var frequency: ExpenseFrequency
    @State private var error: String?
    @State private var isWorking = false
    @State private var showRemoveConfirm = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        expense: RecurringExpense,
        onSave: @escaping (String, Int, ExpenseFrequency) async -> Bool,
        onRemove: @escaping () async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.expense = expense
        self.onSave = onSave
        self.onRemove = onRemove
        self.onClose = onClose
        self._name = State(initialValue: expense.name)
        self._amountText = State(initialValue: String(format: "%.2f", Double(expense.amountCents) / 100.0))
        self._frequency = State(initialValue: expense.frequency)
    }

    /// The entered amount, in cents — nil when it does not parse.
    private var enteredCents: Int? {
        MoneyFormat.parseDollarsStrict(amountText)
    }

    /// The monthly cost of the entered amount at one frequency —
    /// so each frequency row shows what it works out to a month.
    private func monthlyCents(for frequency: ExpenseFrequency) -> Int? {
        guard let cents = enteredCents else { return nil }
        return Int((Double(cents) * frequency.monthlyFactor).rounded())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Expense", onClose: onClose)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                FundsTextField("Name", text: $name)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Amount")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                DollarTextField(text: $amountText, placeholder: "0.00", maxWidth: .infinity, minHeight: 48)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How Often")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                VStack(spacing: 0) {
                    ForEach(ExpenseFrequency.allCases, id: \.self) { option in
                        Button {
                            frequency = option
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: frequency == option ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(frequency == option ? DesignTokens.primary : Color(hex: "#9ca3af"))
                                Text(option.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                Spacer()
                                if let monthly = monthlyCents(for: option) {
                                    Text("\(MoneyFormat.formatCents(monthly))/mo")
                                        .font(.system(size: 14))
                                        .foregroundStyle(DesignTokens.muted)
                                }
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if option != ExpenseFrequency.allCases.last {
                            SheetActionDivider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
            }
            if let error {
                SoftErrorBox(error)
            }
            if showRemoveConfirm {
                Text("Remove this expense? The transaction counts as a purchase again, back in weekly spending.")
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.ink)
                TwoButtonRow {
                    Button("Remove Expense") {
                        Task {
                            isWorking = true
                            let ok = await onRemove()
                            isWorking = false
                            if ok { onClose() }
                        }
                    }
                    .buttonStyle(ExpenseDangerButtonStyle())
                    .disabled(isWorking)
                } secondary: {
                    Button("Keep It") { showRemoveConfirm = false }
                        .buttonStyle(TertiaryButtonStyle())
                }
            } else {
                TwoButtonRow {
                    Button("Save") {
                        Task {
                            let trimmed = name.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else {
                                error = "Enter a name."
                                return
                            }
                            guard let cents = enteredCents, cents > 0 else {
                                error = "Enter an amount above $0.00."
                                return
                            }
                            error = nil
                            isWorking = true
                            let ok = await onSave(trimmed, cents, frequency)
                            isWorking = false
                            if ok { onClose() }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isWorking)
                } secondary: {
                    Button("Cancel") { onClose() }
                        .buttonStyle(TertiaryButtonStyle())
                }
                // Below the Save / Cancel pair, not beside it — a
                // red text button, so it never shares a colour or
                // treatment with either button in the pair.
                Button("Remove Expense") { showRemoveConfirm = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: DesignTokens.errorTextHex))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        .presentationDetents([.fraction(0.45), .medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
    }
}
