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
    }

    func testToastStyleIsBrandBlue() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .info), DesignTokens.primaryHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .error), DesignTokens.errorBackgroundHex)
    }

    func testSupabaseConfigurationPresent() {
        XCTAssertEqual(Configuration.supabaseURL, "https://tnkhvdkmwmwiogiienee.supabase.co")
        XCTAssertTrue(Configuration.supabaseAnonKey.hasPrefix("sb_publishable_"))
    }
}
