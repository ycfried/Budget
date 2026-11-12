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

    /// Audit X-P2-11: by/as/at/on/with are minor words too.
    func testTitleCaseMinorWordsByAsAtOnWith() {
        XCTAssertEqual(TitleCase.apply(to: "filter by date"), "Filter by Date")
        XCTAssertEqual(TitleCase.apply(to: "add a transaction by hand"), "Add a Transaction by Hand")
        XCTAssertEqual(TitleCase.apply(to: "sort by"), "Sort by")
        XCTAssertEqual(TitleCase.apply(to: "mark as charity"), "Mark as Charity")
        XCTAssertEqual(TitleCase.apply(to: "spend from fund"), "Spend from Fund")
    }

    /// Audit X-P2-14: hyphen segments capitalise individually and
    /// acronyms / internal capitals survive; all-caps merchants
    /// still title-case down.
    func testTitleCaseHyphensAndAcronyms() {
        XCTAssertEqual(TitleCase.apply(to: "save top-up"), "Save Top-Up")
        XCTAssertEqual(TitleCase.apply(to: "Save Top-Up"), "Save Top-Up")
        XCTAssertEqual(TitleCase.apply(to: "CSV import"), "CSV Import")
        XCTAssertEqual(TitleCase.apply(to: "McDonald's"), "McDonald's")
        XCTAssertEqual(TitleCase.apply(to: "trader joes"), "Trader Joes")
        XCTAssertEqual(TitleCase.apply(to: "TRADER JOES"), "Trader Joes")
        XCTAssertEqual(TitleCase.apply(to: "7-eleven"), "7-Eleven")
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
