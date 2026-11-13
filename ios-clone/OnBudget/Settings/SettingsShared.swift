// OnBudget — Settings shared UI (Settings workstream, live web v66).
//
// Shared context, toast, button styles, cards, and the bank-logo view
// used by every Settings / Past Weeks / Activity / CSV screen.
// Shared button styles (Primary/Tertiary/Pale), BackButton, ErrorBox
// and ToastBanner are NOT redefined here — they live in the shared
// SharedViews.swift (Auth/Home); QuietButtonStyle lives in
// Transactions/OnBudgetButtons.swift. Money formatting uses the kit
// type qualified as OnBudgetKit.MoneyFormat: the app target already
// has two unqualified MoneyFormat types (Formatting.swift and
// Funds/OnBudgetKit.MoneyFormat.swift) — a pre-existing duplicate the coordinator
// still needs to resolve (see report).

import SwiftUI
import UIKit
import OnBudgetKit

// MARK: - Context

/// Everything a Settings-family screen needs, handed in by the app
/// coordinator (Auth/Home own the session + household loading).
/// Views never fetch the session themselves and never touch the real
/// household unless the coordinator passes it in.
struct SettingsContext {
    let client: SupabaseClient
    let householdId: UUID
    let isAdmin: Bool
    /// Owner = the household creator (`households.owner_id`). The
    /// owner keeps role `.admin`; this flag is what gates
    /// owner-only UI (invite code, Remove member, demote).
    let isOwner: Bool
    let currentUserId: UUID?
    let displayName: String?
    let email: String?
    let householdName: String?

    /// Called after a successful sign-out (Profile menu / Settings).
    var onSignOut: () -> Void
    /// Called after a successful account deletion, with the message
    /// the auth screen should show ("Your account was deleted.").
    var onAccountDeleted: (String) -> Void
    /// Called when a Past Week is tapped: the Transactions agent
    /// opens Transactions filtered to that Sun–Sat week.
    var onShowWeekTransactions: (String) -> Void
    /// Called from Budget when the owner taps Temporary Allowance.
    /// The Temporary Allowance box itself is owned by the Funds
    /// agent — Settings only links to it. Nil hides the link.
    var onOpenTemporaryAllowance: (() -> Void)?
    /// Best-effort push-token unregister (APNS_DESIGN §3: fire-and-
    /// forget on sign-out / account deletion). Nil = no token store
    /// wired yet; deletion still proceeds.
    var unregisterPushToken: (() async -> Void)?

    init(
        client: SupabaseClient,
        householdId: UUID,
        isAdmin: Bool,
        isOwner: Bool = false,
        currentUserId: UUID? = nil,
        displayName: String? = nil,
        email: String? = nil,
        householdName: String? = nil,
        onSignOut: @escaping () -> Void = {},
        onAccountDeleted: @escaping (String) -> Void = { _ in },
        onShowWeekTransactions: @escaping (String) -> Void = { _ in },
        onOpenTemporaryAllowance: (() -> Void)? = nil,
        unregisterPushToken: (() async -> Void)? = nil
    ) {
        self.client = client
        self.householdId = householdId
        self.isAdmin = isAdmin
        self.isOwner = isOwner
        self.currentUserId = currentUserId
        self.displayName = displayName
        self.email = email
        self.householdName = householdName
        self.onSignOut = onSignOut
        self.onAccountDeleted = onAccountDeleted
        self.onShowWeekTransactions = onShowWeekTransactions
        self.onOpenTemporaryAllowance = onOpenTemporaryAllowance
        self.unregisterPushToken = unregisterPushToken
    }
}

// MARK: - Errors

