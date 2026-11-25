// STAGE — In-app walkthrough (build 48, owner Nov 19, 2026).
//
// The first-run guided tour: one element at a time, arrows pointing,
// one short plain line each. About 11 steps, ~90 seconds to 2 minutes
// — long enough that nobody is lost, short enough that nobody loses
// patience. Shows once on first entry to Home after sign-up AND the
// household is set (invite-only — join-by-code),
// skippable at any point, re-playable from Settings ("Replay Tutorial").
//
// The v2 plan (owner-delegated priorities, Nov 19, 2026 — the full
// list is the general ideal, not a checklist):
//   1. Home — the one number (Spending), the star.
//   2. Home — Charity card, tap to open (10% automatic).
//   3. Charity rules — change the rate (0% pauses giving).
//   4. + Add.
//   5. Transactions — the list.
//   6. Transactions — open a row (see it, change it if it's wrong).
//   7. Transactions — search and filters.
//   8. Funds — the tab.
//   9. Funds — Savings card (your cushion).
//   10. Funds — Debt card (pay it down).
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
// border, and a tooltip card with the one line + Back / Skip tour
// / Next (or Done). The tour drives `appState.selectedTab` as it moves between
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
    /// Funds — the Charity rate editor (change the rate; 0%
    /// pauses giving — there is no Off switch, 0% IS off).
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
    /// Funds — the Debt card (renamed from "Overspent (Past)"
    /// in build 70).
    case debtCard
    /// The shell's PageSelectControl (Home / Transactions /
    /// Funds) — build 65, the single page select, rendered by
    /// the shell above the tab content. The Funds-tab step
    /// points at it; it used to point at the bottom tab bar's
    /// Funds item, which no longer exists (no TabView).
    case pageSelect
}

