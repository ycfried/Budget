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
        XCTAssertEqual(DesignTokens.successHex, "#22c55e")
        // Charity keeps its own deeper green even though the
        // success green went lighter (owner, Nov 14, 2026).
        XCTAssertEqual(DesignTokens.charityHex, "#16a34a")
    }

    /// Info toasts are SOFT LIGHT BLUE (owner, Nov 25, 2026 —
    /// build 77): the solid brand-blue bar did not match the
    /// soft-tint success/error toasts. Errors stay soft red.
    func testToastStyleInfoIsLightBlue() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .info), DesignTokens.toastInfoBackgroundHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .info), "#dbeafe")
        XCTAssertEqual(ToastStyle.textHex(for: .info), DesignTokens.toastInfoTextHex)
        XCTAssertEqual(ToastStyle.textHex(for: .info), "#1d4ed8")
        XCTAssertEqual(ToastStyle.backgroundHex(for: .error), DesignTokens.errorBackgroundHex)
    }

    /// Success toasts are GREEN, not blue (owner rule, Nov 11 2026 —
    /// native only; the web app keeps brand-blue success toasts).
    /// Info is soft light blue (owner, Nov 25, 2026 — build 77);
    /// errors stay soft red. The success toast uses the Posted
    /// status badge treatment (owner, Nov 15, 2026): light green
    /// background #dcfce7, dark green text #166534 — NOT the solid
    /// #22c55e bar with white text.
    func testToastStyleSuccessIsGreen() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .success), DesignTokens.toastSuccessBackgroundHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .success), "#dcfce7")
        XCTAssertEqual(ToastStyle.textHex(for: .success), DesignTokens.toastSuccessTextHex)
        XCTAssertEqual(ToastStyle.textHex(for: .success), "#166534")
        XCTAssertEqual(ToastStyle.textHex(for: .error), DesignTokens.errorTextHex)
        XCTAssertEqual(ToastStyle.autoDismissSeconds, 4.0)
    }

    func testSupabaseConfigurationPresent() {
        XCTAssertEqual(Configuration.supabaseURL, "https://tnkhvdkmwmwiogiienee.supabase.co")
        XCTAssertTrue(Configuration.supabaseAnonKey.hasPrefix("sb_publishable_"))
    }
}
