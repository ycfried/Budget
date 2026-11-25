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
    /// The charges the tag picker offers (build 77, owner
    /// Nov 25, 2026 — add an expense from this sheet): the
    /// same live list the Calculator's picker reads.
    public let transactions: [Transaction]
    /// Tag a charge as a new expense (build 77): the Funds view
    /// model's tagExpense, so the new row is the SAME row the
    /// list and the Calculator read.
    public let onTag: (Transaction) async -> RecurringExpense?
    @State private var selectedExpense: RecurringExpense?
    /// The ⓘ beside "About These Expenses" (build 68, item 14):
    /// the explainer used to sit inline under the list.
    @State private var showAboutInfo = false
    /// The tag picker (build 77): adding an expense from this
    /// sheet picks a charge to tag, then opens the editor.
    @State private var showExpensePicker = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        expenses: [RecurringExpense],
        isAdmin: Bool,
        onSave: @escaping (RecurringExpense, String, Int, ExpenseFrequency) async -> Bool,
        onRemove: @escaping (RecurringExpense) async -> Bool,
        onClose: @escaping () -> Void,
        transactions: [Transaction],
        onTag: @escaping (Transaction) async -> RecurringExpense?
    ) {
        self.expenses = expenses
        self.isAdmin = isAdmin
        self.onSave = onSave
        self.onRemove = onRemove
        self.onClose = onClose
        self.transactions = transactions
        self.onTag = onTag
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
            // Build 74 (owner, Nov 24, 2026 — popup sizing): the
            // rows are unbounded, but this was a plain VStack with
            // no ScrollView — past ~4-5 expenses the rows ran past
            // the .medium detent with no way to scroll to them.
            // The header stays pinned; everything below it scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Build 77 (owner, Nov 25, 2026): "About
                    // These Expenses" sits ABOVE the section,
                    // not below it — and it shows always, not
                    // only when there are expenses. The tap →
                    // info alert behaviour is unchanged.
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
                    }
                    // Build 77 (owner, Nov 25, 2026): add an
                    // expense from this sheet directly — the
                    // same tag-a-charge flow the Calculator
                    // uses. Admin only (tagging is admin-only
                    // server-side). Tapping a row still edits
                    // that expense.
                    if isAdmin {
                        Button {
                            showExpensePicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Add Recurring Expense")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(DesignTokens.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add recurring expense")
                    }
                }
            }
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
        // Build 77: the tag picker for adding an expense from
        // this sheet — the same picker the Calculator uses.
        // The editor cannot open while the picker is still
        // dismissing — the build-67 400ms pattern.
        .sheet(isPresented: $showExpensePicker) {
            ExpenseTagPickerSheet(
                transactions: transactions,
                onTag: { transaction in
                    await onTag(transaction)
                },
                onTagged: { expense in
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        selectedExpense = expense
                    }
                },
                onClose: { showExpensePicker = false }
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
            // Build 74 (owner, Nov 24, 2026 — popup sizing): this
            // form is ~545pt tall (Name + Amount + 4 frequency
            // rows + Save + Remove), but it opened at a 0.45
            // detent (~383pt on iPhone) with no ScrollView — the
            // Save button was below even the .medium detent and
            // unreachable. The form now scrolls under a pinned
            // header, at [.medium, .large] detents.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        // Build 70, item 5 (owner, Nov 24, 2026): the
                        // Cancel button is gone — the SheetHeader X +
                        // swipe-right dismiss without saving, so Cancel
                        // was a third redundant way out.
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
                        // Below the Save button, not beside it — a
                        // red text button, so it never shares a colour or
                        // treatment with it.
                        Button("Remove Expense") { showRemoveConfirm = true }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: DesignTokens.errorTextHex))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .padding()
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
    }
}

/// The "Add Recurring Expense" picker (build 69 — the Calculator's
/// "Add Recurring Expense" option): a fitted sheet listing the
/// charges that can be tagged as an expense, newest first.
/// Tapping one tags it through the same tag_transaction_expense
/// RPC the Actions sheet uses (admin only, 35-day lock,
/// money-out only) and hands the new expense back so the caller
/// can open the editor for it. The new expense is the SAME row
/// the Recurring Expenses list and the Calculator read — never a
/// second, disconnected store.
public struct ExpenseTagPickerSheet: View {
    public let transactions: [Transaction]
    public let onTag: (Transaction) async -> RecurringExpense?
    public let onTagged: (RecurringExpense) -> Void
    public let onClose: () -> Void
    @State private var isWorking = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        transactions: [Transaction],
        onTag: @escaping (Transaction) async -> RecurringExpense?,
        onTagged: @escaping (RecurringExpense) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.transactions = transactions
        self.onTag = onTag
        self.onTagged = onTagged
        self.onClose = onClose
    }

    /// The charges that can be tagged: live money-out charges
    /// with a positive amount, not already an expense, within
    /// the server's 35-day tag lock (the current Sunday week no
    /// more than 35 days past the transaction's Sunday week).
    /// Newest first, capped at 50.
    private var candidates: [Transaction] {
        let currentSunday = MoneyFormat.currentSundayNY()
        let taggable = transactions.filter { tx in
            guard tx.kind == .charge, tx.amountCents > 0, !tx.isInTrash,
                  tx.state == .verified || tx.state == .provisional,
                  let txSunday = sunday(of: tx.date),
                  let gap = MoneyFormat.daysBetween(txSunday, currentSunday) else { return false }
            return gap <= 35
        }
        return Array(taggable.sorted { $0.date > $1.date }.prefix(50))
    }

    /// The Sunday (YYYY-MM-DD) of the week a date falls in —
    /// the same week the server's 35-day lock counts from.
    private func sunday(of dateString: String) -> String? {
        guard let date = MoneyFormat.date(from: dateString) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 1
        let weekday = calendar.component(.weekday, from: date)
        guard let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: date) else { return nil }
        return MoneyFormat.dateString(from: sunday)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Tag a Charge as an Expense", onClose: onClose)
            FundsMuted("Pick a charge — it becomes a recurring expense and stops counting as weekly spending.")
            if candidates.isEmpty {
                FundsMuted("No charges to tag right now — tag a transaction as an Expense from its Actions sheet.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { tx in
                            Button {
                                Task {
                                    guard !isWorking else { return }
                                    isWorking = true
                                    let expense = await onTag(tx)
                                    isWorking = false
                                    guard let expense else { return }
                                    onClose()
                                    onTagged(expense)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(tx.merchant.uppercased())
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(DesignTokens.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(MoneyFormat.fmtShort(tx.date))
                                        .font(.system(size: 14))
                                        .foregroundStyle(DesignTokens.muted)
                                    Text(MoneyFormat.formatCents(tx.amountCents))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(DesignTokens.ink)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                            if tx.id != candidates.last?.id {
                                SheetActionDivider()
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 74 (owner, Nov 24, 2026 — popup sizing): a list
        // of up to 50 charges opened at a 0.45 detent, showing
        // ~3 rows — the list scrolls, but it opens cramped. Lists
        // open at [.medium, .large] now.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
    }
}
