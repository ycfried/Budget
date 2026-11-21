import XCTest
@testable import OnBudgetKit

/// Build 53 (audit C2): the icon map must not match a keyword
/// inside a longer word, and a specific entry must beat its prefix.
final class MerchantKeywordMatchTests: XCTestCase {
    private let entries: [(keyword: String, value: String)] = [
        (keyword: "apple", value: "apple.com"),
        (keyword: "applebee", value: "applebees.com"),
        (keyword: "sonic", value: "sonicdrivein.com"),
        (keyword: "ups", value: "ups.com"),
        (keyword: "bp", value: "bp.com"),
        (keyword: "heb", value: "heb.com"),
        (keyword: "trader joe", value: "traderjoes.com"),
        (keyword: "trader", value: "trader.com"),
        (keyword: "cvs", value: "cvs.com"),
        (keyword: "target", value: "target.com"),
        (keyword: "lowe", value: "lowes.com"),
    ]

    func testApplebeesDoesNotGetTheAppleLogo() {
        XCTAssertEqual(MerchantKeywordMatch.bestMatch(in: "APPLEBEE'S", from: entries), "applebees.com")
        XCTAssertEqual(MerchantKeywordMatch.bestMatch(in: "Applebee's Grill", from: entries), "applebees.com")
        XCTAssertEqual(MerchantKeywordMatch.bestMatch(in: "APPLE STORE", from: entries), "apple.com")
        XCTAssertEqual(MerchantKeywordMatch.bestMatch(in: "APPLE.COM", from: entries), "apple.com")
    }

    func testKeywordInsideALongerWordDoesNotMatch() {
        XCTAssertFalse(MerchantKeywordMatch.matches("sonic", in: "PANASONIC"))
        XCTAssertFalse(MerchantKeywordMatch.matches("ups", in: "CUPS"))
        XCTAssertFalse(MerchantKeywordMatch.matches("apple", in: "APPLEBEE'S"))
        XCTAssertFalse(MerchantKeywordMatch.matches("bp", in: "SUBWAY"))
    }

    func testShortKeywordsMatchWholeWords() {
        XCTAssertTrue(MerchantKeywordMatch.matches("bp", in: "BP"))
        XCTAssertTrue(MerchantKeywordMatch.matches("bp", in: "BP #1234"))
        XCTAssertTrue(MerchantKeywordMatch.matches("heb", in: "HEB"))
        XCTAssertTrue(MerchantKeywordMatch.matches("ups", in: "UPS STORE"))
        XCTAssertFalse(MerchantKeywordMatch.matches("ups", in: "CUPS"))
    }

    func testBoundaryCharactersCount() {
        XCTAssertTrue(MerchantKeywordMatch.matches("cvs", in: "CVS/PHARMACY"))
        XCTAssertTrue(MerchantKeywordMatch.matches("target", in: "TARGET #1234"))
        XCTAssertTrue(MerchantKeywordMatch.matches("lowe", in: "LOWE'S"))
        XCTAssertTrue(MerchantKeywordMatch.matches("apple", in: "APPLE.COM"))
    }

    func testLongestKeywordWins() {
        XCTAssertEqual(MerchantKeywordMatch.bestMatch(in: "TRADER JOE'S", from: entries), "traderjoes.com")
        XCTAssertEqual(MerchantKeywordMatch.bestMatch(in: "TRADER JOE'S #123", from: entries), "traderjoes.com")
    }

    func testNoMatchForUnmappedName() {
        XCTAssertNil(MerchantKeywordMatch.bestMatch(in: "AVRAHAM FRIEDMAN", from: entries))
        XCTAssertNil(MerchantKeywordMatch.bestMatch(in: "THE TIMEPIECE", from: entries))
        XCTAssertFalse(MerchantKeywordMatch.matches("apple", in: "AVRAHAM FRIEDMAN"))
    }
}
