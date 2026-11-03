import XCTest
@testable import OnBudgetCore

final class CSVTests: XCTestCase {
    let header = "Date,Description,Amount,Card Ending\n"
    func testQuotedCommaEscapedQuoteAndRefund() {
        let preview = CSVImport.preview(header + "11/02/2026,\"Sample, \"\"Market\"\"\",12.50,1111\n2026-11-01,Return,(3.25),2222")
        XCTAssertTrue(preview.errors.isEmpty)
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertEqual(preview.rows[0].merchant, "Sample, \"Market\"")
        XCTAssertEqual(preview.rows[0].amount.cents, 1_250)
        XCTAssertEqual(preview.rows[1].amount.cents, -325)
    }
    func testBOMAndCRLFAndMultiline() {
        let preview = CSVImport.preview("\u{FEFF}Date,Description,Amount,Card Ending\r\n2026-11-02,\"Sample\r\nMerchant\",1.00,0001\r\n")
        XCTAssertEqual(preview.rows.count, 1)
        XCTAssertEqual(preview.rows.first?.cardSuffix, "0001")
        XCTAssertEqual(preview.rows.first?.merchant, "Sample\nMerchant")
    }
    func testMalformedQuoteFailsClosed() {
        for row in ["2026-11-02,\"unfinished,1.00,1111", "2026-11-02,\"closed\"junk,1.00,1111"] {
            let preview = CSVImport.preview(header + row)
            XCTAssertTrue(preview.rows.isEmpty)
            XCTAssertFalse(preview.errors.isEmpty)
        }
    }
    func testInvalidRowsReportedWithoutInventingValues() {
        let preview = CSVImport.preview(header + "2026-02-29,Sample,1.00,1111\n2026-11-02,Sample,,1111\n2026-11-02,Sample,1.00,nope\n2026-11-02,Valid,2.00,1111")
        XCTAssertEqual(preview.errors.count, 3)
        XCTAssertEqual(preview.rows.count, 1)
    }
    func testSameAmountPurchasesAreNotDeduplicatedOnDevice() {
        let line = "2026-11-02,Sample,12.00,1111\n"
        let preview = CSVImport.preview(header + line + line)
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertTrue(preview.reconciliationNote.contains("server"))
    }
    func testNonNumericDatePartsAreRejected() {
        let preview = CSVImport.preview(header + "11/x/02/2026,Sample,1.00,1111")
        XCTAssertTrue(preview.rows.isEmpty)
        XCTAssertEqual(preview.errors.count, 1)
    }
    func testEmptyMissingAndDuplicateHeaders() {
        XCTAssertFalse(CSVImport.preview("").errors.isEmpty)
        XCTAssertFalse(CSVImport.preview("Date,Amount\n").errors.isEmpty)
        XCTAssertFalse(CSVImport.preview("Date,Description,Amount,Card Ending,Amount\n").errors.isEmpty)
    }
    func testSizeLimit() {
        XCTAssertFalse(CSVImport.preview(String(repeating: "x", count: CSVImport.maximumBytes + 1)).errors.isEmpty)
    }
}
