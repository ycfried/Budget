import SwiftUI
import OnBudgetKit

// MARK: - Funds tab (spec §9)
//
// Top: two balance panels side by side in the web app — stacked here,
// same face as the Home stat cards (Title + Amount only, chevron `⌄`
// bottom-right) with the same in-place expansion, except the Funds
// expansions INCLUDE action buttons (Home does not). At most one card
// expanded at a time.
//
// Forms: one at a time; the More card hides while a form is open.
// Back returns to the Funds list (swipe-right closes the form too,
// via the navigation stack in the coordinator).
//
// Entry point for the app shell's tab bar:
//   FundsView(context: FundsContext(client:householdId:role:userId:),
//             appState: appState)
// The view model is owned here. Card expansion is the SHARED
// `appState.expandedCard` (integration, Nov 9, 2026 — the local
// `FundsExpandedCard` state is deleted): one-open-at-a-time spans
// Home + Funds. Temporary Allowance opens as a form here when the
// shell sets `appState.pendingTemporaryAllowance` (Settings Budget
// link).

public enum FundsForm: Equatable {
    case add
    case use
    case ask
    case income
    /// Temporary Allowance (Settings Budget link) — owned by the
    /// Funds workstream, presented as a form, never duplicated in
    /// Settings.
    case temp
}

public enum FundsMoreSection: Equatable {
    case activity
    case review
    case savings
}

public struct FundsView: View {
    @StateObject private var viewModel: FundsViewModel
    /// Shared shell state: card expansion + the Temporary Allowance
    /// handoff from Settings Budget.
    @ObservedObject var appState: AppViewModel
    @State private var openForm: FundsForm?
    @State private var openMore: FundsMoreSection?
    @State private var correctingIncome: CharityIncome?

    public init(context: FundsContext, appState: AppViewModel) {
        self.appState = appState
        self._viewModel = StateObject(wrappedValue: FundsViewModel(context: context))
    }

    /// The shared view model, for Review (same data, one refresh).
    public var fundsViewModel: FundsViewModel { viewModel }

