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
    /// Build 99 (loading audit, owner Nov 26, 2026): false until
    /// this push's `refreshReview` returns — the view model
    /// starts with empty arrays, so the page must not render
    /// ReviewView at once (it would paint the "All clear" card
    /// and then swap in the real sections once the fetch lands).
    @State private var reviewReady = false

    public init(viewModel: FundsViewModel, onBack: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
    }

    /// Build 68 (owner, Nov 23, 2026 — the Toiremorg $1 pair):
    /// translate the server's cryptic resolve refusal into plain
    /// language. The server's repoint logic expects the kept row
    /// to be a live purchase, so merging a charity+charity pair
    /// refuses with "repoint target is not a live purchase" — a
    /// sentence that says nothing to the owner. Until the server
    /// follow-up lands (the resolve path must accept a charity
    /// pair — flagged in the build 68 report), the owner sees
    /// this instead, and nothing is changed by the failed tap.
    /// Any other message passes through untouched.
    private var friendlyAlertMessage: String {
        let message = viewModel.alertMessage ?? ""
        if message.localizedCaseInsensitiveContains("repoint target is not a live purchase") {
            return "These two charity gifts can't be merged yet — the merge needs a small server update first. Nothing was changed."
        }
        return message
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
                // Build 99 (loading audit): skeletons until this
                // push's review fetch has resolved — see
                // `reviewReady` above.
                if reviewReady {
                    ReviewView(viewModel: viewModel)
                } else {
                    ReviewPageSkeleton()
                }
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
            Text(friendlyAlertMessage)
        }
        .task {
            await viewModel.refreshReview()
            reviewReady = true
        }
    }
}

/// Build 99 (loading audit): skeleton of the Review page while
/// `refreshReview` runs — four section cards shaped like the
/// loaded sections (white card, icon + title header, content
/// lines; the first card carries the duplicate comparison box
/// with its two buttons), so the page never first paints the
/// "All clear" card and then swaps in the real sections once
/// the fetch lands.
private struct ReviewPageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        SkeletonBlock(width: 16, height: 16, cornerRadius: 8)
                        SkeletonBlock(width: 150, height: 17)
                        Spacer()
                        SkeletonBlock(width: 24, height: 14)
                    }
                    if index == 0 {
                        // The duplicate comparison card: a grey
                        // inner box with two text lines and two
                        // button-sized blocks.
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 220, height: 14)
                            SkeletonBlock(width: 180, height: 14)
                            HStack(spacing: 12) {
                                SkeletonBlock(width: 110, height: 32, cornerRadius: 8)
                                SkeletonBlock(width: 90, height: 32, cornerRadius: 8)
                            }
                        }
                        .padding(12)
                        .background(Color(hex: "#f9fafb"))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        SkeletonBlock(width: 240, height: 14)
                        SkeletonBlock(width: 190, height: 14)
                    }
                }
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
            }
        }
        .accessibilityLabel("Loading review")
    }
}
