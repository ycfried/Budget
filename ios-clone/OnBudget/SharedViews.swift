// OnBudget — SharedViews.swift
//
// Shared SwiftUI building blocks for the Auth + Home screens.
// Colours come from OnBudgetKit DesignTokens only — never hard-coded
// hex in a screen. Button rules (owner, Nov 3–4): two-button rows are
// primary blue first + grey tertiary second; pale #bfdbfe is ONLY the
// middle tier of a three-button row; no two adjacent buttons share a
// colour/treatment. Back buttons are light blue #3b82f6, bold 700,
// 15px. Errors are soft red (bg #fef2f2, text #dc2626, border
// #fecaca). Toasts are brand blue, bottom only, auto-dismiss 4s.
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

// MARK: - Buttons

/// Primary: #2f6bff fill, white text.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Grey tertiary: #e5e7eb fill, ink text. Second button in
/// two-button rows.
public struct TertiaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Color(hex: "#e5e7eb"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Pale middle tier: #bfdbfe fill, ink text. ONLY as the middle tier
/// of a three-button row — never beside another pale button.
public struct PaleButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.pale)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Distinct outline: white bg, brand-blue border + text, same
/// sizing as Primary / Tertiary. The second treatment in a pair
/// that must not share a colour with a grey tertiary neighbour
/// (owner button rule, Nov 3–4, 2026).
public struct OutlineButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.primary)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DesignTokens.primary, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Small variant of the tertiary style for in-row actions.
public struct SmallTertiaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(hex: "#e5e7eb"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Plain row style with pressed-state dimming (audit X-P2-6):
/// a full-width tappable row (e.g. a Past Week) must give press
/// feedback, which `.buttonStyle(.plain)` does not. The label's
/// own styling is untouched — only opacity dips while pressed.
public struct DimOnPressButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Back buttons: light blue #3b82f6, bold 700, 15px, no background,
/// no border. Text is always "← Back". This is the ONE back
/// implementation (audit X-P2-7, Nov 12 2026): the Funds inline
/// duplicate and the `BackButtonStyle()` toolbar call sites all
/// route through here now; the rendering itself lives in
/// `BackButtonStyle`, used by this view and nothing else.
/// Exception (owner, Nov 15, 2026): the Choose Dates calendar
/// toolbar uses a bare chevron instead — its "← Back" text
/// truncated to "←…" under the centred title + Clear, and a
/// truncated button must never ship.
public struct BackButton: View {
    public let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            Text("← Back")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DesignTokens.mid)
        }
        .buttonStyle(BackButtonStyle())
        .accessibilityLabel("Back")
    }
}

/// Sheet header (owner, Nov 14, 2026): an X close symbol at
/// top-left, the title centred, and a balancing 44pt spacer at
/// top-right so the title stays centred. Replaces the toolbar
/// "Cancel" text button, which truncated to "Ca…" in the sheet
/// toolbar, and the NavigationStack root, which broke
/// .presentationSizing(.fitted) — a NavigationStack reports an
/// unbounded ideal height, so fitted sheets rendered tall and
/// mostly empty (Add / Actions sheets, build 24). A plain VStack
/// root + this header lets fitted measure the real content. When
/// onBack is given, the leading control is a back chevron that
/// returns to the previous step instead of closing.
public struct SheetHeader: View {
    let title: String
    let onClose: () -> Void
    let onBack: (() -> Void)?

    public init(title: String, onClose: @escaping () -> Void, onBack: (() -> Void)? = nil) {
        self.title = title
        self.onClose = onClose
        self.onBack = onBack
    }

    public var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.mid)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.mid)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Spacer()
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }
}

// MARK: - Shared form fields (owner, Nov 15, 2026 — build 28)

/// Dollar amount field: a fixed "$" prefix inside the field —
/// display only, never part of the typed text, so parsing is
/// unchanged. Same white field + 1pt #e5e7eb border + cornerRadius
/// 10 treatment as the Filters Min/Max fields (owner, Nov 13,
/// 2026) and the other text fields. One implementation for every
/// $ entry field cross-app (Add Purchase / Add Donation, Record
/// Income, Add / Use / Ask Fund, Approve, Temporary Allowance,
/// base allowance, Extra Fund request).
public struct DollarTextField: View {
    @Binding public var text: String
    public let placeholder: String
    public let maxWidth: CGFloat?
    public let minHeight: CGFloat

