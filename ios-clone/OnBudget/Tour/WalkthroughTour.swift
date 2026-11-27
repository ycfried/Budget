// STAGE — In-app walkthrough (build 48, owner Nov 19, 2026;
// refreshed Nov 26, 2026 — owner: "update walkthrough for new
// users to be perfect and up to date with sizing, pages, pop ups,
// style etc."; expanded Nov 26, 2026 — owner: a THOROUGH tour
// that actually USES the allowance and the Calculator, in the
// owner's own order: the 3 main pages first, then connecting the
// bank (Plaid, email optional), then the allowance, then Tzedaka,
// then everything else — with a full debt section and the Savings
// system explained as saving toward something specific, not a
// general savings account).
//
// The first-run guided tour: one element at a time, arrows pointing,
// one short plain line each. 39 steps, ~5 minutes — long enough
// that nobody is lost, short enough that nobody loses patience.
// Shows once on first entry to Home after sign-up AND the
// household is set (invite-only — join-by-code),
// skippable at any point, re-playable from Settings ("Replay Tutorial").
//
// The v3 plan (owner's order, Nov 26, 2026):
//   Welcome — the core idea: the app suggests, from your own
//     rules, what to spend, what to put aside, and what to give —
//     and tracks it all in one place.
//   Section 1 — the 3 main pages: Home, Transactions, Funds.
//   Section 2 — connect: the bank through Plaid (Settings >
//     Connections), email alerts as an optional second layer.
//   Section 3 — the allowance: the Weekly Allowance sheet (the
//     week's numbers, the week close, Adjust / Set New) and the
//     Calculator (income, household + lifestyle, recurring
//     expenses, giving rate, the suggestion — which never applies
//     itself; Set New Allowance is how a suggestion is used).
//   Section 4 — Tzedaka: 10% of what comes in, the Available
//     figure on the card, the rate, the actions.
//   Section 5 — everything else: + Add (purchase / donation /
//     record income), open a row (and tag a charge as a recurring
//     expense from its Actions), search + filters, Needs Review,
//     Export, merchant names + rules, Savings (saving toward
//     something specific, or covering a week that goes over),
//     Debt (what carried debt is, the weekly payment rule, paying
//     it down / clearing it).
//   Close — "That's the app — you're set."
// Cut (recorded in the plan file): sign-up / household / rules /
// members (onboarding guides those), profile & settings
// (discoverable — except Connections, which the tour opens),
// bank & Gmail beyond the Connect steps (explained on the
// Connect screen), reorder / hide-show (power feature).
//
// How it works: each target view reports its frame in the
// "tourSpace" coordinate space via `.tourAnchor(_:)`; the shell
// draws a dim overlay with a cutout around the current target, a
// border, and a tooltip card with the one line + Back / Skip tour
// / Next (or Done). The tour drives `appState.selectedTab` as it moves between
// screens, and opens the Charity card / expands the first row where
// the step needs it. The lines are name-agnostic, so no fund-name
// substitution is needed — but any line added later must read the
// household's CURRENT display names from `appState.fundNames`,
// never hardcode defaults.
//
// Sheets (Nov 26, 2026 — the tour walks THROUGH them, not just
// at their entry buttons): a step's `sheet` says which sheet it
// lives in (nil for shell steps). `goToStep` drives
// `appState.tourSheet` (and `showSettings` for the Settings
// steps); each presenting view observes it and opens/closes its
// sheet only while the tour is active, so manual sheet use is
// never fought. Each sheet/cover renders its own
// `TourOverlayView` inside itself, gated on the current step
// belonging to that sheet, with that sheet's own "tourSpace" —
// and the SHELL overlay is gated OFF for sheet steps
// (`currentStep.sheet == nil`, AppShellView): a medium-detent /
// fitted sheet leaves the presenting view visible above it, so
// an ungated shell overlay rendered a SECOND tooltip over Home
// and drew the sheet-measured frame in the shell's coordinate
// space, in the wrong place/size (owner, Nov 27, 2026 —
// duplicate tooltip + huge empty highlight box, e.g. step 15).
// If the user dismisses a tour sheet by hand, the
// sheet's onDismiss clears that sheet's frames, so the shell
// overlay shows the tooltip with no cutout and Next still
// advances — no auto-advance on manual dismiss, by design.
// The Weekly sheet's overlay lives in `FittedSheetOnIPad`
// (HomeView), so its GeometryReader measures the sheet viewport,
// not the iPhone scroll content; the Calculator's lives on
// `WeeklyBudgetCalculatorSheet`'s root; the Add cover's on
// `AddTransactionView`'s root; the Settings one on the shell's
// settingsCover NavigationStack.

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
    /// Funds — the Tzedaka action buttons in the expanded
    /// Tzedaka card: Add to Tzedaka (solid blue) + Record a
    /// Donation (ink outline). Admin-only: the row does not
    /// exist for members, so the step is skipped for them.
    case charityActions
    /// Funds — the Spending card's blue Calculate button, which
    /// opens the Weekly Budget Calculator. The tour expands the
    /// Spending card for this step.
    case calculatorButton
    /// Transactions — the + Add button.
    case addButton
    /// Transactions — the list.
    case transactionsList
    /// Transactions — the first row.
    case firstRow
    /// Transactions — the search field (live-as-you-type; there
    /// is no Search button — Filters is a separate header button).
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
    /// Weekly sheet — the numbers card (Allowance / Base /
    /// Spent / Balance / debt rows). Shared by the weekClose
    /// step, which talks about the same numbers.
    case weeklyNumbers
    /// Weekly sheet — the "Adjust This Week's Allowance" row.
    /// Admin-only: the row does not exist for members.
    case weeklyAdjust
    /// Weekly sheet — the "Set New Allowance" row. Admin-only.
    case weeklySetNew
    /// Weekly sheet — the "Weekly Allowance Calculator" row.
    case weeklyCalcRow
    /// Calculator — the fixed suggestion block at the top
    /// ("Suggested Weekly Allowance"). Shared by the calcApply
    /// step, which talks about the same suggestion.
    case calcSuggestion
    /// Calculator — the Expected Income card.
    case calcIncome
    /// Calculator — the Household Size + Lifestyle card (one
    /// card holding both).
    case calcHousehold
    /// Calculator — the Recurring Expenses card.
    case calcExpenses
    /// Calculator — the Expected Tzedaka (giving rate) section.
    case calcCharity
    /// Add cover — the Purchase option button.
    case addPurchase
    /// Add cover — the Donation option button. Admin-only.
    case addDonation
    /// Add cover — the Record Income option button. Admin-only.
    case addIncome
    /// Funds — the expanded Savings card's Add / Take actions
    /// ("Add Money" + "Take Money Out"). Admin-only: the row
    /// does not exist for members.
    case savingsActions
    /// Funds — the expanded Debt card's Pay / Clear actions
    /// ("Pay from [Fund]" + Adjust / Clear Debt). Admin-only.
    case debtActions
    /// Funds — the Debt Repayment Rule section inside the
    /// expanded Debt card (percent / fixed / off).
    case debtRule
    /// Settings > Connections — the Bank Connection card
    /// (Plaid). Lives on the Connections subpage, which the
    /// tour opens by driving the shell's Settings path.
    case bankConnection
    /// Settings > Connections — the Email Alerts card (Gmail).
    /// Same subpage as the bank card.
    case emailAlerts
    /// Transactions — the Needs Review banner (admin-only, only
    /// rendered when review items exist).
    case needsReviewBanner
    /// Transactions — the ⋯ "More" menu button in the header.
    /// Export lives INSIDE that menu (there is no standalone
    /// Export button — the old pills row is gone), so the tour
    /// points at the menu and says so.
    case exportButton
    /// Transactions — the ⋯ "More" menu button, again: the
    /// Merchants row lives inside the same menu (admin-only),
    /// so it shares the one visible entry point with Export.
    /// The anchor frame is the menu label's, so the two steps
    /// can each carry their own `.id` for scroll-to.
    case merchantsChip
}

