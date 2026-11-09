import SwiftUI
import OnBudgetKit

// MARK: - Trash (spec §11)
//
// Own page: heading Trash + Back (→ Transactions; swipe-right also
// returns to Transactions). Subtext: "Bank rows you deleted live here.
// The admin can bring them back."
//
// Lists excluded rows only, from the same load as Transactions. Each
// row: icon, merchant, amount, day + card, and a Restore button
// (primary, small). Restore → `restore_transaction`, returning the row
// to its stored prior state (verified / provisional / reversed). A NULL
// prior-state snapshot refuses with "cannot restore: no prior state
// recorded", surfaced verbatim.
//
// The Trash link on Transactions is admin-only and hidden when the
// count is 0; this page itself renders from the same `all` list.

public struct TrashView: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let onBack: () -> Void

    public init(viewModel: FundsViewModel, onBack: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DesignTokens.mid)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Transactions")
                FundsHeading("Trash")
                FundsMuted(text: "Bank rows you deleted live here. The admin can bring them back.")
                if let error = viewModel.transactionsError {
                    FundsErrorBox(error)
                } else if viewModel.trashRows.isEmpty {
                    FundsMuted(text: "Trash is empty.")
                } else {
                    FundsCard {
                        VStack(spacing: 0) {
                            ForEach(viewModel.trashRows) { row in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(TitleCase.apply(to: row.merchant.lowercased()))
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(DesignTokens.ink)
                                        Text("\(MoneyFormat.fmtLong(row.date)) · \(row.cardSuffix == "0000" ? "Cash / no card" : "••\(row.cardSuffix)")")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(hex: "#6b7280"))
                                    }
                                    Spacer()
                                    Text(MoneyFormat.formatCents(row.amountCents))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(DesignTokens.ink)
                                    FundsSmallPrimaryButton("Restore", isBusy: viewModel.busyAction == "restore-\(row.id.uuidString)") {
                                        Task { await viewModel.restoreTransaction(row) }
                                    }
                                }
                                .padding(.vertical, 8)
                                if row.id != viewModel.trashRows.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(DesignTokens.background)
        .navigationBarBackButtonHidden(true)
    }
}