    public init(text: Binding<String>, placeholder: String = "0.00", maxWidth: CGFloat? = 220, minHeight: CGFloat = 44) {
        self._text = text
        self.placeholder = placeholder
        self.maxWidth = maxWidth
        self.minHeight = minHeight
    }

    public var body: some View {
        HStack(spacing: 2) {
            Text("$")
                .font(.system(size: 17))
                .foregroundStyle(DesignTokens.ink)
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: maxWidth, minHeight: minHeight, alignment: .leading)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Date field (owner, Nov 15, 2026): the compact DatePicker
/// renders as a grey pill — off brand under the Nov 11 no-pills
/// rule, extended to date controls. This looks like the other
/// fields — squarish white field with border, ink text — and opens
/// a graphical calendar picker in a sheet. One implementation for
/// every date entry (Add Purchase / Add Donation / Record Income).
/// The Filters date-range calendar is already custom and stays
/// as it is.
public struct DateField: View {
    @Binding public var date: Date
    @State private var showingPicker = false

    public init(date: Binding<Date>) {
        self._date = date
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    public var body: some View {
        Button { showingPicker = true } label: {
            HStack {
                Text(Self.displayFormatter.string(from: date))
                    .font(.system(size: 17))
                    .foregroundStyle(DesignTokens.ink)
                Spacer()
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Whole-area tap target (owner, Nov 15, 2026 app-wide
            // pass): the padded box responds across its full frame.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Date, \(Self.displayFormatter.string(from: date))")
        .sheet(isPresented: $showingPicker) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Choose Date", onClose: { showingPicker = false })
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Button("Done") { showingPicker = false }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
            .presentationSizing(.fitted)
            .presentationBackground(.white)
        }
    }
}

// MARK: - Error / info boxes

/// Inline soft-red error box (`.result.error` in the web app).
/// Sign-in / join failures stay in this box under the fields —
/// never in a toast, which vanishes before the fix.
public struct ErrorBox: View {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        Text(message)
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
    }
}

/// Error box that leaves on its own (owner rule, Nov 11 2026: an
/// error message that pops up must not stay for good). Tap dismisses
/// it, and it auto-dismisses after `ToastStyle.autoDismissSeconds`
/// (4s — the same shared value as the toasts). The caller passes
/// `onDismiss` to clear the underlying message, so the box never
/// reappears from stale state; a fresh failure shows a fresh box.
/// The timer restarts if the message changes (`.task(id:)`), and is
/// cancelled when the view goes away — so an error never lingers
/// across navigation either.
public struct DismissableErrorBox: View {
    public let message: String
    public let onDismiss: () -> Void
    public init(_ message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }
    public var body: some View {
        ErrorBox(message)
            .onTapGesture(perform: onDismiss)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
                // A cancelled sleep (message changed, view gone) must
                // NOT dismiss the replacement message — the guard is
                // the whole point of the id: task.
                guard !Task.isCancelled else { return }
                onDismiss()
            }
    }
}

/// Inline info box (`.result`, info bg #eef4ff, ink text).
public struct InfoBox: View {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(DesignTokens.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DesignTokens.infoBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Inline soft-green success box: the green mirror of ErrorBox.
/// Inline success states are GREEN, like the success toasts (owner
/// decision, Nov 12, 2026) — never the blue InfoBox.
public struct SuccessBox: View {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(DesignTokens.successText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DesignTokens.successBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignTokens.successBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Loading screen

/// Full-screen loading view (live.html:39-43): logo + blue ring,
/// "OnBudget", "Loading Your Household". Shown on first paint and
/// kept until the first data load completes or fails — never a blank
/// or half-built page, and never an endless spinner with no error.
/// The logo wears the animated blue ring (BrandedLoader) — the
/// iOS spinner is abolished app-wide (owner, Nov 14, 2026).
public struct LoadingView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            // The real logo (Assets.xcassets/AppLogo), not the "S"
            // placeholder ring (owner, Nov 11, 2026), with the
            // animated brand-blue ring around it.
            BrandedLoader(size: 72)
            Text("OnBudget")
                .font(.system(size: 28, weight: .bold, design: .default))
                .foregroundStyle(DesignTokens.ink)
            Text("Loading Your Household")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
    }
}

// MARK: - Branded loader

/// Branded loading indicator (owner, Nov 14, 2026): the real app
/// logo with an animated brand-blue ring around it. This replaces
/// EVERY ProgressView in the app — the iOS asterisk spinner is
/// abolished app-wide. The logo itself is static; only the ring
/// moves (a 270° arc rotating once a second). Use it for full-page
/// or section loading states. Where a shimmer skeleton already
/// stands in for the content, keep the skeleton and do NOT stack
/// this on top of it. The sync button's rotating arrow is a
/// different thing (the sync affordance the owner approved) and is
/// untouched.
public struct BrandedLoader: View {
    /// Logo size; the ring sits 6pt outside it on every side.
    public let size: CGFloat

    @State private var spinning = false

    public init(size: CGFloat = 56) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    DesignTokens.primary,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: size + 12, height: size + 12)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    .linear(duration: 1.0).repeatForever(autoreverses: false),
                    value: spinning
                )
        }
        .onAppear { spinning = true }
        .accessibilityLabel("Loading")
    }
}

// MARK: - Expand / collapse animation

/// The ONE opening/closing effect for every expandable surface
/// (owner rule, Nov 11 2026 — "they should all share a classy
/// opening/closing effect"): Charity / Extra Fund cards, transaction
/// detail rows, fund rows, sheets' inner expands — all share the same
/// smooth ease-in-out, 0.25s. No abrupt snaps, no per-screen timing.
/// NO-FADE, LOCKED IN (owner rule, Nov 12 2026 ~8:47 AM, re-confirmed
/// Nov 15 2026): the transition is height/position ONLY — the words
/// stay fully solid and opaque throughout, visible as the row drops
/// open, and stay solid until covered when it closes. There is no
/// opacity component anywhere in this transition. Do NOT reintroduce
/// a fade: the fade was put back on Nov 12 ~10:00 PM ("make it
/// typical", iOS disclosure feel) and the owner still called the
/// animation "funny" and said it "keeps going in circles" (Nov 15),
/// then re-confirmed no-fade. The fade stays out. Apply with
/// `.animation(ExpandAnimation.animation, value: <the expanded flag>)`
/// at the toggle site and `.transition(ExpandAnimation.transition)`
/// on the expanding content; chevrons rotate 180° with the same
/// animation (down when collapsed, up when expanded). Sheets keep
/// the system presentation animation.
public enum ExpandAnimation {
    public static let duration = 0.25
    public static var animation: Animation { .easeInOut(duration: duration) }
    public static var transition: AnyTransition {
        .move(edge: .top)
    }
}

// MARK: - Toast

/// Bottom toast, floating clear of the tab bar. Info is brand blue,
/// success is the Posted badge treatment (owner, Nov 15, 2026 —
/// build 33: the solid #22c55e bar with white text was the wrong
/// green), errors are soft red. Auto-dismiss 4s
/// (ToastStyle.autoDismissSeconds, CLONE_SPEC §2.3); tap dismisses
/// sooner.
///
/// `clearTabBar` (audit X-P2-1, Nov 12 2026): true where a tab bar
/// is actually present (the three tabs) — the banner floats 120pt
/// above the bottom edge, clear of it. False on Auth/Household and
/// inside the Settings cover, where there is no tab bar — the banner
/// sits 16pt above the bottom edge instead of hovering mid-screen.
public struct ToastBanner: View {
    public let toast: Toast
    public let onDismiss: () -> Void
    public let clearTabBar: Bool
    public init(toast: Toast, clearTabBar: Bool = true, onDismiss: @escaping () -> Void) {
        self.toast = toast
        self.clearTabBar = clearTabBar
        self.onDismiss = onDismiss
    }
    /// Banner background + text by kind, straight from the
    /// `ToastStyle` spec — the ONE source of truth, so the banner
    /// can never drift from it again (build 33: the banner had its
    /// own success colour, solid #22c55e with white text, while the
    /// spec said the Posted badge treatment #dcfce7 / #166534).
    private var bannerBackground: Color {
        Color(hex: ToastStyle.backgroundHex(for: toast.kind))
    }
    private var bannerText: Color {
        Color(hex: ToastStyle.textHex(for: toast.kind))
    }
    public var body: some View {
        Button(action: onDismiss) {
            Text(toast.message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(bannerText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(bannerBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            toast.kind == .error ? DesignTokens.errorBorder : Color.clear,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, clearTabBar ? 120 : 16) // Clear of the tab bar (web: bottom 120px); 16pt where there is none.
    }
}

/// Overlays the current toast at the bottom of any screen, with the
/// 4-second auto-dismiss (ToastStyle.autoDismissSeconds — the one
/// shared value, CLONE_SPEC §2.3).
public struct ToastOverlayModifier: ViewModifier {
    @Binding public var toast: Toast?
    public let clearTabBar: Bool
    public init(toast: Binding<Toast?>, clearTabBar: Bool = true) {
        self._toast = toast
        self.clearTabBar = clearTabBar
    }
    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                ToastBanner(toast: toast, clearTabBar: clearTabBar) { self.toast = nil }
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
                        if self.toast?.id == toast.id { self.toast = nil }
                    }
            }
        }
    }
}

