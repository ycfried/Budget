import XCTest
@testable import OnBudgetKit

/// Settings workstream (Nov 9, 2026): ports of the web's display
/// formatting — money, dates, audit translation, CSV parsing,
/// classification, bank branding. Fixtures only, no network.
final class SettingsFormattingTests: XCTestCase {
    // MARK: - MoneyFormat

    func testFormatCents() {
        XCTAssertEqual(MoneyFormat.formatCents(0), "$0.00")
        XCTAssertEqual(MoneyFormat.formatCents(123456), "$1,234.56")
        XCTAssertEqual(MoneyFormat.formatCents(-15897), "-$158.97")
        XCTAssertEqual(MoneyFormat.formatCents(37500), "$375.00")
    }

    func testFmtLongAndShort() {
        XCTAssertEqual(MoneyFormat.fmtLong("2026-11-08"), "Nov 8, 2026")
        XCTAssertEqual(MoneyFormat.fmtShort("2026-11-08"), "Nov 8")
        XCTAssertEqual(MoneyFormat.fmtLong("not-a-date"), "not-a-date")
    }

    func testFmtDateTimeIsNewYork() {
        // 2026-11-08T19:30:00Z is 2:30 PM EST.
        XCTAssertEqual(MoneyFormat.fmtDateTime("2026-11-08T19:30:00Z"), "Nov 8, 2:30 PM")
        XCTAssertEqual(MoneyFormat.fmtDateTime("garbage"), "garbage")
    }

    func testWeekEndString() {
        XCTAssertEqual(MoneyFormat.weekEndString(weekStart: "2026-11-08"), "2026-11-14")
        XCTAssertNil(MoneyFormat.weekEndString(weekStart: "nope"))
    }

    func testParseDollarsStrict() {
        XCTAssertNil(MoneyFormat.parseDollarsStrict(""))
        XCTAssertNil(MoneyFormat.parseDollarsStrict("  "))
        XCTAssertNil(MoneyFormat.parseDollarsStrict("abc"))
        XCTAssertNil(MoneyFormat.parseDollarsStrict("12.345"))
        XCTAssertEqual(MoneyFormat.parseDollarsStrict("0"), 0)
        XCTAssertEqual(MoneyFormat.parseDollarsStrict("375"), 37500)
        XCTAssertEqual(MoneyFormat.parseDollarsStrict("12.34"), 1234)
    }

    func testIsValidEmail() {
        XCTAssertTrue(MoneyFormat.isValidEmail("shuki@example.com"))
        XCTAssertFalse(MoneyFormat.isValidEmail("not-an-email"))
        XCTAssertFalse(MoneyFormat.isValidEmail("a@b"))
    }

    // MARK: - AuditFormatting

    func testFormatDetailStripsUUIDsAndConvertsCentsAndDates() {
        let detail = AuditFormatting.formatDetail(
            "Refund 123e4567-e89b-12d3-a456-426614174000 for 2026-11-01: 70000 cents restored."
        )
        XCTAssertFalse(detail.contains("123e4567"))
        XCTAssertTrue(detail.contains("Nov 1, 2026"))
        XCTAssertTrue(detail.contains("$700.00"))
    }

    func testFormatDetailBasisPointsAndProvisional() {
        // NOTE: the "20%." (trailing dot kept) is the web's own
        // output — the greedy `[^ ]+` capture swallows the sentence
        // dot, exactly as filterState.mjs does. Ported faithfully.
        XCTAssertEqual(
            AuditFormatting.formatDetail("Default charity rate set to 2000 basis points."),
            "Charity rate: 20%. for future income."
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Row reclassified as provisional."),
            "Row reclassified as pending."
        )
    }

    func testFormatActionRenamesOldRows() {
        XCTAssertEqual(
            AuditFormatting.formatAction("Purchase added by hand"),
            "Transaction added by hand"
        )
        XCTAssertEqual(AuditFormatting.formatAction("CSV import"), "CSV import")
    }

    func testFormatActor() {
        XCTAssertEqual(AuditFormatting.formatActor("admin"), "Admin")
        XCTAssertEqual(AuditFormatting.formatActor("member"), "Member")
        XCTAssertEqual(AuditFormatting.formatActor("shuki@example.com"), "shuki")
        XCTAssertEqual(AuditFormatting.formatActor("Shuki Friedman"), "Shuki Friedman")
    }