/// One step of the walkthrough (v2 plan, 11 steps). The `line` is the
/// one short plain line the tooltip shows; `tab` is the screen the
/// step lives on; `anchor` is the element the arrow points at (nil
/// only for Close, which has no target; the Funds-tab step points
/// at the shell's PageSelectControl via `.pageSelect`).
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
            return "You can change the rate — set it to 0% to pause giving."
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
            return "Your debt — pay it down here."
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
        case .fundsTab:
            return .pageSelect
        case .close:
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
/// reads them. The "seen" flag is per household per device
/// (UserDefaults), so a new family member on their own device gets
/// the tour once, and a new household gets it once too.
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

    /// The walkthrough's "seen" flag (build 50, Nov 20, 2026 —
    /// tutorial one-time fix): a STABLE per-household, per-device
    /// key via `TourSeen` (OnBudgetKit). The old key folded in the
    /// session user UUID, which can be nil during a session-store
    /// swap, so the flag was read back under a different key and
    /// the tour showed on every open. The household id is set
    /// once at boot and never changes; UserDefaults is per device.
    public func hasSeen(householdId: UUID?, userId: UUID? = nil) -> Bool {
        TourSeen.hasSeen(householdId: householdId, userId: userId)
    }

    public func markSeen(householdId: UUID?, userId: UUID? = nil) {
        TourSeen.markSeen(householdId: householdId, userId: userId)
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
        // Build 68 (item 6): a LIGHTER dim (0.32, was 0.55) so
        // the dimmed background fits the light, airy theme — the
        // page behind the tour still reads through it.
        .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))
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
/// and Back / Skip tour / Next (Done on the last step). The card sits below the
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
            let target = targetFrame(for: step, containerSize: size)
            let cardTop = cardTopY(containerSize: size, target: target, bottomInset: bottomInset(proxy: proxy))
            // Build 54 (owner, Nov 21, 2026): the tooltip card is
            // capped at 600pt and centred — on iPad the uncapped
            // `size.width - 32` made a ~788pt (portrait) / ~1148pt
            // (landscape) banner, far wider than the content it
            // points at and wider than the app's own iPad sheet
            // convention (600pt). On iPhone the cap does not bite
            // (358pt on a 390pt phone).
            let cardWidth = min(size.width - 32, 600)
            let cardMinX = size.width / 2 - cardWidth / 2
            let cardMaxX = size.width / 2 + cardWidth / 2
            ZStack(alignment: .topLeading) {
                if let target {
                    TourDimCutout(frame: target, containerSize: size)
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: target.width + 12, height: target.height + 12)
                        .position(x: target.midX, y: target.midY)
                } else {
                    // Build 68 (item 6): same lighter dim as the
                    // cutout above (0.32, was 0.55).
                    Color.black.opacity(0.32)
                }
                // Arrow on the card's edge, pointing at the target.
                if let target {
                    let pointsUp = cardTop > target.maxY
                    // Build 54: clamp the arrow to the CARD's span
                    // as well as to the screen — with the card
                    // capped at 600pt and centred, a target near
                    // the edge of the 900pt content column can put
                    // the arrow outside the card (e.g. iPad
                    // landscape, target midX ~200, card spans
                    // ~290–890). The 20pt margin keeps the 16pt
                    // arrow off the card's edge. On iPhone the
                    // card-span clamp equals the old screen clamp
                    // ([36, size.width - 36]).
                    let arrowX = min(max(target.midX, cardMinX + 20), cardMaxX - 20)
                    TourArrow(pointsUp: pointsUp)
                        .position(
                            x: arrowX,
                            y: pointsUp ? cardTop - 5 : cardTop + cardHeight + 5
                        )
                }
                tooltipCard(step: step)
                    .frame(width: cardWidth)
                    .position(x: size.width / 2, y: cardTop + cardHeight / 2)
            }
        }
        .ignoresSafeArea()
    }

    /// The bottom inset below the tab content: the bottom safe
    /// area ONLY (build 74 — the old `tabBarHeight()` returned
    /// 49 + safe area for a bottom tab bar that no longer exists;
    /// build 65 replaced the TabView with the shell's
    /// PageSelectControl at the TOP, so the Close card sat 49pt
    /// too high, floating above the bottom with a dead gap, and
    /// every near-bottom target lost 49pt of room below it).
    private func bottomInset(proxy: GeometryProxy) -> CGFloat {
        proxy.safeAreaInsets.bottom
    }

    /// The current step's target frame: the reported anchor frame.
    /// Nil for Close (no target) and while a new tab is still
    /// laying out (the anchor has not reported yet). Build 65: the
    /// Funds-tab step used to compute the bottom tab bar's Funds
    /// item from the container geometry — that branch is gone with
    /// the tab bar; the step now points at the shell's
    /// PageSelectControl via the `.pageSelect` anchor instead.
    private func targetFrame(for step: TourStep, containerSize: CGSize) -> CGRect? {
        if let anchor = step.anchor {
            return tour.frame(for: anchor)
        }
        return nil
    }

    /// The tooltip card's top edge: below the target when it fits
    /// there, else above the target, else clamped to the screen
    /// (above the bottom safe area). No target → the bottom of the
    /// screen.
    private func cardTopY(containerSize: CGSize, target: CGRect?, bottomInset: CGFloat) -> CGFloat {
        let topSafe: CGFloat = 8
        let bottomLimit = containerSize.height - bottomInset - 8
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

    /// The tooltip card: the one line, the step count, Back /
    /// Skip tour / Next (Done on the last step). White, squarish rounded edges
    /// (cornerRadius 14, the app's card treatment), shadow so it
    /// lifts off the dim.
    private func tooltipCard(step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Step \(tour.stepNumber) of \(tour.steps.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.muted)
                Spacer()
                // Build 74 (owner, Nov 24, 2026 — "the skip/x
                // should work"): an explicit × close button beside
                // the step count, the same dismiss as "Skip tour"
                // below. There was no × before — only the quiet
                // "Skip tour" text link — so a user looking for
                // the close affordance had nothing to tap.
                Button { skip() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(DesignTokens.muted)
                .accessibilityLabel("Close tour")
                .accessibilityIdentifier("tour.closeButton")
            }
            Text(step.line)
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                // Build 64 (F-9): one "Skip tour" (quiet text
                // link — muted, not blue) + "Next"; the two
                // near-identical blue Skips are gone (a mis-tap
                // on "Skip" used to kill the whole tour), and a
                // Back chevron returns to the previous step.
                // "Skip this tip" is dropped outright — it did
                // the same thing as "Next" (advance one step).
                if tour.stepIndex > 0 {
                    Button { back() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(DesignTokens.primary)
                    .accessibilityLabel("Back")
                }
                Button("Skip tour") { skip() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.muted)
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
        // Build 54: skip the open-row step when there are no
        // transactions — a brand-new household with zero rows has
        // no first row, so the anchor never reports and the step
        // would point at nothing, telling the user to "Tap any
        // row" when there is no row. Advance straight to the next
        // step instead of inventing a fake row. Only .openRow is
        // skippable, so this recurses at most once.
        let step = tour.steps[index]
        if step == .openRow, transactionsViewModel?.shownTransactions.first == nil {
            let nextIndex = index + 1
            if nextIndex >= tour.steps.count {
                finish()
            } else {
                goToStep(nextIndex)
            }
            return
        }
        tour.stepIndex = index
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

    /// Build 64 (F-9): back one step. Steps over the open-row
    /// step when there are no transactions — `goToStep` would
    /// skip forward past it again, landing back where we
    /// started. No-op on the first step (no Back button there).
    private func back() {
        var target = tour.stepIndex - 1
        while target >= 0 {
            if tour.steps[target] == .openRow,
               transactionsViewModel?.shownTransactions.first == nil {
                target -= 1
                continue
            }
            break
        }
        guard target >= 0 else { return }
        goToStep(target)
    }

    /// Skip and Done both end the tour and count as seen — the user
    /// chose not to take it (Skip) or finished it (Done); it must
    /// not auto-show again on the next Home entry. Re-playable from
    /// Settings ("Replay Tutorial"). Returns to Home, clean.
    private func skip() {
        finish()
    }

    private func finish() {
        appState.markTourSeen()
        transactionsViewModel?.expandedTransactionId = nil
        tour.end()
        if appState.selectedTab != .home {
            appState.selectedTab = .home
        }
    }
}

/// Build 74: scrolls the current tour step's anchor into view —
/// the tour's targets (the Funds rate editor, the Savings/Debt
/// cards) can sit below the fold, where the cutout would point at
/// nothing visible. Called from the tab's ScrollViewReader on
/// step change; a no-op unless the tour is running on this tab.
/// The anchored views carry the matching `.id(TourAnchor)` so
/// `scrollTo` can find them. @MainActor: TourState is
/// main-actor-isolated, so its properties cannot be read from a
/// nonisolated free function (compile error, build 74 fix-up).
@MainActor
public func scrollTourAnchorIntoView(_ proxy: ScrollViewProxy, tour: TourState, tab: AppTab) {
    guard tour.isActive, tour.currentStep.tab == tab, let anchor = tour.currentStep.anchor else { return }
    withAnimation(.none) { proxy.scrollTo(anchor, anchor: .center) }
}
