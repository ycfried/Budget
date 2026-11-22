import SwiftUI
import OnBudgetKit

/// Transaction Actions sheet (CLONE_SPEC §7.4, live.js:3763-3970).
///
/// ONE sheet, no "Other" bucket (build 52, owner Nov 20, 2026 —
/// the flow was "too hard to navigate": row → Actions → Other →
/// Reclassify page, with the same action in two places). Build 54
/// (owner, Nov 21, 2026) splits it into TWO groups, because the
/// most-used actions were buried under the rest of the kinds:
///
/// - Group 1, "How It Counts", always visible: the row's CURRENT
///   category first (marked with a checkmark, not a Button — it is
///   the current state, not an action), then the actions that drive
///   the math, in the brief's order — Spending, Income, Mark as
///   Tzedaka, Cover with Savings, Add to Savings, Exclude, Delete
///   (RED). Spending IS in the list now (it was not, even though
///   the charge IS spending). For a kind that lives in Group 2
///   (Transfer, Refund, Fund Charge, Payment, Cashback), the
///   current category is prepended to Group 1 marked — the current
///   category is always visible, never hidden in "More".
/// - Group 2, "More", collapsed by default behind a "More"
///   disclosure row that expands inline: Transfer, Refund, Fund
///   Charge, Payment, Cashback, Rename Merchant. The sheet opens
///   showing only Group 1 + the More row.
///
/// Subtitles STAY (owner, Nov 21, 2026 — they help many users).
/// "Mark as Tzedaka" IS the Tzedaka reclassify (there is no second
/// Tzedaka row), and "Cover with Savings" (ask the fund to cover
/// this charge) and "Add to Savings" (count this amount toward the
/// fund) are different functions, so each appears exactly once,
/// clearly labelled, not literally merged. A refund row keeps
/// "Link to Purchase" in Group 1 (it was a TOP action; dropping it
/// would break refund linking).
///
/// Which actions appear is decided by the `actionGroups` table —
/// the clone uses this exact table (relaxed Nov 8, 2026: Charity
/// is offered on ANY charge; members do not see it at all — owner
/// rule, Nov 13, 2026: the sheet never renders a disabled row,
/// only actions that work). Per-kind applicability follows the
/// build-52 table, reorganised into the two groups (Transfer moves
/// from TOP to "More" for every kind):
///
/// | kind | Admin — Group 1 | Admin — Group 2 (More) | Member |
/// | charge | Spending (current), Income, Mark as Tzedaka, Cover with Savings, Add to Savings, Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Cashback, Rename Merchant | Spending (current), Cover with Savings |
/// | refund | Refund (current), Link to Purchase, Spending, Income, Add to Savings, Exclude, Delete | Transfer, Fund Charge, Payment, Cashback, Rename Merchant | — (no actions) |
/// | transfer, payment, fund_charge | current kind, Spending, Income, Exclude, Delete | the other kinds, Rename Merchant | — |
/// | cashback | Cashback (current), Spending, Income, Add to Savings, Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Rename Merchant | — |
/// | charity | Mark as Tzedaka (current), Delete | Rename Merchant | — |
/// | income | Income (current), Spending, Add to Savings, Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Cashback, Rename Merchant | — |
/// | other | Other (current), Spending, Income, Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Cashback, Rename Merchant | — |
///
/// "Add to Savings" only appears when `canDesignateAsSavings`
/// (admin, non-zero, live row, charge/income/refund/cashback).
///
/// Sheet header: X close (top-left symbol) on the list flow, back
/// chevron on a sub-flow, title centred (owner, Nov 14, 2026 — the
/// toolbar "Cancel" text truncated to "Ca…" and the NavigationStack
/// root broke fitted sizing, so the sheet rendered tall and mostly
/// empty). The merchant + amount line is bold, the amount in the
/// transaction's colour, with a Divider below it — clearly
/// separated from the action rows. Rows are tappable list rows
/// (label bold + muted sub-line + ›).
///
/// Owner rule (Nov 13, 2026): the sheet never renders a disabled
/// row — only actions that work. A member simply does not see
/// "Mark as Charity" (it used to render greyed-out with an
/// "Only the admin can..." subline). The `disabled` flag is gone
/// from SheetAction entirely so the pattern cannot come back. The
/// current-category row is a non-Button indicator, not a disabled
/// button, for the same reason.
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
        case reclassifyReason(TransactionKind)
        case deleteConfirm
        /// Build 50 (owner, Nov 20, 2026): exclude this row from
        /// the spending math without reclassifying it — the owner
        /// had to misuse "Transfer" to get a row out of the math
        /// because there was no Exclude. Same server call as
        /// Delete → Trash (`exclude_transaction`, restorable),
        /// but labelled for its intent.
        case excludeConfirm
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
        /// Reclassify directly to a kind — the reclassify kinds
        /// sit in this sheet (build 52), so there is no
        /// "Other" bucket and no separate reclassify page.
        case reclassifyTo(TransactionKind)
        /// Build 42: count this amount toward the fund. A
        /// different function from "Use Extra Fund" (a coverage
        /// request), so it is its own action, not a merge.
        case designateSavings
        /// Build 50: take the row out of the spending math
        /// without reclassifying it.
        case exclude
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
        /// Build 54: this row IS the transaction's current
        /// category — rendered as a non-Button indicator with a
        /// checkmark, never a tappable action and never a
        /// greyed-out button (the standing rule forbids those).
        let isCurrent: Bool
        /// Build 54: Delete — the label renders in error red
        /// (#dc2626), the subline and chevron stay muted.
        let isDestructive: Bool

        init(id: ActionKind, label: String, subline: String, isCurrent: Bool = false, isDestructive: Bool = false) {
            self.id = id
            self.label = label
            self.subline = subline
            self.isCurrent = isCurrent
            self.isDestructive = isDestructive
        }
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
    @State private var excludeReason: String = ""
    @State private var excludeReasonError: String?
    @State private var renameName: String = ""
    @State private var renameFixedKind: String?
    @State private var renameError: String?
    /// Build 47 (owner, Nov 19, 2026): the rename popup shows
    /// HOW the rule matches — "exact" (the current behaviour,
    /// normalised for case/punctuation) or "includes" (any future
    /// bank name containing the bank name). Pre-filled from the
    /// existing rule when there is one, else Exact.
    @State private var renameMatchType: String = "exact"
    /// Build 47: the bank name as the bank sends it — the rule's
    /// stored source merchant when there is one, else this row's
    /// raw merchant. Shown raw, never Title-Cased.
    @State private var renameBankName: String = ""
    @State private var linkCandidates: [Transaction]?
    @State private var linkedSummary: (merchant: String, amountCents: Int, date: String)?
    @State private var isWorking: Bool = false
    /// Build 54: whether the "More" group is expanded. The sheet
    /// opens collapsed (Group 1 + the More row only); the toggle
    /// is instant, no animation (standing rule). Fresh per sheet
    /// open — a new sheet instance always starts collapsed.
    @State private var moreExpanded: Bool = false

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

    // MARK: - Action table (build 54 — two groups, no "Other")

    /// One group in the single Actions sheet: Group 1 ("How It
    /// Counts", always visible) and Group 2 ("More", collapsed
    /// behind a disclosure row by default, expands inline).
    private struct ActionGroup {
        let label: String?
        let isMore: Bool
        let actions: [SheetAction]

        init(label: String?, actions: [SheetAction], isMore: Bool = false) {
            self.label = label
            self.isMore = isMore
            self.actions = actions
        }
    }

    /// Whether "Add to <Extra Fund>" is offered for this row
    /// (build 42, owner Nov 17, 2026): admin only, a charge or a
    /// money-in kind (income / refund / cashback), a non-zero
    /// amount, and a live row — never a reversed or trashed one.
    /// Members never see it (owner rule, Nov 13, 2026: the sheet
    /// never renders a row that cannot work). Build 54 (owner, Nov
    /// 21, 2026): it lives in Group 1 ("How It Counts") of this
    /// sheet, next to the other math-driving actions, and routes
    /// to .savingsConfirm. It is a DIFFERENT function from "Cover
    /// with Savings" (a coverage request), so each appears exactly
    /// once, clearly labelled.
    private var canDesignateAsSavings: Bool {
        guard isAdmin else { return false }
        guard transaction.amountCents != 0 else { return false }
        guard transaction.state != .reversed && !transaction.isInTrash else { return false }
        switch transaction.kind {
        case .charge, .income, .refund, .cashback: return true
        default: return false
        }
    }

    /// The plain label for a reclassify kind. Build 54: a charge
    /// is "Spending", not "Charge" — the owner wants the list to
    /// say what the money IS, and the current category (a charge)
    /// must read "Spending" in Group 1.
    private func kindLabel(_ kind: TransactionKind) -> String {
        switch kind {
        case .charge: return "Spending"
        case .refund: return "Refund"
        case .fundCharge: return "Fund Charge"
        case .transfer: return "Transfer"
        case .payment: return "Payment"
        case .cashback: return "Cashback"
        case .income: return "Income"
        case .charity: return charityName
        case .other: return "Other"
        }
    }

    /// The one-line plain-English subline for a reclassify kind.
    private func kindSubline(_ kind: TransactionKind) -> String {
        switch kind {
        case .charge: return "Count it as spending"
        case .refund: return "Count it as a refund"
        case .fundCharge: return "Count it as a fund charge"
        case .transfer: return "Move money between accounts, not spending"
        case .payment: return "Count it as a card payment"
        case .cashback: return "Count it as cash back"
        case .income: return "Count it as money in"
        case .charity: return "Count it as a charity gift"
        case .other: return "Count it as something else"
        }
    }

    private var actionGroups: [ActionGroup] {
        let isVerified = transaction.state == .verified
        let charitySubline = isVerified
            ? "Counts it as a charity gift, out of weekly spending"
            : "Counts as a charity gift once it posts"
        let deleteSubline = transaction.source == .manual
            ? "Permanently deletes this hand-entered row"
            : "Moves this row to the Trash"
        let rename = SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it")
        let delete = SheetAction(id: .delete, label: "Delete", subline: deleteSubline, isDestructive: true)
        let exclude = SheetAction(id: .exclude, label: "Exclude", subline: "Takes it out of the spending math")
        // Build 54 (owner, Nov 21, 2026): the owner renamed "Pay
        // from Savings" to "Cover with Savings" (build 53 used
        // "Pay from Savings" for audit item 8). "Cover with
        // Savings" spends from the fund for this purchase; "Add
        // to Savings" moves this money into the fund — the two
        // labels say their direction, so they no longer read as
        // the same thing.
        let extraFund = SheetAction(id: .extraFund, label: "Cover with \(extraFundName)", subline: "Use the fund to cover this charge")
        let charity = SheetAction(id: .charity, label: "Mark as \(charityName)", subline: charitySubline)
        let designate = SheetAction(id: .designateSavings, label: "Add to \(extraFundName)", subline: "Counts this amount toward the fund")

        /// A reclassify row for a kind — nil when it IS the row's
        /// current kind (reclassifying to what it already is is
        /// not an action). Tzedaka is never a reclassify row here:
        /// it is the top "Mark as Tzedaka" action.
        func reclassify(_ kind: TransactionKind) -> SheetAction? {
            guard kind != transaction.kind else { return nil }
            return SheetAction(id: .reclassifyTo(kind), label: kindLabel(kind), subline: kindSubline(kind))
        }

        /// The row's CURRENT category (build 54): always first in
        /// Group 1, marked with a checkmark, not a Button — it is
        /// the current state, not an action. Spending is in the
        /// list now (it was not, even though the charge IS
        /// spending). For a kind that lives in Group 2 (Transfer,
        /// Refund, Fund Charge, Payment, Cashback), the current
        /// category is prepended to Group 1 marked — the current
        /// category is always visible, never hidden in "More".
        func current() -> SheetAction {
            switch transaction.kind {
            case .charity:
                return SheetAction(id: .charity, label: "Mark as \(charityName)", subline: "Current category", isCurrent: true)
            case .charge:
                return SheetAction(id: .reclassifyTo(.charge), label: "Spending", subline: "Current category", isCurrent: true)
            default:
                return SheetAction(id: .reclassifyTo(transaction.kind), label: kindLabel(transaction.kind), subline: "Current category", isCurrent: true)
            }
        }

        switch transaction.kind {
        case .charge:
            if isAdmin {
                var group1 = [current()]
                group1 += [reclassify(.income)].compactMap { $0 }
                group1.append(charity)
                group1.append(extraFund)
                if canDesignateAsSavings { group1.append(designate) }
                group1.append(exclude)
                group1.append(delete)
                let group2 = [reclassify(.transfer), reclassify(.refund), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 } + [rename]
                return [
                    ActionGroup(label: "How It Counts", actions: group1),
                    ActionGroup(label: nil, actions: group2, isMore: true),
                ]
            }
            // Owner rule (Nov 13, 2026): no disabled rows — a
            // member simply does not see "Mark as Charity".
            return [ActionGroup(label: "How It Counts", actions: [current(), extraFund])]
        case .refund:
            guard isAdmin else { return [] }
            let linkSubline = transaction.originalPurchaseId != nil
                ? "Change or remove the purchase this refund is linked to"
                : "Link this refund to the purchase it came from"
            let link = SheetAction(id: .linkRefund, label: "Link to Purchase", subline: linkSubline)
            var group1 = [current(), link]
            group1 += [reclassify(.charge), reclassify(.income)].compactMap { $0 }
            if canDesignateAsSavings { group1.append(designate) }
            group1.append(exclude)
            group1.append(delete)
            let group2 = [reclassify(.transfer), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 } + [rename]
            return [
                ActionGroup(label: "How It Counts", actions: group1),
                ActionGroup(label: nil, actions: group2, isMore: true),
            ]
        case .transfer, .payment, .cashback, .fundCharge:
            guard isAdmin else { return [] }
            var group1 = [current()]
            group1 += [reclassify(.charge), reclassify(.income)].compactMap { $0 }
            if canDesignateAsSavings { group1.append(designate) }
            group1.append(exclude)
            group1.append(delete)
            let group2 = [reclassify(.transfer), reclassify(.refund), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 } + [rename]
            return [
                ActionGroup(label: "How It Counts", actions: group1),
                ActionGroup(label: nil, actions: group2, isMore: true),
            ]
        case .charity:
            guard isAdmin else { return [] }
            return [
                ActionGroup(label: "How It Counts", actions: [current(), delete]),
                ActionGroup(label: nil, actions: [rename], isMore: true),
            ]
        case .income, .other:
            guard isAdmin else { return [] }
            var group1 = [current()]
            // For an income row reclassify(.income) is nil (it is
            // the current kind); for an .other row it is the
            // Income action — one list covers both.
            group1 += [reclassify(.charge), reclassify(.income)].compactMap { $0 }
            if canDesignateAsSavings { group1.append(designate) }
            group1.append(exclude)
            group1.append(delete)
            let group2 = [reclassify(.transfer), reclassify(.refund), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 } + [rename]
            return [
                ActionGroup(label: "How It Counts", actions: group1),
                ActionGroup(label: nil, actions: group2, isMore: true),
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
            case .reclassifyReason(let kind): reclassifyReasonContent(kind: kind)
            case .deleteConfirm: deleteConfirmContent
            case .excludeConfirm: excludeConfirmContent
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
        case .extraFund: return "Cover with \(extraFundName)"
        case .linkCandidates: return "Link Refund to Purchase"
        case .unlinkConfirm: return "Unlink Refund"
        case .reclassifyReason: return "Reclassify Transaction"
        case .excludeConfirm: return "Exclude Transaction"
        case .rename: return "Rename Merchant"
        case .savingsConfirm: return "Designate as \(extraFundName)"
        case .deleteConfirm:
            return transaction.source == .manual ? "Delete Transaction" : "Move to Trash"
        }
    }

    // MARK: - List

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Build 54: the merchant + amount line is obvious —
            // bold merchant, bold amount in the transaction's
            // colour, with a Divider below it separating the
            // header from the action rows (the old muted
            // "Merchant — $X" subline read as a caption).
            let amount = TransactionFormatting.amountDisplay(for: transaction)
            HStack(alignment: .firstTextBaseline) {
                Text(TransactionFormatting.displayMerchant(transaction.merchant))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Spacer()
                Text(amount.text)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(amount.color)
            }
            Divider()
            // Build 54: Group 1 ("How It Counts") renders always;
            // Group 2 ("More") renders behind a disclosure row
            // that expands inline. The sheet opens showing only
            // Group 1 + the More row.
            ForEach(actionGroups.indices, id: \.self) { groupIndex in
                let group = actionGroups[groupIndex]
                if group.isMore {
                    VStack(spacing: 0) {
                        Button {
                            // Instant, no animation (standing rule).
                            moreExpanded.toggle()
                        } label: {
                            HStack {
                                Text("More")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                Spacer()
                                Image(systemName: moreExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: "#6b7280"))
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if moreExpanded {
                            ForEach(group.actions) { action in
                                Divider()
                                actionRow(action)
                            }
                        }
                    }
                } else {
                    if let label = group.label {
                        Text(label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                    VStack(spacing: 0) {
                        ForEach(group.actions) { action in
                            actionRow(action)
                            if action.id != group.actions.last?.id {
                                Divider()
                            }
                        }
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

    /// One action row (build 54): a tappable Button, or — when
    /// `isCurrent` — a non-Button indicator row with a checkmark.
    /// A non-Button is honest: the current category is not an
    /// action, and the standing rule forbids greyed-out buttons.
    /// Delete renders its label in error red; every other label
    /// stays ink, the subline and chevron stay muted.
    private func actionRow(_ action: SheetAction) -> some View {
        if action.isCurrent {
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
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
            .padding(.vertical, 12)
        } else {
            // Whole-row tap target (owner, Nov 15, 2026
            // app-wide pass): `.contentShape(Rectangle())`
            // makes the empty space between the text and the
            // chevron respond too — the same treatment as
            // the link-candidate rows below.
            Button {
                select(action.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.label)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(action.isDestructive ? DesignTokens.errorText : DesignTokens.ink)
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
        case .reclassifyTo(let kind):
            // Tzedaka is never a reclassify row (it is the top
            // "Mark as Tzedaka" action), but the guard keeps the
            // charity path honest if one is ever constructed.
            if kind == .charity {
                flow = .charityConfirm
            } else {
                flow = .reclassifyReason(kind)
            }
        case .designateSavings:
            flow = .savingsConfirm
        case .exclude:
            flow = .excludeConfirm
        case .rename:
            renameName = TitleCase.apply(to: transaction.merchant.lowercased())
            renameFixedKind = nil
            renameMatchType = "exact"
            renameBankName = transaction.merchant
            renameError = nil
            flow = .rename
            // Build 47: when a rule already matches this bank name,
            // pre-fill from it — the stored display name, match
            // type and bank name — so editing a rule shows what it
            // already says instead of the defaults. Only what the
            // owner has not already edited while the rule loaded
            // gets overwritten.
            Task {
                let initialName = renameName
                let initialKind = renameFixedKind
                let initialMatch = renameMatchType
                if let rule = await viewModel.existingMerchantRule(for: transaction),
                   renameName == initialName, renameFixedKind == initialKind, renameMatchType == initialMatch {
                    renameName = rule.displayName
                    renameFixedKind = rule.fixedKind
                    renameMatchType = rule.matchType
                    if let source = rule.sourceMerchant, !source.isEmpty {
                        renameBankName = source
                    }
                }
            }
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

    // MARK: - Rename merchant (build 30, teachable rules; build
    // 47, owner Nov 19, 2026: the popup shows three things
    // plainly — From the Bank (what the bank sends, raw), Show as
    // (the display name), Match (Exact name only vs Any name
    // containing this). The old description paragraph is gone;
    // the fields say it. "Always Count As" is unchanged.

    private var renameContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("From the Bank")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Text(renameBankName)
                    .font(.system(size: 15))
                    .foregroundStyle(DesignTokens.ink)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Show as")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                TextField("", text: $renameName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Match")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Picker("Match", selection: $renameMatchType) {
                    Text("Exact Name Only").tag("exact")
                    Text("Any Name Containing This").tag("includes")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("rename.matchTypePicker")
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
                        let ok = await viewModel.renameMerchant(transaction, to: name, fixedKind: renameFixedKind, matchType: renameMatchType)
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

    // MARK: - Reclassify (build 52: the kinds sit directly in
    // the Actions sheet — there is no "Other" bucket and no
    // separate reclassify page. A kind tap lands here for its
    // reason; Cancel returns to the list, not to a reclassify
    // page. `charity` is never a reason here: it routes to the
    // guarded mark-as-charity path from the top action.)

    /// Exclude confirm (build 50, owner Nov 20, 2026): takes the
    /// row out of the spending math without changing its kind. It
    /// moves to the Trash — the admin can bring it back from the
    /// Trash — and the reason is required (audited, like Delete
    /// and Reclassify).
    private var excludeConfirmContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This takes it out of the spending math — it will not count toward weekly spending, and its kind stays as it is. It moves to the Trash. The admin can bring it back from the Trash. Give a reason to continue.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text("Reason (Required)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                TextField("Reason", text: $excludeReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
            if let excludeReasonError {
                SoftErrorBox(excludeReasonError)
            }
            TwoButtonRow {
                Button("Exclude") {
                    Task {
                        let reason = excludeReason.trimmingCharacters(in: .whitespaces)
                        guard !reason.isEmpty else {
                            excludeReasonError = "Reason required"
                            return
                        }
                        isWorking = true
                        let ok = await viewModel.exclude(transaction, reason: reason)
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
                Button("Cancel") { flow = .list }
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
