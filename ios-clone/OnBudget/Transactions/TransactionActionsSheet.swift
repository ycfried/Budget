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
///   the math, in the brief's order — Purchase, Income, Tzedaka,
///   Rename Merchant (build 64, F-41 — out of "More", at the end
///   of this group). Build 64 (F-33) splits the old seven-row
///   Group 1: the two fund actions live in their own "Savings"
///   section below it (Cover with Savings, Add to Savings),
///   and Exclude + Delete sit below that, Delete last below its
///   own rule, in its own block — the actions are unchanged,
///   only the grouping.
///   Build 63 (Lean): the group renders as a flat list with no
///   "How It Counts" header, and Delete sits last below its own
///   rule, in its own block — the actions are unchanged, only
///   the look.
///   Purchase IS in the list now (it was not, even though the
///   charge IS a purchase). For a kind that lives in Group 2
///   (Transfer, Refund, Fund Charge, Payment, Cashback), the
///   current category is prepended to Group 1 marked — the current
///   category is always visible, never hidden in "More".
///
/// Build 62 (owner, Nov 22, 2026 — the Actions options "all look
/// the same"): every row is colour-coded from the transaction
/// colour code with an SF Symbol in a tinted chip, so each option
/// is easy to spot at a glance — Purchase ink, Income deep blue,
/// Tzedaka primary blue, Exclude grey, Delete red, and the two
/// fund actions share one muted slate family so they read as a
/// pair. The label names the category; the subline says what it
/// does (owner: "The word should just name the category").
/// - Group 2, "More", collapsed by default behind a "More"
///   disclosure row that expands inline: Transfer, Refund, Fund
///   Charge, Payment, Cashback. The sheet opens showing only
///   Group 1 + the More row.
/// - Build 64 (C-4, owner Nov 23, 2026): fitted detents, not a
///   full-screen cover (reverses the Nov 17 full-screen rule) —
///   .medium for the list, small for the confirms — with the
///   merchant + amount summary header at the top of every
///   confirm flow.
///
/// Subtitles STAY (owner, Nov 21, 2026 — they help many users).
/// "Tzedaka" IS the Tzedaka reclassify (there is no second
/// Tzedaka row; build 62 dropped the "Mark as" prefix — the label
/// is just the fund name, the subline says what it does), and
/// "Cover with Savings" (ask the fund to cover this charge) and
/// "Add to Savings" (count this amount toward the fund) are
/// different functions, so each appears exactly once, clearly
/// labelled, not literally merged. A refund row keeps
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
/// | kind | Admin — Group 1 ("How It Counts" + "Savings" + rest) | Admin — Group 2 (More) | Member |
/// | charge | Purchase (current), Income, Tzedaka, Rename Merchant; Savings: Cover with Savings, Add to Savings; Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Cashback | Purchase (current); Savings: Cover with Savings |
/// | refund | Refund (current), Link to Purchase, Purchase, Income, Rename Merchant; Savings: Add to Savings; Exclude, Delete | Transfer, Fund Charge, Payment, Cashback | — (no actions) |
/// | transfer, payment, fund_charge | current kind, Purchase, Income, Rename Merchant; Savings: Add to Savings where offered; Exclude, Delete | the other kinds | — |
/// | cashback | Cashback (current), Purchase, Income, Rename Merchant; Savings: Add to Savings; Exclude, Delete | Transfer, Refund, Fund Charge, Payment | — |
/// | charity | Tzedaka (current), Purchase, Income, Rename Merchant, Exclude, Delete | — (no More group) | — |
/// | income | Income (current), Purchase, Rename Merchant; Savings: Add to Savings; Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Cashback | — |
/// | other | Other (current), Purchase, Income, Rename Merchant; Savings: Add to Savings; Exclude, Delete | Transfer, Refund, Fund Charge, Payment, Cashback | — |
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
/// the Tzedaka action (it used to render greyed-out with an
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
        /// Build 62 (owner, Nov 22, 2026 — the options "all look
        /// the same"): the row's colour, from the transaction
        /// colour code — Purchase ink, Income deep blue, Tzedaka
        /// primary blue, Exclude grey, Delete error red, the fund
        /// pair muted slate. The label renders in this colour and
        /// the icon chip is tinted with it, so each option is easy
        /// to spot at a glance. A hex string (not a Color) so the
        /// mapping is unit-testable.
        let colorHex: String
        /// Build 62: the SF Symbol for the row, shown in the
        /// action's colour in a tinted chip — rows are
        /// distinguishable by icon as well as colour.
        let icon: String

        init(id: ActionKind, label: String, subline: String, colorHex: String, icon: String, isCurrent: Bool = false) {
            self.id = id
            self.label = label
            self.subline = subline
            self.colorHex = colorHex
            self.icon = icon
            self.isCurrent = isCurrent
        }
    }

    let transaction: Transaction
    let isAdmin: Bool
    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void
    /// Custom fund names (build 37 — fund rename, owner Nov 16,
    /// 2026): the household's `fund_names` map, so the Tzedaka /
    /// Cover with Savings action labels use the renamed fund's
    /// name. [:] means the defaults.
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

    /// The plain label for a reclassify kind. Build 62: a charge
    /// is "Purchase", not "Spending" (owner, Nov 22, 2026 —
    /// "change spending to purchase"), and charity is just the
    /// fund name (owner: "just plain tzedaka"). The label names
    /// the category; the subline says what it does. Static + pure
    /// (the charity display name is passed in) so the mapping is
    /// unit-testable.
    static func kindLabel(_ kind: TransactionKind, charityName: String) -> String {
        switch kind {
        case .charge: return "Purchase"
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

    /// The colour + SF Symbol for one kind (build 62, owner Nov 22,
    /// 2026 — the Actions options "all look the same"). Colours
    /// follow the amount rule (Models.fixedAmountColorHex + the
    /// export chart colours): money-in kinds deep blue, charity
    /// primary blue, transfer/payment muted grey, fund charge fund
    /// amber, regular kinds ink. A hex string (not a Color) so the
    /// mapping is unit-testable.
    static func kindStyle(_ kind: TransactionKind) -> (colorHex: String, icon: String) {
        switch kind {
        case .charge: return (DesignTokens.inkHex, "bag")
        case .income: return (DesignTokens.deepHex, "arrow.down.left")
        case .charity: return (DesignTokens.primaryHex, "heart")
        case .refund: return (DesignTokens.deepHex, "arrow.uturn.left")
        case .transfer: return (DesignTokens.mutedHex, "arrow.left.arrow.right")
        case .fundCharge: return (DesignTokens.fundHex, "banknote")
        case .payment: return (DesignTokens.mutedHex, "creditcard")
        case .cashback: return (DesignTokens.deepHex, "dollarsign.circle")
        case .other: return (DesignTokens.mutedHex, "ellipsis.circle")
        }
    }

    /// The one-line plain-English subline for a reclassify kind.
    /// Static + pure so it is unit-testable alongside the label.
    static func kindSubline(_ kind: TransactionKind) -> String {
        switch kind {
        case .charge: return "Count it as a purchase"
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

    /// Build 64 (F-33/F-41): split the old Group 1 into its
    /// sections — "How It Counts" (the math-driving reclassifies
    /// and Link), "Savings" (Cover with Savings + Add to
    /// Savings — the two fund actions no longer sit adjacent
    /// inside one seven-row group), and the rest (Exclude,
    /// Delete). The split is by action id, so the per-kind tables
    /// in `actionGroups` stay as they were; only the grouping
    /// changes. A group with a label renders a small section
    /// header above its rows (see `listContent`); the counting
    /// group keeps the flat build-63 look with no header.
    /// Rename Merchant (F-41) arrives here already appended to
    /// `group1` — it moved out of "More" into Group 1, at the end
    /// of the counting rows, because it is the most-used typing
    /// action and was the hardest to reach.
    private func grouped(_ group1: [SheetAction], more: [SheetAction]) -> [ActionGroup] {
        let savingsIds: Set<ActionKind> = [.extraFund, .designateSavings]
        let restIds: Set<ActionKind> = [.exclude, .delete]
        let counting = group1.filter { !savingsIds.contains($0.id) && !restIds.contains($0.id) }
        let savings = group1.filter { savingsIds.contains($0.id) }
        let rest = group1.filter { restIds.contains($0.id) }
        var groups: [ActionGroup] = []
        if !counting.isEmpty { groups.append(ActionGroup(label: nil, actions: counting)) }
        if !savings.isEmpty { groups.append(ActionGroup(label: "Savings", actions: savings)) }
        if !rest.isEmpty { groups.append(ActionGroup(label: nil, actions: rest)) }
        if !more.isEmpty { groups.append(ActionGroup(label: nil, actions: more, isMore: true)) }
        return groups
    }

    private var actionGroups: [ActionGroup] {
        let isVerified = transaction.state == .verified
        let charitySubline = isVerified
            ? "Counts it as a charity gift, out of weekly spending"
            : "Counts as a charity gift once it posts"
        let deleteSubline = transaction.source == .manual
            ? "Permanently deletes this hand-entered row"
            : "Moves this row to the Trash"
        let rename = SheetAction(id: .rename, label: "Rename Merchant", subline: "Rename this merchant everywhere, and remember it", colorHex: DesignTokens.mutedHex, icon: "pencil")
        let delete = SheetAction(id: .delete, label: "Delete", subline: deleteSubline, colorHex: DesignTokens.errorTextHex, icon: "trash")
        let exclude = SheetAction(id: .exclude, label: "Exclude", subline: "Takes it out of the spending math", colorHex: DesignTokens.mutedHex, icon: "eye.slash")
        // Build 54 (owner, Nov 21, 2026): the owner renamed "Pay
        // from Savings" to "Cover with Savings" (build 53 used
        // "Pay from Savings" for audit item 8). "Cover with
        // Savings" spends from the fund for this purchase; "Add
        // to Savings" moves this money into the fund — the two
        // labels say their direction, so they no longer read as
        // the same thing. Build 62: the two fund actions share
        // one muted slate family so they read as a pair.
        let extraFund = SheetAction(id: .extraFund, label: "Cover with \(extraFundName)", subline: "Use the fund to cover this charge", colorHex: DesignTokens.actionSlateHex, icon: "shield")
        let charity = SheetAction(id: .charity, label: charityName, subline: charitySubline, colorHex: DesignTokens.primaryHex, icon: "heart")
        let designate = SheetAction(id: .designateSavings, label: "Add to \(extraFundName)", subline: "Counts this amount toward the fund", colorHex: DesignTokens.actionSlateHex, icon: "plus.circle")

        /// A reclassify row for a kind — nil when it IS the row's
        /// current kind (reclassifying to what it already is is
        /// not an action). Tzedaka is never a reclassify row here:
        /// it is the top Tzedaka action.
        func reclassify(_ kind: TransactionKind) -> SheetAction? {
            guard kind != transaction.kind else { return nil }
            let style = Self.kindStyle(kind)
            return SheetAction(id: .reclassifyTo(kind), label: Self.kindLabel(kind, charityName: charityName), subline: Self.kindSubline(kind), colorHex: style.colorHex, icon: style.icon)
        }

        /// The row's CURRENT category (build 54): always first in
        /// Group 1, marked with a checkmark, not a Button — it is
        /// the current state, not an action. Purchase is in the
        /// list now (it was not, even though the charge IS a
        /// purchase). For a kind that lives in Group 2 (Transfer,
        /// Refund, Fund Charge, Payment, Cashback), the current
        /// category is prepended to Group 1 marked — the current
        /// category is always visible, never hidden in "More".
        func current() -> SheetAction {
            let style = Self.kindStyle(transaction.kind)
            switch transaction.kind {
            case .charity:
                return SheetAction(id: .charity, label: charityName, subline: "Current category", colorHex: style.colorHex, icon: style.icon, isCurrent: true)
            default:
                return SheetAction(id: .reclassifyTo(transaction.kind), label: Self.kindLabel(transaction.kind, charityName: charityName), subline: "Current category", colorHex: style.colorHex, icon: style.icon, isCurrent: true)
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
                let group2 = [reclassify(.transfer), reclassify(.refund), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 }
                return grouped(group1 + [rename], more: group2)
            }
            // Owner rule (Nov 13, 2026): no disabled rows — a
            // member simply does not see the Tzedaka action.
            return grouped([current(), extraFund], more: [])
        case .refund:
            guard isAdmin else { return [] }
            let linkSubline = transaction.originalPurchaseId != nil
                ? "Change or remove the purchase this refund is linked to"
                : "Link this refund to the purchase it came from"
            let link = SheetAction(id: .linkRefund, label: "Link to Purchase", subline: linkSubline, colorHex: DesignTokens.deepHex, icon: "link")
            var group1 = [current(), link]
            group1 += [reclassify(.charge), reclassify(.income)].compactMap { $0 }
            if canDesignateAsSavings { group1.append(designate) }
            group1.append(exclude)
            group1.append(delete)
            let group2 = [reclassify(.transfer), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 }
            return grouped(group1 + [rename], more: group2)
        case .transfer, .payment, .cashback, .fundCharge:
            guard isAdmin else { return [] }
            var group1 = [current()]
            group1 += [reclassify(.charge), reclassify(.income)].compactMap { $0 }
            if canDesignateAsSavings { group1.append(designate) }
            group1.append(exclude)
            group1.append(delete)
            let group2 = [reclassify(.transfer), reclassify(.refund), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 }
            return grouped(group1 + [rename], more: group2)
        case .charity:
            // Build 62 (owner, Nov 22, 2026 — "Why shouldn't you
            // be able to reclassify it?"): a charity row can be
            // reclassified to Purchase or Income, and excluded —
            // so a misclassified gift can be corrected in-app
            // instead of only deleted. The backend already
            // reverses the charity accrual on reclassify (trigger
            // v4), and the reclassify flow requires a reason
            // (audited), so no server change is needed.
            guard isAdmin else { return [] }
            var group1 = [current()]
            group1 += [reclassify(.charge), reclassify(.income)].compactMap { $0 }
            group1.append(exclude)
            group1.append(delete)
            return grouped(group1 + [rename], more: [])
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
            let group2 = [reclassify(.transfer), reclassify(.refund), reclassify(.fundCharge), reclassify(.payment), reclassify(.cashback)].compactMap { $0 }
            return grouped(group1 + [rename], more: group2)
        }
    }

    var showsNonCountingNote: Bool {
        switch transaction.kind {
        case .transfer, .payment, .cashback, .fundCharge: return true
        default: return false
        }
    }

    // MARK: - Body

    /// Build 64 (C-4): the merchant + amount summary header —
    /// the same line the list flow shows above its rows — at the
    /// top of EVERY sub-flow, so a short confirm never ends at
    /// 1/4 screen with no context for what it is confirming.
    private var summaryHeader: some View {
        let amount = TransactionFormatting.amountDisplay(for: transaction)
        return VStack(alignment: .leading, spacing: 0) {
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
                .padding(.top, 12)
        }
    }

    /// Build 64 (C-4): fitted detents, not a full-screen cover
    /// (reverses the Nov 17 full-screen rule, build 43 item 17).
    /// The list is a half-screen sheet; the confirm flows are
    /// small (.fraction(0.45), draggable to .medium when the
    /// content needs it); the taller flows (Rename, Link) get
    /// .medium. iPad: the 600pt frame (regular size class) keeps
    /// the sheet a centred card, never full-width or awkwardly
    /// small — the build-42 detents were the version that did
    /// not work well, so the width is pinned and the heights
    /// come from the detents, not from the content.
    private var sheetDetents: Set<PresentationDetent> {
        switch flow {
        case .list, .rename, .linkCandidates:
            return [.medium, .large]
        default:
            return [.fraction(0.45), .medium]
        }
    }

    public var body: some View {
        // No NavigationStack root (owner, Nov 14, 2026): the
        // toolbar "Cancel" truncated to "Ca…", and a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty (build 24) — a single
        // "Use Extra Fund" row in a full-height card. A plain VStack
        // root + SheetHeader keeps the content at the top of the
        // sheet (build 43, item 18 — the trailing Spacer below
        // is what top-anchors it). On the list flow the
        // header shows X (dismiss); on a sub-flow it shows a back
        // chevron (return to the list).
        // Build 64 (C-4): fitted detents (see `sheetDetents`) —
        // the cover is a sheet now, not full-screen.
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
        // the short flows — in the fitted sheet (build 64, C-4)
        // it does the same against the detent height, so short
        // confirms sit at the top of the sheet instead of
        // centring themselves in it.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 64 (C-4): the fitted detents for this flow — the
        // modifier lives on the presented content, so the sheet
        // resizes when the flow changes (list → confirm).
        .presentationDetents(sheetDetents)
        .presentationDragIndicator(.visible)
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
        // Build 64 (F-29): was "Designate as …" — the old name;
        // the action is "Add to …", so the confirm title matches it.
        case .savingsConfirm: return "Add to \(extraFundName)"
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
                    // Build 63 (Lean): a flat list — no group
                    // header — and Delete sits last below its own
                    // rule, in its own block, so the destructive
                    // action reads as separate from the rest. The
                    // actions themselves are unchanged — only the
                    // look changes.
                    // Build 64 (F-33): the one exception is the
                    // "Savings" section — it carries a small muted
                    // header, so the two fund actions read as
                    // their own group instead of a continuation of
                    // the counting rows. The counting group keeps
                    // the flat build-63 look with no header.
                    if let label = group.label {
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                    let mainActions = group.actions.filter { $0.id != .delete }
                    let deleteActions = group.actions.filter { $0.id == .delete }
                    VStack(spacing: 0) {
                        ForEach(mainActions) { action in
                            actionRow(action)
                            if action.id != mainActions.last?.id {
                                Divider()
                            }
                        }
                        if !deleteActions.isEmpty {
                            Divider()
                                .padding(.top, 12)
                            ForEach(deleteActions) { action in
                                actionRow(action)
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
    /// Build 62: every row carries a tinted icon chip (the
    /// action's colour at low opacity, icon in the full colour)
    /// and the label renders in the action's colour, so each
    /// option is easy to spot at a glance; the subline and
    /// chevron stay muted. Delete's colour is error red.
    @ViewBuilder
    private func actionRow(_ action: SheetAction) -> some View {
        /// The tinted icon chip (build 62): a small squarish chip
        /// in the action's colour at low opacity, icon in the full
        /// colour — rows are distinguishable by icon as well as
        /// colour.
        let chip = ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(hex: action.colorHex).opacity(0.12))
                .frame(width: 30, height: 30)
            Image(systemName: action.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: action.colorHex))
        }
        if action.isCurrent {
            HStack(spacing: 12) {
                chip
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: action.colorHex))
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
                HStack(spacing: 12) {
                    chip
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.label)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(hex: action.colorHex))
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
            // Tzedaka action), but the guard keeps the
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
            summaryHeader
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
            summaryHeader
            Text(savingsMessage)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            TwoButtonRow {
                // Build 64 (F-29): same rename as the confirm
                // title above — the button must read "Add to …",
                // not the old "Designate as …".
                Button("Add to \(extraFundName)") {
                    Task {
                        isWorking = true
                        guard let fundsViewModel = makeFundsViewModel() else {
                            isWorking = false
                            viewModel.showAlert(title: "Could Not Add to \(extraFundName)", message: "Could not load your household. Try again.")
                            return
                        }
                        let message = await fundsViewModel.designateTransactionAsSavings(transaction)
                        isWorking = false
                        if let message {
                            viewModel.showConfirmation(message, kind: .success)
                            onDismiss()
                        } else {
                            viewModel.showAlert(
                                title: fundsViewModel.alertTitle ?? "Could Not Add to \(extraFundName)",
                                message: fundsViewModel.alertMessage ?? "Could not add this transaction to the fund. Try again."
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
            summaryHeader
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
            summaryHeader
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
            summaryHeader
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
            summaryHeader
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
            summaryHeader
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
            summaryHeader
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
            summaryHeader
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
