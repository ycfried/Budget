import SwiftUI
import OnBudgetKit

/// Trash (CLONE_SPEC §11): own page, heading "Trash" + "← Back"
/// (→ Transactions). Subtext: "Bank rows you deleted live here. The
/// admin can bring them back."
/// Lists excluded rows only, from the same load as Transactions. Each
/// row: icon, merchant, amount, day + card, and a Restore button
/// (primary, small). The WHOLE row is the tap target — tapping
/// anywhere on a row restores it, the same action as the Restore
/// button; the button is only the visual hint. Restore →
/// `restore_transaction`, which restores the stored
/// `pre_exclusion_state` and clears excluded/reason/snapshot. Refuses with an alert when no prior state was recorded
/// ("cannot restore: no prior state recorded" — surfaced verbatim).
/// Empty: "Trash is empty."
///
/// The single TrashView (integration, Nov 9, 2026): the Funds copy
/// is deleted — CLONE_SPEC §11 links Trash only from Transactions,
/// and no Funds call site ever existed. Reached from the
/// Transactions "Trash" link only (admin-only, hidden when empty —
/// no count is shown).
///
/// KNOWN LIVE DEFECT (not worked around): merged duplicates were
/// excluded without recording `pre_exclusion_state`, so restoring
/// one always refuses until the server fix lands (branch-only fix
/// `fix-live-defects-dedupe-held`, awaiting owner approval). When the
/// fix lands, restore works with no clone change.
public struct TrashView: View {
    @Bindable var viewModel: TransactionsViewModel
    let onBack: () -> Void
    /// Load error from the shared list load, when the caller has one
    /// (merged from the deleted Funds copy, which surfaced its view
    /// model's `transactionsError` here; the Transactions screen
    /// surfaces load failure on the list itself, so this stays nil
    /// there). Shown above the list when non-nil.
    let errorMessage: String?

    @State private var restoringId: UUID?

    public init(viewModel: TransactionsViewModel, onBack: @escaping () -> Void, errorMessage: String? = nil) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.errorMessage = errorMessage
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bank rows you deleted live here. The admin can bring them back.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.errorText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(DesignTokens.errorBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignTokens.errorBorder, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if viewModel.trashTransactions.isEmpty {
                        Text("Trash is empty.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: "#6b7280"))
                            .padding(.top, 8)
                    } else {
                        // ONE continuous list, like the main
                        // Transactions list (T-P2-14) — a single white
                        // card with a divider between rows, not a
                        // card per row.
                        VStack(spacing: 0) {
                            ForEach(viewModel.trashTransactions) { transaction in
                                Button {
                                    Task {
                                        restoringId = transaction.id
                                        _ = await viewModel.restore(transaction)
                                        restoringId = nil
                                    }
                                } label: {
                                    // The amount uses the one shared
                                    // kind rule (amountDisplay):
                                    // money in green with "+",
                                    // charity blue, regular kinds
                                    // ink — never red.
                                    let display = TransactionFormatting.amountDisplay(for: transaction)
                                    HStack(spacing: 10) {
                                        TransactionIconView(
                                            merchant: transaction.merchant,
                                            institutionName: transaction.cardSuffix == "0000"
                                                ? nil : viewModel.institutionBySuffix[transaction.cardSuffix]
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(TransactionFormatting.displayMerchant(transaction.merchant))
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(DesignTokens.ink)
                                                .lineLimit(1)
                                            Text("\(TransactionFormatting.displayDay(transaction.date)) · \(TransactionFormatting.cardLabel(for: transaction))")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Color(hex: "#6b7280"))
                                        }
                                        Spacer()
                                        Text(display.text)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(display.color)
                                        // The Restore pill is the visual hint for
                                        // the whole-row action (same look as
                                        // SmallPrimaryButtonStyle); the row
                                        // itself is the button.
                                        Text("Restore")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 12)
                                            .background(DesignTokens.primary)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .padding(14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(restoringId == transaction.id)
                                if transaction.id != viewModel.trashTransactions.last?.id {
                                    Divider()
                                        .padding(.leading, 64)
                                }
                            }
                        }
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                    }
                }
                .padding()
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton(action: onBack)
                }
            }
            // T-P2-1: the failure alert lives on this sheet, not on
            // the Transactions parent — a restore failure surfaced
            // nowhere while this sheet was up.
            .alert(
                viewModel.alertTitle ?? "Something Went Wrong",
                isPresented: $viewModel.showAlert,
                presenting: viewModel.alertMessage
            ) { _ in
                Button("Close", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }
}
