import XCTest
import OnBudgetKit

/// Scaffold smoke tests — prove the skeleton compiles, links and runs
/// on a simulator. Screen builders add their own tests per screen.
final class SmokeTests: XCTestCase {
    func testTitleCaseKeepsMinorWordsLowercase() {
        XCTAssertEqual(TitleCase.apply(to: "spend from fund"), "Spend from Fund")
        XCTAssertEqual(TitleCase.apply(to: "mark as charity"), "Mark as Charity")
        XCTAssertEqual(TitleCase.apply(to: "or join a household"), "Or Join a Household")
    }

    func testTitleCaseSignInException() {
        XCTAssertEqual(TitleCase.apply(to: "sign in"), "Sign In")
    }

    func testTitleCaseFirstWordAlwaysCapitalised() {
        XCTAssertEqual(TitleCase.apply(to: "the week of oct 25, 2026"), "The Week of Oct 25, 2026")
        XCTAssertEqual(TitleCase.apply(to: ""), "")
    }

    func testDesignTokenHexValues() {
        XCTAssertEqual(DesignTokens.primaryHex, "#2f6bff")
        XCTAssertEqual(DesignTokens.deepHex, "#1d4ed8")
        XCTAssertEqual(DesignTokens.midHex, "#3b82f6")
        XCTAssertEqual(DesignTokens.lightHex, "#60a5fa")
        XCTAssertEqual(DesignTokens.paleHex, "#bfdbfe")
        XCTAssertEqual(DesignTokens.backgroundHex, "#ffffff")
        XCTAssertEqual(DesignTokens.inkHex, "#0f172a")
        XCTAssertEqual(DesignTokens.errorBackgroundHex, "#fef2f2")
        XCTAssertEqual(DesignTokens.errorTextHex, "#dc2626")
        XCTAssertEqual(DesignTokens.errorBorderHex, "#fecaca")
    }

    func testSupabaseConfigurationPresent() {
        XCTAssertEqual(Configuration.supabaseURL, "https://tnkhvdkmwmwiogiienee.supabase.co")
        XCTAssertFalse(Configuration.supabaseAnonKey.isEmpty)
        XCTAssertTrue(Configuration.supabaseAnonKey.hasPrefix("sb_publishable_"))
    }

    func testToastStyleIsBrandBlue() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .info), DesignTokens.primaryHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .success), DesignTokens.primaryHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .error), DesignTokens.errorBackgroundHex)
        XCTAssertEqual(ToastStyle.textHex(for: .error), DesignTokens.errorTextHex)
        XCTAssertEqual(ToastStyle.placement, "bottom")
    }
}