    func testSimplifyMergedDuplicate() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail(
                "Merged duplicate (TOIREMORG CHARITY $1.00) into the original bank row (TOIREMORG $1.00). Duplicate excluded, not deleted. Note: merge"
            ),
            "Counted once: TOIREMORG CHARITY $1.00."
        )
    }

    func testSimplifyWeeksClosedDropsZeroParts() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("2 weeks closed, 1 surplus released, 0 refunds restored, 0 refunds held for review."),
            "2 weeks closed · 1 surplus released."
        )
    }

    func testSimplifySurplusReleased() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("Surplus $120.00 for week Nov 1, 2026 released to the Extra Fund."),
            "$120.00 to the Extra Fund · Week of Nov 1, 2026."
        )
    }

    func testSimplifyExcludedAndRestored() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("TRADER JOES $12.00 excluded — reason: Duplicate."),
            "Removed from the week: TRADER JOES $12.00 (Duplicate)."
        )
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("TRADER JOES $12.00 restored to the week as posted."),
            "Back in the week: TRADER JOES $12.00."
        )
    }

    func testActivityTitleAndGrouping() {
        XCTAssertEqual(AuditFormatting.activityTitle(action: "Weeks processed", count: 3), "3 weeks closed")
        XCTAssertEqual(AuditFormatting.activityTitle(action: "Weeks processed", count: 1), "1 week closed")
        XCTAssertEqual(AuditFormatting.activityTitle(action: "CSV import", count: 2), "CSV import")
        let entries = [
            AuditDisplayEntry(action: "Weeks processed", detail: "2 weeks closed.", actor: "Admin", time: "Nov 8, 9:00 AM"),
            AuditDisplayEntry(action: "Weeks processed", detail: "2 weeks closed.", actor: "Admin", time: "Nov 8, 9:00 AM"),
            AuditDisplayEntry(action: "CSV import", detail: "3 added.", actor: "Admin", time: "Nov 8, 9:01 AM"),
        ]
        let grouped = AuditFormatting.groupDayActivity(entries)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].count, 2)
        XCTAssertEqual(grouped[1].count, 1)
    }

    func testDotClass() {
        XCTAssertEqual(AuditFormatting.dotClass(action: "Gift recorded", detail: "Charity gift"), "charity")
        XCTAssertEqual(AuditFormatting.dotClass(action: "Weeks processed", detail: ""), "system")
        XCTAssertEqual(AuditFormatting.dotClass(action: "CSV import", detail: ""), "money")
    }

    func testHistoryPeriodLabel() {
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: nil, to: nil), "")
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: "2026-11-01", to: "2026-11-08"), "Showing 2026-11-01 to 2026-11-08.")
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: "2026-11-01", to: nil), "Showing from 2026-11-01 onward.")
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: nil, to: "2026-11-08"), "Showing up to 2026-11-08.")
    }

    func testFilterRowsByDateKeepsUndatedRows() {
        struct Row { let date: String? }
        let rows = [Row(date: "2026-11-01"), Row(date: "2026-11-09"), Row(date: nil)]
        let filtered = AuditFormatting.filterRowsByDate(rows, getDate: { $0.date }, from: "2026-11-05", to: nil)
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - CSVParsing

    func testParseCSVBasic() {
        let text = "Date,Description,Amount,Card Ending\n2026-11-05,TRADER JOES,$12.34,1005\n11/06/2026,AMAZON,(5.00),2006\n"
        let parsed = CSVParsing.parseCSV(text)
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.rows[0], ParsedCSVRow(date: "2026-11-05", merchant: "TRADER JOES", amountCents: 1234, suffix: "1005"))
        XCTAssertEqual(parsed.rows[1], ParsedCSVRow(date: "2026-11-06", merchant: "AMAZON", amountCents: -500, suffix: "2006"))
    }

    func testParseCSVSkipsPreNovAndUnparseable() {
        let text = "Date,Description,Amount\n2026-10-31,OLD STORE,10.00\nbad,row\n2026-11-02,GOOD STORE,10.00\n"
        let parsed = CSVParsing.parseCSV(text)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.errors.count, 2)
        XCTAssertTrue(parsed.errors[0].contains("before Nov 1, 2026"))
        XCTAssertTrue(parsed.errors[1].contains("unparseable"))
    }

    func testParseCSVMissingColumns() {
        let parsed = CSVParsing.parseCSV("Date,Amount\n2026-11-02,10.00\n")
        XCTAssertEqual(parsed.rows, [])
        XCTAssertEqual(parsed.errors, ["Header must include Date, Description, and Amount columns."])
    }

    func testParseCSVTooShort() {
        let parsed = CSVParsing.parseCSV("Date,Description,Amount\n")
        XCTAssertEqual(parsed.errors, ["CSV needs a header row and at least one data row."])
    }

    func testCSVRowKeyNormalizesMerchant() {
        let a = CSVParsing.csvRowKey(merchant: "Trader Joe's", date: "2026-11-05", amountCents: 1234, suffix: "1005")
        let b = CSVParsing.csvRowKey(merchant: "TRADER JOES", date: "2026-11-05", amountCents: 1234, suffix: "1005")
        XCTAssertEqual(a, b)
    }

    func testClassifyKind() {
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "INTERNAL TRANSFER", amountCents: 100), "transfer")
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "CHECK DEPOSIT", amountCents: -5000), "income")
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "PAYMENT - THANK YOU", amountCents: -100), "payment")
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "CASH BACK", amountCents: -500), "cashback")
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "TOIREMORG", amountCents: 200), "charity")
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "AMAZON", amountCents: -999), "refund")
        XCTAssertEqual(CSVParsing.classifyKind(merchant: "AMAZON", amountCents: 999), "charge")
    }

    // MARK: - BankBranding

    func testBankDomainAndBrand() {
        XCTAssertEqual(BankBranding.domain(for: "Chase Sapphire"), "chase.com")
        XCTAssertEqual(BankBranding.brandHex(for: "Chase Sapphire"), "#117aca")
        XCTAssertEqual(BankBranding.brandHex(for: "Unknown Bank"), "#475569")
        XCTAssertNil(BankBranding.domain(for: "Unknown Bank"))
        XCTAssertEqual(
            BankBranding.faviconURL(for: "American Express")?.absoluteString,
            "https://www.google.com/s2/favicons?domain=americanexpress.com&sz=128"
        )
        XCTAssertEqual(BankBranding.initial(for: "Chase"), "C")
    }

    func testEmailConnectionWarnings() {
        // Grant 6 days ago -> expiring; last poll 2 days ago -> stale.
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let sixDaysAgo = Date(timeIntervalSince1970: 1_793_000_000 - 6 * 24 * 3600).isoString
        let twoDaysAgo = Date(timeIntervalSince1970: 1_793_000_000 - 2 * 24 * 3600).isoString
        XCTAssertEqual(
            EmailConnectionWarnings.warnings(status: "active", connectedAt: sixDaysAgo, createdAt: nil, lastPollAt: twoDaysAgo, now: now),
            ["expiring", "stale"]
        )
        XCTAssertEqual(
            EmailConnectionWarnings.warnings(status: "error", connectedAt: sixDaysAgo, createdAt: nil, lastPollAt: twoDaysAgo, now: now),
            []
        )
    }

    func testBankSyncToast() {
        let (text, isError) = BankSyncToast.text(
            error: nil, added: 3, updated: 1, skipped: 2, items: 2,
            duplicateRemoved: [], stale: true, minutesSincePreviousSync: 400,
            skippedByReason: ["already-known": 2], failedInstitutions: []
        )
        XCTAssertFalse(isError)
        XCTAssertTrue(text.hasPrefix("Sync done: 3 added, 1 updated, 2 skipped across 2 connected account(s)."))
        XCTAssertTrue(text.contains("400 minutes since the last one"))
        XCTAssertTrue(text.contains("already known ×2"))
        let (errText, errIsError) = BankSyncToast.text(
            error: "boom", added: 0, updated: 0, skipped: 0, items: 0,
            duplicateRemoved: [], stale: nil, minutesSincePreviousSync: nil,
            skippedByReason: nil, failedInstitutions: ["Chase"]
        )
        XCTAssertTrue(errIsError)
        XCTAssertEqual(errText, "Sync failed: boom — Chase")
    }

    func testEmailCheckMessage() {
        let (text, isError) = EmailCheckMessage.text(
            topLevelError: nil, firstConnectionError: "reauthorization required",
            stored: 0, duplicates: 0, quarantined: 0, unparseable: 0,
            stale: nil, minutesSincePreviousPoll: nil
        )
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "Email check failed: access expired — reconnect your email.")
        let (okText, okIsError) = EmailCheckMessage.text(
            topLevelError: nil, firstConnectionError: nil,
            stored: 2, duplicates: 1, quarantined: 0, unparseable: 0,
            stale: true, minutesSincePreviousPoll: 90
        )
        XCTAssertFalse(okIsError)
        XCTAssertTrue(okText.hasPrefix("Email checked: 2 added, 1 already known, 0 quarantined, 0 could not be read."))
        XCTAssertTrue(okText.contains("90 minutes since the last one"))
    }
}

private extension Date {
    var isoString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}
