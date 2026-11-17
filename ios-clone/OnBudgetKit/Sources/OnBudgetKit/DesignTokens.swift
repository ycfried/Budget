#if canImport(SwiftUI)
import SwiftUI
#endif
import Foundation

/// Design tokens from the live web app (v66), carried over verbatim.
/// Single source of truth for brand colours — screens must use these,
/// never hard-coded hex values.
public enum DesignTokens {
    // MARK: - Brand blues

    public static let primaryHex = "#2f6bff"
    public static let deepHex = "#1d4ed8"
    public static let midHex = "#3b82f6"
    public static let lightHex = "#60a5fa"
    public static let paleHex = "#bfdbfe"

    // MARK: - Neutrals

    public static let backgroundHex = "#ffffff"
    public static let inkHex = "#0f172a"
    /// Muted secondary text (#6b7280) and the info-box background
    /// (#eef4ff) — tokens since audit X-P2-8 (Nov 12 2026); screens
    /// must use these, never the raw hex.
    public static let mutedHex = "#6b7280"
    /// Light grey banner for the Extra Fund (owner, Nov 16, 2026 —
    /// build 38: the medium grey #6b7280 banner was the wrong
    /// colour; the fund's banner is light grey #d1d5db, with dark
    /// ink text on it). RETIRED from banners in build 39 (owner,
    /// Nov 16, 2026 — "Coloring still doesn't look great"): the
    /// light grey read as washed-out and as an empty/dead card at
    /// $0.00 — Extra Fund is muted grey #6b7280 with white text
    /// again. The token stays (tokens are never deleted), but no
    /// fund card reads it any more.
    public static let bannerLightGreyHex = "#d1d5db"
    /// Loading-banner tint (owner, Nov 16, 2026 — build 38): the
    /// solid muted grey #e5e7eb banner read as a FINISHED grey card,
    /// not a placeholder. While loading the banner is this pale
    /// brand-blue tint #dbeafe with shimmer skeleton blocks for
    /// the name and amount — it reads as a placeholder, in the
    /// brand, consistent with the app's skeleton loading style.
    /// The failed/error banner stays the muted grey #e5e7eb, so a
    /// failed load still reads as distinct from loading.
    public static let loadingBannerHex = "#dbeafe"
    public static let infoBackgroundHex = "#eef4ff"

    // MARK: - Soft-red errors (owner rule, Nov 5 2026: light background,
    // dark red text — never a hard red fill)

    public static let errorBackgroundHex = "#fef2f2"
    public static let errorTextHex = "#dc2626"
    public static let errorBorderHex = "#fecaca"

    // MARK: - Hero over-budget red (owner rule, Nov 14 2026: the
    // Spending hero's negative figure + progress bar in the bright
    // error red #dc2626 were too stark — "too much colors". This
    // quieter, deeper muted red is the over-budget signal ONLY on
    // the hero figure and its progress bar. The bright errorText
    // above stays for error text, toasts, and failed loads.)

    public static let heroOverBudgetHex = "#991b1b"

    // MARK: - Success green (owner rule, Nov 11 2026: success toasts
    // are GREEN, not blue — native only; the web app keeps brand-blue
    // toasts. Info toasts stay brand blue. Owner, Nov 14, 2026: the
    // green was too dark — #16a34a → #22c55e, lighter and brighter,
    // white text still readable on banners. Charity keeps its own
    // deeper green below (charityHex) — the card outline does NOT
    // follow this token.)

    public static let successHex = "#22c55e"

    // Toast success colours (owner, Nov 15, 2026): the success toast
    // used to be a solid #22c55e bar with white text — the owner
    // said it was the wrong green and pointed at the Posted status
    // badge. Success toasts now use the badge treatment: light green
    // background #dcfce7 with dark green text #166534 (the same pair
    // TransactionIconView uses for the Posted pill). The money-in
    // green (successHex) does NOT move — only the toast does.
    public static let toastSuccessBackgroundHex = "#dcfce7"
    public static let toastSuccessTextHex = "#166534"