public extension View {
    func toastOverlay(_ toast: Binding<Toast?>, clearTabBar: Bool = true) -> some View {
        modifier(ToastOverlayModifier(toast: toast, clearTabBar: clearTabBar))
    }
}

// MARK: - Cards

/// Standard white card: radius 20, hairline shadow (styles.css:388).
public struct Card<Content: View>: View {
    public let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                    radius: 2, x: 0, y: 1)
    }
}


// MARK: - Loading skeletons + empty placeholders
//
// ONE loading language (owner direction, Nov 12 2026 — umbrella for
// audit items H-P2-5, F-P2-13, H-P1-4, S-P1-2): every loading state
// is a shimmer skeleton shaped like the loaded content (same rows,
// same sizes, so no layout jump), never a spinner mixed in, never a
// "Loading…" text line, never a "—" dash while loading. A failed
// load is a third, distinct state — a short plain error line +
// retry (ErrorBox + Try Again), never a skeleton, never a bare
// dash, never a false empty state. An empty / no-value face is a
// muted placeholder in the value's own size and position (a static
// grey block, or the words "Not set" in muted regular type where
// the value is genuinely unset) — never a bare bold "—" in amount
// type, never a sentence in amount type.

// MARK: - Stat-card themes (owner direction, Nov 12 2026,
// corrected ~2:02 PM the same day; corrected again ~9:55 PM:
// skeletons keep their coloured outlines — the muted-grey
// loading outline is gone)
//
// The Home + Funds Charity / Extra Fund cards share ONE theme each
// (same outline, icon, amount size on both screens). Charity is
// green (giving/growth — green is already the native success
// colour); Extra Fund is amber (savings — amber, not blue like
// the Weekly Budget hero, so the two cards tell apart). NOT a
// wash: the card is white inside, exactly like the Weekly Budget
// hero, with a 2px coloured outline. SUPERSEDED Nov 14, 2026
// (~11:28 PM, "too much colors"): amounts and icons are ink,
// chevrons muted grey — ONLY the coloured outline keeps colour.
// The hero stays the anchor by size and by the thickest outline
// (2.5px). While loading the card keeps its coloured outline —
// only the amount/icon faces are grey skeleton blocks in the same
// bigger shape.

