import XCTest
import SwiftUI
import UIKit
@testable import OnBudget

/// Savings header is the BRAND grey (owner, Nov 22, 2026 —
/// build 57: the muted #6b7280 "isn't bad but it's not the one
/// from our branding"). The brand grey is the tertiary grey
/// #e5e7eb — the third button colour in the build-41 3-button
/// scheme the fund headers follow (primary blue / pale /
/// tertiary grey). On the light banner the text is ink (white is
/// unreadable on it); the glyph and number keep the readable
/// muted grey on white. The brown #b45309 stays only as a future
/// Spending candidate, never applied.
final class StatCardThemeTests: XCTestCase {
    /// Resolve a SwiftUI Color to its "#rrggbb" hex (sRGB) so the
    /// theme colours can be asserted by value. Returns nil when
    /// the colour does not resolve to RGB components.
    private func hex(of color: Color) -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    func testSavingsBannerIsTertiaryGrey() {
        XCTAssertEqual(hex(of: StatCardTheme.fund.banner), "#e5e7eb")
        XCTAssertEqual(DesignTokens.tertiaryHex, "#e5e7eb")
        // NOT the muted secondary-text grey.
        XCTAssertNotEqual(hex(of: StatCardTheme.fund.banner), "#6b7280")
    }

    func testSavingsBannerTextIsInk() {
        // White is unreadable on the light tertiary banner.
        XCTAssertEqual(hex(of: StatCardTheme.fund.onBanner), "#0f172a")
    }

    func testSavingsGlyphAndNumberStayMutedGrey() {
        // The glyph (on the white disc) and the number (on the
        // white body) keep the readable muted grey — tertiary
        // would be invisible on white.
        XCTAssertEqual(hex(of: StatCardTheme.fund.glyph), "#6b7280")
        XCTAssertEqual(hex(of: StatCardTheme.fund.number), "#6b7280")
        XCTAssertEqual(DesignTokens.mutedHex, "#6b7280")
    }

    func testSpendingStaysDeepBlue() {
        XCTAssertEqual(hex(of: StatCardTheme.spending.banner), "#1d4ed8")
        XCTAssertEqual(DesignTokens.deepHex, "#1d4ed8")
    }

    func testBrownStaysOnlyAsFutureSpendingCandidate() {
        // The brown token is preserved, never applied anywhere.
        XCTAssertEqual(DesignTokens.fundDeepHex, "#b45309")
        XCTAssertNotEqual(hex(of: StatCardTheme.fund.banner), "#b45309")
        XCTAssertNotEqual(hex(of: StatCardTheme.spending.banner), "#b45309")
    }
}
