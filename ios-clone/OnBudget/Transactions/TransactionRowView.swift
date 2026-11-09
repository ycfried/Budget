import SwiftUI
import OnBudgetKit

/// One Transactions row + its detail panel (CLONE_SPEC §7.2).
///
/// Row line 1: icon, Title-Cased merchant (bold), signed amount,
/// chevron (rotates when open). Line 2: state pill + source pill +
/// "`Today` · ••1005" meta. Row accessible name: merchant + amount +
/// day + status + "— show detail".
///
/// Detail panel, in order: bold merchant + amount + kind label; the
/// counting sentence; labelled rows Week (Sun–Sat range) / Date (long)
/// / Status / Card / Source (+ Refund link row for refunds); the
/// email-alert line for `amex_alert` rows; then the Actions button —
/// one small tertiary button, only when the viewer has any action on
/// that row.
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
                            institutionName: institutionName,
                            merchant: transaction.merchant
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
                    }
                    HStack(spacing: 8) {
                        StatePill(transaction)
                        SourcePill(transaction)
                        Text("\(TransactionFormatting.displayDay(transaction.date)) · \(TransactionFormatting.cardLabel(for: transaction))")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                    .padding(.leading, 50)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(TransactionFormatting.displayMerchant(transaction.merchant)) \(TransactionFormatting.formatCents(transaction.amountCents)) \(TransactionFormatting.displayDay(transaction.date)) \(TransactionFormatting.stateWord(for: transaction)) — show detail"
            )

            if isExpanded {
                TransactionDetailView(
                    transaction: transaction,
                    hasActions: hasActions,
                    onActions: onActions
                )
                .padding(.top, 12)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
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

            Text(TransactionFormatting.countingSentence(for: transaction))
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))

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

            if let emailLine = TransactionFormatting.emailAlertLine(for: transaction) {
                Text(emailLine)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
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
