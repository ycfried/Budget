import SwiftUI
import OnBudgetKit

/// One Transactions row + its detail panel (CLONE_SPEC §7.2).
///
/// Row line 1: icon, Title-Cased merchant (bold), signed amount,
/// chevron (rotates when open). Line 2: state pill + source pill +
/// "`Today` · ••1005" meta. Row accessible name: merchant + amount +
/// day + status + "— show detail".
///
/// Detail panel, in order: bold merchant + amount + kind label;
/// labelled rows Week (Sun–Sat range) / Date (long) / Status / Card /
/// Source (+ Refund link row for refunds); then the Actions button —
/// one small tertiary button, only when the viewer has any action on
/// that row. No explainer sentences: the facts already say it.
/// The whole row is the tap target — the chevron is only a visual
/// hint. Expand/collapse uses the shared ExpandAnimation.
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        TransactionIconView(
                            merchant: transaction.merchant,
                            institutionName: institutionName
                        )
                        Text(TransactionFormatting.displayMerchant(transaction.merchant))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DesignTokens.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(TransactionFormatting.formatCents(transaction.amountCents))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                transaction.amountCents < 0 ? DesignTokens.errorText : DesignTokens.ink
                            )
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "#6b7280"))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .animation(ExpandAnimation.animation, value: isExpanded)
                    }
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
                    .padding(.leading, 50)
                }
                // The whole card is the tap target — the padding is
                // inside the button, so taps on the card edge toggle
                // too; the chevron is only a visual hint.
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(TransactionFormatting.displayMerchant(transaction.merchant)) \(TransactionFormatting.formatCents(transaction.amountCents)) \(TransactionFormatting.displayDay(transaction.date)) \(TransactionFormatting.stateWord(for: transaction)) — show detail"
            )
            .accessibilityIdentifier("transaction.row")

            if isExpanded {
                TransactionDetailView(
                    transaction: transaction,
                    hasActions: hasActions,
                    onActions: onActions
                )
                .padding(.top, 12)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(ExpandAnimation.transition)
            }
        }
        .animation(ExpandAnimation.animation, value: isExpanded)
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
            Text(
                "\(TransactionFormatting.displayMerchant(transaction.merchant)) — \(TransactionFormatting.formatCents(transaction.amountCents)) (\(TransactionFormatting.kindLabel(for: transaction)))"
            )
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(DesignTokens.ink)

            VStack(spacing: 6) {
                detailRow(label: "Week", value: "\(TransactionFormatting.weekRangeOf(transaction.date)) (Sun–Sat)")
                detailRow(label: "Date", value: TransactionFormatting.fmtLong(transaction.date))
                detailRow(label: "Status", value: TransactionFormatting.stateWord(for: transaction))
                detailRow(label: "Card", value: TransactionFormatting.cardLabel(for: transaction))
                detailRow(label: "Source", value: TransactionFormatting.sourceLabel(for: transaction.source))
                if transaction.kind == .refund {
                    detailRow(
                        label: "Refund link",
                        value: transaction.originalPurchaseId != nil
                            ? "Linked to a purchase"
                            : "Not linked to a purchase yet"
                    )
                }
            }

            if hasActions {
                HStack {
                    Button("Actions", action: onActions)
                        .buttonStyle(SmallTertiaryButtonStyle())
                    Spacer()
                }
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
}
