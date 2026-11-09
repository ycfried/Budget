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

    // MARK: - Soft-red errors (owner rule, Nov 5 2026: light background,
    // dark red text — never a hard red fill)

    public static let errorBackgroundHex = "#fef2f2"
    public static let errorTextHex = "#dc2626"
    public static let errorBorderHex = "#fecaca"

    // MARK: - SwiftUI colours

    #if canImport(SwiftUI)
    public static var primary: Color { Color(hex: primaryHex) }
    public static var deep: Color { Color(hex: deepHex) }
    public static var mid: Color { Color(hex: midHex) }
    public static var light: Color { Color(hex: lightHex) }
    public static var pale: Color { Color(hex: paleHex) }
    public static var background: Color { Color(hex: backgroundHex) }
    public static var ink: Color { Color(hex: inkHex) }
    public static var errorBackground: Color { Color(hex: errorBackgroundHex) }
    public static var errorText: Color { Color(hex: errorTextHex) }
    public static var errorBorder: Color { Color(hex: errorBorderHex) }
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