    private var isAdmin: Bool { viewModel.context.isAdmin }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let form = openForm {
                    backButton
                    switch form {
                    case .add:
                        AddMoneyForm(viewModel: viewModel)
                    case .use:
                        UseFundForm(viewModel: viewModel)
                    case .ask:
                        AskFundForm(viewModel: viewModel)
                    case .income:
                        CharityIncomeForm(viewModel: viewModel, correcting: $correctingIncome)
                    case .temp:
                        TemporaryAllowanceView(viewModel: viewModel)
                    }
                } else {
                    fundCard
                    charityCard
                    moreCard
                }
            }
            .padding()
        }
        .background(DesignTokens.background)
        .fundsToast($viewModel.toast)
        .alert(
            viewModel.alertTitle ?? "Could Not Complete",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil; viewModel.alertTitle = nil } }
            )
        ) {
            Button(TitleCase.apply(to: "Close"), role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .task {
            consumeTemporaryAllowanceHandoff()
            await viewModel.refresh()
        }
        .onChange(of: appState.pendingTemporaryAllowance) { _, _ in
            consumeTemporaryAllowanceHandoff()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var backButton: some View {
        Button {
            openForm = nil
        } label: {
            Text("← Back")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DesignTokens.mid)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Back to Funds")
    }

    // MARK: - Extra Fund card (§9.1)

    private var fundCard: some View {
        FundsExpandableCard(
            title: "Extra Fund",
            amountText: fundFaceText,
            isExpanded: appState.expandedCard == .fund,
            isNegative: (viewModel.fundSummary?.availableCents ?? 0) < 0,
            accessibilityLabel: fundAccessibilityLabel,
            onToggle: { toggleCard(.fund) }
        ) {
            if let error = viewModel.fundError {
                FundsErrorBox(error)
            } else if let summary = viewModel.fundSummary {
                FundsBreakdownRow(
                    isAdmin ? "Spendable available" : "Available to request",
                    value: MoneyFormat.formatCents(summary.availableCents),
                    isNegative: summary.availableCents < 0
                )
                FundsBreakdownRow("Pending", value: MoneyFormat.formatCents(summary.pendingIncludingHeldCents))
                FundsBreakdownRow("Total", value: MoneyFormat.formatCents(summary.totalCents))
                HStack(spacing: 12) {
                    if isAdmin {
                        FundsPrimaryButton("Add Money") { openForm = .add }
                        FundsPaleButton("Spend from Fund") { openForm = .use }
                        FundsTertiaryButton("Request Money") { openForm = .ask }
                    } else {
                        FundsTertiaryButton("Request Money") { openForm = .ask }
                    }
                }
            } else {
                FundsMuted("Loading fund balance…")
            }
        }
    }

    private var fundFaceText: String {
        guard let summary = viewModel.fundSummary else {
            return viewModel.fundError == nil ? "Loading fund balance…" : "—"
        }
        return MoneyFormat.formatCents(summary.availableCents)
    }

    private var fundAccessibilityLabel: String {
        guard let summary = viewModel.fundSummary else {
            return "Extra Fund, could not load balances, show breakdown"
        }
        let word = isAdmin ? "available to use" : "available to request"
        if summary.pendingIncludingHeldCents > 0 {
            return "Extra Fund, \(MoneyFormat.formatCents(summary.availableCents)) \(word), \(MoneyFormat.formatCents(summary.pendingIncludingHeldCents)) pending, show breakdown"
        }
        return "Extra Fund, \(MoneyFormat.formatCents(summary.availableCents)) \(word), show breakdown"
    }

    // MARK: - Charity card (§9.1)

    private var charityCard: some View {
        FundsExpandableCard(
            title: "Charity",
            amountText: charityFaceText,
            isExpanded: appState.expandedCard == .charity,
            isNegative: (viewModel.charitySummary?.remainingCents ?? 0) < 0,
            accessibilityLabel: charityAccessibilityLabel,
            onToggle: { toggleCard(.charity) }
        ) {
            if let error = viewModel.charityError {
                FundsErrorBox(error)
            } else if let summary = viewModel.charitySummary {
                FundsBreakdownRow("Available", value: MoneyFormat.formatCents(summary.remainingCents), isNegative: summary.remainingCents < 0)
                FundsBreakdownRow("Given", value: MoneyFormat.formatCents(summary.givenCents))
                FundsBreakdownRow("Total", value: MoneyFormat.formatCents(summary.committedCents))
                FundsMuted("November 2026 onward")
                HStack(spacing: 12) {
                    if isAdmin {
                        FundsPrimaryButton("Record Income") {
                            correctingIncome = nil
                            openForm = .income
                        }
                        FundsTertiaryButton("Close") { appState.expandedCard = nil }
                    } else {
                        FundsTertiaryButton("Close") { appState.expandedCard = nil }
                    }
                }
            } else {
                FundsMuted("Loading charity…")
            }
        }
    }

    private var charityFaceText: String {
        guard let summary = viewModel.charitySummary else {
            return viewModel.charityError == nil ? "Loading charity…" : "—"
        }
        return MoneyFormat.formatCents(summary.remainingCents)
    }

    private var charityAccessibilityLabel: String {
        guard let summary = viewModel.charitySummary else {
            return "Charity, could not load, show breakdown"
        }
        if summary.committedCents == 0 && summary.givenCents == 0 {
            return "Charity, no charity tracked yet, show breakdown"
        }
        if summary.remainingCents < 0 {
            return "Charity, ahead by \(MoneyFormat.formatCents(-summary.remainingCents)), show breakdown"
        }
        return "Charity, \(MoneyFormat.formatCents(summary.remainingCents)) remaining, \(MoneyFormat.formatCents(summary.givenCents)) given, \(MoneyFormat.formatCents(summary.committedCents)) committed, show breakdown"
    }

    /// Settings Budget → Temporary Allowance: open the form here
    /// and clear the flag so a later tab switch does not re-open it.
    private func consumeTemporaryAllowanceHandoff() {
        guard appState.pendingTemporaryAllowance else { return }
        appState.pendingTemporaryAllowance = false
        openForm = .temp
    }

    private func toggleCard(_ card: ExpandedCard) {
        if appState.expandedCard == card {
            appState.expandedCard = nil
        } else {
            appState.expandedCard = card
        }
    }

    // MARK: - More card (§9.2)

    private var moreCard: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 0) {
                FundsHeading("More")
                moreRow(
                    title: "Fund Activity",
                    section: .activity,
                    isAdminOnly: true
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        FundTopupsHistory(viewModel: viewModel)
                        Divider()
                        CharityIncomeHistory(
                            viewModel: viewModel,
                            correcting: $correctingIncome,
                            openIncomeForm: Binding(
                                get: { openForm == .income },
                                set: { if $0 { openForm = .income } }
                            )
                        )
                    }
                }
                moreRow(
                    title: viewModel.reviewCount > 0 ? "Review (\(viewModel.reviewCount))" : "Review",
                    section: .review,
                    isAdminOnly: true
                ) {
                    ReviewView(viewModel: viewModel)
                }
                moreRow(
                    title: "Past Savings Records",
                    section: .savings,
                    isAdminOnly: false
                ) {
                    SavingsSection(viewModel: viewModel)
                }
            }
        }
    }

    @ViewBuilder
    private func moreRow<Content: View>(
        title: String,
        section: FundsMoreSection,
        isAdminOnly: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if !isAdminOnly || isAdmin {
            Button {
                openMore = openMore == section ? nil : section
            } label: {
                HStack {
                    Text(TitleCase.apply(to: title))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer()
                    Text(openMore == section ? "⌃" : "›")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            if openMore == section {
                content()
                    .padding(.bottom, 12)
            }
            Divider()
        }
    }
}

// MARK: - Past Savings Records (§9.2, read-only)
//
// Four numbers from `savings_ledger` kinds: Balance (latest attested
// `actual_balance_cents` — NEVER a sum of movements; "Not recorded yet"
// if none), Transferred in, Withdrawn, Interest / adjustments.
// Below: latest 20 records + "Showing the latest 20 records." when
// more exist. No form writes savings anymore.

public struct SavingsSection: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var latestBalance: Int? {
        viewModel.savings
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            .compactMap { $0.actualBalanceCents }
            .first
    }

    private func sum(kind: String) -> Int {
        viewModel.savings.filter { $0.kind == kind }.reduce(0) { $0 + $1.amountCents }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.savingsError {
                FundsErrorBox(error)
            } else if viewModel.savings.isEmpty {
                FundsMuted("No past savings records.")
            } else {
                FundsBreakdownRow(
                    "Balance",
                    value: latestBalance.map { MoneyFormat.formatCents($0) } ?? "Not recorded yet"
                )
                FundsBreakdownRow("Transferred In", value: MoneyFormat.formatCents(sum(kind: "transfer_in")))
                FundsBreakdownRow("Withdrawn", value: MoneyFormat.formatCents(sum(kind: "withdrawal")))
                FundsBreakdownRow(
                    "Interest / Adjustments",
                    value: MoneyFormat.formatCents(
                        viewModel.savings
                            .filter { $0.kind != "transfer_in" && $0.kind != "withdrawal" }
                            .reduce(0) { $0 + $1.amountCents }
                    )
                )
                if latestBalance == nil {
                    FundsMuted("Past savings records exist, but no balance was ever recorded for them — that is a missing balance, not $0.")
                }
                Divider()
                let latest = Array(viewModel.savings.prefix(20))
                ForEach(Array(latest.enumerated()), id: \.offset) { _, row in
                    Text("\(row.kind) \(MoneyFormat.formatCents(row.amountCents)) · Recorded balance \(row.actualBalanceCents.map { MoneyFormat.formatCents($0) } ?? "—") · \(row.createdAt.map { MoneyFormat.fmtDateTime($0) } ?? "")\(row.note.isEmpty ? "" : " · \(row.note)")")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                if viewModel.savings.count > 20 {
                    FundsMuted("Showing the latest 20 records.")
                }
            }
        }
    }
}
