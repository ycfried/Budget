import SwiftUI
import OnBudgetKit

/// Transaction Actions sheet (CLONE_SPEC §7.4, live.js:3763-3970).
///
/// Sheet header: X close (top-left symbol) on the list flow, back
/// chevron on a sub-flow, title centred (owner, Nov 14, 2026 — the
/// toolbar "Cancel" text truncated to "Ca…" and the NavigationStack
/// root broke fitted sizing, so the sheet rendered tall and mostly
/// empty). Subtitle "Merchant — $X". Rows are tappable list rows (label bold
/// + muted sub-line + ›). Which actions appear is decided by the
/// `actionsForTxKind` table — the clone uses this exact table
/// (relaxed Nov 8, 2026: Charity is offered on ANY charge;
/// members do not see it at all — owner rule, Nov 13, 2026:
/// the sheet never renders a disabled row, only actions that
/// work):
///
/// | kind | Admin | Member |
/// | charge | Charity, Extra Fund, Designate as Savings, Other, Delete | Extra Fund |
/// | refund | Link to Purchase, Designate as Savings, Other, Delete | — (no actions) |
/// | cashback | Designate as Savings, Other, Delete | — |
/// | transfer, payment, fund_charge | Other, Delete | — |
/// | charity | Delete | — |
/// | income | Designate as Savings, Other, Delete | — |
/// | other kinds | Other, Delete | — |
///
/// Owner rule (Nov 13, 2026): the sheet never renders a disabled
/// row — only actions that work. A member simply does not see
/// "Mark as Charity" (it used to render greyed-out with an
/// "Only the admin can..." subline). The `disabled` flag is gone
/// from SheetAction entirely so the pattern cannot come back.
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
        /// Build 30: teachable merchant rename (name + fixed kind, when set,
        /// fixed kind, remembered for all matching rows).
        case rename
        /// Build 42 (owner, Nov 17, 2026): designate this row as a
        /// Savings transaction — money-in adds to Savings Available,
        /// a charge subtracts from it (Available → Pending →
        /// carried debt).
        case savingsConfirm
    }

    enum ActionKind: Hashable {
        case charity
        case extraFund
        case linkRefund
        case reclassify
        case delete
        case rename
    }

    /// Fixed-kind options for the rename flow: the server's kind
    /// values with plain labels. "No Fixed Kind" (nil) is name-only.
    private static let fixedKindOptions: [(raw: String, label: String)] = [
        ("charge", "Charge"),
        ("refund", "Refund"),
        ("fund_charge", "Fund Charge"),
        ("payment", "Payment"),
        ("cashback", "Cash Back"),
        ("charity", "Charity"),
        ("transfer", "Transfer"),
        ("income", "Income"),
    ]

    struct SheetAction: Identifiable {
        let id: ActionKind
        let label: String
        let subline: String
    }

    let transaction: Transaction
    let isAdmin: Bool
    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void
    /// Custom fund names (build 37 — fund rename, owner Nov 16,
    /// 2026): the household's `fund_names` map, so the "Mark as
    /// Charity" / "Use Extra Fund" action labels use the renamed
    /// fund's name. [:] means the defaults.
    let fundNames: [String: String]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var flow: Flow = .list
    @State private var extraFundAmount: String = ""
    @State private var extraFundError: String?
    @State private var reclassifyReason: String = ""
    @State private var reclassifyReasonError: String?
    @State private var deleteReason: String = ""
    @State private var deleteReasonError: String?
    @State private var renameName: String = ""
    @State private var renameFixedKind: String?
    @State private var renameError: String?
    @State private var linkCandidates: [Transaction]?
    @State private var linkedSummary: (merchant: String, amountCents: Int, date: String)?
    @State private var isWorking: Bool = false

    public init(
        transaction: Transaction,
        isAdmin: Bool,
        viewModel: TransactionsViewModel,
        fundNames: [String: String] = [:],
        onDismiss: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.isAdmin = isAdmin
        self.viewModel = viewModel
        self.fundNames = fundNames
        self.onDismiss = onDismiss
    }

    /// The charity / Extra Fund display names (build 37 — fund
    /// rename): the custom name when stored, else the default.
    private var charityName: String { FundSectionID.charity.displayName(customNames: fundNames) }
    private var extraFundName: String { FundSectionID.fund.displayName(customNames: fundNames) }

    // MARK: - Action table

    /// Whether "Designate as <Extra Fund>" is offered for this row
    /// (build 42, owner Nov 17, 2026): admin only, a charge or a
    /// money-in kind (income / refund / cashback), a non-zero
    /// amount, and a live row — never a reversed or trashed one.
    /// Members never see it (owner rule, Nov 13, 2026: the sheet
    /// never renders a row that cannot work). Build 43 (owner, Nov
    /// 17, 2026 — item 19): it is no longer a standalone top-level
    /// row — it lives inside the reclassify list ("Other → Change
    /// how this transaction counts"), next to the other
    /// reclassification options, and routes to .savingsConfirm.
    private var canDesignateAsSavings: Bool {
        guard isAdmin else { return false }
        guard transaction.amountCents != 0 else { return false }
        guard transaction.state != .reversed && !transaction.isInTrash else { return false }
        switch transaction.kind {
        case .charge, .income, .refund, .cashback: return true
        default: return false
        }
    }

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
                var list = [
                    SheetAction(id: .charity, label: "Mark as \(charityName)", subline: charitySubline),
                    SheetAction(id: .extraFund, label: "Use \(extraFundName)", subline: "Ask for this charge to be covered from the fund"),
                ]
                list += [
                    SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts"),
                    SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it"),
                    SheetAction(id: .delete, label: "Delete", subline: deleteSubline),
                ]
                return list
            }
            // Owner rule (Nov 13, 2026): no disabled rows — a
            // member simply does not see "Mark as Charity".
            return [
                SheetAction(id: .extraFund, label: "Use \(extraFundName)", subline: "Ask for this charge to be covered from the fund"),
            ]
        case .refund:
            guard isAdmin else { return [] }
            let linkSubline = transaction.originalPurchaseId != nil
                ? "Change or remove the purchase this refund is linked to"
                : "Link this refund to the purchase it came from"
            var list = [
                SheetAction(id: .linkRefund, label: "Link to Purchase", subline: linkSubline),
            ]
            list += [
                SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts"),
                SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it"),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline),
            ]
            return list
        case .transfer, .payment, .cashback, .fundCharge:
            guard isAdmin else { return [] }
            var list: [SheetAction] = []
            // Only cashback is money-in here: a transfer, a card
            // payment and a fund charge cannot be designated.
            list += [
                SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts"),
                SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it"),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline),
            ]
            return list
        case .charity:
            guard isAdmin else { return [] }
            return [
                SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it"),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline),
            ]
        case .income, .other:
            guard isAdmin else { return [] }
            var list: [SheetAction] = []
            // Only income is money-in here: "other" has no
            // direction to designate.
            list += [
                SheetAction(id: .reclassify, label: "Other", subline: "Change how this transaction counts"),
                SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it"),
                SheetAction(id: .delete, label: "Delete", subline: deleteSubline),
            ]
            return list
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
        // No NavigationStack root (owner, Nov 14, 2026): the
        // toolbar "Cancel" truncated to "Ca…", and a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty (build 24) — a single
        // "Use Extra Fund" row in a full-height card. A plain VStack
        // root + SheetHeader keeps the content at the top of the
        // full-screen popup (build 43, item 17 — the cover is
        // full-screen now, no detents; the trailing Spacer below
        // is what top-anchors it, item 18). On the list flow the
        // header shows X (dismiss); on a sub-flow it shows a back
        // chevron (return to the list).
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(
                title: flowTitle,
                onClose: { onDismiss() },
                onBack: flow == .list ? nil : { flow = .list }
            )
            switch flow {
            case .list: listContent
            case .charityConfirm: charityConfirmContent
            case .extraFund: extraFundContent
            case .linkCandidates: linkCandidatesContent
            case .unlinkConfirm: unlinkConfirmContent
            case .reclassifyKind: reclassifyKindContent
            case .reclassifyReason(let kind): reclassifyReasonContent(kind: kind)
            case .deleteConfirm: deleteConfirmContent
            case .rename: renameContent
            case .savingsConfirm: savingsConfirmContent
            }
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // full-screen cover — without it the short flows
            // centre themselves vertically in the full screen.
            Spacer()
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet. The trailing Spacer is back (build
        // 43, item 18): in the full-screen cover it top-anchors
        // the short flows — in the old detent sheet it stretched
        // the middle empty against the tall form sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // T-P2-1: the failure alert lives on this sheet, not on the
        // Transactions parent — an alert attached behind a presented
        // sheet never surfaces, so failures from markAsCharity,
        // reclassify, delete, designate-as-Savings and
        // link/unlinkRefund were invisible.
        .alert(
            viewModel.alertTitle ?? "Something Went Wrong",
            isPresented: $viewModel.showAlert,
            presenting: viewModel.alertMessage
        ) { _ in
            Button("Close", role: .cancel) {}
        } message: { message in
            Text(message)
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
        case .charityConfirm: return "Mark as \(charityName) Gift"
        case .extraFund: return "Use \(extraFundName)"
        case .linkCandidates: return "Link Refund to Purchase"
        case .unlinkConfirm: return "Unlink Refund"
        case .reclassifyKind: return "Reclassify Transaction"
        case .reclassifyReason: return "Reclassify Transaction"
        case .rename: return "Rename Merchant"
        case .savingsConfirm: return "Designate as \(extraFundName)"
        case .deleteConfirm:
            return transaction.source == .manual ? "Delete Transaction" : "Move to Trash"
        }
    }

    private var subtitle: String {
        "\(TransactionFormatting.displayMerchant(transaction.merchant)) — \(TransactionFormatting.amountDisplay(for: transaction).text)"
    }

    // MARK: - List

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
            VStack(spacing: 0) {
                ForEach(actions) { action in
                    // Whole-row tap target (owner, Nov 15, 2026
                    // app-wide pass): `.contentShape(Rectangle())`
                    // makes the empty space between the text and the
                    // chevron respond too — the same treatment as
                    // the link-candidate and reclassify rows below.
                    Button {
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        case .rename:
            renameName = TitleCase.apply(to: transaction.merchant.lowercased())
            renameFixedKind = nil
            renameError = nil
            flow = .rename
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
                Button("Mark as \(charityName)") {
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

    // MARK: - Designate as Savings (build 42, owner Nov 17, 2026)

    /// A FundsViewModel for the designate call: the sheet only owns
    /// a TransactionsViewModel, so one is built here from the same
    /// client / household / role. It loads fresh fund figures inside
    /// `designateTransactionAsSavings` before it splits anything.
    /// Nil when there is no signed-in user id to build the context
    /// from — the action is then refused, never attempted half-built.
    /// (The shell also owns a FundsViewModel for Review; it is not
    /// reachable from this sheet, and this throwaway instance is
    /// enough — the call refreshes its own figures and the Funds
    /// tab re-reads on its next refresh.)
    private func makeFundsViewModel() -> FundsViewModel? {
        guard let userId = viewModel.currentUserId else { return nil }
        // Build 43 (owner, Nov 17, 2026 — item 16): the throwaway
        // instance gets the sheet's fund names, so its toasts and
        // alerts read with the fund's CURRENT display name.
        let fundsViewModel = FundsViewModel(context: FundsContext(
            client: viewModel.client,
            householdId: viewModel.householdId,
            role: isAdmin ? .admin : .member,
            userId: userId
        ))
        fundsViewModel.fundNames = fundNames
        return fundsViewModel
    }

    private var savingsConfirmContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(savingsMessage)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            TwoButtonRow {
                Button("Designate as \(extraFundName)") {
                    Task {
                        isWorking = true
                        guard let fundsViewModel = makeFundsViewModel() else {
                            isWorking = false
                            viewModel.showAlert(title: "Could Not Designate", message: "Could not load your household. Try again.")
                            return
                        }
                        let message = await fundsViewModel.designateTransactionAsSavings(transaction)
                        isWorking = false
                        if let message {
                            viewModel.toastManager.show(message, kind: .success)
                            onDismiss()
                        } else {
                            viewModel.showAlert(
                                title: fundsViewModel.alertTitle ?? "Could Not Designate",
                                message: fundsViewModel.alertMessage ?? "Could not designate this transaction. Try again."
                            )
                        }
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

    private var savingsMessage: String {
        let amount = TransactionFormatting.amountDisplay(for: transaction).text
        let merchant = TransactionFormatting.displayMerchant(transaction.merchant)
        if transaction.kind.isMoneyIn {
            return "This adds \(amount) to the \(extraFundName) Available balance — “\(merchant)” is already in checking, so it counts immediately, with no pending state. If money is owed back, the fund's shortfall is covered first and the rest is added to Available."
        }
        return "This takes \(amount) out of the \(extraFundName) Available balance for “\(merchant)”. If Available runs out, the rest comes from Pending top-ups, then adds to carried debt. The transaction row itself stays a charge — it still counts toward weekly spending; only the fund balance moves."
    }

    // MARK: - Extra Fund

    private var extraFundContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask the admin to cover “\(TransactionFormatting.displayMerchant(transaction.merchant))” (\(TransactionFormatting.amountDisplay(for: transaction).text)) from the \(extraFundName)?")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Amount", required: true)
                DollarTextField(text: $extraFundAmount)
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
                        // T-P2-6: a request can never exceed the
                        // charge it covers.
                        guard cents <= transaction.amountCents else {
                            extraFundError = "The request can't be more than the charge (\(TransactionFormatting.amountDisplay(for: transaction).text))."
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

    // MARK: - Rename merchant (build 30, teachable rules)

    private var renameContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename “\(TransactionFormatting.displayMerchant(transaction.merchant))” everywhere — old rows and new ones. The name is remembered, so future rows with this name arrive renamed.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text("Merchant Name")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                TextField("", text: $renameName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Always Count As")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Picker("", selection: $renameFixedKind) {
                    Text("No Fixed Kind").tag(nil as String?)
                    ForEach(Self.fixedKindOptions, id: \.0) { option in
                        Text(option.label).tag(option.raw as String?)
                    }
                }
                .pickerStyle(.menu)
            }
            if let renameError {
                SoftErrorBox(renameError)
            }
            TwoButtonRow {
                Button("Save Name") {
                    Task {
                        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else {
                            renameError = "Enter a name."
                            return
                        }
                        isWorking = true
                        let ok = await viewModel.renameMerchant(transaction, to: name, fixedKind: renameFixedKind)
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
                    Text("No Matching Purchase Found")
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
                                .contentShape(Rectangle())
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
                HStack {
                    Spacer()
                    BrandedLoader(size: 40)
                    Spacer()
                }
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if option.kind != reclassifyOptions.last?.kind {
                        Divider()
                    }
                }
                // Build 43 (owner, Nov 17, 2026 — item 19):
                // "Designate as <Extra Fund>" is a reclassification
                // (it changes how the transaction counts), so it
                // lives here with the other reclassify options
                // instead of as a standalone Actions row. Money-in
                // adds to the fund, a charge pays out of it — the
                // confirm screen explains the direction.
                if canDesignateAsSavings {
                    Divider()
                    Button {
                        flow = .savingsConfirm
                    } label: {
                        HStack {
                            Text("Designate as \(extraFundName)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DesignTokens.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            (.charity, charityName),
        ]
    }

    private func reclassifyReasonContent(kind: TransactionKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give a reason for reclassifying this transaction.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text("Reason (Required)")
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
                    Text("Reason (Required)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField("Reason", text: $deleteReason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
                if let deleteReasonError {
                    SoftErrorBox(deleteReasonError)
                }
                TwoButtonRow {
                    Button("Move to Trash") {
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
