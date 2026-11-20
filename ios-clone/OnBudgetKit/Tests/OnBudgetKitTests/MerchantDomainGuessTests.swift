import XCTest
@testable import OnBudgetKit

/// Build 52 — the auto-guess half of the smart merchant-icon plan:
/// name → .com, with the generic words stripped.
final class MerchantDomainGuessTests: XCTestCase {
    func testStripsTrailingGenericWords() {
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "ACME MARKETS"), "acme.com")
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "Walmart Supercenter"), "walmart.com")
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "Joe's Pizza"), "joespizza.com")
    }

    func testStripsLeadingTheAndStoreNumbers() {
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "The Home Depot"), "homedepot.com")
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "Main Street Bagels #5"), "mainstreetbagels.com")
    }

    func testNeverGuessesForGenericTransferDescriptors() {
        XCTAssertNil(MerchantDomainGuess.guessedDomain(for: "Online Transfer"))
        XCTAssertNil(MerchantDomainGuess.guessedDomain(for: "Payment: Credit"))
        XCTAssertNil(MerchantDomainGuess.guessedDomain(for: "Zelle Transfer From John"))
    }

    func testTooShortToBeABrand() {
        XCTAssertNil(MerchantDomainGuess.guessedDomain(for: "BP"))
        XCTAssertNil(MerchantDomainGuess.guessedDomain(for: "KFC"))
    }

    /// The honest limit, pinned: the guess for Erie IS erie.com —
    /// a different company. The curated list must win for the
    /// tricky ones (erieinsurance.com), never the guess.
    func testErieGuessIsTheWrongCompany() {
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "Erie Insurance"), "erieinsurance.com")
        XCTAssertEqual(MerchantDomainGuess.guessedDomain(for: "Erie"), "erie.com")
    }
}
