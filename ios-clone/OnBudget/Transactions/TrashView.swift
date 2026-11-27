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
/// `pre_exclusion_state` and clears excluded/reason/snapshot.
///
/// Build 44, change 2 — bank-dropped rows: a row with NO snapshot
/// (`preExclusionState == nil`, e.g. Plaid reported it in
/// removed[]) does NOT call `restore_transaction` at all. Tapping
/// it sets `viewModel.pendingForceRestoreTransaction` and this view
/// shows a CENTRED .alert (the Delete Account / Clear Debt
/// precedent — a confirmationDialog is a popover anchored at the
/// top of the screen on iPad): "The bank dropped this transaction.
/// Restore it anyway?" Confirm calls `force_restore_transaction`,
/// which restores the row as verified with source='restored'.
/// Empty: "Trash is empty."
///
/// The single TrashView (integration, Nov 9, 2026): the Funds copy
/// is deleted — CLONE_SPEC §11 links Trash only from Transactions,
/// and no Funds call site ever existed. Reached from the
/// Transactions "Trash" link only (admin-only, hidden when empty —
/// no count is shown).
///
/// BANK-DROPPED ROWS (build 44, change 2): merged duplicates were
/// excluded without recording `pre_exclusion_state`, so restoring
/// one always refused until the server fix landed. The fix is the
/// force-restore path in this branch (`force_restore_transaction`
/// + the confirm popup above) — a no-snapshot row now restores as
/// verified with source='restored' instead of refusing.
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
    /// Build 68 (item 14): the Trash explainer behind the ⓘ.
    @State private var showingAboutInfo = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: TransactionsViewModel, onBack: @escaping () -> Void, errorMessage: String? = nil) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.errorMessage = errorMessage
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
                                                ? nil : viewModel.institutionBySuffix[transaction.cardSuffix],
                                            // Build 53 (owner, Nov 21, 2026): only a
                                            // bank row (transfer / card payment) keeps
                                            // the bank logo — an unmapped merchant gets
                                            // the monogram, never the bank logo.
                                            isBankRow: transaction.kind == .transfer || transaction.kind == .payment
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
                                        // Build 112 (owner, Nov 27, 2026): Restore
                                        // is a quiet blue TEXT button with no
                                        // fill — the solid blue pill on every
                                        // row was loud and repetitive ("super
                                        // ugly"). Same primary blue text, same
                                        // position, same action; the padding
                                        // keeps its tap area generous and the
                                        // row itself is still the button.
                                        Text("Restore")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(DesignTokens.primary)
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 12)
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
                // Build 44, change 2 — force-restore confirm: a
                // CENTRED .alert (not a confirmationDialog — on iPad
                // that is a popover anchored at the top of the screen;
                // same fix as the Clear Debt confirm). Attached to
                // this VStack, not to the ScrollView — the ScrollView
                // already carries the failure .alert below, and two
                // .alert modifiers on one view fight. The exact
                // owner-directed message; Confirm force-restores the
                // row as verified, source='restored'.
                .appConfirmDialog(item: $viewModel.pendingForceRestoreTransaction) { transaction in
                    AppConfirmDialog.Config(
                        title: "Restore Transaction",
                        message: "The bank dropped this transaction. Restore it anyway?",
                        primaryTitle: "Restore Anyway",
                        onPrimary: {
                            Task {
                                _ = await viewModel.forceRestore(transaction)
                            }
                        }
                    )
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            // Nov 27, 2026 (owner — Trash ⓘ clipped on iPad):
            // the nav bar must be laid out by the system at full
            // cover width. The old `.frame(width: 600)` on the
            // NavigationStack itself squeezed the bar on iPad, so
            // the trailing ⓘ was pushed to — and clipped by — the
            // screen edge (the same pattern already truncated the
            // calendar cover's Back button to "←…"). The width cap
            // now lives on the content only (below), and this stack
            // stays full-width, so the ⓘ sits inside the safe area
            // with the standard trailing inset.
            .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton(action: onBack)
                }
                // Build 68 (item 14): the Trash explainer lives
                // behind this blue ⓘ, not as an inline line at the
                // top of the list.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAboutInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Trash")
                }
            }
            .alert("Trash", isPresented: $showingAboutInfo) {
                Button("OK") {}
            } message: {
                Text("Bank rows you deleted live here. The admin can bring them back.")
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
        // iPad width (Nov 27, 2026 — owner: the 600pt column read
        // as a thin strip on iPad mini): the content now uses the
        // app's standard tab width — a centred 900pt column on the
        // regular size class, full-width on iPhone — via
        // `.mainContentWidth` on the ScrollView above, matching
        // the Transactions tab. The old fixed 600pt frame sat on
        // the NavigationStack itself, which also squeezed the nav
        // bar and clipped the trailing ⓘ; the stack itself is now
        // full-width and only the content is capped.
        // Build 70, item 2 (owner, Nov 24, 2026): swipe-right
        // dismisses the cover, matching the top-left Back button.
        // (The Trash cover has no SheetHeader, so the gesture does
        // not come from there.)
        .sheetSwipeBack()
    }
}