/// One step of the walkthrough (v3 plan, 39 steps — the owner's
/// order, Nov 26, 2026). The `line` is the one short plain line
/// the tooltip shows; `tab` is the screen the step lives on (nil
/// for the Settings steps, which present over the current tab);
/// `anchor` is the element the arrow points at (nil only for
/// Welcome and Close, which have no target); `sheet` is the sheet
/// the step lives in (nil for shell steps — the overlay drives
/// `appState.tourSheet` from it, and `showSettings` for the
/// Settings steps).
///
/// The through-line (owner, Nov 26, 2026 — the CORE IDEA): the
/// app suggests, from the user's OWN rules, what to spend each
/// week, what to put aside, and what to give — and tracks it all
/// in one place. The Welcome step opens with it, the Close step
/// closes with it, and the three strands run through the tour:
/// the allowance steps are the "what to spend" suggestion, the
/// Savings steps are the "what to put aside" suggestion, the
/// Tzedaka steps are the "what to give" suggestion.
public enum TourStep: Int, CaseIterable {
    // Section 1 — the 3 main pages.
    case welcome
    case homePage
    case transactionsPage
    case fundsPage
    // Section 2 — connect (Settings > Connections).
    case connectBank
    case connectEmail
    // Section 3 — the allowance (Weekly sheet + Calculator).
    case spendingNumber
    case weeklyBudget
    case weeklyNumbers
    case weekClose
    case weeklyAdjust
    case weeklySetNew
    case weeklyCalculatorRow
    case calculator
    case calcSuggestion
    case calcIncome
    case calcHousehold
    case calcExpenses
    case calcCharity
    case calcApply
    // Section 4 — Tzedaka.
    case charityCard
    case charityRules
    case charityActions
    // Section 5 — everything else.
    case addButton
    case addPurchase
    case addDonation
    case addIncome
    case openRow
    case searchFilters
    case needsReview
    case export
    case merchantRules
    case savingsCard
    case savingsActions
    case debtCard
    case debtIdea
    case debtRule
    case debtActions
    case close

