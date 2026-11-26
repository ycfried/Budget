// STAGE — SharedViews.swift
//
// Shared SwiftUI building blocks for the Auth + Home screens.
// Colours come from OnBudgetKit DesignTokens only — never hard-coded
// hex in a screen. Button rules (owner, Nov 3–4): two-button rows are
// primary blue first + grey tertiary second; pale #bfdbfe is the
// middle tier of a three-button row — and, since build 52 (owner,
// Nov 20, 2026), the full-width treatment for exactly two buttons
// that sit below a solid blue one (Top Up Budget under Calculate;
// Activity & Transactions under Add to Tzedaka); no two adjacent
// buttons share a colour/treatment. Back buttons are light blue
// #3b82f6, bold 700, 15px. Errors are soft red (bg #fef2f2, text
// #dc2626, border #fecaca). Toasts are a top popup (owner Nov 20,
// 2026), auto-dismiss 4s. Clone basis: live web v66.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import OnBudgetKit

// MARK: - Buttons

/// Primary: #2f6bff fill, white text. Build 64 (P-3): full-width
/// buttons are 10pt radius.
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .background(DesignTokens.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Pale middle tier: #bfdbfe fill, ink text. As the middle tier
/// of a three-button row — never beside another pale button — and,
/// since build 52 (owner, Nov 20, 2026), as the full-width
/// treatment for exactly two buttons that sit below a solid blue
/// one (Top Up Budget under Calculate; Activity & Transactions
/// under Add to Tzedaka). See `FundsPaleButton` (FundsShared) for
/// the Funds full-width version.
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Small variant of the Lean soft style for in-row actions
/// (e.g. the Transactions page-links row): a pale soft-blue
/// fill with a hairline border, ink text — a real button, not
/// a bare outline and not a solid blue block. Replaces the
/// outline and pale small styles (build 63, Lean).
public struct SmallSoftButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(DesignTokens.softFill)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignTokens.softBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Page select

/// Page select (build 63, Lean): the top segmented control on
/// Home and Funds — Home / Transactions / Funds, in that order,
/// the current page active. Build 66 (owner, Nov 23, 2026): a
/// WHITE floating card (soft shadow, centred in the shell by
/// AppShellView) instead of the build-65 grey left-aligned bar —
/// the Lean look was nicer — and the selected tab is a light-grey
/// floater on the white card (the old grey track colour, now the
/// pill, never a blue fill). Tapping a segment switches to that
/// tab. The selected pill SLIDES to the tapped tab (the Lean
/// glide, restored build 66 — build 65's instant jump read as
/// broken); the slide is the page-select exception to the
/// instant-change rule, which covers expand/collapse only.
/// Build 68 (owner, Nov 23, 2026 — "Header is small and ugly..
/// The slide bar is tiny.."): BIGGER and more prominent — larger
/// text (16pt), larger padding/tap targets, and a bigger/taller
/// sliding pill, so the header reads as a real control, not a
/// tiny sliver.
/// Owner, Nov 26, 2026 (approved treatment): MORE prominent
/// still — a stronger, softer shadow for lift, a hairline border
/// to define the edge, and slightly larger on iPad, where the
/// white pill blended into the large light background.
public struct PageSelectControl: View {
    @Binding var selectedTab: AppTab
    /// Build 66: the namespace for the sliding indicator — the
    /// selected pill glides between segments via
    /// matchedGeometryEffect (see the background below).
    @Namespace private var indicatorNamespace
    /// Owner, Nov 26, 2026: the regular size class is the iPad
    /// proxy — the control grows slightly there.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(selectedTab: Binding<AppTab>) {
        self._selectedTab = selectedTab
    }

    /// Slightly larger on iPad (regular size class): 17pt text
    /// and roomier tap targets instead of 16pt.
    private var isPad: Bool { horizontalSizeClass == .regular }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                // Build 77 (owner, Nov 25, 2026 — tap targets):
                // the whole segment must be tappable, not just
                // the centred label — same plain-button hit-area
                // fix as SquarishPicker.
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: isPad ? 17 : 16, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DesignTokens.ink : DesignTokens.segmentInactive)
                        .padding(.vertical, isPad ? 14 : 12)
                        .padding(.horizontal, isPad ? 24 : 20)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(DesignTokens.track)
                                        .matchedGeometryEffect(id: "pageSelectIndicator", in: indicatorNamespace)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pageSelect.\(tab.rawValue.lowercased())")
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                // Owner, Nov 26, 2026 (approved treatment): more
                // lift — a stronger, softer shadow — plus a
                // hairline border, so the pill reads as floating
                // on the iPad's large light background instead of
                // blending into it.
                .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(DesignTokens.tertiary, lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: selectedTab)
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
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DesignTokens.primary, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .background(DesignTokens.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
/// no border. This is the ONE back implementation (audit X-P2-7,
/// Nov 12 2026): the Funds inline duplicate and the
/// `BackButtonStyle()` toolbar call sites all route through here
/// now; the rendering itself lives in `BackButtonStyle`, used by
/// this view and nothing else.
/// Bare chevron, no text (owner, Nov 16, 2026 — build 40): the
/// "← Back" TEXT truncated to "← ..." on the Trash page — the
/// centred inline title squeezes the leading toolbar item — and
/// the owner confirmed "That needs to be fixed here and anywhere
/// else it exists.." The same truncation had already forced the
/// Choose Dates calendar toolbar to a bare chevron (owner, Nov 15,
/// 2026). A symbol cannot truncate, so every back button in the
/// app is now a clean chevron and the "..." cannot appear on any
/// screen. The style (light blue #3b82f6, bold 700, 15px,
/// top-left) is unchanged; only the label went from text to a
/// symbol.
public struct BackButton: View {
    public let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
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
/// root + this header keeps the content at the top of the sheet. When
/// onBack is given, the leading control is a back chevron that
/// returns to the previous step instead of closing. Build 70
/// (item 2): the header also attaches the swipe-right-to-dismiss
/// gesture (`.sheetSwipeBack()`), so every sheet/cover using it
/// gets swipe-right matching the top-left button — on a multi-step
/// sheet the swipe calls onBack instead of dismissing.
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
            // Build 74 (B24): headlines are Title Case — the
            // header applies it, so a raw-title call site can
            // never slip a capital minor word through again.
            Text(TitleCase.apply(to: title))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        // Build 70, item 2 (owner, Nov 24, 2026): swipe-right
        // dismisses the sheet/cover, matching the top-left back /
        // close button. Every sheet/cover that uses a SheetHeader
        // gets it from here; covers whose root is a NavigationStack
        // or a plain VStack apply `.sheetSwipeBack()` directly.
        // The header's own onBack is passed through, so on a
        // multi-step sheet the swipe returns to the previous step
        // (like the back chevron) instead of dismissing.
        .sheetSwipeBack(onBack: onBack)
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
    /// Build 77 (owner, Nov 25, 2026 — tap targets): the whole
    /// box focuses the field — tapping the "$" or the edge
    /// padding used to do nothing, only the field itself
    /// registered. Setting focus is idempotent, so a tap that
    /// also lands on the field itself is harmless.
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, placeholder: String = "0.00", maxWidth: CGFloat? = 220, minHeight: CGFloat = 48) {
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
                // Dark Mode (owner's father, Nov 26, 2026): the
                // field background is hardcoded white, so the typed
                // text must be explicit ink — the system default is
                // white in Dark Mode and invisible on white.
                .foregroundStyle(DesignTokens.ink)
                .keyboardType(.decimalPad)
                .focused($isFocused)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: maxWidth, minHeight: minHeight, alignment: .leading)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
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
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Whole-area tap target (owner, Nov 15, 2026 app-wide
            // pass): the padded box responds across its full frame.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Date, \(Self.displayFormatter.string(from: date))")
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(isPresented: $showingPicker) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Choose Date", onClose: { showingPicker = false })
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Button("Done") { showingPicker = false }
                    .buttonStyle(PrimaryButtonStyle())
                // Build 43 (owner, Nov 17, 2026 — item 18): the
                // trailing Spacer top-anchors the content in the
                // full-screen cover — without it the picker and
                // button centre themselves vertically in the
                // full screen.
                Spacer()
            }
            .padding()
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
/// S logo + "T · A · G · E" wordmark, "Spend Track And Give Easily"
/// (build 74 — bold initials spell STAGE; owner, Nov 26, 2026 —
/// "Spend Track And Give Easily" replaces "Spending Tracking And
/// Giving Easily").
/// Shown on first paint and kept until the first data load
/// completes or fails — never a blank or half-built page, and never
/// an endless spinner with no error. Build 65: logo + tagline
/// ONLY — no skeleton blocks at all (the owner read the three grey
/// bars below the wordmark as stray boxes / a bug, and the
/// BrandedLoader skeleton halo behind the logo the same way).
/// The skeletons belong on the Home screen itself (its
/// card-shaped skeletons), not on the splash. Build 66 (owner,
/// Nov 23, 2026): the splash WITHOUT any loading indicator read
/// as frozen — a subtle brand-blue arc ring circles the logo
/// while the app loads. This ring is the branded splash
/// exception to the no-spinner rule (a thin arc around the logo,
/// not a generic spinner); the three grey skeleton bars stay gone.
public struct LoadingView: View {
    /// Drives the loading ring's rotation (false → true on appear,
    /// then repeating — the same pattern as the sync button's spin).
    @State private var ringSpinning = false
    public init() {}
    public var body: some View {
        VStack(spacing: 6) {
            // ONE horizontal line (owner, Nov 20, 2026 — build 50):
            // the S logo IS the S of STAGE — the logo (larger, the
            // main part, with its animated brand-blue ring) + "T ·
            // A · G · E" beside it, a blue dot between the S and
            // the T, reading as one word S · T · A · G · E. The
            // stacked layout read as "S" then "TAGE".
            HStack(spacing: 4) {
                // The real logo (Assets.xcassets/AppLogo), not the "S"
                // placeholder ring (owner, Nov 11, 2026) — plain,
                // no skeleton halo: build 65, the splash holds no
                // skeleton blocks at all (the BrandedLoader halo
                // read as a stray box / bug, like the bars below).
                // BrandedLoader itself is untouched — it is still
                // used by other loading states (see its uses).
                // Build 66: a subtle loading ring circles the logo
                // (see the comment on LoadingView) — just the
                // brand-blue arc rotating slowly, so the splash
                // reads as loading, not frozen. Owner, Nov 26,
                // 2026: the light full-circle track ring is gone —
                // it read as an ugly pale circle; only the darker
                // arc moves around the logo now. The ring sits 7pt
                // outside the 72pt logo (build 74 FINAL — the 48pt
                // mark was wrong; the S is not shrunk).
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(DesignTokens.stageBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 86, height: 86)
                        .rotationEffect(.degrees(ringSpinning ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: ringSpinning)
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                }
                .onAppear { ringSpinning = true }
                // The S logo IS the S of STAGE (owner, Nov 18, 2026 —
                // build 47): the logo + "T · A · G · E", never the logo
                // next to the full word "STAGE" (no second S).
                // Build 74 (owner, Nov 25, 2026 — DECIDED, FINAL
                // proportions, ~00:59): STAGE on ONE LINE — the
                // mark (72pt, its previous size — NOT shrunk) +
                // letters (40pt medium, sized up from 32pt light)
                // tight together (4pt gap), reading left to right
                // as a single word; the stacked version is wrong.
                // Uniform stageBlue #0288dd.
                StageWordmarkText(font: .system(size: 40, weight: .medium))
            }
            // Build 74 (owner, Nov 25, 2026 — DECIDED): the tagline
            // is "Spend Track And Give Easily" — NO periods,
            // and the FIRST LETTER of each word is BOLD so the bold
            // initials spell STAGE. Owner, Nov 26, 2026: "Spend
            // Track And Give Easily" replaces "Spending Tracking
            // And Giving Easily" (build 74) — same 15pt semibold
            // base, same uniform stageBlue #0288dd; only the
            // initials are heavy. The tagline sits BELOW the
            // one-line lockup, 6pt under it (the VStack spacing —
            // was 12pt, and the tagline floated too far below
            // STAGE).
            (
                Text("S").fontWeight(.heavy)
                + Text("pend ")
                + Text("T").fontWeight(.heavy)
                + Text("rack ")
                + Text("A").fontWeight(.heavy)
                + Text("nd ")
                + Text("G").fontWeight(.heavy)
                + Text("ive ")
                + Text("E").fontWeight(.heavy)
                + Text("asily")
            )
                .foregroundStyle(DesignTokens.stageBlue)
                .font(.system(size: 15, weight: .semibold))
            // Build 65 (owner, Nov 23, 2026): NO skeleton bars
            // here — the three grey bars read as stray boxes / a
            // bug on the splash. The splash is logo + tagline
            // only; the skeletons belong on the Home screen
            // itself (its card-shaped skeletons), not here.
            // (Build 64, F-35, had put hero- + fund-card-shaped
            // SkeletonBlocks here; they are removed, not moved.)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
    }
}

// MARK: - Branded loader

/// Branded loading indicator (owner, Nov 14, 2026): the real app
/// logo. Build 64 (F-35): the spinning ring is GONE — the loading
/// rule forbids spinners, and the ring was one. The logo is static
/// now; the only motion is the skeleton shimmer behind it (a
/// circular SkeletonBlock the size of the logo + ring, the same
/// shimmer language every loading state already uses), so the mark
/// reads as a skeleton of the content that follows rather than a
/// spinner. Where a shimmer skeleton already stands in for the
/// content, keep the skeleton and do NOT stack this on top of it.
/// The sync button's rotating arrow is a different thing (the sync
/// affordance the owner approved) and is untouched.
public struct BrandedLoader: View {
    /// Logo size; the skeleton halo sits 6pt outside it on every side.
    public let size: CGFloat

    public init(size: CGFloat = 56) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            SkeletonBlock(width: size + 12, height: size + 12, cornerRadius: (size + 12) / 2)
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
        .accessibilityLabel("Loading")
    }
}

// MARK: - Swipe-back gesture (build 68, item 18)
//
// The edge-swipe-back gesture stopped navigating back: only the
// back button worked. Hiding the navigation bar (the Transactions
// stack and the Settings cover both use `.toolbar(.hidden, for:
// .navigationBar)` with their own chevron back buttons) turns the
// navigation controller's interactive pop gesture off, so a
// left-edge swipe does nothing. This re-enables it: a tiny hosted
// view controller that finds its navigation controller and forces
// the gesture recogniser back on whenever its view appears or
// lays out (SwiftUI re-disables it when a new screen is pushed,
// so a one-time call is not enough). The delegate is deliberately
// left alone — SwiftUI owns it, and only the enabled flag is
// forced. Attach with `.enableSwipeBack()` inside any
// NavigationStack content (the Transactions tab + its subpages,
// the Settings cover). No behaviour changes besides the gesture:
// the back buttons keep working exactly as before.
public struct SwipeBackEnabler: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> UIViewController {
        SwipeBackViewController()
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class SwipeBackViewController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enablePopGesture()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            enablePopGesture()
        }

        private func enablePopGesture() {
            guard let navigationController else { return }
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

public extension View {
    /// Restore the left-edge swipe-back gesture inside a
    /// NavigationStack whose bar is hidden (build 68, item 18).
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }

    /// Swipe-right-to-dismiss for a presented sheet or full-screen
    /// cover (build 70, item 2). Attach to the content root of a
    /// sheet or cover; `SheetHeader` applies it itself, so every
    /// sheet/cover that uses a SheetHeader gets it for free.
    /// When `onBack` is given (a multi-step sheet whose header
    /// back chevron returns to a previous step), the swipe calls
    /// it instead of dismissing — swipe-right behaves exactly
    /// like the back button.
    func sheetSwipeBack(onBack: (() -> Void)? = nil) -> some View {
        background(SheetSwipeBackEnabler(onBack: onBack))
    }
}

// MARK: - Swipe-right-to-dismiss for sheets and full-screen covers

/// Swipe-right-to-dismiss for a presented sheet or full-screen
/// cover (build 70, item 2 — owner, Nov 24, 2026): EVERY popup
/// and page-within-a-page must have a back button (top left) AND
/// a working swipe-right-to-go-back. Sheets dismiss by swiping
/// down natively, but full-screen covers have NO dismiss gesture
/// at all — the only way out was a Cancel button. This adds a
/// left-edge swipe-right that dismisses the presented view
/// controller, mirroring the navigation pop gesture. When `onBack`
/// is given (a multi-step sheet whose header back chevron returns
/// to a previous step), the swipe calls it instead of dismissing
/// — swipe-right behaves exactly like the back button.
///
/// A UIScreenEdgePanGestureRecognizer only fires for touches that
/// START at the screen's left edge, so a slider or other
/// horizontal control in the middle of the sheet is never stolen.
/// The delegate additionally refuses to begin when:
///   - a subpage is pushed inside the sheet/cover (the embedded
///     navigation controller has more than one view controller) —
///     the navigation pop gesture owns the edge swipe there, and
///     this dismiss must not fire under it; or
///   - the touch lands inside a UIControl (a slider thumb parked
///     at 0% sits at the left edge) — the control keeps the touch.
/// Attach with `.sheetSwipeBack()` on the content root of a sheet
/// or cover. No behaviour changes besides the gesture: the back
/// and close buttons keep working exactly as before.
public struct SheetSwipeBackEnabler: UIViewControllerRepresentable {
    /// Called instead of dismissing when set (a multi-step
    /// sheet's back step). Updated as the sheet's flow changes.
    public let onBack: (() -> Void)?

    public init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = SheetSwipeBackViewController()
        controller.onBack = onBack
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // The back step changes as the sheet's flow changes (the
        // Actions sheet's header goes X → chevron when a sub-flow
        // opens) — keep the hosted controller's copy current.
        if let controller = uiViewController as? SheetSwipeBackViewController {
            controller.onBack = onBack
        }
    }

    private final class SheetSwipeBackViewController: UIViewController, UIGestureRecognizerDelegate {
        var onBack: (() -> Void)?
        private var edgePan: UIScreenEdgePanGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachEdgePan()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attachEdgePan()
        }

        private func attachEdgePan() {
            guard edgePan == nil else { return }
            guard let target = presentedViewController() else { return }
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            pan.edges = .left
            pan.delegate = self
            target.view.addGestureRecognizer(pan)
            edgePan = pan
        }

        /// The presented view controller hosting this sheet/cover:
        /// this hosted VC is a child of the sheet's hosting
        /// controller, which is the presented VC (its
        /// presentingViewController is set). Walk up until the
        /// presented one is found; nil when this view is not
        /// inside a presented sheet/cover (then nothing attaches).
        private func presentedViewController() -> UIViewController? {
            var current: UIViewController? = parent
            while let vc = current {
                if vc.presentingViewController != nil { return vc }
                current = vc.parent
            }
            return nil
        }

        /// The navigation controller embedded in this sheet/cover
        /// (if any) — a NavigationStack embeds one as a child of
        /// the hosting controller.
        private func embeddedNavigationController(in root: UIViewController) -> UINavigationController? {
            for child in root.children {
                if let nav = child as? UINavigationController { return nav }
                if let found = embeddedNavigationController(in: child) { return found }
            }
            return nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer,
                  let target = presentedViewController() else { return false }
            // A pushed subpage owns the edge swipe: the navigation
            // controller's interactive pop gesture pops it. This
            // dismiss only fires on the sheet/cover's root page.
            if let nav = embeddedNavigationController(in: target), nav.viewControllers.count > 1 {
                return false
            }
            // A control under the touch (a slider thumb parked at
            // the left edge, a full-width button) keeps the touch
            // — the sheet must not steal a drag the user meant for
            // the control.
            let point = pan.location(in: target.view)
            if let hit = target.view.hitTest(point, with: nil) {
                var view: UIView? = hit
                while let current = view {
                    if current is UIControl { return false }
                    view = current.superview
                }
            }
            return true
        }

        @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            // A back step, when the sheet has one (a sub-flow) —
            // otherwise dismiss the sheet/cover.
            if let onBack {
                onBack()
            } else {
                presentedViewController()?.dismiss(animated: true)
            }
        }
    }
}

