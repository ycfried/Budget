import SwiftUI
import OnBudgetKit

/// One Transactions row + its detail panel (CLONE_SPEC §7.2).
///
/// The text column is exactly as tall as the 40pt icon, split
/// into two halves (owner, Nov 14, 2026): the merchant name sits
/// centred on the icon's top half, the badges line centred on its
/// bottom half. Row line 1: icon, ALL-CAPS merchant (bold) —
/// ALWAYS the merchant name, even for transfers (build 50, owner
/// Nov 20, 2026: the transfer title hid the merchant) — signed
/// amount, chevron (rotates when open). Line 2 (collapsed only):
/// plain grey state text (+ a "Transfer" badge for transfers) +
/// "`Today` · ••1005" meta — the source is NOT shown here (build
/// 42, owner Nov 17, 2026: source shows only in the expanded
/// detail); the badges hide while the card is open, because the
/// detail already says all of it (owner, Nov 12, 2026). Row
/// accessible name: merchant + amount + day + status + "— show
/// detail".
///
/// Detail panel: labelled rows Date (long) / Account / Status
/// (plain grey text) / Source (plain grey text) (+ Refund Link row
/// for refunds; + Amount row for refunded purchases, whose
/// collapsed amount is struck through; + Type row, the bottom row
/// — the kind in the Actions sheet's labels, build 65). Then the Actions button —
/// one small tertiary button, only when the viewer has any action
/// on that row. The bold merchant — amount header is gone (owner,
/// Nov 13, 2026): the collapsed row already says both, so
/// repeating them here said the merchant and the price twice. No
/// explainer sentences: the facts already say it.
/// The whole row is the tap target — the chevron is only a visual
/// hint. Expand/collapse is instant, no animation at all (owner
/// decision, Nov 15, 2026 — build 34: the motion itself was ugly,
/// not just the fade).
public struct TransactionRowView: View {
    let transaction: Transaction
    /// Institution name for the card suffix, when known.
    let institutionName: String?
    let isExpanded: Bool
    let hasActions: Bool
    /// The active search query (build 41, owner Nov 17, 2026):
    /// the matched part of the merchant name and the amount is
    /// highlighted, so the user can see why the row matched.
    /// Empty when no search is active — the row renders unchanged.
    let searchQuery: String
    /// Build 52 (week mode): this charge has a linked refund —
    /// its amount nets to $0 in the header total. Build 53 (owner,
    /// Nov 21, 2026): the row shows the amount struck through and
    /// the status reads just "Refunded" (replacing
    /// "Pending"/"Posted"); the original amount stays visible in
    /// the expanded detail.
    let isRefunded: Bool
    let onToggle: () -> Void
    let onActions: () -> Void

    public init(
        transaction: Transaction,
        institutionName: String? = nil,
        isExpanded: Bool,
        hasActions: Bool,
        searchQuery: String = "",
        isRefunded: Bool = false,
        onToggle: @escaping () -> Void,
        onActions: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.institutionName = institutionName
        self.isExpanded = isExpanded
        self.hasActions = hasActions
        self.searchQuery = searchQuery
        self.isRefunded = isRefunded
        self.onToggle = onToggle
        self.onActions = onActions
    }

    /// The row's amount under the one shared kind rule
    /// (TransactionFormatting.amountDisplay): money in deep blue
    /// with "+", charity primary blue, transfers / payments /
    /// trashed rows grey, spending ink — never green or red
    /// (owner, Nov 17, 2026 — build 42).
    private var amount: (text: String, color: Color) {
        TransactionFormatting.amountDisplay(for: transaction)
    }