    public var line: String {
        switch self {
        case .welcome:
            return "This app suggests, from your own rules, what to spend each week, what to put aside, and what to give — and tracks it all in one place."
        case .homePage:
            return "This is Home — your week at a glance: what's left to spend, and what's set aside for giving."
        case .transactionsPage:
            return "This is Transactions — everything in and out, all in one place."
        case .fundsPage:
            return "This is Funds — your giving, your cushion, and your debt."
        case .connectBank:
            return "Connect your bank here — your purchases show up automatically."
        case .connectEmail:
            return "Email is optional — connect it too and your purchases show up faster and more completely."
        case .spendingNumber:
            return "This is what you have left to spend this week."
        case .weeklyBudget:
            return "Tap this card to open the Weekly Allowance — the week's numbers, and the Calculator that works them out."
        case .weeklyNumbers:
            return "Here's the week broken down — what you started with, what you spent, and what's left."
        case .weekClose:
            return "When the week ends, what's left pays your debt first, then goes to surplus."
        case .weeklyAdjust:
            return "Need more or less just this week? Change this week only — next week goes back to normal."
        case .weeklySetNew:
            return "This changes your allowance every week going forward."
        case .weeklyCalculatorRow:
            return "Not sure what your allowance should be? The Calculator works it out from your income and regular expenses."
        case .charityCard:
            return "This is set aside for giving — 10% of what comes in. The number here is what's available to give."
        case .charityRules:
            return "You set the rate — that's your rule. Set it to 0% to pause giving."
        case .charityActions:
            return "Add money to giving here — or record a donation you gave off the card."
        case .calculator:
            return "Tap Calculate to work out the weekly allowance from your income and regular expenses."
        case .calcSuggestion:
            return "This is the suggestion — from your own rules: your income, your giving rate, and your regular expenses."
        case .calcIncome:
            return "Put in what your household expects to earn each month."
        case .calcHousehold:
            return "How many people it covers, and how much to hold back for a comfortable life."
        case .calcExpenses:
            return "Your regular monthly costs — rent, bills, subscriptions. They come off before the suggestion."
        case .calcCharity:
            return "The giving rate used in the maths — change it here and the suggestion updates."
        case .calcApply:
            return "The Calculator only suggests — it never changes your allowance. To use this number, set it as your new allowance."
        case .addButton:
            // Nov 26, 2026: + Add opens the options popup
            // (Purchase / Donation / Record Income — members see
            // Purchase only), it no longer adds a purchase
            // directly, so the line stays role-neutral.
            return "Tap here to add something new."
        case .addPurchase:
            return "Add a purchase by hand — what you bought, and how much."
        case .addDonation:
            return "Record a gift you gave off the card."
        case .addIncome:
            return "Record money that came in — a paycheque, anything. Income sets aside charity automatically."
        case .openRow:
            // Tag-as-Expense lives only behind the row's Actions
            // sheet (TransactionActionsSheet), never in the row
            // itself — so there is no tagExpense step; the idea
            // is folded into this line instead.
            return "Tap any row to see it — and change it if it's wrong, or tag it as a recurring expense."
        case .searchFilters:
            return "Find anything fast."
        case .needsReview:
            return "If something needs a look — a possible duplicate, a charge to check — it shows up here. Tap it to sort it out."
        case .export:
            // Export lives inside the ⋯ menu (there is no
            // standalone Export button), so the step points at
            // the menu and says so.
            return "Export lives in this menu — send your transactions out as a file, for your records or your accountant."
        case .merchantRules:
            // Merchant Names lives inside the same ⋯ menu
            // (admin-only), so this step points at the menu too.
            return "Merchant names live in this menu too — rename one here, and it applies to every matching row, not just one."
        case .savingsCard:
            // Owner, Nov 26, 2026 — the Savings system is NOT a
            // general savings account: it is saving toward a
            // SPECIFIC purchase, or covering a week that goes
            // over. The line says so, never "cushion".
            return "This is for saving toward something specific — a purchase — or to cover a week that goes over."
        case .savingsActions:
            return "Add to it while you're saving toward something — take from it when a week goes over."
        case .debtCard:
            return "Your debt — pay it down here."
        case .debtIdea:
            return "Carried debt is what you still owe when a week costs more than your allowance."
        case .debtRule:
            return "A part of each week's allowance pays it down before you spend it — a %, a fixed amount, or off."
        case .debtActions:
            return "Pay it down from your cushion, or clear part of it here."
        case .close:
            return "That's the app — your rules suggest what to spend, put aside, and give, and it's all tracked here."
        }
    }