/// The exact text a Settings screen should show for a backend failure.
/// The kit's `userMessage` returns the server's text verbatim for
/// server/transport errors — that is how a raw database error
/// ("column households.household_id does not exist", owner report
/// Nov 11, 2026) reached the user. This layer passes through only the
/// specific refusal cases whose messages are already plain language
/// (admin-only, week-locked, rate-limited, validation, …) and maps
/// everything else — raw server strings, decode failures, transport
/// text, non-kit errors — to a generic plain message. The raw text
/// stays on the error for logging; it never reaches the screen.
func settingsErrorMessage(_ error: Error) -> String {
    guard let budgetError = error as? OnBudgetError else {
        return "Could not complete that. Try again."
    }
    switch budgetError {
    case .networkOffline, .timedOut, .sessionExpired,
         .forbidden, .adminOnly, .weekLocked, .insufficientFund,
         .cannotRestore, .heldRefundAlreadyResolved, .rateLimited,
         .notFound, .validationFailed, .invalidCredentials:
        return budgetError.userMessage
    case .networkError, .serverError, .decodingError, .unknown:
        return "Could not complete that. Try again."
    }
}

// MARK: - Toast

/// Bottom-only toast state. Info renders brand blue, success GREEN
/// (owner rule, Nov 11 2026 — native only), errors soft red.
/// Auto-dismisses after 4s (spec §2.3); tap dismisses sooner. One
/// toast at a time — a new toast replaces the old one.
///
/// NOTE (rebase, Nov 9): the button styles, BackButton, ErrorBox
/// and ToastBanner this file used to define now live in the shared
/// `SharedViews.swift` (Auth/Home) / `Transactions/OnBudgetButtons.swift`
/// — this file keeps only Settings-only helpers plus the ToastState
/// object the Settings cards share. The banner itself is the shared
/// `ToastBanner(toast:onDismiss:)` from SharedViews.
@MainActor
final class ToastState: ObservableObject {
    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, kind: ToastStyle.Kind = .info) {
        dismissTask?.cancel()
        current = Toast(message: message, kind: kind)
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }

    func showError(_ message: String) { show(message, kind: .error) }
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

extension View {
    /// Bottom toast overlay, floating clear of the tab bar. Uses the
    /// shared `ToastBanner` (SharedViews) so there is one banner.
    /// Overloads the shared `toastOverlay(Binding<Toast?>)` — this
    /// one takes the shared Settings `ToastState` instead.
    ///
    /// Plain `.overlay(alignment: .bottom)` on the screen itself —
    /// NOT a wrapping ZStack. A ZStack sizes to its content, and a
    /// ScrollView inside one can size the stack to the scroll content
    /// rather than the screen, which floated the banner mid-screen
    /// (owner report, Nov 11 2026). An overlay is positioned inside
    /// the screen's own bounds, so the banner is always at the
    /// screen's bottom, never mid-screen.
    func toastOverlay(_ toastState: ToastState, clearTabBar: Bool = true) -> some View {
        overlay(alignment: .bottom) {
            if let toast = toastState.current {
                // Move-only entrance (audit X-P2-9, Nov 12 2026):
                // the toast used to fade in too (`.combined(with:
                // .opacity)`), the app's only opacity fade. Toasts
                // are not expand/collapse cards, so this is a
                // consistency change, not a rule-violation fix — the
                // 0.2s animation below is unchanged.
                ToastBanner(toast: toast, clearTabBar: clearTabBar) { toastState.dismiss() }
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastState.current?.id)
    }
}

// MARK: - Buttons
//
// Primary / Tertiary / Pale button styles, BackButton, ErrorBox and
// ToastBanner live in the shared `SharedViews.swift` (Auth/Home) —
// `QuietButtonStyle` in `Transactions/OnBudgetButtons.swift`. This
// file defines only the Settings-only button styles below, so the
// app target has exactly one of each shared definition.

/// Danger: soft-red treatment — bg #fef2f2, text #dc2626.
/// Never a solid red button.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DesignTokens.errorText)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(DesignTokens.errorBackground)
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

/// Small danger button (member Remove, per-account Disconnect).
struct SmallDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(DesignTokens.errorText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DesignTokens.errorBackground)
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

// MARK: - Cards, fields, messages

/// White card, radius 20, light shadow (styles.css:388).
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TitleCase.apply(to: title))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(DesignTokens.ink)
            content
        }
        .padding(16)
        .background(.white)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