// MARK: - Expand / collapse animation

// Expand/collapse is INSTANT — no animation at all (owner
// decision, Nov 15, 2026 — build 34). The shared ExpandAnimation
// (0.25s easeInOut, .move transition) is deleted: the no-fade
// height-only version from build 32 was still ugly, because the
// problem was the motion itself — the row growing and the list
// below it jumping — not the fade. Tap a row or card and it just
// opens or closes immediately: no motion, no fade, no slide, no
// spring. Do NOT reintroduce an expand/collapse animation.
// (Sheets keep the system presentation animation; sync spinners,
// loader rings, and toasts keep theirs — those are not
// expand/collapse.)

// MARK: - Toast

/// Transient popup notification (owner, Nov 20, 2026 — build 50):
/// a nicer-looking popup, NOT a blocking modal and NOT a centered
/// box (centered toasts were "horrendous"). A status icon leads —
/// green check for success, red X for error, blue info for info —
/// then the message, with an X in the top corner to close early.
/// Success is the Posted badge treatment (light green #dcfce7 /
/// dark green #166534), errors are soft red, info is brand blue.
/// Auto-dismiss 4s (ToastStyle.autoDismissSeconds); tap dismisses
/// sooner — the overlay's tap-anywhere background also dismisses
/// it. It spans a good portion of the screen width (up to the
/// 900pt iPad column), never a thin strip.
public struct ToastBanner: View {
    public let toast: Toast
    public let onDismiss: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    public init(toast: Toast, onDismiss: @escaping () -> Void) {
        self.toast = toast
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
    /// The leading status icon: a green check for success, a red X
    /// for error, a blue info mark for info (owner, Nov 20, 2026).
    private var iconName: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(bannerText)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(bannerText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(bannerText.opacity(0.7))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(16)
        .background(bannerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    toast.kind == .error ? DesignTokens.errorBorder : Color.clear,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        // A good portion of the screen width, up to the 900pt iPad
        // column — never a thin strip.
        .frame(maxWidth: horizontalSizeClass == .regular ? 900 : .infinity)
        .padding(.horizontal, 16)
    }
}

/// Overlays the current toast at the TOP of any screen, with the
/// 4-second auto-dismiss (ToastStyle.autoDismissSeconds — the one
/// shared value, CLONE_SPEC §2.3). (Owner, Nov 20, 2026 — build 50:
/// the centered popup was "horrendous"; the toast is a top popup
/// now, placed where it looks best — never forced to the bottom,
/// never centered.) A tap anywhere else on the page dismisses it:
/// the clear background below catches the tap, so the page under
/// it never receives a stray tap while the toast is up. The toast
/// itself is a small popup, never a modal — it never blocks the
/// page, it just sits on top of it for 4 seconds.
public struct ToastOverlayModifier: ViewModifier {
    @Binding public var toast: Toast?
    public var enabled: Bool
    public init(toast: Binding<Toast?>, enabled: Bool = true) {
        self._toast = toast
        self.enabled = enabled
    }
    public func body(content: Content) -> some View {
        content.overlay {
            if enabled, let toast {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        // Tap anywhere else dismisses (owner,
                        // Nov 20, 2026). Clear, so the page shows
                        // through — but it still catches the tap.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { self.toast = nil }
                        ToastBanner(toast: toast) { self.toast = nil }
                            .padding(.top, proxy.safeAreaInsets.top + 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
                    if self.toast?.id == toast.id { self.toast = nil }
                }
            }
        }
    }
}

public extension View {
    func toastOverlay(_ toast: Binding<Toast?>, enabled: Bool = true) -> some View {
        modifier(ToastOverlayModifier(toast: toast, enabled: enabled))
    }

    /// Main tab content width (build 36, owner Nov 16, 2026 — iPad):
    /// on iPad (regular size class) the tabs read as a centered
    /// 900pt column — clearly wider than the 600pt sheet columns
    /// used elsewhere on iPad, and never stretched edge-to-edge on
    /// a wide screen. On iPhone (compact) the content stays
    /// full-width, unchanged.
    func mainContentWidth(horizontalSizeClass: UserInterfaceSizeClass?) -> some View {
        frame(maxWidth: horizontalSizeClass == .regular ? 900 : .infinity)
    }
}

// MARK: - Choice dialog
//
// App-styled choice dialog (owner, Nov 24, 2026 — build 74):
// system alerts render both buttons blue (`.default` + `.cancel`
// are the same blue), so every two-button confirmation uses this
// instead: a centred white card over a dim background, presented
// as a full-screen cover with a clear background (so it works
// from any view, like `.alert`), with the primary action solid
// blue (or soft-red for a destructive action) and the secondary
// grey — never two buttons in the same colour. A single-button
// dialog (secondaryTitle nil) renders one full-width primary.
// Informational confirmations are the top toast, not this dialog.
// The card sits in a ScrollView so a dialog with a field (the
// override-reason field) still clears the keyboard. Taps outside
// the card do nothing — a choice dialog needs a button, like the
// system alert it replaces.

/// One choice dialog: title + message + primary / secondary
/// buttons, rendered as a centred white card.
public struct AppConfirmDialog: View {
    public enum Tone { case primary, destructive }

    public struct Config {
        public var title: String
        public var message: String
        public var primaryTitle: String
        public var tone: Tone
        /// Nil renders a single full-width primary button.
        public var secondaryTitle: String?
        public var onPrimary: () -> Void
        public var onSecondary: (() -> Void)?
        /// Optional extra content between the message and the
        /// buttons (e.g. a reason field) — nil for a plain confirm.
        public var extra: AnyView?

        public init(title: String, message: String, primaryTitle: String, tone: Tone = .primary, secondaryTitle: String? = "Cancel", onPrimary: @escaping () -> Void, onSecondary: (() -> Void)? = nil, extra: AnyView? = nil) {
            self.title = title
            self.message = message
            self.primaryTitle = primaryTitle
            self.tone = tone
            self.secondaryTitle = secondaryTitle
            self.onPrimary = onPrimary
            self.onSecondary = onSecondary
            self.extra = extra
        }
    }

    let config: Config
    let onDismiss: () -> Void

    public init(config: Config, onDismiss: @escaping () -> Void) {
        self.config = config
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .center) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ScrollView {
                    VStack {
                        Spacer(minLength: 0)
                        card
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
        .presentationBackground(.clear)
        // Build 75 (audit — back+swipe gap): swipe-right
        // dismisses the dialog, matching the Cancel button.
        // No back button is added: the Cancel button is the
        // dialog's dismiss control, and an X would duplicate
        // it on a small card — see BUILD75-AUDIT.md.
        .sheetSwipeBack()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TitleCase.apply(to: config.title))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Text(config.message)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            if let extra = config.extra {
                extra
            }
            HStack(spacing: 12) {
                Button(TitleCase.apply(to: config.primaryTitle)) {
                    config.onPrimary()
                    onDismiss()
                }
                .buttonStyle(AppConfirmPrimaryButtonStyle(tone: config.tone))
                if let secondaryTitle = config.secondaryTitle {
                    Button(TitleCase.apply(to: secondaryTitle)) {
                        config.onSecondary?()
                        onDismiss()
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
            }
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .fundCardShadow()
        .padding(.horizontal, 20)
        .frame(maxWidth: 480)
    }
}

/// The dialog's primary button: solid brand blue, or the soft-red
/// delete treatment (the FundsDangerButton colours — soft-red bg
/// #fef2f2, red text #dc2626) for a destructive action. Same
/// size/shape as PrimaryButtonStyle.
private struct AppConfirmPrimaryButtonStyle: ButtonStyle {
    let tone: AppConfirmDialog.Tone
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tone == .destructive ? DesignTokens.errorText : .white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(tone == .destructive ? DesignTokens.errorBackground : DesignTokens.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

public extension View {
    /// Present the app-styled choice dialog (see AppConfirmDialog).
    func appConfirmDialog(isPresented: Binding<Bool>, title: String, message: String, primaryTitle: String, tone: AppConfirmDialog.Tone = .primary, secondaryTitle: String? = "Cancel", extra: AnyView? = nil, onPrimary: @escaping () -> Void, onSecondary: (() -> Void)? = nil) -> some View {
        fullScreenCover(isPresented: isPresented) {
            AppConfirmDialog(
                config: AppConfirmDialog.Config(title: title, message: message, primaryTitle: primaryTitle, tone: tone, secondaryTitle: secondaryTitle, onPrimary: onPrimary, onSecondary: onSecondary, extra: extra),
                onDismiss: { isPresented.wrappedValue = false }
            )
        }
    }

    /// Item-driven variant — mirrors `.alert(item:)`: while the
    /// item is non-nil the dialog shows, built from that item.
    /// Dismissal clears the item ONLY if it is still the item the
    /// dialog opened for — a primary action that advances the
    /// state machine (e.g. delete step one → step two, by setting
    /// a new alert value) must not have its next step wiped by
    /// the dismiss that follows it.
    func appConfirmDialog<Item: Identifiable>(item: Binding<Item?>, config: @escaping (Item) -> AppConfirmDialog.Config) -> some View {
        fullScreenCover(item: item) { value in
            AppConfirmDialog(
                config: config(value),
                onDismiss: { if item.wrappedValue?.id == value.id { item.wrappedValue = nil } }
            )
        }
    }
}

// MARK: - Cards

/// Standard white card: radius 12, hairline shadow (styles.css:388;
/// build 64, P-3 — one radius system: cards 12pt everywhere).
public struct Card<Content: View>: View {
    public let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                    radius: 2, x: 0, y: 1)
    }
}

// MARK: - Fund cards (build 41)
//
// Fund-card lift (owner, Nov 16, 2026 — build 41: "These need to
// be much bigger and look like cards.. a small shadow below each
// card.."). ONE shared value so the Home hero + stat cards and the
// Funds page's FundsExpandableCard all lift identically — the
// shadow is the card look, not a per-screen tweak. Small and soft
// (10% black, 8pt blur, 4pt down): clearly visible against the
// page, never heavy. The older hairline shadow above (5%, radius
// 2, y 1) is invisible against the page — that is why the build-33
// outer wrapper was dropped — so fund cards do NOT reuse it.
// Applied to the clipped card container, AFTER the clip, so the
// shadow follows the card's rounded corners.
public extension View {
    func fundCardShadow() -> some View {
        shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
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

// MARK: - Stat-card themes (owner direction, Nov 12 2026;
// the coloured-outline design (Charity green / Extra Fund
// amber / Debt muted red / Spending blue, 2px on a white card)
// was SUPERSEDED Nov 16, 2026 (owner choice, Mockup C): the
// outlines did not fit the branding and the thin lines read
// cheap/childish. Each fund is now a SECTION with a COLOURED
// BANNER — the banner holds the icon, name and amount in white,
// and the detail below it sits on plain white, with no outline
// or border anywhere. The Home + Funds cards share ONE theme
// each (same banner colour, icon, amount size on both screens).
// While loading the banner is a muted grey block with grey
// skeleton faces — no colour until the numbers arrive.

/// The shared banner identity of a fund section.
public enum StatCardTheme {
    case charity
    case fund
    /// Carried Debt (build 29): black ink banner.
    case debt
    /// Spending (build 30): the weekly budget fund — the base
    /// allowance lives here. DEEP blue banner #1d4ed8 with WHITE
    /// text since build 46 (owner, Nov 18, 2026 — the light blue
    /// #60a5fa banner from build 43 was "a new/medium blue, not
    /// the dark blue from the branding": the header goes back to
    /// the brand dark blue — DesignTokens.deep, the Income colour
    /// and the build-39 Spending banner — with white text on it,
    /// as Mockup C originally had it. White on #1d4ed8 reads
    /// ~5.9:1. Deep — not primary #2f6bff — so Spending stays the
    /// darkest fund header on both the Home hero and the Funds
    /// page).
    case spending

    /// Banner colour of the fund section — the 3-BUTTON SCHEME
    /// (owner, Nov 16, 2026 — build 41: "The 3 card header bars
    /// should be the same color as the 3 buttons schem we have").
    /// The three visible fund headers use the three button
    /// colours, one system — as build 41 set them, except Spending
    /// (build 46, owner Nov 18, 2026: the build-43 light blue
    /// #60a5fa was the wrong blue, so Spending leaves it for DEEP
    /// blue #1d4ed8, the Income colour; Charity stays PALE #bfdbfe,
    /// Extra Fund TERTIARY grey #e5e7eb). Carried Debt keeps black
    /// ink #0f172a (the owner said three bars — the debt card is
    /// not one of them).
    /// History: build 38 corrected the Mockup C assignment, build
    /// 39 refined it ("Coloring still doesn't look great") to
    /// Spending deep blue #1d4ed8, Charity MID blue #3b82f6, Extra
    /// Fund MUTED grey #6b7280 with white text on all four — the
    /// owner then said the Savings grey was "way too dark.. not our
    /// brand" and asked for the button scheme instead, so build 41
    /// replaces those three banner colours. Build 43 lightened
    /// Spending to #60a5fa for black header text; build 46 returns
    /// it to deep #1d4ed8 with white text. The green (#16a34a) /
    /// amber (#d97706) / muted-red (#991b1b) outlines are gone from
    /// the fund cards.
    /// Build 48 (owner, Nov 19, 2026 — "the Savings card on Home
    /// is still grey"): Savings leaves the tertiary grey for its
    /// own colour, the fund amber #b45309 (`fundDeep` — the Extra
    /// Fund's historical deep colour, kept in DesignTokens and
    /// pinned by a smoke test). Grey is not a fund colour; the
    /// Savings header is now amber on Home AND on the Funds page
    /// (both read this one theme), with white text on it (~5:1).
    /// SUPERSEDED build 56 (owner, Nov 22, 2026): the brown/rust
    /// is NOT in the branding — Savings goes back to the brand
    /// grey, MUTED #6b7280, on Home AND on the Funds page (both
    /// read this one theme), with white text on it (~4.8:1).
    /// The brown #b45309 (`fundDeep`) stays in DesignTokens as a
    /// FUTURE candidate for the Spending fund colour — the owner
    /// likes it for Spending — but is NOT applied anywhere now;
    /// Spending stays deep blue #1d4ed8.
    /// SUPERSEDED build 57 (owner, Nov 22, 2026 — "This grey
    /// isn't bad but it's not the one from our branding"): the
    /// muted #6b7280 is secondary-text grey, NOT the brand grey.
    /// The brand grey is the TERTIARY grey #e5e7eb — the third
    /// button colour in the build-41 3-button scheme the fund
    /// headers follow (primary blue / pale / tertiary grey). So
    /// Savings is back to tertiary #e5e7eb, with INK text on it
    /// (white is unreadable on a light banner — same as the pale
    /// Charity banner). The muted #6b7280 stays as the Savings
    /// glyph and number — the readable grey on white — and the
    /// brown #b45309 stays a future Spending candidate.
    public var banner: Color {
        switch self {
        case .charity: return DesignTokens.pale
        case .fund: return DesignTokens.tertiary
        case .debt: return DesignTokens.ink
        case .spending: return DesignTokens.deep
        }
    }

    /// Text colour on the banner — per theme now (owner, Nov 16,
    /// 2026 — build 41, updated build 43, updated build 46, updated
    /// build 48, updated build 56, updated build 57): WHITE on the
    /// dark banners (Debt ink, Spending deep #1d4ed8 — white on deep
    /// reads ~5.9:1), INK on the light banners — Charity pale
    /// #bfdbfe (white text is unreadable on it, ~1.6:1; ink reads
    /// ~12:1) and Savings tertiary #e5e7eb (build 57 — white on the
    /// light brand grey is unreadable; ink, like the tertiary
    /// button's own ink text). The title and amount are large bold
    /// text. (Build 39 had white on all four — the build-39 banners
    /// were all dark enough for it; the build-41 light banners are
    /// not. Build 48 moved Savings off the light tertiary grey onto
    /// amber, so it takes white text too; build 56 moves it back to
    /// the brand grey, keeping white text; build 57 corrects the
    /// grey to tertiary #e5e7eb, which takes INK text.)
    public var onBanner: Color {
        switch self {
        case .charity, .fund: return DesignTokens.ink
        case .debt, .spending: return .white
        }
    }

    /// Icon colour on the WHITE disc in the header. The icon
    /// cannot be the banner colour on the light banners — pale
    /// #bfdbfe on white is invisible — so each fund keeps a
    /// readable glyph: Spending PRIMARY #2f6bff (the strong brand
    /// blue — it still reads on the white disc; the banner is deep
    /// #1d4ed8 again since build 46, and the primary glyph reads
    /// on white against it), Charity MID blue #3b82f6 (its
    /// build-39 banner — the charity blue identity, 3.7:1 on
    /// white), Extra Fund MUTED grey #6b7280 — ~4.8:1 on white
    /// (build 57: the banner is the tertiary grey #e5e7eb, which
    /// would be invisible on the white disc, so the glyph keeps
    /// the readable muted grey; the build-48 amber #b45309 is kept
    /// as a future Spending candidate, not applied), Debt ink.
    public var glyph: Color {
        switch self {
        case .charity: return DesignTokens.mid
        case .fund: return DesignTokens.muted
        case .debt: return DesignTokens.ink
        case .spending: return DesignTokens.primary
        }
    }

    // NOTE (owner, Nov 14, 2026 — "too much colors", and Nov 16,
    // 2026 — banners): there is deliberately NO deep amount/icon
    // colour on this theme any more. The old `deep` property
    // (charity #15803d, fund #b45309) coloured the amount and
    // icon; the banner now carries the colour instead, and the
    // amount/icon/chevron inside it are white. The hex tokens stay
    // in DesignTokens (the widget still uses charityDeep; a smoke
    // test pins fundDeepHex).

    /// The card's number colour on the white card BODY (build 46 —
    /// the simpler Home, owner Nov 18, 2026: "number colour =
    /// header colour"). The number is the same colour family as
    /// the header, at a depth that reads well on white: Spending
    /// the brand dark blue #1d4ed8 (its banner, 5.9:1 on white),
    /// Tzedaka the primary blue #2f6bff (4.4:1), Savings the
    /// muted grey #6b7280 — ~4.8:1 (build 57: the banner is the
    /// tertiary grey #e5e7eb, which would be invisible on white,
    /// so the number keeps the readable muted grey; the build-48
    /// amber #b45309 is kept as a future Spending candidate, not
    /// applied), Overspent (Past) ink #0f172a.
    /// The CLASSIC Home keeps its all-ink numbers — this colour
    /// applies in the simple layout AND on the Funds page body
    /// (build 50: the Funds amount moved off the banner into the
    /// white body, so it takes this colour there). An over-budget
    /// Spending amount is
    /// NOT this colour: it stays `heroOverBudget` red #991b1b, so
    /// the over-budget signal is never lost.
    public var number: Color {
        switch self {
        case .charity: return DesignTokens.primary
        case .fund: return DesignTokens.muted
        case .debt: return DesignTokens.ink
        case .spending: return DesignTokens.deep
        }
    }

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

/// Skeleton rows that fill the visible page (owner, Nov 26, 2026 —
/// skeletons must fill the whole visible page, never a few rows
/// floating in empty space). `rowHeight` is one loaded row's full
/// height in points (content + vertical padding + divider);
/// `above` is the height of the page content above the list
/// (title, headers, explainer, card chrome). The count is computed
/// from the screen height so it fills on every device — a fixed
/// representative count (2 member rows, 3 expense rows) left the
/// page looking empty. Rounded up so the last row reaches the
/// bottom of the screen; the skeleton→content swap may still
/// change height when the real content is shorter — that one-time
/// swap is accepted, the loading state itself must not look empty.
public enum SkeletonFill {
    public static func rows(rowHeight: CGFloat, above: CGFloat) -> Int {
        let visible = UIScreen.main.bounds.height - above
        return max(3, Int(ceil(visible / rowHeight)))
    }
}

/// Shimmer skeleton of one transaction row (40pt icon + two text
/// lines + amount), matching the loaded Home Recent row shape:
/// 40pt icon + 2pt top/bottom padding = 44pt tall, so a skeleton
/// row and a loaded row occupy exactly the same height (owner,
/// Nov 26, 2026 — Home is NOT scrollable; the skeleton and the
/// loaded list must match exactly). Used for the Recent
/// Transactions loading state on Home and the Transactions list
/// loading state (there it sits inside 14pt padding, so the
/// shorter row only makes the skeleton card a little shorter
/// while loading — the list scrolls and the loaded rows replace
/// it).
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
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}


// MARK: - Transaction icons / state label
//
// `TransactionIconView` + `StatePill` live in
// Transactions/TransactionIconView.swift (integration, Nov 9, 2026):
// that copy has the size parameter + `TransactionIconLookup` icon
// maps, so the simpler SharedViews copies were deleted. `StatePill`
// is plain grey text (owner, Nov 17, 2026 — build 42, badge
// Version A: no pills, no tint); `SourcePill` was deleted in
// build 42 (the source shows only in the expanded row detail).
// Call sites use `TransactionIconView(merchant:institutionName:)`
// or `StatePill(_ transaction:)`.
