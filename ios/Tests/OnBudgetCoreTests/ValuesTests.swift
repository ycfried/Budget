import XCTest
@testable import OnBudgetCore

final class ValuesTests: XCTestCase {
    func testExactCentsWithoutFloatingPoint() throws {
        XCTAssertEqual(try Money(dollars: "0.29").cents, 29)
        XCTAssertEqual(try Money(dollars: " 375.5 ").cents, 37_550)
        XCTAssertEqual(try Money(dollars: "-15.00").cents, -1_500)
        XCTAssertEqual(Money(cents: -1_500).formatted, "−$15.00")
        XCTAssertEqual(Money(cents: .min).formatted, "−$92233720368547758.08")
    }
    func testInvalidAndOverflowAmounts() {
        for text in ["", " ", "1.234", "nan", "inf", "1e3", "$1", "1,000", "12.", ".5", "--1", "92233720368547759"] {
            XCTAssertThrowsError(try Money(dollars: text), text)
        }
    }
    func testDateValidationAndLeapYear() throws {
        XCTAssertEqual(try PurchaseDate("2024-02-29").rawValue, "2024-02-29")
        for date in ["2026-02-29", "2026-13-01", "2026-11-31", "26-01-01", "2026-00-01"] {
            XCTAssertThrowsError(try PurchaseDate(date), date)
        }
        XCTAssertLessThan(try PurchaseDate("2026-10-31"), try PurchaseDate("2026-11-01"))
    }
    func testHouseholdDateUsesNewYorkAtDSTBoundary() {
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(PurchaseDate.today(at: formatter.date(from: "2026-11-01T03:59:00Z")!).rawValue, "2026-10-31")
        XCTAssertEqual(PurchaseDate.today(at: formatter.date(from: "2026-11-01T04:01:00Z")!).rawValue, "2026-11-01")
        XCTAssertEqual(PurchaseDate.today(at: formatter.date(from: "2026-03-08T07:01:00Z")!).rawValue, "2026-03-08")
    }
    func testManualPurchaseInput() throws {
        let date = try PurchaseDate("2026-11-02")
        XCTAssertThrowsError(try ManualPurchase(merchant: " ", amount: Money(cents: 10), date: date, cardSuffix: "1111"))
        XCTAssertThrowsError(try ManualPurchase(merchant: "Sample", amount: Money(cents: 0), date: date, cardSuffix: "1111"))
        XCTAssertThrowsError(try ManualPurchase(merchant: "Sample", amount: Money(cents: 10), date: date, cardSuffix: "abc1"))
        XCTAssertEqual(try ManualPurchase(merchant: " Sample ", amount: Money(cents: 10), date: date, cardSuffix: "0001").merchant, "Sample")
    }
    func testAuthenticationValidation() throws {
        XCTAssertThrowsError(try Credentials(email: "invalid", password: "sample-only"))
        XCTAssertThrowsError(try Credentials(email: "sample@example.invalid", password: "short"))
        _ = try Credentials(email: "sample@example.invalid", password: "sample-only")
    }
}
