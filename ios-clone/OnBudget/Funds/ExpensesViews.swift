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
    /// The Funds view model (build 78, owner Nov 25, 2026):
    /// the tag picker reads its live `allTransactions` and
    /// `isLoading` (it observes the view model itself, so the
    /// picker fills the moment the fetch lands — a plain
    /// transactions snapshot went stale and the picker opened
    /// empty). It also supplies the household id for a
    /// from-scratch expense.
    /// Loading mandate (owner, Nov 26, 2026): the LIST observes
    /// it too now — the `expenses` snapshot below is captured
    /// when the sheet presents, which can be before the
    /// view model's refresh has finished its (supporting)
    /// expenses load, so the list flashed "No expenses tagged
    /// yet" with $0.00 totals and never updated. The list reads
    /// `liveExpenses` below and shows skeletons until
    /// `expensesReady`.
    @ObservedObject public var viewModel: FundsViewModel
    /// Tag a charge as a new expense (build 77): the Funds view
    /// model's tagExpense, so the new row is the SAME row the
    /// list and the Calculator read.
    public let onTag: (Transaction) async -> RecurringExpense?
    /// Create an expense from scratch (build 78, owner
    /// Nov 25, 2026): the Funds view model's createExpense.
    /// Returns true only when the save committed.
    public let onCreate: (String, Int, ExpenseFrequency) async -> Bool
    @State private var selectedExpense: RecurringExpense?
    /// The ⓘ beside "About These Expenses" (build 68, item 14):
    /// the explainer used to sit inline under the list.
    @State private var showAboutInfo = false
    /// The tag picker (build 77): adding an expense from this
    /// sheet picks a charge to tag, then opens the editor.
    @State private var showExpensePicker = false
    /// A from-scratch expense being created (build 78): the
    /// blank expense, built once on tap so the editor's typed
    /// input survives re-renders.
    @State private var newExpense: RecurringExpense?
    /// The expense tagged in the picker, waiting for the picker
    /// to finish dismissing (build 78): the editor opens from
    /// the picker's onDismiss, not from a sleep — presenting a
    /// sheet while another is still dismissing collides, so the
    /// editor waits until the picker is fully gone. A plain
    /// close (no tag) leaves this nil and opens nothing.
    @State private var pendingExpense: RecurringExpense?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        expenses: [RecurringExpense],
        isAdmin: Bool,
        onSave: @escaping (RecurringExpense, String, Int, ExpenseFrequency) async -> Bool,
        onRemove: @escaping (RecurringExpense) async -> Bool,
        onClose: @escaping () -> Void,
        viewModel: FundsViewModel,
        onTag: @escaping (Transaction) async -> RecurringExpense?,
        onCreate: @escaping (String, Int, ExpenseFrequency) async -> Bool
    ) {
        self.expenses = expenses
        self.isAdmin = isAdmin
        self.onSave = onSave
        self.onRemove = onRemove
        self.onClose = onClose
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.onTag = onTag
        self.onCreate = onCreate
    }

    /// The rows the list shows: the view model's LIVE expenses
    /// (see the viewModel note above), never the presentation-time
    /// snapshot — the snapshot can predate the expenses load, and
    /// a stale list would never catch up while open. Once loaded
    /// the two are the same rows.
    private var displayedExpenses: [RecurringExpense] {
        viewModel.liveExpenses
    }

    /// The monthly cost of all the expenses together — the figure
    /// the Calculator subtracts from income.
    private var monthlyTotalCents: Int {
        displayedExpenses.reduce(0) { $0 + $1.monthlyCents }
    }

    /// The weekly cost — the monthly total spread over the year's
    /// 52 weeks (monthly × 12/52), before the Calculator's holdback.
    private var weeklyTotalCents: Int {
        displayedExpenses.reduce(0) { $0 + $1.weeklyCents }
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
                    // Loading mandate (owner, Nov 26, 2026): until
                    // `expensesReady` the summary and the rows are
                    // skeletons, never a $0.00 summary with a false
                    // "No expenses tagged yet" that fills in after
                    // first paint (see displayedExpenses).
                    if !viewModel.expensesReady {
                        expensesListSkeleton
                    } else {
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
                        if displayedExpenses.isEmpty {
                            Text("No expenses tagged yet — tag a transaction as an Expense from its Actions to add one.")
                                .font(.system(size: 15))
                                .foregroundStyle(DesignTokens.muted)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(displayedExpenses) { expense in
                                    expenseRow(expense)
                                    if expense.id != displayedExpenses.last?.id {
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
                    }
                    // Nov 26, 2026 (owner — ExpensesListView
                    // flip, matching item 20's Calculator flip):
                    // manual add is the MAIN way, so "Create a
                    // New Expense" is the full-width solid-blue
                    // primary on top and "Add Recurring Expense"
                    // (tag a charge) is the distinct tertiary
                    // OUTLINE button below it — never two
                    // solid-blue primaries next to each other.
                    // Admin only (tagging is admin-only
                    // server-side).
                    if isAdmin {
                        Button {
                            newExpense = RecurringExpense(
                                id: UUID(),
                                householdId: viewModel.context.householdId,
                                transactionId: nil,
                                name: "",
                                amountCents: 0,
                                frequency: .monthly
                            )
                        } label: {
                            Label("Create a New Expense", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityLabel("Create a new recurring expense")
                        Button {
                            showExpensePicker = true
                        } label: {
                            Label("Add Recurring Expense", systemImage: "plus.circle")
                        }
                        .buttonStyle(OutlineButtonStyle())
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
        // Loading mandate (owner, Nov 26, 2026): make sure the
        // expenses (and the transactions the tag picker reads)
        // are loaded before the list reveals — a list opened
        // from the Weekly Budget sheet can beat its view model's
        // refresh, so the load is triggered here too.
        .task {
            await viewModel.ensureCalculatorDataLoaded()
        }
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
        // Build 78 (owner, Nov 25, 2026): the picker reads the
        // Funds view model live (see the viewModel property) —
        // it opens instantly and fills when the fetch lands.
        // The editor opens from the picker's onDismiss (see
        // pendingExpense) as soon as the tag RPC returns — the
        // build-67 400ms sleep is gone, and the editor no longer
        // waits on the full refresh (see tagExpense).
        .sheet(isPresented: $showExpensePicker, onDismiss: {
            if let pending = pendingExpense {
                pendingExpense = nil
                selectedExpense = pending
            }
        }) {
            ExpenseTagPickerSheet(
                viewModel: viewModel,
                onTag: { transaction in
                    await onTag(transaction)
                },
                onTagged: { expense in
                    pendingExpense = expense
                },
                onClose: { showExpensePicker = false }
            )
        }
        // Build 78 (owner, Nov 25, 2026): create an expense
        // from scratch — blank name, $0.00, monthly, NO Remove
        // (nothing to remove yet). Save creates it via onCreate.
        .sheet(item: $newExpense) { expense in
            ExpenseEditorSheet(
                expense: expense,
                onSave: { name, amountCents, frequency in
                    await onCreate(name, amountCents, frequency)
                },
                onRemove: { false },
                onClose: { newExpense = nil },
                isNew: true
            )
        }
    }

    /// The loading skeleton (owner, Nov 26, 2026): the summary
    /// card (two rows) plus expense rows, in the same card
    /// chrome — see the body. The row count varies once loaded,
    /// so the skeleton carries enough rows to fill the visible
    /// page (owner, Nov 26, 2026 — skeletons must fill the whole
    /// visible page, not a fixed representative count of three);
    /// the sheet still settles shorter once the real (smaller)
    /// list lands — that one-time swap is accepted. An expense
    /// row is 16pt tall with 10pt vertical padding (37pt pitch
    /// with the divider); the rows start ~230pt down the sheet
    /// (sheet header + summary card).
    private var expensesSkeletonRowCount: Int {
        SkeletonFill.rows(rowHeight: 37, above: 230)
    }

    private var expensesListSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                HStack {
                    SkeletonBlock(width: 110, height: 16)
                    Spacer()
                    SkeletonBlock(width: 80, height: 16)
                }
                .padding(.vertical, 10)
                SheetActionDivider()
                HStack {
                    SkeletonBlock(width: 110, height: 16)
                    Spacer()
                    SkeletonBlock(width: 80, height: 16)
                }
                .padding(.vertical, 10)
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
            VStack(spacing: 0) {
                ForEach(0..<expensesSkeletonRowCount, id: \.self) { index in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            SkeletonBlock(width: 140, height: 16)
                        }
                        Spacer()
                        SkeletonBlock(width: 90, height: 16)
                    }
                    .padding(.vertical, 10)
                    if index < expensesSkeletonRowCount - 1 {
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
    /// New from scratch (build 78, owner Nov 25, 2026): the
    /// editor opens blank (name "", $0.00, monthly) and has NO
    /// Remove button — there is nothing to remove yet. Save
    /// creates the expense instead of updating it.
    public let isNew: Bool
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
        onClose: @escaping () -> Void,
        isNew: Bool = false
    ) {
        self.expense = expense
        self.onSave = onSave
        self.onRemove = onRemove
        self.onClose = onClose
        self.isNew = isNew
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
                        // treatment with it. Hidden for a new expense
                        // (build 78): nothing to remove yet.
                        if !isNew {
                            Button("Remove Expense") { showRemoveConfirm = true }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(hex: DesignTokens.errorTextHex))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Nov 26, 2026 (owner — dead space below Save): the sheet
        // sizes to its content (.presentationSizing(.fitted)) instead
        // of the [.medium, .large] detents — at .large the ~545pt
        // form left a big empty bottom, and at .medium the Save
        // button sat below the fold. Fitted hugs the form (Name +
        // Amount + How Often + Save + Remove) with no dead space;
        // the ScrollView still scrolls when the keyboard is up, the
        // error box appears, or the remove confirm opens — fitted
        // re-measures as the content grows, up to the screen height.
        // (Build 74's .medium/.large detents fixed the unreachable
        // Save; fitted keeps that fix and removes the empty bottom.)
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
    }
}

/// The "Tag a Charge as an Expense" picker (build 77, owner
/// Nov 25, 2026): pick a recent charge to tag as a recurring
/// expense. Build 78 (owner, Nov 25, 2026): the picker reads
/// the Funds view model LIVE (it observes it — the sheet
/// presents at once and fills the moment the fetch lands, with
/// skeleton rows shaped like charge rows while loading, never
/// the premature "No charges" empty state); rows carry the
/// merchant icon (TransactionIconView, as in the Transactions
/// list); the list shows 30 rows with a one-tap Load More for the
/// rest (Nov 26, 2026 — 15 up front took three taps to reach all
/// 50) and a merchant search; and tapping a charge opens the editor
/// as soon as the tag RPC returns (the editor no longer waits on the
/// full refresh or the 400ms sleep — see onTagged / tagExpense).
public struct ExpenseTagPickerSheet: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let onTag: (Transaction) async -> RecurringExpense?
    public let onTagged: (RecurringExpense) -> Void
    public let onClose: () -> Void
    @State private var isWorking = false
    /// The merchant search (build 78): filters the full
    /// candidate list by name; the 30-row first page / Load More
    /// applies to the filtered results.
    @State private var searchText = ""
    /// How many rows are shown (Nov 26, 2026 — owner: 15 up
    /// front meant three taps to reach all 50): 30 at first, and
    /// Load More reveals ALL the rest in one tap. The 50-row cap
    /// stays, as do the candidate criteria.
    @State private var visibleCount = 30
    /// The candidate list, computed ONCE — not on every render
    /// (owner, Nov 25, 2026 — the picker lagged). `candidates`
    /// used to be a computed property: every body evaluation
    /// re-filtered and re-sorted all transactions AND ran the
    /// per-transaction date math (`sunday(of:)` + `daysBetween`,
    /// each of which builds fresh DateFormatters — see
    /// MoneyFormat.date(from:) / dateString(from:)) on the main
    /// thread, including the first render when the sheet opens —
    /// so the tap felt laggy before the sheet even appeared. The
    /// list is now computed once, off the main thread, when the
    /// sheet appears and whenever the transactions change; the
    /// sheet opens at once with skeleton rows and fills in when
    /// the list lands. Nil until the first computation finishes.
    @State private var cachedCandidates: [Transaction]?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        viewModel: FundsViewModel,
        onTag: @escaping (Transaction) async -> RecurringExpense?,
        onTagged: @escaping (RecurringExpense) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onTag = onTag
        self.onTagged = onTagged
        self.onClose = onClose
    }

    /// The charges that can be tagged: live money-out charges
    /// with a positive amount, not already an expense, within
    /// the server's 35-day tag lock (the current Sunday week no
    /// more than 35 days past the transaction's Sunday week).
    /// Newest first, capped at 50. Pure + Sendable, so the sheet
    /// can run it off the main thread (see cachedCandidates).
    private static func computeCandidates(from allTransactions: [Transaction]) -> [Transaction] {
        let currentSunday = MoneyFormat.currentSundayNY()
        let taggable = allTransactions.filter { tx in
            guard tx.kind == .charge, tx.amountCents > 0, !tx.isInTrash,
                  tx.state == .verified || tx.state == .provisional,
                  let txSunday = sunday(of: tx.date),
                  let gap = MoneyFormat.daysBetween(txSunday, currentSunday) else { return false }
            return gap <= 35
        }
        return Array(taggable.sorted { $0.date > $1.date }.prefix(50))
    }

    /// The candidates after the merchant search (build 78):
    /// case-insensitive contains on the merchant name. An
    /// empty search shows the full list. Reads the cached list —
    /// empty until the first computation lands, so the sheet
    /// shows skeletons (never a premature "No charges") while
    /// it computes.
    private var filteredCandidates: [Transaction] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = cachedCandidates ?? []
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.merchant.localizedCaseInsensitiveContains(query) }
    }

    /// The rows actually shown (build 78): the first
    /// `visibleCount` of the filtered candidates.
    private var visibleCandidates: [Transaction] {
        Array(filteredCandidates.prefix(visibleCount))
    }

    /// The Sunday (YYYY-MM-DD) of the week a date falls in —
    /// the same week the server's 35-day lock counts from.
    private static func sunday(of dateString: String) -> String? {
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
            // The merchant search (build 78): the Transactions
            // search pattern — magnifying glass, placeholder,
            // clear button.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignTokens.muted)
                TextField("Search charges", text: $searchText)
                    .font(.system(size: 17))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignTokens.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(14)
            .background(Color(hex: "#f3f4f6"))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if !viewModel.calculatorDataReady || cachedCandidates == nil {
                // Still loading — or still computing the list
                // (owner, Nov 25, 2026): skeleton rows shaped
                // like the charge rows (icon + two text lines),
                // never a spinner, "Loading…" or a premature
                // "No charges" empty state. Enough rows to fill
                // the visible page (owner, Nov 26, 2026 —
                // skeletons must fill the whole visible page, not
                // a fixed six); a charge row is 61pt tall and the
                // list starts ~100pt down the sheet (search
                // field + padding), so the count fills the sheet
                // at its large detent on every device.
                // Loading mandate (owner, Nov 26, 2026): the gate
                // is the data being ready, NOT `viewModel.isLoading`
                // — a background refresh (tagging an expense runs
                // one) used to blank this open picker back to
                // skeletons mid-use, even though the cached list
                // was still good. `calculatorDataReady` only flips
                // once the transactions are actually in.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<SkeletonFill.rows(rowHeight: 61, above: 100), id: \.self) { _ in
                            skeletonRow
                            SheetActionDivider()
                        }
                    }
                }
            } else if filteredCandidates.isEmpty {
                FundsMuted(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No charges to tag right now — tag a transaction as an Expense from its Actions sheet."
                    : "No charges match \"\(searchText)\".")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visibleCandidates) { tx in
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
                                HStack(spacing: 10) {
                                    // Build 78: the merchant icon,
                                    // the same TransactionIconView
                                    // the Transactions list uses
                                    // (40pt, ~10pt spacing) — the
                                    // bare text rows were hard to
                                    // scan. Charges only, so
                                    // isBankRow is false and the
                                    // institution is nil; the
                                    // monogram fallback comes free.
                                    TransactionIconView(merchant: tx.merchant, size: 40)
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
                            if tx.id != visibleCandidates.last?.id {
                                SheetActionDivider()
                            }
                        }
                        // Load More (Nov 26, 2026): the list shows
                        // 30 rows at first; this reveals ALL the
                        // rest in one tap (the old +15-at-a-time
                        // took three taps to reach 50). Only while
                        // more rows remain.
                        if filteredCandidates.count > visibleCount {
                            Button {
                                visibleCount = filteredCandidates.count
                            } label: {
                                Text("Load More (\(filteredCandidates.count - visibleCount) more)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(DesignTokens.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Load more charges")
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
        // Loading mandate (owner, Nov 26, 2026): make sure the
        // transactions are loaded before the list reveals — a
        // picker opened from the Expenses list can beat its view
        // model's refresh, so the load is triggered here too.
        .task {
            await viewModel.ensureCalculatorDataLoaded()
        }
        // Compute the candidate list once, off the main thread
        // (see cachedCandidates): the sheet is already up with
        // skeletons by the time this lands. Re-runs when the
        // transactions change; the old list stays on screen until
        // the new one lands, so there is no flicker back to
        // skeletons. Transaction is Sendable, so the detached
        // task can take the array.
        .task(id: viewModel.allTransactions) {
            let transactions = viewModel.allTransactions
            let list = await Task.detached {
                Self.computeCandidates(from: transactions)
            }.value
            cachedCandidates = list
        }
    }

    /// A skeleton row shaped like a charge row (build 78): a
    /// 40pt icon tile + two text lines + a date + an amount, in
    /// skeleton grey. Loading mandate (owner, Nov 26, 2026): the
    /// date block was missing, so the amount sat further left
    /// than in a real row while loading.
    private var skeletonRow: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 140, height: 14)
                SkeletonBlock(width: 90, height: 12)
            }
            Spacer()
            SkeletonBlock(width: 44, height: 12)
            SkeletonBlock(width: 56, height: 14)
        }
        .padding(.vertical, 10)
    }
}