    /// The icon's edge — the text column is exactly this tall, split
    /// into two equal halves (owner, Nov 14, 2026): the merchant
    /// name sits centred on the icon's top half, the badges line
    /// centred on its bottom half, so the two lines are spread
    /// across the icon instead of the name hugging the top with the
    /// badges crammed just under it.
    private let iconSize: CGFloat = 40

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    TransactionIconView(
                        merchant: transaction.merchant,
                        institutionName: institutionName,
                        // Build 53 (owner, Nov 21, 2026): only a
                        // bank row (transfer / card payment) keeps
                        // the bank logo — an unmapped merchant gets
                        // the monogram, never the bank logo.
                        isBankRow: transaction.kind == .transfer || transaction.kind == .payment,
                        size: iconSize
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        // Top half: merchant + amount + chevron.
                        // The title is ALWAYS the merchant name
                        // (build 50, owner Nov 20, 2026) — a
                        // transfer used to show "Transfer to" here
                        // and hide the merchant — in ALL CAPS
                        // (build 65: `rowTitle` uppercases via the
                        // shared `displayMerchant` helper, so the
                        // collapsed row, its search highlight, and
                        // its accessibility label all agree). The
                        // kind is a badge on the bottom line; the
                        // direction + other account live in the
                        // detail panel.
                        HStack(spacing: 10) {
                            TransactionFormatting.highlightedSearchText(
                                TransactionFormatting.rowTitle(for: transaction),
                                query: searchQuery
                            )
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DesignTokens.ink)
                                .lineLimit(1)
                            Spacer()
                            TransactionFormatting.highlightedSearchText(amount.text, query: searchQuery)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(amount.color)
                                // Build 53 (owner, Nov 21, 2026): a
                                // refunded purchase shows its amount
                                // struck through — the week's total
                                // already nets it to $0, and the
                                // struck-through amount still reads
                                // as the original charge.
                                .strikethrough(isRefunded)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .frame(height: iconSize / 2)
                        // Bottom half: state + date meta, collapsed
                        // only — when open, the detail below says
                        // all of it (owner, Nov 12, 2026). Badges
                        // are plain grey text, no pills, no tint
                        // (build 42, owner Nov 17, 2026 — Version A);
                        // the source is NOT shown here — it shows
                        // only in the expanded detail view.
                        if !isExpanded {
                            HStack(spacing: 8) {
                                // Transfer badge (build 50, owner
                                // Nov 20, 2026): the merchant stays
                                // on the top line, and the kind
                                // reads here as plain grey text, no
                                // pill (build 42, Version A) —
                                // never a bare "Transfer to" in
                                // place of the merchant name.
                                if transaction.kind == .transfer {
                                    Text("Transfer")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DesignTokens.muted)
                                }
                                // Build 53 (owner, Nov 21, 2026): the
                                // status IS "Refunded" — it replaces
                                // "Pending"/"Posted", it does not sit
                                // next to it ("Refunded Pending" read
                                // as neither one clearly). Visible
                                // style: primary blue semibold, not
                                // small grey text.
                                if isRefunded {
                                    Text("Refunded")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DesignTokens.primary)
                                } else {
                                    Text(TransactionFormatting.stateWord(for: transaction))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DesignTokens.muted)
                                }
                                Spacer()
                                // Date + card sit at the row's trailing edge —
                                // a fixed column that never moves with the
                                // badge widths (owner, Nov 11, 2026).
                                Text("\(TransactionFormatting.displayDay(transaction.date)) · \(TransactionFormatting.cardLabel(for: transaction))")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(hex: "#6b7280"))
                                    .lineLimit(1)
                            }
                            .frame(height: iconSize / 2)
                        }
                    }
                }
                // The whole card is the tap target — the padding is
                // inside the button, so taps on the card edge toggle
                // too; the chevron is only a visual hint. When
                // expanded the detail follows directly underneath,
                // so the header keeps only a small bottom gap
                // (owner, Nov 15, 2026): the full 14pt plus the
                // detail's own top padding left a dead blank line
                // between the header and the Date row.
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, isExpanded ? 4 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(TransactionFormatting.rowTitle(for: transaction)) \(amount.text) \(TransactionFormatting.displayDay(transaction.date)) \(isRefunded ? "Refunded" : TransactionFormatting.stateWord(for: transaction)) — show detail"
            )
            .accessibilityIdentifier("transaction.row")

            if isExpanded {
                TransactionDetailView(
                    transaction: transaction,
                    hasActions: hasActions,
                    isRefunded: isRefunded,
                    onActions: onActions
                )
                .padding(.top, 2)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        // No per-row card: the list is ONE continuous list — the
        // container in TransactionsView carries the single white card
        // and the dividers between rows (owner, Nov 11, 2026).
    }
}