/// Muted small line (secondary labels, #6b7280).
struct MutedLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(DesignTokens.muted)
    }
}

// MARK: - History date filter (shared by Past Weeks + Activity)

/// ONE History date filter (audit X-P2-10, Nov 12 2026): Past Weeks
/// and Activity used to carry separate ~60-line copies of this card,
/// including the same today-as-default bug in both. Both screens
/// now render this one component, bound to their view model's
/// drafts and the shared `HistoryFilterState`.
///
/// Redesign (owner, Nov 12 2026): the same one-button + one-calendar
/// range picker as the Transactions redesign (build 15) — one button
/// shows the range ("Choose Dates" with no filter set, never today's
/// date — audit X-P1-1), one calendar picks a start date then an end
/// date. The calendar is the shared `DateRangeCalendarView`; picking
/// only changes the DRAFT — nothing applies until Apply. Cancel
/// restores the drafts to the applied filter; Reset Filters (a small
/// plain link, not a third button) clears the filters. `onResetAll`
/// clears every filter on the page (Activity: date + type); when nil
/// (Past Weeks) Reset clears the date filter only.
struct HistoryDateFilterCard: View {
    @Binding var draftFrom: String
    @Binding var draftTo: String
    let filter: HistoryFilterState
    let onApply: () -> Void
    let onClear: () -> Void
    var onResetAll: (() -> Void)? = nil

    @State private var showingCalendar = false
    @State private var calendarSelection: WhenSelection = .allTime
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// True once the calendar actually picked something (Done, a
    /// quick pick, or Clear). Backing out without picking leaves
    /// the drafts untouched — in particular a one-sided draft the
    /// range calendar cannot represent is never clobbered.
    @State private var calendarChose = false

    /// "Choose Dates" with no filter set, else the range
    /// ("Nov 8 – Nov 14", "Nov 8", "From Nov 8" / "To Nov 14").
    private var rangeLabel: String {
        TransactionFormatting.dateRangeChipLabel(from: draftFrom, to: draftTo) ?? "Choose Dates"
    }

