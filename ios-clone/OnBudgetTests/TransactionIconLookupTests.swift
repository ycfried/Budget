import XCTest
@testable import OnBudget

/// No guessed merchant icons (owner, Nov 22, 2026 — build 57).
/// THE Timepiece wore a blurry clock from the auto-guessed
/// thetimepiece.com; the owner ruled that a transaction with no
/// merchant or available logo should rely on the DEFAULT monogram
/// rather than a made-up or improper icon. The auto-guess and the
/// remembered guesses are removed — resolvedDomain is curated-only.
/// These tests pin that: an unmapped merchant resolves to nil (so
/// the row shows its monogram initial), while curated merchants
/// still resolve to their real domains. The bank/email dedupe
/// merge is a separate path and is NOT covered here.
final class TransactionIconLookupTests: XCTestCase {
    func testUnmappedMerchantResolvesToNil() {
        // THE Timepiece is the reported case: no curated entry,
        // so no favicon is fetched and the row shows the monogram.
        XCTAssertNil(TransactionIconLookup.resolvedDomain(for: "THE Timepiece"))
        XCTAssertNil(TransactionIconLookup.resolvedDomain(for: "Avraham Friedman"))
        XCTAssertNil(TransactionIconLookup.resolvedDomain(for: "Fraida Grossman"))
    }

    func testCuratedMerchantsStillResolve() {
        XCTAssertEqual(TransactionIconLookup.resolvedDomain(for: "Amazon"), "amazon.com")
        XCTAssertEqual(TransactionIconLookup.resolvedDomain(for: "Royal Farms"), "royalfarms.com")
        XCTAssertEqual(TransactionIconLookup.resolvedDomain(for: "Carter's"), "carters.com")
        // Erie must resolve to the insurer, not erie.com.
        XCTAssertEqual(TransactionIconLookup.resolvedDomain(for: "Erie Insurance"), "erieinsurance.com")
    }

    func testTimepieceMonogramInitial() {
        // The fallback tile for THE Timepiece is a monogram "T".
        XCTAssertEqual(TransactionIconLookup.initial(for: "THE Timepiece"), "T")
    }

    func testCuratedBrandColourStillKnown() {
        XCTAssertEqual(TransactionIconLookup.merchantBrandHex(for: "Amazon"), "#ff9900")
        // An unmapped merchant has no brand colour — its monogram
        // uses the soft neutral tile, never an invented colour.
        XCTAssertNil(TransactionIconLookup.merchantBrandHex(for: "THE Timepiece"))
    }
}
