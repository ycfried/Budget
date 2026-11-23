import XCTest
import SwiftUI
import UIKit
@testable import OnBudget
import OnBudgetKit

/// Lean design tokens + page select (build 63, owner Nov 23,
/// 2026). Pins the values so a later change to the Lean palette
/// or the page-select options is a deliberate edit, not drift.
final class LeanDesignTests: XCTestCase {
    /// Resolve a SwiftUI Color to its "#rrggbb" hex (sRGB).
    private func hex(of color: Color) -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    func testLeanSoftTokens() {
        // Between-style secondary: a pale soft-blue fill with a
        // hairline border — never a bare outline, never a solid
        // blue block.
        XCTAssertEqual(DesignTokens.softFillHex, "#e9effe")
        XCTAssertEqual(DesignTokens.softBorderHex, "#bfdbfe")
        XCTAssertEqual(hex(of: DesignTokens.softFill), "#e9effe")
        XCTAssertEqual(hex(of: DesignTokens.softBorder), "#bfdbfe")
        // The soft fill is lighter than the pale middle tier.
        XCTAssertNotEqual(DesignTokens.softFillHex, DesignTokens.paleHex)
    }

    func testLeanPageSelectTokens() {
        // White floater on a light-grey track — never a blue fill.
        XCTAssertEqual(DesignTokens.trackHex, "#eef0f3")
        XCTAssertEqual(DesignTokens.segmentInactiveHex, "#5b6a84")
        XCTAssertEqual(hex(of: DesignTokens.track), "#eef0f3")
        XCTAssertEqual(hex(of: DesignTokens.segmentInactive), "#5b6a84")
        // The track is not the tertiary grey and not white.
        XCTAssertNotEqual(DesignTokens.trackHex, DesignTokens.tertiaryHex)
        XCTAssertNotEqual(DesignTokens.trackHex, DesignTokens.backgroundHex)
    }

    func testPageSelectOptionsAreHomeTransactionsFunds() {
        // The page select's three options, in this order — the
        // mockup's segPro order. Do not substitute Activity for
        // Transactions or reorder.
        XCTAssertEqual(AppTab.allCases.map(\.rawValue), ["Home", "Transactions", "Funds"])
    }

    func testLeanDeepPrimaryIsDeepBlue() {
        // The one filled primary in a Lean action group is the
        // deep blue, not the brighter primary blue.
        XCTAssertEqual(DesignTokens.deepHex, "#1d4ed8")
        XCTAssertNotEqual(DesignTokens.deepHex, DesignTokens.primaryHex)
    }
}
