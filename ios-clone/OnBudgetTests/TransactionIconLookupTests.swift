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

    // MARK: - Build 60 — logo fit + HomeGoods high-res source
    // (owner, Nov 22, 2026)

    func testFittedSizeKeepsWideLogoWhole() {
        // Seven Mile Market's favicon is 168×107 (wide): fit
        // keeps the full width and shrinks the height — it must
        // NOT come back as the whole 40×40 tile (that would be
        // the old fill-by-cropping, which cut it to "MIL"/"ARKE").
        let wide = TransactionIconView.fittedSize(imageSize: CGSize(width: 168, height: 107), tileSize: 40)
        XCTAssertEqual(wide.width, 40, accuracy: 0.01)
        XCTAssertEqual(wide.height, 40 * 107 / 168, accuracy: 0.01)
        // A square source fills the tile exactly, as before.
        let square = TransactionIconView.fittedSize(imageSize: CGSize(width: 48, height: 48), tileSize: 40)
        XCTAssertEqual(square.width, 40, accuracy: 0.01)
        XCTAssertEqual(square.height, 40, accuracy: 0.01)
        // A tall source keeps its full height and narrows.
        let tall = TransactionIconView.fittedSize(imageSize: CGSize(width: 107, height: 168), tileSize: 40)
        XCTAssertEqual(tall.width, 40 * 107 / 168, accuracy: 0.01)
        XCTAssertEqual(tall.height, 40, accuracy: 0.01)
        // A degenerate source falls back to the whole tile.
        let zero = TransactionIconView.fittedSize(imageSize: .zero, tileSize: 40)
        XCTAssertEqual(zero.width, 40, accuracy: 0.01)
        XCTAssertEqual(zero.height, 40, accuracy: 0.01)
    }

    func testHomeGoodsUsesHigherResOverride() {
        // The site's own favicon is only 48×48 ("HG" tile), so
        // the curated override points at the 280×94 wordmark on
        // Wikimedia Commons instead (verified Nov 22, 2026:
        // fetched, 200, the dark-red "HomeGoods" wordmark).
        XCTAssertEqual(
            TransactionIconLookup.iconURL(for: "HomeGoods")?.absoluteString,
            "https://upload.wikimedia.org/wikipedia/commons/8/88/Homegoods_logo.png"
        )
        // The curated domain map itself is untouched — the
        // override is layered on top of it.
        XCTAssertEqual(TransactionIconLookup.resolvedDomain(for: "HomeGoods"), "homegoods.com")
    }

    func testOtherMerchantsStillUseFaviconService() {
        XCTAssertEqual(
            TransactionIconLookup.iconURL(for: "Amazon")?.absoluteString,
            "https://www.google.com/s2/favicons?sz=128&domain=amazon.com"
        )
        XCTAssertEqual(
            TransactionIconLookup.iconURL(for: "Seven Mile Market")?.absoluteString,
            "https://www.google.com/s2/favicons?sz=128&domain=sevenmilemarket.com"
        )
        XCTAssertNil(TransactionIconLookup.iconURL(for: "THE Timepiece"))
    }

    // MARK: - Build 99 — owner-managed icon state (Merchant Rules)

    /// The removed / confirmed / custom sets live in
    /// UserDefaults, shared with the app — every test here
    /// clears them first and last, so a recorded removal can
    /// never leak into the curated-map tests above.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hb-merchant-removed-icon-domains")
        UserDefaults.standard.removeObject(forKey: "hb-merchant-confirmed-icon-domains")
        UserDefaults.standard.removeObject(forKey: "hb-merchant-custom-icon-domains")
        super.tearDown()
    }

    func testRemovedDomainSuppressesIcon() {
        // Amazon resolves, then the owner removes it: the
        // lookup returns nil (monogram) and even the icon URL
        // is gone. Clearing the removal brings it back — the
        // curated map itself is never edited.
        XCTAssertEqual(TransactionIconLookup.merchantDomain(for: "Amazon"), "amazon.com")
        TransactionIconLookup.recordRemovedIconDomain("amazon.com")
        XCTAssertNil(TransactionIconLookup.merchantDomain(for: "Amazon"))
        XCTAssertNil(TransactionIconLookup.iconURL(for: "Amazon"))
        TransactionIconLookup.clearRemovedIconDomain("amazon.com")
        XCTAssertEqual(TransactionIconLookup.merchantDomain(for: "Amazon"), "amazon.com")
    }

    func testRemovedDomainSuppressesOverrideToo() {
        // HomeGoods has both a curated domain AND an override
        // URL — removing the domain must suppress the override
        // as well, or Remove would leave the wordmark showing.
        XCTAssertNotNil(TransactionIconLookup.iconURL(for: "HomeGoods"))
        TransactionIconLookup.recordRemovedIconDomain("homegoods.com")
        XCTAssertNil(TransactionIconLookup.iconURL(for: "HomeGoods"))
        TransactionIconLookup.clearRemovedIconDomain("homegoods.com")
        XCTAssertNotNil(TransactionIconLookup.iconURL(for: "HomeGoods"))
    }

    func testConfirmedDomainIsRecorded() {
        XCTAssertFalse(TransactionIconLookup.confirmedIconDomains().contains("amazon.com"))
        TransactionIconLookup.recordConfirmedIconDomain("amazon.com")
        XCTAssertTrue(TransactionIconLookup.confirmedIconDomains().contains("amazon.com"))
        TransactionIconLookup.clearConfirmedIconDomain("amazon.com")
        XCTAssertFalse(TransactionIconLookup.confirmedIconDomains().contains("amazon.com"))
    }

    func testCustomSlugResolvesForUnmappedMerchant() {
        // Belluno Cafe has no curated domain (it sits on the
        // Merchants Without an Icon list). Uploading an icon
        // records its slug, and the lookup then resolves it —
        // the curated map is consulted first, so a later
        // curated entry would still win.
        XCTAssertNil(TransactionIconLookup.merchantDomain(for: "BELLUNO CAFE"))
        XCTAssertEqual(TransactionIconLookup.iconSlug(for: "BELLUNO CAFE"), "belluno-cafe")
        XCTAssertTrue(TransactionIconLookup.recordCustomIconDomain("belluno-cafe", forMerchant: "BELLUNO CAFE"))
        XCTAssertEqual(TransactionIconLookup.merchantDomain(for: "BELLUNO CAFE"), "belluno-cafe")
        // A slug already claimed by another merchant is refused.
        XCTAssertFalse(TransactionIconLookup.recordCustomIconDomain("belluno-cafe", forMerchant: "NORIBAR"))
        // A name of pure punctuation cannot be slugged.
        XCTAssertNil(TransactionIconLookup.iconSlug(for: "!!!"))
    }
}