/// The shared outline/identity of a Charity or Extra Fund stat card.
public enum StatCardTheme {
    case charity
    case fund
    /// Carried Debt (build 29): the outline is the muted deep red
    /// #991b1b (`DesignTokens.heroOverBudget`) — distinct from
    /// Charity green / Extra Fund amber, and debt is a negative
    /// balance, so red reads correctly. Like the other two cards the
    /// amount and icon stay ink and the chevron muted grey; ONLY the
    /// outline keeps colour (owner, Nov 14, 2026 — "too much colors").
    case debt
    /// Spending (build 30): the weekly budget fund — the base
    /// allowance lives here. Blue outline #2f6bff (the primary /
    /// hero blue): this is the week's spending money.
    case spending

    /// Coloured outline of the card, loaded or loading: green
    /// #16a34a for Charity (its own token — NOT the success green,
    /// which went lighter Nov 14, 2026), amber #d97706 for Extra
    /// Fund, muted deep red #991b1b for Carried Debt. White inside —
    /// never a wash.
    public var outline: Color {
        switch self {
        case .charity: return DesignTokens.charity
        case .fund: return DesignTokens.fund
        case .debt: return DesignTokens.heroOverBudget
        case .spending: return DesignTokens.primary
        }
    }

    /// Outline width: 2px for both stat cards. The hero's is
    /// thicker (2.5px), so the hero stays the anchor card.
    public var outlineWidth: CGFloat { 2 }

