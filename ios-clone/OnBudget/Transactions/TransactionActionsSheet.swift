import SwiftUI
import OnBudgetKit

/// Transaction Actions sheet (CLONE_SPEC §7.4, live.js:3763-3970).
///
/// Sheet header: Cancel (top-left text link), title "Actions",
/// subtitle "Merchant — $X". Rows are tappable list rows (label bold
/// + muted sub-line + ›). Which actions appear is decided by the
/// `actionsForTxKind` table — the clone uses this exact table
/// (relaxed Nov 8, 2026: Charity is offered on ANY charge; members
/// see it disabled):
///
/// | kind | Admin | Member |
/// | charge | Charity, Extra Fund, Other, Delete | Charity (disabled), Extra Fund |
/// | refund | Link to Purchase, Other, Delete | — (no actions) |
/// | transfer, payment, cashback, fund_charge | Other, Delete | — |
/// | charity | Delete | — |
/// | other kinds | Other, Delete | — |
///
/// Plus the note under the sheet for transfer/payment/cashback/
/// fund_charge: "This row does not count toward weekly spending."
public struct TransactionActionsSheet: View {
    enum Flow: Equatable {
        case list
        case charityConfirm
        case extraFund
        case linkCandidates
        case unlinkConfirm
        case reclassifyKind
        case reclassifyReason(TransactionKind)
        case deleteConfirm
    }

    enum ActionKind: Hashable {
        case charity
        case extraFund
        case linkRefund
        case reclassify
        case delete
    }

    struct SheetAction: Identifiable {
        let id: ActionKind
        let label: String
        let subline: String
        let disabled: Bool
    }

    let transaction: Transaction
    let isAdmin: Bool
    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void

    @State private var flow: Flow = .list
    @State private var extraFundAmount: String = ""
    @State private var extraFundError: String?
    @State private var reclassifyReason: String = ""
    @State private var reclassifyReasonError: String?
    @State private var deleteReason: String = ""
    @State private var deleteReasonError: String?
    @State private var linkCandidates: [Transaction]?
    @State private var linkedSummary: (merchant: String, amountCents: Int, date: String)?
    @State private var isWorking: Bool = false