    public var tab: AppTab? {
        switch self {
        case .welcome, .homePage, .spendingNumber, .weeklyBudget, .weeklyNumbers, .weekClose, .weeklyAdjust, .weeklySetNew, .weeklyCalculatorRow, .charityCard:
            return .home
        case .connectBank, .connectEmail:
            // Settings presents over the current tab — no switch.
            return nil
        case .transactionsPage, .addButton, .addPurchase, .addDonation, .addIncome, .openRow, .searchFilters, .needsReview, .export, .merchantRules:
            return .transactions
        case .fundsPage, .calculator, .calcSuggestion, .calcIncome, .calcHousehold, .calcExpenses, .calcCharity, .calcApply, .charityRules, .charityActions, .savingsCard, .savingsActions, .debtCard, .debtIdea, .debtRule, .debtActions:
            return .funds
        case .close:
            return .home
        }
    }

    public var anchor: TourAnchor? {
        switch self {
        case .welcome:
            return nil
        case .homePage, .spendingNumber, .weeklyBudget:
            return .spendingHero
        case .transactionsPage:
            return .transactionsList
        case .fundsPage:
            return .charityCard
        case .connectBank:
            return .bankConnection
        case .connectEmail:
            return .emailAlerts
        case .weeklyNumbers, .weekClose:
            return .weeklyNumbers
        case .weeklyAdjust:
            return .weeklyAdjust
        case .weeklySetNew:
            return .weeklySetNew
        case .weeklyCalculatorRow:
            return .weeklyCalcRow
        case .calculator:
            return .calculatorButton
        case .calcSuggestion, .calcApply:
            return .calcSuggestion
        case .calcIncome:
            return .calcIncome
        case .calcHousehold:
            return .calcHousehold
        case .calcExpenses:
            return .calcExpenses
        case .calcCharity:
            return .calcCharity
        case .charityCard:
            return .charityCard
        case .charityRules:
            return .charityRules
        case .charityActions:
            return .charityActions
        case .addButton:
            return .addButton
        case .addPurchase:
            return .addPurchase
        case .addDonation:
            return .addDonation
        case .addIncome:
            return .addIncome
        case .openRow:
            return .firstRow
        case .searchFilters:
            return .searchBar
        case .needsReview:
            return .needsReviewBanner
        case .export:
            return .exportButton
        case .merchantRules:
            return .merchantsChip
        case .savingsCard:
            return .savingsCard
        case .savingsActions:
            return .savingsActions
        case .debtCard, .debtIdea:
            return .debtCard
        case .debtRule:
            return .debtRule
        case .debtActions:
            return .debtActions
        case .close:
            return nil
        }
    }

