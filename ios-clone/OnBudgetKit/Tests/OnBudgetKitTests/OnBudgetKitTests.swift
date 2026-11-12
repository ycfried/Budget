import XCTest
@testable import OnBudgetKit

/// Package-level mirror of the Xcode smoke tests — runs with
/// `swift test` on the macOS runner, proving the shared module
/// compiles and behaves before the simulator build starts.
final class OnBudgetKitTests: XCTestCase {
    func testTitleCaseKeepsMinorWordsLowercase() {
        XCTAssertEqual(TitleCase.apply(to: "spend from fund"), "Spend from Fund")
        XCTAssertEqual(TitleCase.apply(to: "sign in"), "Sign In")
    }

    func testDesignTokenHexValues() {
        XCTAssertEqual(DesignTokens.primaryHex, "#2f6bff")
        XCTAssertEqual(DesignTokens.paleHex, "#bfdbfe")
        XCTAssertEqual(DesignTokens.errorTextHex, "#dc2626")
        XCTAssertEqual(DesignTokens.successHex, "#16a34a")
    }

    func testToastStyleIsBrandBlue() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .info), DesignTokens.primaryHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .error), DesignTokens.errorBackgroundHex)
    }

    /// Success toasts are GREEN, not blue (owner rule, Nov 11 2026 —
    /// native only; the web app keeps brand-blue success toasts).
    /// Info stays brand blue; errors stay soft red.
    func testToastStyleSuccessIsGreen() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .success), DesignTokens.successHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .success), "#16a34a")
        XCTAssertEqual(ToastStyle.textHex(for: .success), "#ffffff")
        XCTAssertEqual(ToastStyle.textHex(for: .info), "#ffffff")
        XCTAssertEqual(ToastStyle.textHex(for: .error), DesignTokens.errorTextHex)
        XCTAssertEqual(ToastStyle.autoDismissSeconds, 4.0)
    }

    func testSupabaseConfigurationPresent() {
        XCTAssertEqual(Configuration.supabaseURL, "https://tnkhvdkmwmwiogiienee.supabase.co")
        XCTAssertTrue(Configuration.supabaseAnonKey.hasPrefix("sb_publishable_"))
    }
}