    public init(
        transaction: Transaction,
        isAdmin: Bool,
        viewModel: TransactionsViewModel,
        onDismiss: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.isAdmin = isAdmin
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    // MARK: - Action table

    var actions: [SheetAction] {
        let isVerified = transaction.state == .verified
        let charitySubline = isVerified
            ? "Counts it as a charity gift, out of weekly spending"
            : "Counts as a charity gift once it posts"
        let deleteSubline = transaction.source == .manual
            ? "Permanently deletes this hand-entered row"
            : "Moves this row to the Trash"
        switch transaction.kind {
        case .charge:
            if isAdmin {
                return [
                    SheetAction(id: .charity, label: "Mark as Charity", subline: charitySubline, disabled: false),
                    SheetAction(id: .extraFund, label: "Use Extra Fund", subline: "Ask for this charge to be covered from the fund", disabled: false),
                    SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts", disabled: false),
                    SheetAction(id: .delete, label: "Delete", subline: deleteSubline, disabled: false),
                ]
            }
            return [
                SheetAction(id: .charity, label: "Mark as Charity", subline: "Ask the admin to mark this as a gift", disabled: true),
                SheetAction(id: .extraFund, label: "Use Extra Fund", subline: "Ask for this charge to be covered from the fund", disabled: false),
            ]
        case .refund:
            guard isAdmin else { return [] }
            let linkSubline = transaction.originalPurchaseId != nil
                ? "Change or remove the purchase this refund is linked to"
                : "Link this refund to the purchase it came from"
            return [
                SheetAction(id: .linkRefund, label: "Link to Purchase", subline: linkSubline, disabled: false),
                SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts", disabled: false),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline, disabled: false),
            ]
        case .transfer, .payment, .cashback, .fundCharge:
            guard isAdmin else { return [] }
            return [
                SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts", disabled: false),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline, disabled: false),
            ]
        case .charity:
            guard isAdmin else { return [] }
            return [SheetAction(id: .delete, label: "Delete", subline: deleteSubline, disabled: false)]
        case .income, .other:
            guard isAdmin else { return [] }
            return [
                SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts", disabled: false),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline, disabled: false),
            ]
        }
    }

    var showsNonCountingNote: Bool {
        switch transaction.kind {
        case .transfer, .payment, .cashback, .fundCharge: return true
        default: return false
        }
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch flow {
                case .list: listContent
                case .charityConfirm: charityConfirmContent
                case .extraFund: extraFundContent
                case .linkCandidates: linkCandidatesContent
                case .unlinkConfirm: unlinkConfirmContent
                case .reclassifyKind: reclassifyKindContent
                case .reclassifyReason(let kind): reclassifyReasonContent(kind: kind)
                case .deleteConfirm: deleteConfirmContent
                }
                Spacer()
            }
            .padding()
            .navigationTitle(flowTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if flow == .list {
                            onDismiss()
                        } else {
                            flow = .list
                        }
                    }
                    .foregroundStyle(DesignTokens.mid)
                }
            }
        }
        .task {
            if transaction.originalPurchaseId != nil {
                linkedSummary = await viewModel.linkedPurchaseSummary(for: transaction)
            }
        }
    }

    private var flowTitle: String {
        switch flow {
        case .list: return "Actions"
        case .charityConfirm: return "Mark as Charity Gift"
        case .extraFund: return "Use Extra Fund"
        case .linkCandidates: return "Link Refund to Purchase"
        case .unlinkConfirm: return "Unlink Refund"
        case .reclassifyKind: return "Reclassify Transaction"
        case .reclassifyReason: return "Reclassify Transaction"
        case .deleteConfirm:
            return transaction.source == .manual ? "Delete Transaction" : "Move to Trash"
        }
    }

    private var subtitle: String {
        "\(TransactionFormatting.displayMerchant(transaction.merchant)) — \(TransactionFormatting.formatCents(transaction.amountCents))"
    }

    // MARK: - List

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
            VStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        guard !action.disabled else { return }
                        select(action.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.label)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(DesignTokens.ink)
                                Text(action.subline)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(hex: "#6b7280"))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        .padding(.vertical, 12)
                        .opacity(action.disabled ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(action.disabled)
                    if action.id != actions.last?.id {
                        Divider()
                    }
                }
            }
            if showsNonCountingNote {
                Text("This row does not count toward weekly spending.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
    }

    private func select(_ action: ActionKind) {
        switch action {
        case .charity:
            flow = .charityConfirm
        case .extraFund:
            extraFundAmount = String(format: "%.2f", Double(transaction.amountCents) / 100.0)
            flow = .extraFund
        case .linkRefund:
            if transaction.originalPurchaseId != nil {
                flow = .unlinkConfirm
            } else {
                flow = .linkCandidates
                Task {
                    linkCandidates = await viewModel.linkCandidates(for: transaction)
                }
            }
        case .reclassify:
            flow = .reclassifyKind
        case .delete:
            flow = .deleteConfirm
        }
    }

    // MARK: - Charity

    private var charityConfirmContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(charityMessage)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            TwoButtonRow {
                Button("Mark as Charity") {
                    Task {
                        isWorking = true
                        let ok = await viewModel.markAsCharity(transaction)
                        isWorking = false
                        if ok { onDismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking)
            } secondary: {
                Button("Cancel") { flow = .list }
                    .buttonStyle(TertiaryButtonStyle())
            }
        }
    }

    private var charityMessage: String {
        if transaction.state == .provisional {
            return "This moves the whole transaction out of weekly spending. It counts as charity given once it posts. If only part of it was a gift, do not mark it here: part-gifts are not supported yet."
        }
        return "This moves the whole transaction out of weekly spending and counts it as charity given. If only part of it was a gift, do not mark it here: part-gifts are not supported yet."
    }

    // MARK: - Extra Fund

    private var extraFundContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask the admin to cover “\(TransactionFormatting.displayMerchant(transaction.merchant))” (\(TransactionFormatting.formatCents(transaction.amountCents))) from the Extra Fund?")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text("Amount ($)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                TextField("0.00", text: $extraFundAmount)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            if let extraFundError {
                SoftErrorBox(extraFundError)
            }
            TwoButtonRow {
                Button("Send Request") {
                    Task {
                        guard let cents = TransactionFormatting.parseDollarsStrict(extraFundAmount),
                              cents > 0 else {
                            extraFundError = "Enter a positive amount."
                            return
                        }
                        isWorking = true
                        let ok = await viewModel.requestExtraFund(for: transaction, amountCents: cents)
                        isWorking = false
                        if ok { onDismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking)
            } secondary: {
                Button("Cancel") { flow = .list }
                    .buttonStyle(TertiaryButtonStyle())
            }
        }
    }

    // MARK: - Link / unlink refund

    private var linkCandidatesContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let linkCandidates {
                if linkCandidates.isEmpty {
                    Text("No matching purchase found")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    Text(
                        "No charge on the same card in the 90 days before \(TransactionFormatting.fmtLong(transaction.date)). If the purchase was older, on another card, or under a different name, it cannot be linked from here."
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#6b7280"))
                } else {
                    Text("Choose the purchase this refund came from.")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.ink)
                    VStack(spacing: 0) {
                        ForEach(linkCandidates) { purchase in
                            Button {
                                Task {
                                    isWorking = true
                                    let ok = await viewModel.linkRefund(transaction, to: purchase)
                                    isWorking = false
                                    if ok { onDismiss() }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(TransactionFormatting.displayMerchant(purchase.merchant))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(DesignTokens.ink)
                                        Text("\(TransactionFormatting.formatCents(purchase.amountCents)) · \(TransactionFormatting.displayDay(purchase.date))")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(hex: "#6b7280"))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color(hex: "#6b7280"))
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                            if purchase.id != linkCandidates.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            Button("Cancel") { flow = .list }
                .buttonStyle(TertiaryButtonStyle())
        }
    }

    private var unlinkConfirmContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(unlinkMessage)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            TwoButtonRow {
                Button("Unlink") {
                    Task {
                        isWorking = true
                        let ok = await viewModel.unlinkRefund(transaction)
                        isWorking = false
                        if ok { onDismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking)
            } secondary: {
                Button("Cancel") { flow = .list }
                    .buttonStyle(TertiaryButtonStyle())
            }
        }
    }

    private var unlinkMessage: String {
        if let linkedSummary {
            return "This refund is linked to \(TransactionFormatting.displayMerchant(linkedSummary.merchant)) — \(TransactionFormatting.formatCents(linkedSummary.amountCents)) · \(TransactionFormatting.displayDay(linkedSummary.date)). Unlink it? It will count as an unlinked refund again."
        }
        return "This refund is linked to a purchase. Unlink it? It will count as an unlinked refund again."
    }

    // MARK: - Reclassify ("Other")

    private var reclassifyKindContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change how this transaction counts. Pick the new type, then give a reason.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(spacing: 0) {
                ForEach(reclassifyOptions, id: \.label) { option in
                    Button {
                        if option.kind == .charity {
                            flow = .charityConfirm
                        } else {
                            flow = .reclassifyReason(option.kind)
                        }
                    } label: {
                        HStack {
                            Text(option.label)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DesignTokens.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    if option.kind != reclassifyOptions.last?.kind {
                        Divider()
                    }
                }
            }
        }
    }

    /// Reclassify options (live.js:3923-3930). `charity` is listed
    /// but routes to the guarded mark-as-charity path, never the raw
    /// RPC (`TransactionKind.reclassifiable` excludes it for the call).
    private var reclassifyOptions: [(kind: TransactionKind, label: String)] {
        [
            (.charge, "Charge"),
            (.refund, "Refund"),
            (.fundCharge, "Fund Charge"),
            (.transfer, "Transfer"),
            (.payment, "Payment"),
            (.cashback, "Cashback"),
            (.income, "Income"),
            (.charity, "Charity"),
        ]
    }

    private func reclassifyReasonContent(kind: TransactionKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give a reason for reclassifying this transaction.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text("Reason (required)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                TextField("Reason", text: $reclassifyReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
            if let reclassifyReasonError {
                SoftErrorBox(reclassifyReasonError)
            }
            TwoButtonRow {
                Button("Continue") {
                    Task {
                        let reason = reclassifyReason.trimmingCharacters(in: .whitespaces)
                        guard !reason.isEmpty else {
                            reclassifyReasonError = "Reason required"
                            return
                        }
                        isWorking = true
                        let ok = await viewModel.reclassify(transaction, to: kind, reason: reason)
                        isWorking = false
                        if ok { onDismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking)
            } secondary: {
                Button("Cancel") { flow = .reclassifyKind }
                    .buttonStyle(TertiaryButtonStyle())
            }
        }
    }

    // MARK: - Delete

    private var deleteConfirmContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if transaction.source == .manual {
                Text("This removes the hand-entered transaction and cannot be undone.")
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.ink)
                TwoButtonRow {
                    Button("Delete") {
                        Task {
                            isWorking = true
                            let ok = await viewModel.delete(transaction, reason: "")
                            isWorking = false
                            if ok { onDismiss() }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isWorking)
                } secondary: {
                    Button("Keep It") { flow = .list }
                        .buttonStyle(TertiaryButtonStyle())
                }
            } else {
                Text("This moves it to the Trash. The admin can bring it back from the Trash. Give a reason to continue.")
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.ink)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reason (required)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField("Reason", text: $deleteReason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
                if let deleteReasonError {
                    SoftErrorBox(deleteReasonError)
                }
                TwoButtonRow {
                    Button("Delete") {
                        Task {
                            let reason = deleteReason.trimmingCharacters(in: .whitespaces)
                            guard !reason.isEmpty else {
                                deleteReasonError = "Reason required"
                                return
                            }
                            isWorking = true
                            let ok = await viewModel.delete(transaction, reason: reason)
                            isWorking = false
                            if ok { onDismiss() }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isWorking)
                } secondary: {
                    Button("Keep It") { flow = .list }
                        .buttonStyle(TertiaryButtonStyle())
                }
            }
        }
    }
}