    /// The sheet this step lives in, if any — the tour drives
    /// `appState.tourSheet` from it on every step change (and
    /// `showSettings` for `.settings`), so the tour walks
    /// THROUGH the Weekly sheet, the Calculator, the Add cover
    /// and Settings, instead of only pointing at their entry
    /// buttons. Nil for shell steps.
    public var sheet: TourSheet? {
        switch self {
        case .weeklyNumbers, .weekClose, .weeklyAdjust, .weeklySetNew, .weeklyCalculatorRow:
            return .weekly
        case .calcSuggestion, .calcIncome, .calcHousehold, .calcExpenses, .calcCharity, .calcApply:
            return .calculator
        case .addPurchase, .addDonation, .addIncome:
            return .add
        case .connectBank, .connectEmail:
            return .settings
        default:
            return nil
        }
    }
}

/// Which sheet a tour step lives in (Nov 26, 2026 — the tour
/// walks through sheets, not just at them). `goToStep` drives
/// `appState.tourSheet` from `TourStep.sheet` on every step
/// change; each presenting view observes it and opens/closes its
/// sheet only while the tour is active. `.settings` is driven
/// the same way via `appState.showSettings` (the Settings cover
/// is shell-owned, not a per-view sheet).
public enum TourSheet: Equatable {
    /// The Weekly Allowance sheet (Home).
    case weekly
    /// The Weekly Allowance Calculator sheet (Funds).
    case calculator
    /// The + Add full-screen cover (Transactions).
    case add
    /// The Settings full-screen cover (shell).
    case settings
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

    /// Drop the frames for a sheet's anchors (Nov 26, 2026 —
    /// the manual-dismiss safety net): if the user dismisses a
    /// tour sheet by hand, its frames are in that sheet's
    /// coordinate space and must not be read by the shell
    /// overlay — with them cleared, the shell overlay shows
    /// the tooltip with no cutout and Next still advances.
    /// Each sheet's onDismiss clears its own anchors.
    public func clearFrames(for anchors: [TourAnchor]) {
        for anchor in anchors {
            frames.removeValue(forKey: anchor)
        }
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
/// anchor is chosen by the section. A nil tour is likewise a no-op
/// (Nov 26, 2026: sections that only sometimes carry the tour, e.g.
/// SpendingAllowanceSection, pass nil when they have none).
public struct TourAnchorModifier: ViewModifier {
    public let anchor: TourAnchor?
    /// Plain stored reference, NOT @ObservedObject: the modifier
    /// only WRITES frames (setFrame) and never reads published
    /// state, and @ObservedObject requires ObservableObject
    /// conformance, which Optional does not have (compile error,
    /// Nov 26, 2026 fix-up).
    public let tour: TourState?

    public init(anchor: TourAnchor?, tour: TourState?) {
        self.anchor = anchor
        self.tour = tour
    }

    public func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        if let anchor, let tour {
                            tour.setFrame(anchor, proxy.frame(in: .named("tourSpace")))
                        }
                    }
                    .onChange(of: proxy.frame(in: .named("tourSpace"))) { _, new in
                        if let anchor, let tour {
                            tour.setFrame(anchor, new)
                        }
                    }
            }
        )
    }
}