    // MARK: - Stat-card deep colours (owner direction, Nov 12 2026,
    // corrected ~2:02 PM the same day: the Home/Funds Charity +
    // Extra Fund cards are bigger and more colourful, but NOT a
    // wash — a coloured OUTLINE on a white card, like the Weekly
    // Budget hero. Charity keeps a green identity, Extra Fund an
    // amber one (Nov 12 ~9:55 PM: amber, not blue like the hero,
    // so the two cards tell apart). SUPERSEDED Nov 14, 2026
    // (~11:28 PM, "too much colors"): the deep amount/icon colours
    // below NO LONGER colour the card faces — amounts and icons
    // are ink, chevrons muted grey, and ONLY the coloured outline
    // keeps colour. The deep hexes stay as tokens (a smoke test
    // pins fundDeepHex), not as card-face colours. The widget used
    // charityDeep for its charity figure until Nov 15, 2026
    // (widget polish: charity is ink there now). The soft-wash tokens that the
    // first pass added (charityTint/fundTint, charityChip/fundChip)
    // are REMOVED: nothing else referenced them — they only
    // duplicated the success/info backgrounds (#f0fdf4 / #eef4ff)
    // — and no wash remains on these cards. Text stays dark ink.

    public static let skeletonHex = "#ececf1"
    public static let charityDeepHex = "#15803d"

    /// Charity card outline green (owner, Nov 14, 2026): the
    /// success green went lighter (#22c55e), but the Charity card
    /// outline stays the deeper #16a34a — it has its own token now
    /// so the success change cannot move it.
    public static let charityHex = "#16a34a"
    public static let fundHex = "#d97706"
    public static let fundDeepHex = "#b45309"

    // Soft-green inline success box (owner decision, Nov 12, 2026:
    // inline success states are GREEN like the success toasts):
    // pale background, dark green text, soft border — the green
    // mirror of the soft-red error tokens above.
    public static let successBackgroundHex = "#f0fdf4"
    public static let successTextHex = "#15803d"
    public static let successBorderHex = "#bbf7d0"

    // MARK: - SwiftUI colours

    #if canImport(SwiftUI)
    public static var primary: Color { Color(hex: primaryHex) }
    public static var deep: Color { Color(hex: deepHex) }
    public static var mid: Color { Color(hex: midHex) }
    public static var light: Color { Color(hex: lightHex) }
    public static var pale: Color { Color(hex: paleHex) }
    public static var background: Color { Color(hex: backgroundHex) }
    public static var ink: Color { Color(hex: inkHex) }
    public static var muted: Color { Color(hex: mutedHex) }
    public static var bannerLightGrey: Color { Color(hex: bannerLightGreyHex) }
    public static var loadingBanner: Color { Color(hex: loadingBannerHex) }
    public static var infoBackground: Color { Color(hex: infoBackgroundHex) }
    public static var errorBackground: Color { Color(hex: errorBackgroundHex) }
    public static var errorText: Color { Color(hex: errorTextHex) }
    public static var errorBorder: Color { Color(hex: errorBorderHex) }
    public static var heroOverBudget: Color { Color(hex: heroOverBudgetHex) }
    public static var success: Color { Color(hex: successHex) }
    public static var successBackground: Color { Color(hex: successBackgroundHex) }
    public static var successText: Color { Color(hex: successTextHex) }
    public static var successBorder: Color { Color(hex: successBorderHex) }
    public static var skeleton: Color { Color(hex: skeletonHex) }
    public static var charity: Color { Color(hex: charityHex) }
    public static var charityDeep: Color { Color(hex: charityDeepHex) }
    public static var fund: Color { Color(hex: fundHex) }
    public static var fundDeep: Color { Color(hex: fundDeepHex) }
    #endif
}

#if canImport(SwiftUI)
public extension Color {
    /// Initialise a SwiftUI Color from a "#rrggbb" hex string.
    /// Falls back to `.clear` for malformed input — never crashes.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard cleaned.count == 6,
              Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .clear
            return
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
#endif
