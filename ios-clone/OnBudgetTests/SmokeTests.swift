import XCTest
import UIKit
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

    func testToastStyleColours() {
        XCTAssertEqual(ToastStyle.backgroundHex(for: .info), DesignTokens.primaryHex)
        // Success is GREEN on native (owner, Nov 11, 2026: "green like
        // all success messages") — the old brand-blue rule for success
        // toasts is superseded for native only; the web app keeps blue.
        XCTAssertEqual(ToastStyle.backgroundHex(for: .success), DesignTokens.successHex)
        XCTAssertEqual(ToastStyle.backgroundHex(for: .error), DesignTokens.errorBackgroundHex)
        XCTAssertEqual(ToastStyle.textHex(for: .error), DesignTokens.errorTextHex)
        XCTAssertEqual(ToastStyle.placement, "bottom")
    }

    func testStatCardIconSymbolsResolve() {
        // Owner, Nov 12 2026: the Charity card icon is a giving
        // hand (handshake), not a heart; Extra Fund keeps its
        // banknote. An unknown systemName renders as nothing with
        // no compile error, so the glyphs must resolve at runtime.
        // (StatCardTheme itself lives in the app target, which
        // this bundle cannot import — no host app — so this
        // asserts the symbol names resolve; the mapping is the
        // one-line change in SharedViews.swift.)
        XCTAssertNotNil(UIImage(systemName: "handshake.fill"))
        XCTAssertNotNil(UIImage(systemName: "banknote.fill"))
    }

    func testExtraFundAccentIsAmber() {
        // Owner, Nov 12 2026: Extra Fund is amber, not blue like
        // the Weekly Budget hero. Outline amber-600, deep tint
        // amber-700 — the card accent on Home + Funds, loaded
        // and loading alike.
        XCTAssertEqual(DesignTokens.fundHex, "#d97706")
        XCTAssertEqual(DesignTokens.fundDeepHex, "#b45309")
    }
}
