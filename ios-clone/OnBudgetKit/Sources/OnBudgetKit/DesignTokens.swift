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
    public static let infoBackgroundHex = "#eef4ff"

    // MARK: - Soft-red errors (owner rule, Nov 5 2026: light background,
    // dark red text — never a hard red fill)

    public static let errorBackgroundHex = "#fef2f2"
    public static let errorTextHex = "#dc2626"
    public static let errorBorderHex = "#fecaca"

    // MARK: - Success green (owner rule, Nov 11 2026: success toasts
    // are GREEN, not blue — native only; the web app keeps brand-blue
    // toasts. Info toasts stay brand blue.)

    public static let successHex = "#16a34a"

    // MARK: - Stat-card deep colours (owner direction, Nov 12 2026,
    // corrected ~2:02 PM the same day: the Home/Funds Charity +
    // Extra Fund cards are bigger and more colourful, but NOT a
    // wash — a coloured OUTLINE on a white card, like the Weekly
    // Budget hero. Charity keeps a green identity, Extra Fund a
    // blue one; the deep amount colours below stay (they are the
    // colour identity, not a wash). The soft-wash tokens that the
    // first pass added (charityTint/fundTint, charityChip/fundChip)
    // are REMOVED: nothing else referenced them — they only
    // duplicated the success/info backgrounds (#f0fdf4 / #eef4ff)
    // — and no wash remains on these cards. Text stays dark ink;
    // amounts are the deep colour, never mid-tone.

    public static let skeletonHex = "#ececf1"
    public static let charityDeepHex = "#15803d"
    public static let fundDeepHex = "#1d4ed8"

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
    public static var infoBackground: Color { Color(hex: infoBackgroundHex) }
    public static var errorBackground: Color { Color(hex: errorBackgroundHex) }
    public static var errorText: Color { Color(hex: errorTextHex) }
    public static var errorBorder: Color { Color(hex: errorBorderHex) }
    public static var success: Color { Color(hex: successHex) }
    public static var successBackground: Color { Color(hex: successBackgroundHex) }
    public static var successText: Color { Color(hex: successTextHex) }
    public static var successBorder: Color { Color(hex: successBorderHex) }
    public static var skeleton: Color { Color(hex: skeletonHex) }
    public static var charityDeep: Color { Color(hex: charityDeepHex) }
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