    var body: some View {
        SettingsCard(title: "Filter by Date") {
            Button { openCalendar() } label: {
                HStack {
                    Image(systemName: "calendar")
                    Text(rangeLabel)
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose dates, \(rangeLabel)")

            TwoButtonRow {
                Button("Apply") { onApply() }
                    .buttonStyle(PrimaryButtonStyle())
            } secondary: {
                Button("Cancel") { cancelDrafts() }
                    .buttonStyle(TertiaryButtonStyle())
            }

            HStack {
                Spacer()
                Button("Reset Filters") { (onResetAll ?? onClear)() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
            }

            if !filter.periodLine.isEmpty {
                MutedLine(text: filter.periodLine)
            }
            if !filter.countLine.isEmpty {
                MutedLine(text: filter.countLine)
            }
        }
        .sheet(isPresented: $showingCalendar, onDismiss: commitCalendarSelection) {
            NavigationStack {
                DateRangeCalendarView(selection: calendarBinding)
            }
            // iPad sheet height (owner, Nov 13, 2026): the
            // calendar content is a ScrollView, and
            // .presentationSizing(.fitted) sizes a sheet to its
            // content's ideal height — a ScrollView has none, so
            // the sheet collapsed in build 23. Detents give it a
            // real height on iPhone; on iPad they are ignored and
            // the sheet takes the default form-sheet height. The
            // month grid is flexible (7 columns), so it uses the
            // extra width.
            .presentationDetents([.medium, .large])
            .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        }
    }

    /// The calendar binding: any set counts as a pick, so Back
    /// without picking commits nothing.
    private var calendarBinding: Binding<WhenSelection> {
        Binding(
            get: { calendarSelection },
            set: { calendarSelection = $0; calendarChose = true }
        )
    }

    private func openCalendar() {
        calendarChose = false
        if draftFrom.isEmpty, draftTo.isEmpty {
            calendarSelection = .allTime
        } else if !draftFrom.isEmpty, !draftTo.isEmpty {
            calendarSelection = .custom(from: draftFrom, to: draftTo)
        } else {
            // A one-sided draft has no range form: open unfiltered
            // so the calendar starts blank rather than inventing a
            // range; Back leaves the draft as it was.
            calendarSelection = .allTime
        }
        showingCalendar = true
    }

    /// Commit the calendar's pick into the drafts (still
    /// unapplied until Apply). Quick picks become concrete bounds.
    private func commitCalendarSelection() {
        guard calendarChose else { return }
        switch calendarSelection {
        case .allTime:
            draftFrom = ""
            draftTo = ""
        case .thisWeek:
            let bounds = TransactionFormatting.currentWeekBounds()
            draftFrom = bounds.start
            draftTo = bounds.end
        case .thisMonth:
            let bounds = TransactionFormatting.currentMonthBounds()
            draftFrom = bounds.start
            draftTo = bounds.end
        case .custom(let from, let to):
            draftFrom = from
            draftTo = to
        }
    }

    /// Cancel restores the drafts to the applied filter; the list
    /// is untouched (no reload).
    private func cancelDrafts() {
        draftFrom = filter.fromDate
        draftTo = filter.toDate
    }
}

/// A labelled field, sized to what it can hold — money inputs are
/// capped, not full-width (owner card-sizing rule).
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var maxWidth: CGFloat? = nil
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    /// Optional focus binding, so a screen can offer a keyboard
    /// Done button (Profile). When nil the field is unfocused-only.
    /// Must be a FocusState binding: .focused() takes
    /// FocusState<Bool>.Binding, not a plain Binding<Bool>.
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TitleCase.apply(to: label))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.ink)
            field
        }
    }

    @ViewBuilder
    private var field: some View {
        // Owner, Nov 13, 2026: the fields looked thin and small
        // next to the Save buttons below them. Same height and
        // weight as the buttons (48pt, white, 1pt border,
        // radius 10) — the .roundedBorder system style is gone.
        let base = Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autocapitalization)
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 12)
        .frame(maxWidth: maxWidth, minHeight: 48, alignment: .leading)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        if let focused {
            base.focused(focused)
        } else {
            base
        }
    }
}

/// Role pill: "Admin" / "Member".
struct RolePill: View {
    let role: HouseholdRole

    var body: some View {
        Text(role.label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(hex: "#eef4ff"))
            .foregroundStyle(DesignTokens.ink)
            .cornerRadius(6)
    }
}

// MARK: - Bank logo

/// Bank favicon (Google favicon service, sz=128) with a
/// brand-coloured monogram fallback. Never Clearbit (dead Nov 4,
/// 2026). Unmapped banks fall back to a slate monogram tile. A loaded
/// logo FILLS the whole tile edge-to-edge — the same fill rule as
/// TransactionIconView (owner, Nov 12, 2026): aspect-fill + clip,
/// cropping overflow, never stretched, no inner padding between the
/// image and the tile edge; the 1pt border and corner radius stay.
/// (Nov 11, 2026: logos looked weird as a white box on a coloured
/// tile / stretched edge-to-edge — that was the old scaledToFit +
/// 14% padding; fill-by-cropping is not stretching.) Small sources
/// upscale with high interpolation.
struct BankLogoView: View {
    let institutionName: String?
    var size: CGFloat = 40

    @State private var imageFailed = false

    var body: some View {
        Group {
            if let url = BankBranding.faviconURL(for: institutionName), !imageFailed {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipped()
                            .background(Color.white)
                    default:
                        monogram
                            .onAppear {
                                if case .failure = phase { imageFailed = true }
                            }
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
    }

    private var monogram: some View {
        Text(BankBranding.initial(for: institutionName))
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: BankBranding.brandHex(for: institutionName)))
            .cornerRadius(8)
    }
}

// MARK: - Share sheet

/// Native iOS share sheet (UIActivityViewController).
struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
