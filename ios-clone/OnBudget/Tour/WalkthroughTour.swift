// STAGE — In-app walkthrough (build 48, owner Nov 19, 2026).
//
// The first-run guided tour: one element at a time, arrows pointing,
// one short plain line each. About 11 steps, ~90 seconds to 2 minutes
// — long enough that nobody is lost, short enough that nobody loses
// patience. Shows once on first entry to Home after sign-up AND the
// household is set (join-by-code or create-your-own, either path),
// skippable at any point, re-playable from Settings ("Take the Tour").
//
// The v2 plan (owner-delegated priorities, Nov 19, 2026 — the full
// list is the general ideal, not a checklist):
//   1. Home — the one number (Spending), the star.
//   2. Home — Charity card, tap to open (10% automatic).
//   3. Charity rules — change the rate, or turn it off.
//   4. + Add.
//   5. Transactions — the list.
//   6. Transactions — open a row (see it, change it if it's wrong).
//   7. Transactions — search and filters.
//   8. Funds — the tab.
//   9. Funds — Savings card (your cushion).
//   10. Funds — Overspent (Past) card (pay it down).
//   11. Close — "That's the app — you're set."
// Cut (recorded in the plan file): sign-up / household / rules /
// members (onboarding guides those), profile & settings
// (discoverable), bank & Gmail (explained on the Connect screen),
// reorder / hide-show (power feature), charity deep-dive steps
// (folded into + Add and the open card), savings/debt full detail
// (one step each — the pattern is the same).
//
// How it works: each target view reports its frame in the shell's
// "tourSpace" coordinate space via `.tourAnchor(_:)`; the shell
// draws a dim overlay with a cutout around the current target, a
// border, and a tooltip card with the one line + Skip / Next (or
// Done). The tour drives `appState.selectedTab` as it moves between
// screens, and opens the Charity card / expands the first row where
// the step needs it. The v2 lines are name-agnostic, so no fund-name
// substitution is needed — but any line added later must read the
// household's CURRENT display names from `appState.fundNames`,
// never hardcode defaults.

import SwiftUI
import OnBudgetKit

/// The walkthrough's anchor points — the real UI elements the tour
/// points at. Views report their frames via `.tourAnchor(_:)`.
public enum TourAnchor: String, CaseIterable {
    /// Home — the Spending hero (the one number).
    case spendingHero
    /// Home — the Tzedaka card.
    case charityCard
    /// Funds — the Charity rate editor (change the rate, turn it off).
    case charityRules
    /// Transactions — the + Add button.
    case addButton
    /// Transactions — the list.
    case transactionsList
    /// Transactions — the first row.
    case firstRow
    /// Transactions — the search field + Search button.
    case searchBar
    /// Funds — the Savings card.
    case savingsCard
    /// Funds — the Overspent (Past) card.
    case debtCard
}

/// One step of the walkthrough (v2 plan, 11 steps). The `line` is the
/// one short plain line the tooltip shows; `tab` is the screen the
/// step lives on; `anchor` is the element the arrow points at (nil
/// for the Funds-tab step, whose target is the tab bar item itself,
/// computed from the container geometry, and for Close, which has
/// no target).
public enum TourStep: Int, CaseIterable {
    case spendingNumber
    case charityCard
    case charityRules
    case addButton
    case transactionsList
    case openRow
    case searchFilters
    case fundsTab
    case savingsCard
    case debtCard
    case close

    public var line: String {
        switch self {
        case .spendingNumber:
            return "This is what you have left to spend this week."
        case .charityCard:
            return "This is set aside for giving — 10% of what comes in, automatically."
        case .charityRules:
            return "You can change the rate, or turn it off."
        case .addButton:
            return "Tap here to add something you paid for."
        case .transactionsList:
            return "Everything you spent, all in one place."
        case .openRow:
            return "Tap any row to see it — and change it if it's wrong."
        case .searchFilters:
            return "Find anything fast."
        case .fundsTab:
            return "Your savings and giving, all in one place."
        case .savingsCard:
            return "Your cushion — add to it, or take from it."
        case .debtCard:
            return "What you overspent before — pay it down here."
        case .close:
            return "That's the app — you're set."
        }
    }

    public var tab: AppTab? {
        switch self {
        case .spendingNumber, .charityCard:
            return .home
        case .charityRules:
            return .funds
        case .addButton, .transactionsList, .openRow, .searchFilters, .fundsTab:
            return .transactions
        case .savingsCard, .debtCard:
            return .funds
        case .close:
            return .home
        }
    }

    public var anchor: TourAnchor? {
        switch self {
        case .spendingNumber:
            return .spendingHero
        case .charityCard:
            return .charityCard
        case .charityRules:
            return .charityRules
        case .addButton:
            return .addButton
        case .transactionsList:
            return .transactionsList
        case .openRow:
            return .firstRow
        case .searchFilters:
            return .searchBar
        case .fundsTab, .close:
            return nil
        case .savingsCard:
            return .savingsCard
        case .debtCard:
            return .debtCard
        }
    }
}

