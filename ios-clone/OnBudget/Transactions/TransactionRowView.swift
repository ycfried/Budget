import SwiftUI
import OnBudgetKit

/// One Transactions row + its detail panel (CLONE_SPEC §7.2).
///
/// The text column is exactly as tall as the 40pt icon, split
/// into two halves (owner, Nov 14, 2026): the merchant name sits
/// centred on the icon's top half, the badges line centred on its
/// bottom half. Row line 1: icon, Title-Cased merchant (bold),
/// signed amount, chevron (rotates when open). Line 2 (collapsed
/// only): state pill + source pill + "`Today` · ••1005" meta — the
/// badges hide while the card is open, because the detail already
/// says all of it (owner, Nov 12, 2026). Row accessible name:
/// merchant + amount + day + status + "— show detail".
///
/// Detail panel: labelled rows Date (long) / Account / Status
/// (pill) / Source (pill) (+ Refund Link row for refunds); then
/// the Actions button — one small tertiary button, only when the
/// viewer has any action on that row. The bold merchant — amount
/// header is gone (owner, Nov 13, 2026): the collapsed row
/// already says both, so repeating them here said the merchant
/// and the price twice. No explainer sentences: the facts
/// already say it.
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
    let onToggle: () -> Void
    let onActions: () -> Void

    public init(
        transaction: Transaction,
        institutionName: String? = nil,
        isExpanded: Bool,
        hasActions: Bool,
        onToggle: @escaping () -> Void,
        onActions: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.institutionName = institutionName
        self.isExpanded = isExpanded
        self.hasActions = hasActions
        self.onToggle = onToggle
        self.onActions = onActions
    }

    /// The row's amount under the one shared kind rule
    /// (TransactionFormatting.amountDisplay): money in green with
    /// "+", charity blue, regular kinds ink — never red.
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
                        size: iconSize
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        // Top half: merchant + amount + chevron.
                        HStack(spacing: 10) {
                            Text(TransactionFormatting.displayMerchant(transaction.merchant))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DesignTokens.ink)
                                .lineLimit(1)
                            Spacer()
                            Text(amount.text)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(amount.color)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .frame(height: iconSize / 2)
                        // Bottom half: badges + date meta, collapsed
                        // only — when open, the detail below says
                        // all of it (owner, Nov 12, 2026).
                        if !isExpanded {
                            HStack(spacing: 8) {
                                StatePill(transaction)
                                SourcePill(transaction)
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
                "\(TransactionFormatting.displayMerchant(transaction.merchant)) \(amount.text) \(TransactionFormatting.displayDay(transaction.date)) \(TransactionFormatting.stateWord(for: transaction)) — show detail"
            )
            .accessibilityIdentifier("transaction.row")

            if isExpanded {
                TransactionDetailView(
                    transaction: transaction,
                    hasActions: hasActions,
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
    let onActions: () -> Void

    public init(transaction: Transaction, hasActions: Bool, onActions: @escaping () -> Void) {
        self.transaction = transaction
        self.hasActions = hasActions
        self.onActions = onActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 6) {
                // No Week row: the Date already says it (owner,
                // Nov 12, 2026). Status and Source render as the
                // same pills the collapsed header shows.
                detailRow(label: "Date", value: TransactionFormatting.fmtLong(transaction.date))
                detailRow(label: "Account", value: TransactionFormatting.cardLabel(for: transaction))
                detailRow(label: "Status") { StatePill(transaction) }
                detailRow(label: "Source") { SourcePill(transaction) }
                if transaction.kind == .refund {
                    detailRow(
                        label: "Refund Link",
                        value: transaction.originalPurchaseId != nil
                            ? "Linked to a purchase"
                            : "Not linked to a purchase yet"
                    )
                }
            }

            // Bottom-centre, in the brand-blue outline treatment
            // (owner, Nov 14, 2026): the small grey pill at the
            // bottom-left got lost — it now spans the detail width
            // in white with a #2f6bff border and text, clearly a
            // button.
            if hasActions {
                Button("Actions", action: onActions)
                    .buttonStyle(OutlineButtonStyle())
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

    /// Label + pill value (Status / Source reuse the header pills).
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