public struct TransactionDetailView: View {
    let transaction: Transaction
    let hasActions: Bool
    /// Build 53 (week mode): this charge has a linked refund —
    /// the Status row reads "Refunded" (replacing
    /// "Pending"/"Posted") and the detail restores the plain
    /// original amount, since the collapsed amount is struck
    /// through.
    let isRefunded: Bool
    let onActions: () -> Void

    public init(transaction: Transaction, hasActions: Bool, isRefunded: Bool = false, onActions: @escaping () -> Void) {
        self.transaction = transaction
        self.hasActions = hasActions
        self.isRefunded = isRefunded
        self.onActions = onActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 6) {
                // No Week row: the Date already says it (owner,
                // Nov 12, 2026). Status and Source render as plain
                // grey text (build 42, owner Nov 17, 2026 —
                // Version A): no pills, no tint, no background.
                // The source lives ONLY here — never on the
                // collapsed row.
                detailRow(label: "Date", value: TransactionFormatting.fmtLong(transaction.date))
                detailRow(label: "Account", value: TransactionFormatting.cardLabel(for: transaction))
                // Build 53 (owner, Nov 21, 2026): the status IS
                // "Refunded" here too — it replaces
                // "Pending"/"Posted", in the same visible blue as
                // the collapsed row.
                detailRow(label: "Status") {
                    if isRefunded {
                        Text("Refunded")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                    } else {
                        Text(TransactionFormatting.stateWord(for: transaction))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
                // Build 53 (owner, Nov 21, 2026): the collapsed
                // amount is struck through for a refunded purchase,
                // so the expanded detail restores the plain original
                // amount. The Nov 13 rule (no amount in the detail
                // — the collapsed row already says it) does not
                // apply here, because a struck-through amount is
                // not a readable value.
                if isRefunded {
                    detailRow(label: "Amount", value: TransactionFormatting.amountDisplay(for: transaction).text)
                }
                detailRow(label: "Source") {
                    Text(TransactionFormatting.sourceLabel(for: transaction.source))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DesignTokens.muted)
                }
                if transaction.kind == .refund {
                    detailRow(
                        label: "Refund Link",
                        value: transaction.originalPurchaseId != nil
                            ? "Linked to a purchase"
                            : "Not linked to a purchase yet"
                    )
                }
                // Type row (build 65, owner Nov 23, 2026): the
                // bottom row, below Source — the kind, in the
                // Actions sheet's own labels (`typeLabel`:
                // Purchase / Refund / Fund Charge / Transfer /
                // Payment / Cashback / Income / Tzedaka / Other).
                // For transfers the value keeps the old transfer
                // detail ("Transfer to ••5939" when the other
                // account's digits are derivable, else bare
                // "Transfer" — never a dangling "Transfer to"
                // with no destination, build 50, owner Nov 20,
                // 2026): that used to be the only Type row, and
                // the direction is part of what the detail says.
                // One Type row only — never two.
                detailRow(
                    label: "Type",
                    value: transaction.kind == .transfer
                        ? TransactionFormatting.transferDetailText(for: transaction)
                        : TransactionFormatting.typeLabel(for: transaction)
                )
            }

            // Build 52 (owner, Nov 20, 2026): a SOLID BLUE button,
            // not an outline — the outline "looks ugly". A single
            // full-width button in its row, so this does not
            // conflict with the no-two-adjacent-buttons-same-colour
            // rule.
            if hasActions {
                Button("Actions", action: onActions)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Label + custom value view (Status / Source render their
    /// plain grey text here — build 42, owner Nov 17, 2026).
    private func detailRow<Content: View>(label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            value()
        }
    }
}