/// The walkthrough's live state, owned by `AppViewModel` (`appState.tour`)
/// so Home, Transactions, Funds, the shell and Settings all read the
/// same tour. Frames are reported by the anchor views; the overlay
/// reads them. The "seen" flag is per user per household (UserDefaults),
/// so a new family member on their own device gets the tour once, and
/// a new household gets it once too.
@MainActor
public final class TourState: ObservableObject {
    @Published public var isActive = false
    @Published public var stepIndex = 0
    /// Anchor key → frame in the shell's "tourSpace" coordinate space.
    @Published public var frames: [TourAnchor: CGRect] = [:]

    public var steps: [TourStep] { TourStep.allCases }

    public var currentStep: TourStep {
        steps[min(max(stepIndex, 0), steps.count - 1)]
    }

    public var stepNumber: Int { stepIndex + 1 }

    public func start() {
        stepIndex = 0
        isActive = true
    }

    public func end() {
        isActive = false
        stepIndex = 0
    }

    public func setFrame(_ anchor: TourAnchor, _ frame: CGRect) {
        // Ignore degenerate frames (a view reporting before layout).
        guard frame.width > 0, frame.height > 0 else { return }
        if frames[anchor] != frame {
            frames[anchor] = frame
        }
    }

    public func frame(for anchor: TourAnchor) -> CGRect? {
        frames[anchor]
    }

    private func seenKey(_ key: String) -> String { "tour.seen.\(key)" }

    public func hasSeen(key: String) -> Bool {
        UserDefaults.standard.bool(forKey: seenKey(key))
    }

    public func markSeen(key: String) {
        UserDefaults.standard.set(true, forKey: seenKey(key))
    }
}

/// Reports a view's frame (in the shell's "tourSpace" coordinate
/// space) to the tour state, so the overlay can point at it. A nil
/// anchor is a no-op — the call site stays unconditional and the
/// anchor is chosen by the section.
public struct TourAnchorModifier: ViewModifier {
    public let anchor: TourAnchor?
    @ObservedObject public var tour: TourState

    public init(anchor: TourAnchor?, tour: TourState) {
        self.anchor = anchor
        self.tour = tour
    }

    public func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        if let anchor {
                            tour.setFrame(anchor, proxy.frame(in: .named("tourSpace")))
                        }
                    }
                    .onChange(of: proxy.frame(in: .named("tourSpace"))) { _, new in
                        if let anchor {
                            tour.setFrame(anchor, new)
                        }
                    }
            }
        )
    }
}

public extension View {
    /// Attach a walkthrough anchor to a view (no-op when nil).
    func tourAnchor(_ anchor: TourAnchor?, tour: TourState) -> some View {
        modifier(TourAnchorModifier(anchor: anchor, tour: tour))
    }
}

// MARK: - Overlay

/// The dim + cutout: the whole screen dimmed, with a rounded-rect
/// hole around the target frame (even-odd fill), so the target reads
/// as the one lit thing on the screen.
private struct TourDimCutout: View {
    let frame: CGRect
    let containerSize: CGSize

    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: containerSize))
            path.addRoundedRect(
                in: frame.insetBy(dx: -6, dy: -6),
                cornerSize: CGSize(width: 12, height: 12)
            )
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
    }
}

/// The arrow: a small triangle pointing at the target, sitting on the
/// tooltip card's edge. Drawn as a Path so it is a real shape, not a
/// text glyph (the "⌄" text chevron is what made the Funds Activity
/// control read like a Word document).
private struct TourArrow: View {
    /// True when the card sits BELOW the target (arrow points up).
    let pointsUp: Bool

    var body: some View {
        Path { path in
            if pointsUp {
                path.move(to: CGPoint(x: 0, y: 10))
                path.addLine(to: CGPoint(x: 8, y: 0))
                path.addLine(to: CGPoint(x: 16, y: 10))
            } else {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 8, y: 10))
                path.addLine(to: CGPoint(x: 16, y: 0))
            }
            path.closeSubpath()
        }
        .fill(Color.white)
        .frame(width: 16, height: 10)
    }
}

/// The walkthrough overlay: dim + cutout + border around the current
/// target, and the tooltip card with the one line, the step count,
/// and Skip / Next (Done on the last step). The card sits below the
/// target when it fits there, else above it, with the arrow pointing
/// at the target. When a step has no target yet (the new tab is still
/// laying out) or no target at all (Close), the card sits at the
/// bottom of the screen with no cutout.
public struct TourOverlayView: View {
    @ObservedObject var tour: TourState
    @ObservedObject var appState: AppViewModel
    var transactionsViewModel: TransactionsViewModel?

    /// The tooltip card's measured height (140 is the first-frame
    /// estimate; the GeometryReader below corrects it after layout).
    @State private var cardHeight: CGFloat = 140

