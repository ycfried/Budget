import SwiftUI
import OnBudgetKit

/// The dedicated Review page (build 30). Review moved off the
/// Funds page: the Transactions tab gets a "Review" button with a
/// count badge, and this page shows the held refunds, possible
/// duplicates, resolved duplicates and refund-link suggestions.
///
/// The view model is the shell-owned FundsViewModel instance shared
/// with the Transactions tab (so the badge count stays live); this
/// page only reads its review properties. Admin-only — the button
/// that reaches here is admin-gated.
public struct ReviewPageView: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let onBack: () -> Void

    public init(viewModel: FundsViewModel, onBack: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Review")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                // Build 52 (owner, Nov 20, 2026): the explainer
                // paragraph at the top is gone — it was a wall of
                // text above an already long page. What it said
                // lives as one short muted line at the bottom.
                ReviewView(viewModel: viewModel)
                FundsMuted("Nothing here deletes a transaction.")
            }
            .padding()
        }
        .background(DesignTokens.background)
        .fundsToast($viewModel.toast)
        .alert(
            viewModel.alertTitle ?? "Could Not Complete",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil; viewModel.alertTitle = nil } }
            )
        ) {
            Button(TitleCase.apply(to: "Close"), role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .task {
            await viewModel.refreshReview()
        }
    }
}