    // NOTE (owner, Nov 14, 2026 — "too much colors"): there is
    // deliberately NO deep amount/icon colour on this theme any
    // more. The old `deep` property (charity #15803d, fund
    // #b45309) coloured the amount and icon; both are ink now and
    // the chevron is muted grey, so ONLY the outline above keeps
    // colour. The hex tokens stay in DesignTokens (the widget
    // still uses charityDeep; a smoke test pins fundDeepHex).

    /// SF Symbol for the card. There is no piggy-bank symbol, so
    /// Extra Fund uses a banknote; Charity uses a giving glyph.
    /// NOTE (build 17): the owner asked for a giving hand, but
    /// NEITHER "handshake.fill" NOR the unfilled "handshake"
    /// resolves — UIImage(systemName:) returned nil for both on
    /// iOS 18.5 (runs 43356758932 and 43365940363), while
    /// "banknote.fill" on the adjacent line resolved fine both
    /// times, so the handshake glyph is simply not available as a
    /// system symbol here. The fallback is a gift box
    /// ("gift.fill"), which reads as giving. Do not re-try
    /// "handshake" in either form.
    public var iconName: String {
        switch self {
        case .charity: return "gift.fill"
        case .fund: return "banknote.fill"
        case .debt: return "minus.circle.fill"
        case .spending: return "dollarsign.circle.fill"
        }
    }
}

/// One shimmer skeleton block: a muted grey rounded rectangle with
/// a soft white sweep travelling across it. Size it to the loaded
/// content it stands in for (same width/height), so the card holds
/// its size while loading. `animated: false` renders the same block
/// static — the muted placeholder used for a failed or empty value
/// face, which must NOT shimmer (a failed load is not a loading
/// state).
public struct SkeletonBlock: View {
    public let width: CGFloat?
    public let height: CGFloat
    public let cornerRadius: CGFloat
    public let animated: Bool
    @State private var sweep: CGFloat = -1.2

    public init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = 6, animated: Bool = true) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.animated = animated
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DesignTokens.skeleton)
            .frame(width: width, height: height)
            .overlay {
                if animated {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.55)
                        .offset(x: sweep * geometry.size.width * 1.55)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    sweep = 1.2
                }
            }
            .accessibilityHidden(true)
    }
}

/// Shimmer skeleton of one transaction row (40pt icon + two text
/// lines + amount), matching the loaded Recent / Transactions row
/// shape. Used for the Recent Transactions loading state on Home
/// and the Transactions list loading state.
public struct TransactionRowSkeleton: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(width: 40, height: 40, cornerRadius: 20)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 150, height: 14)
                SkeletonBlock(width: 100, height: 12)
            }
            Spacer()
            SkeletonBlock(width: 64, height: 16)
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}


// MARK: - Transaction icons / state pills
//
// `TransactionIconView` + `StatePill` live in
// Transactions/TransactionIconView.swift (integration, Nov 9, 2026):
// that copy has the state-based pill colours (live.js:199-220) and
// the size parameter + `TransactionIconLookup` icon maps, so the
// simpler SharedViews copies were deleted. `SourcePill` lives there
// too. Call sites use `TransactionIconView(merchant:institutionName:)`
// or `StatePill(_ transaction:)`.