    public init(tour: TourState, appState: AppViewModel, transactionsViewModel: TransactionsViewModel? = nil) {
        self.tour = tour
        self.appState = appState
        self.transactionsViewModel = transactionsViewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let step = tour.currentStep
            let target = targetFrame(for: step, containerSize: size, tabBarHeight: tabBarHeight(proxy: proxy))
            let cardTop = cardTopY(containerSize: size, target: target, tabBarHeight: tabBarHeight(proxy: proxy))
            ZStack(alignment: .topLeading) {
                if let target {
                    TourDimCutout(frame: target, containerSize: size)
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: target.width + 12, height: target.height + 12)
                        .position(x: target.midX, y: target.midY)
                } else {
                    Color.black.opacity(0.55)
                }
                // Arrow on the card's edge, pointing at the target.
                if let target {
                    let pointsUp = cardTop > target.maxY
                    let arrowX = min(max(target.midX, 36), size.width - 36)
                    TourArrow(pointsUp: pointsUp)
                        .position(
                            x: arrowX,
                            y: pointsUp ? cardTop - 5 : cardTop + cardHeight + 5
                        )
                }
                tooltipCard(step: step)
                    .frame(width: size.width - 32)
                    .position(x: size.width / 2, y: cardTop + cardHeight / 2)
            }
        }
        .ignoresSafeArea()
    }

    /// The tab bar's height: 49pt + the bottom safe area.
    private func tabBarHeight(proxy: GeometryProxy) -> CGFloat {
        49 + proxy.safeAreaInsets.bottom
    }

    /// The current step's target frame: the reported anchor frame,
    /// or (for the Funds-tab step) the Funds tab bar item, computed
    /// from the container — three equal tabs, Funds is the third.
    /// Nil for Close (no target) and while a new tab is still
    /// laying out (the anchor has not reported yet).
    private func targetFrame(for step: TourStep, containerSize: CGSize, tabBarHeight: CGFloat) -> CGRect? {
        if let anchor = step.anchor {
            return tour.frame(for: anchor)
        }
        if step == .fundsTab {
            let tabWidth = containerSize.width / 3
            return CGRect(
                x: tabWidth * 2,
                y: containerSize.height - tabBarHeight,
                width: tabWidth,
                height: tabBarHeight
            )
        }
        return nil
    }

    /// The tooltip card's top edge: below the target when it fits
    /// there, else above the target, else clamped to the screen
    /// (above the tab bar). No target → the bottom of the screen.
    private func cardTopY(containerSize: CGSize, target: CGRect?, tabBarHeight: CGFloat) -> CGFloat {
        let topSafe: CGFloat = 8
        let bottomLimit = containerSize.height - tabBarHeight - 8
        guard let target else {
            return max(topSafe, bottomLimit - cardHeight)
        }
        let belowTop = target.maxY + 16
        if belowTop + cardHeight <= bottomLimit {
            return belowTop
        }
        let aboveTop = target.minY - 16 - cardHeight
        if aboveTop >= topSafe {
            return aboveTop
        }
        return max(topSafe, bottomLimit - cardHeight)
    }

    /// The tooltip card: the one line, the step count, Skip + Next
    /// (Done on the last step). White, squarish rounded edges
    /// (cornerRadius 14, the app's card treatment), shadow so it
    /// lifts off the dim.
    private func tooltipCard(step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Step \(tour.stepNumber) of \(tour.steps.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.muted)
                Spacer()
            }
            Text(step.line)
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Skip") { skip() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                Spacer()
                Button(step == .close ? "Done" : "Next") { next() }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 110)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 4)
        .background(
            GeometryReader { cardProxy in
                Color.clear
                    .onAppear { cardHeight = cardProxy.size.height }
                    .onChange(of: cardProxy.size.height) { _, new in
                        cardHeight = new
                    }
            }
        )
        .accessibilityIdentifier("tour.tooltip")
    }

    // MARK: - Advancing

    /// Move to a step: switch to its tab (keeping the Charity card
    /// open across the switch into the rules step), run the step's
    /// action (open the Charity card, expand the first row), and
    /// collapse the first row again when leaving its step.
    private func goToStep(_ index: Int) {
        tour.stepIndex = index
        let step = tour.steps[index]
        if let tab = step.tab, appState.selectedTab != tab {
            if step == .charityRules {
                // Keep the Charity card open across this switch —
                // the tab-change reset would collapse it otherwise.
                appState.suppressNextTabReset = true
            }
            appState.selectedTab = tab
        }
        switch step {
        case .charityRules:
            appState.expandedCard = .charity
        case .openRow:
            if let first = transactionsViewModel?.shownTransactions.first {
                transactionsViewModel?.expandedTransactionId = first.id
            }
        default:
            break
        }
        if step != .openRow {
            transactionsViewModel?.expandedTransactionId = nil
        }
    }

    private func next() {
        let nextIndex = tour.stepIndex + 1
        if nextIndex >= tour.steps.count {
            finish()
        } else {
            goToStep(nextIndex)
        }
    }

    /// Skip and Done both end the tour and count as seen — the user
    /// chose not to take it (Skip) or finished it (Done); it must
    /// not auto-show again on the next Home entry. Re-playable from
    /// Settings ("Take the Tour"). Returns to Home, clean.
    private func skip() {
        finish()
    }

    private func finish() {
        tour.markSeen(key: appState.tourKey)
        transactionsViewModel?.expandedTransactionId = nil
        tour.end()
        if appState.selectedTab != .home {
            appState.selectedTab = .home
        }
    }
}