public extension View {
    /// Attach a walkthrough anchor to a view (no-op when nil).
    func tourAnchor(_ anchor: TourAnchor?, tour: TourState?) -> some View {
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
    /// The shell-owned Review view model (FundsViewModel):
    /// the Needs Review step is skippable when there is
    /// nothing to review (`reviewCount == 0`). Only the shell
    /// overlay carries it — the in-sheet overlays pass nil
    /// and never evaluate that step (their Next/Back paths
    /// cannot reach it), so nil reads as "nothing to review".
    var reviewViewModel: FundsViewModel?

    /// The tooltip card's measured height (140 is the estimate
    /// used before the first measurement; the preference below
    /// reports the real height per step). Nov 26, 2026 (loading
    /// audit): the card used to render at the 140 estimate on
    /// first paint and then jump to the measured height — on
    /// every step whose line wraps differently. The tooltip (and
    /// its arrow) now stay hidden until the height for the
    /// CURRENT step is measured (`measuredStepIndex`), so the
    /// card only ever appears at its final position.
    @State private var cardHeight: CGFloat = 140
    /// The step whose height `cardHeight` was measured for. Nil
    /// until the first measurement; stale for one frame after a
    /// step change, while the tooltip stays hidden.
    @State private var measuredStepIndex: Int? = nil

    public init(tour: TourState, appState: AppViewModel, transactionsViewModel: TransactionsViewModel? = nil, reviewViewModel: FundsViewModel? = nil) {
        self.tour = tour
        self.appState = appState
        self.transactionsViewModel = transactionsViewModel
        self.reviewViewModel = reviewViewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let step = tour.currentStep
            let target = targetFrame(for: step, containerSize: size)
            let cardTop = cardTopY(containerSize: size, target: target, bottomInset: bottomInset(proxy: proxy))
            // Nov 26, 2026 (loading audit): the tooltip + arrow
            // render only once the card height for THIS step is
            // measured — before that they would sit at the
            // 140pt estimate's position and jump when the real
            // height landed. One hidden frame, then the card
            // appears at its final position; the dim + cutout
            // (which do not depend on the card height) show at
            // once, so the overlay never looks empty.
            let tooltipReady = measuredStepIndex == tour.stepIndex
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
                        .opacity(tooltipReady ? 1 : 0)
                }
                tooltipCard(step: step)
                    .frame(width: cardWidth)
                    .position(x: size.width / 2, y: cardTop + cardHeight / 2)
                    .opacity(tooltipReady ? 1 : 0)
            }
            // The card height, reported per step (see
            // TourCardHeightKey): the step rides along so a
            // step change whose line wraps to the same height
            // still re-marks the card ready — the height alone
            // would not fire then, and the tooltip would stay
            // hidden.
            .onPreferenceChange(TourCardHeightKey.self) { value in
                guard let value else { return }
                cardHeight = value.height
                measuredStepIndex = value.step
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
                    // Nov 26, 2026 (walkthrough refresh — standing
                    // button rule, strengthened Nov 23): the Back
                    // chevron was primary blue, the same colour as
                    // the solid-blue Next — two of the three
                    // controls sharing a colour. Ink now: Back
                    // (ink chevron), Skip tour (muted text), Next
                    // (solid blue) are three distinct treatments.
                    .foregroundStyle(DesignTokens.ink)
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
                    // Nov 26, 2026 (loading audit): report the
                    // height together with the step it was
                    // measured for — the overlay gates the
                    // tooltip on the measurement for the CURRENT
                    // step, so the card never renders at a stale
                    // height and jumps (see TourCardHeightKey).
                    .preference(key: TourCardHeightKey.self, value: TourCardHeight(step: tour.stepIndex, height: cardProxy.size.height))
            }
        )
        .accessibilityIdentifier("tour.tooltip")
    }

    // MARK: - Advancing

    /// Whether a step has nothing to point at for this user, so
    /// the tour steps over it (forward in `goToStep`, backward in
    /// `back()` — the two must agree, or Back lands on a step that
    /// immediately skips forward again). Admin-only steps (the
    /// Weekly sheet's Adjust / Set New rows, the Add cover's
    /// Donation / Record Income options, the Tzedaka actions,
    /// the Savings / Debt action rows, the Merchants row) are
    /// skipped for members, who never see those buttons. The
    /// open-row step is skipped with no transactions, and the
    /// Needs Review step when there is nothing to review
    /// (admin-only banner, only rendered when review items
    /// exist — `reviewCount == 0` also covers the count not
    /// having loaded yet).
    private func isSkippable(_ step: TourStep) -> Bool {
        switch step {
        case .openRow:
            return transactionsViewModel?.shownTransactions.first == nil
        case .charityActions, .weeklyAdjust, .weeklySetNew, .addDonation, .addIncome, .savingsActions, .debtActions, .merchantRules:
            return !appState.isAdmin
        case .needsReview:
            guard appState.isAdmin else { return true }
            return (reviewViewModel?.reviewCount ?? 0) == 0
        default:
            return false
        }
    }

    /// Move to a step: switch to its tab (keeping the Charity card
    /// open across the switch into the rules step), drive the
    /// step's sheet (`tourSheet`, plus `showSettings` for the
    /// Settings steps), run the step's action (open the Charity
    /// card, expand the first row), and collapse the first row
    /// again when leaving its step.
    private func goToStep(_ index: Int) {
        // Skip steps with nothing to point at — a brand-new
        // household with zero rows has no first row, and a member
        // has no Tzedaka action buttons — instead of pointing at
        // nothing. Only skippable steps recurse, so this advances
        // at most past the run of them.
        let step = tour.steps[index]
        if isSkippable(step) {
            let nextIndex = index + 1
            if nextIndex >= tour.steps.count {
                finish()
            } else {
                goToStep(nextIndex)
            }
            return
        }
        tour.stepIndex = index
        // Sheets (Nov 26, 2026): the presenting views observe
        // `tourSheet` and open/close only while the tour is
        // active — setting it here on EVERY step change is what
        // walks the tour through the Weekly sheet, the
        // Calculator, the Add cover and Settings. The Settings
        // cover is shell-owned, so it rides `showSettings`.
        appState.tourSheet = step.sheet
        appState.showSettings = (step.sheet == .settings)
        if let tab = step.tab, appState.selectedTab != tab {
            if step == .charityRules || step == .charityActions || step == .calculator {
                // Keep the fund card open across this switch —
                // the tab-change reset would collapse it otherwise.
                appState.suppressNextTabReset = true
            }
            appState.selectedTab = tab
        }
        switch step {
        case .charityRules, .charityActions:
            appState.expandedCard = .charity
        case .calculator:
            // The Calculate button lives in the Spending card's
            // detail — the card must be open for the anchor to
            // report a frame.
            appState.expandedCard = .spending
        case .savingsActions:
            // The Add / Take actions live in the expanded
            // Savings card — the card must be open for the
            // anchor to report a frame.
            appState.expandedCard = .fund
        case .debtRule, .debtActions:
            // The rule section and the Pay / Clear actions live
            // in the expanded Debt card.
            appState.expandedCard = .debt
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

    /// Build 64 (F-9): back one step. Steps over skippable steps
    /// (`isSkippable` — the open-row step with no transactions,
    /// the admin-only steps for members, the Needs Review step
    /// with nothing to review) — `goToStep` would skip forward
    /// past them again, landing back where we started. No-op on
    /// the first step (no Back button there).
    private func back() {
        var target = tour.stepIndex - 1
        while target >= 0 {
            if isSkippable(tour.steps[target]) {
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
        // Sheets (Nov 26, 2026): close any open tour sheet and
        // the Settings cover BEFORE ending the tour, so the
        // presenting views' tourSheet/showSettings observers
        // close them while the tour is still active (their
        // sync guards on `tour.isActive`).
        appState.tourSheet = nil
        appState.showSettings = false
        tour.end()
        if appState.selectedTab != .home {
            appState.selectedTab = .home
        }
    }
}

/// The tooltip card's measured height, tagged with the step it
/// was measured for (Nov 26, 2026 — loading audit). The overlay
/// positions the card from the height, so the measurement must
/// carry its step: on a step change the height alone may not
/// change (two lines wrapping to the same height), and a bare
/// height preference would not fire — leaving the tooltip hidden
/// under the per-step readiness gate. A small struct (not a
/// tuple) because a tuple cannot satisfy PreferenceKey's
/// Equatable Value requirement here — the change fires when
/// either half changes.
private struct TourCardHeight: Equatable {
    let step: Int
    let height: CGFloat
}

private struct TourCardHeightKey: PreferenceKey {
    static var defaultValue: TourCardHeight? = nil
    static func reduce(value: inout TourCardHeight?, nextValue: () -> TourCardHeight?) {
        value = nextValue() ?? value
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

/// The sheet version of the helper above (Nov 26, 2026): the
/// Settings steps have no tab (`TourStep.tab` is nil — Settings
/// presents over the current tab), so the scroll gate is the
/// step's sheet instead. Used by the Settings subpage scaffold
/// for the Connections steps.
@MainActor
public func scrollTourSheetAnchorIntoView(_ proxy: ScrollViewProxy, tour: TourState, sheet: TourSheet) {
    guard tour.isActive, tour.currentStep.sheet == sheet, let anchor = tour.currentStep.anchor else { return }
    withAnimation(.none) { proxy.scrollTo(anchor, anchor: .center) }
}
