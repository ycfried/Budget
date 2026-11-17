import XCTest
@testable import OnBudgetKit

/// Build 41 — the Activity feeds resolve merchant names at render
/// time through the household's rename rules (the same matcher the
/// server uses). These tests pin the key/squash normalisation and
/// the tier order against the owner's own examples.
final class MerchantDisplayNameTests: XCTestCase {
    private func rule(pattern: String, matchType: String, display: String) -> MerchantRule {
        let json = """
        {"id": "\(UUID().uuidString)", "household_id": "\(UUID().uuidString)",
         "pattern_text": "\(pattern)", "match_type": "\(matchType)",
         "display_name": "\(display)", "fixed_kind": null,
         "created_at": null, "source_merchant": null}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(MerchantRule.self, from: json)
    }

    func testKeyStripsLeadingNonAlphanumericsAndCollapsesWhitespace() {
        XCTAssertEqual(MerchantDisplayName.key("=TENYADKALLAHGEMACH"), "TENYADKALLAHGEMACH")
        XCTAssertEqual(MerchantDisplayName.key("  toiremorg  "), "TOIREMORG")
        XCTAssertEqual(MerchantDisplayName.key("TOIREM.ORG   CHARITY"), "TOIREM.ORG CHARITY")
        XCTAssertEqual(MerchantDisplayName.key(""), "")
    }

    func testSquashRemovesAllNonAlphanumerics() {
        XCTAssertEqual(MerchantDisplayName.squash("TOIREM.ORG CHARITY"), "TOIREMORGCHARITY")
        XCTAssertEqual(MerchantDisplayName.squash("=TENYADKALLAHGEMACH"), "TENYADKALLAHGEMACH")
    }

    func testExactRuleWins() {
        let rules = [rule(pattern: "TOIREMORG", matchType: "exact", display: "Toiremorg")]
        XCTAssertEqual(MerchantDisplayName.displayName(for: "TOIREMORG", rules: rules), "Toiremorg")
        // The key upper-cases, so a lower-case spelling matches too.
        XCTAssertEqual(MerchantDisplayName.displayName(for: "toiremorg", rules: rules), "Toiremorg")
    }

    func testIncludesRuleMatchesSubstring() {
        // The owner's example: "=TENYADKALLAHGEMACH" shows as
        // "Tenyad Kallah Gemach" under an Includes rule.
        let rules = [rule(pattern: "TENYAD", matchType: "includes", display: "Tenyad Kallah Gemach")]
        XCTAssertEqual(
            MerchantDisplayName.displayName(for: "=TENYADKALLAHGEMACH", rules: rules),
            "Tenyad Kallah Gemach"
        )
    }

    func testSquashTierMatchesPunctuationVariants() {
        // "TOIREMORG" and "TOIREM.ORG" differ as keys but share a
        // squash, so an exact rule on one spelling matches the
        // other (tier 2). A longer merchant needs an Includes rule
        // — the exact rule's squash is not the whole merchant.
        let rules = [rule(pattern: "TOIREM.ORG", matchType: "exact", display: "Toiremorg")]
        XCTAssertEqual(MerchantDisplayName.displayName(for: "TOIREMORG", rules: rules), "Toiremorg")
        XCTAssertEqual(
            MerchantDisplayName.displayName(for: "TOIREM.ORG CHARITY", rules: rules),
            "TOIREM.ORG CHARITY"
        )
        let includes = [rule(pattern: "TOIREMORG", matchType: "includes", display: "Toiremorg")]
        XCTAssertEqual(
            MerchantDisplayName.displayName(for: "TOIREM.ORG CHARITY", rules: includes),
            "Toiremorg"
        )
    }

    func testNoRuleReturnsMerchantUnchanged() {
        XCTAssertEqual(MerchantDisplayName.displayName(for: "WALMART", rules: []), "WALMART")
        XCTAssertEqual(MerchantDisplayName.displayName(for: "", rules: []), "")
    }

    func testExactTierBeatsIncludesTier() {
        let rules = [
            rule(pattern: "TOIREM", matchType: "includes", display: "Includes Name"),
            rule(pattern: "TOIREMORG", matchType: "exact", display: "Exact Name"),
        ]
        XCTAssertEqual(MerchantDisplayName.displayName(for: "TOIREMORG", rules: rules), "Exact Name")
    }

    func testLongestPatternWinsWithinATier() {
        let rules = [
            rule(pattern: "TOIREM", matchType: "includes", display: "Short Pattern"),
            rule(pattern: "TOIREMORG", matchType: "includes", display: "Long Pattern"),
        ]
        XCTAssertEqual(
            MerchantDisplayName.displayName(for: "TOIREMORG CHARITY", rules: rules),
            "Long Pattern"
        )
    }

    func testPrefixMatchTypeReadsAsIncludes() {
        // The decoder normalises the legacy "prefix" value to
        // "includes" (build 34), and the matcher treats it the same.
        let rules = [rule(pattern: "TENYAD", matchType: "prefix", display: "Tenyad Kallah Gemach")]
        XCTAssertEqual(rules.first?.matchType, "includes")
        XCTAssertEqual(
            MerchantDisplayName.displayName(for: "=TENYADKALLAHGEMACH", rules: rules),
            "Tenyad Kallah Gemach"
        )
    }
}
