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

    func testWholeDollars() {
        // Widget-only, owner Nov 15 2026: whole dollars, rounded.
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 39365), "$394")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 66300), "$663")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 40000), "$400")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 0), "$0")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 123456), "$1,235")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: -15897), "-$159")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 50), "$1")
        XCTAssertEqual(MoneyFormat.wholeDollars(cents: 49), "$0")
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

    // MARK: - MoneyFormat additions (integration, Nov 9, 2026):
    // APIs ported in from the deleted app-target MoneyFormat copies
    // so the kit type is the single owner.

    func testStringPartsSignedString() {
        XCTAssertEqual(MoneyFormat.string(cents: 123456), "$1,234.56")
        XCTAssertEqual(MoneyFormat.string(cents: -15897), "-$158.97")
        XCTAssertEqual(MoneyFormat.signedString(cents: -500), "-$5.00")
        let parts = MoneyFormat.parts(cents: 123456)
        XCTAssertEqual(parts.sign, "")
        XCTAssertEqual(parts.dollars, "1,234")
        XCTAssertEqual(parts.cents, "56")
        XCTAssertEqual(MoneyFormat.parts(cents: -99).sign, "-")
    }

    func testRateBpRoundTrip() {
        XCTAssertEqual(MoneyFormat.formatRateBp(1000), "10")
        XCTAssertEqual(MoneyFormat.formatRateBp(1050), "10.5")
        XCTAssertEqual(MoneyFormat.parseRatePercent("10.5"), 1050)
        XCTAssertEqual(MoneyFormat.parseRatePercent("10"), 1000)
        XCTAssertNil(MoneyFormat.parseRatePercent("abc"))
        XCTAssertNil(MoneyFormat.parseRatePercent("101"))
    }

    func testDateHelpersAndDataFloor() {
        XCTAssertEqual(MoneyFormat.dataFloor, "2026-11-01")
        XCTAssertEqual(MoneyFormat.dateString(from: MoneyFormat.date(from: "2026-11-08")!), "2026-11-08")
        XCTAssertEqual(MoneyFormat.displayDay("2026-11-08T19:30:00Z"), "Nov 8, 2026")
        XCTAssertEqual(MoneyFormat.sundays(from: "2026-11-08", count: 3),
                       ["2026-11-08", "2026-11-15", "2026-11-22"])
        XCTAssertEqual(MoneyFormat.sundays(from: "2026-11-08", count: 9).count, 4)
        XCTAssertEqual(MoneyFormat.daysBetween("2026-11-08", "2026-11-15"), 7)
        XCTAssertNil(MoneyFormat.daysBetween("nope", "2026-11-15"))
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
        XCTAssertEqual(
            AuditFormatting.formatDetail("Default charity rate set to 2000 basis points."),
            "20% · future income only"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Row reclassified as provisional."),
            "Row reclassified as pending"
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
        // "admin"/"member" are role placeholders, not people — a
        // system row never names a fake person (owner, Nov 14,
        // 2026); the view shows the time only for those rows.
        XCTAssertEqual(AuditFormatting.formatActor("admin"), "")
        XCTAssertEqual(AuditFormatting.formatActor("member"), "")
        XCTAssertEqual(AuditFormatting.formatActor("shuki@example.com"), "shuki")
        XCTAssertEqual(AuditFormatting.formatActor("Shuki Friedman"), "Shuki Friedman")
    }

    func testNormalCaseMerchant() {
        XCTAssertEqual(AuditFormatting.normalCaseMerchant("TOIREMORG CHARITY"), "Toiremorg Charity")
        XCTAssertEqual(AuditFormatting.normalCaseMerchant("WALMART $56.34"), "Walmart $56.34")
        XCTAssertEqual(AuditFormatting.normalCaseMerchant("7-ELEVEN"), "7-Eleven")
        XCTAssertEqual(AuditFormatting.normalCaseMerchant("MCDONALD'S"), "Mcdonald's")
        XCTAssertEqual(AuditFormatting.normalCaseMerchant("SUNOCO INSIDE SALES"), "Sunoco Inside Sales")
    }

    func testSimplifyMergedDuplicate() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail(
                "Merged duplicate (TOIREMORG CHARITY $1.00) into the original bank row (TOIREMORG $1.00). Duplicate excluded, not deleted. Note: merge"
            ),
            "TOIREMORG CHARITY $1.00 · counted once"
        )
    }

    func testSimplifyWeeksClosedDropsZeroParts() {
        // Owner, Nov 12 2026: the TITLE carries the week count, so
        // the detail never restates it — only the new information
        // (releases / restorations / held) stays.
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("2 weeks closed, 1 surplus released, 0 refunds restored, 0 refunds held for review."),
            "1 surplus released"
        )
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("1 week closed, 0 surpluses released, 0 refunds restored, 0 refunds held for review."),
            ""
        )
        XCTAssertEqual(AuditFormatting.simplifyDetail("2 weeks closed."), "")
    }

    func testSimplifyNoOpAllowanceNeverRendersAsAChange() {
        // The no-op row is written server-side by set_base_allowance
        // with no old==new guard; the display side renders it as the
        // plain value (owner, Nov 12 2026). A real change keeps only
        // the values — the title already says it changed.
        XCTAssertEqual(
            AuditFormatting.formatDetail("Base allowance changed from 40000 cents to 40000 cents."),
            "$400.00"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Base allowance changed from 37500 cents to 40000 cents."),
            "$375.00 → $400.00"
        )
        // And the row itself never renders at all: the view drops
        // no-op allowance entries (owner, Nov 14, 2026 — the
        // $400 → $400 row stored Nov 11 still showed as a change).
        XCTAssertTrue(AuditFormatting.isNoOpAllowanceChange(
            action: "Base allowance changed", detail: "$400.00"))
        XCTAssertFalse(AuditFormatting.isNoOpAllowanceChange(
            action: "Base allowance changed", detail: "$375.00 → $400.00"))
        XCTAssertFalse(AuditFormatting.isNoOpAllowanceChange(
            action: "Base allowance set", detail: "$400.00"))
    }

    func testSimplifyCharityMarkIsOneShortLine() {
        // The detail names the transaction only — the title already
        // says it was marked as a charity gift (owner, Nov 14,
        // 2026: no title repeating its subtitle).
        XCTAssertEqual(
            AuditFormatting.formatDetail("Walmart 5634 cents on 2026-11-10 marked as a charity gift (now outside weekly spending)."),
            "Walmart $56.34"
        )
    }

    func testSimplifyMemberRemovedIsOneShortLine() {
        // One line naming who — the stored "They can no longer see
        // the household." tail is wordy and pushed the line past
        // the right edge (owner, Nov 14, 2026).
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("Removed chayasf1 from the household. They can no longer see the household."),
            "chayasf1"
        )
    }

    func testSimplifyRestatementsAreEmpty() {
        // The title says the thing once; a detail that adds nothing
        // renders empty and the row hides the line (owner, Nov 12
        // 2026).
        XCTAssertEqual(AuditFormatting.simplifyDetail("Joined the household."), "")
        XCTAssertEqual(AuditFormatting.simplifyDetail("Joined via invite code."), "")
        XCTAssertEqual(AuditFormatting.simplifyDetail("Household created."), "")
        XCTAssertEqual(AuditFormatting.simplifyDetail("Request approved."), "")
        XCTAssertEqual(AuditFormatting.simplifyDetail("Request approved for $50.00."), "$50.00")
    }

    func testActivityTypeClassification() {
        typealias ActivityType = AuditFormatting.ActivityType
        XCTAssertEqual(ActivityType.classify(action: "Weeks processed", detail: "1 surplus released."), .weekCloses)
        XCTAssertEqual(ActivityType.classify(action: "Household joined", detail: "Joined the household."), .members)
        XCTAssertEqual(ActivityType.classify(action: "Member promoted", detail: ""), .members)
        XCTAssertEqual(ActivityType.classify(action: "Base allowance changed", detail: "Base allowance: $400.00."), .allowance)
        XCTAssertEqual(ActivityType.classify(action: "Temporary increase added", detail: ""), .allowance)
        XCTAssertEqual(ActivityType.classify(action: "Transaction marked as charity gift", detail: "Walmart $56.34."), .charity)
        XCTAssertEqual(ActivityType.classify(action: "Income recorded", detail: "Income $700.00 — $70.00 to charity."), .charity)
        XCTAssertEqual(ActivityType.classify(action: "Duplicate merged", detail: "Toiremorg Charity $1.00 counted once."), .duplicates)
        XCTAssertEqual(ActivityType.classify(action: "Transaction excluded", detail: "Removed from the week: Trader Joes $12.00."), .trash)
        XCTAssertEqual(ActivityType.classify(action: "Transaction deleted", detail: "Deleted for good: X $1.00."), .trash)
        XCTAssertEqual(ActivityType.classify(action: "CSV import", detail: "3 added."), .other)
        XCTAssertEqual(ActivityType.classify(action: "Extra Fund request approved", detail: "$50.00."), .other)
    }

    func testSimplifySurplusReleased() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("Surplus $120.00 for week Nov 1, 2026 released to the Extra Fund."),
            "$120.00 → Extra Fund · Week of Nov 1, 2026"
        )
    }

    func testSimplifyExcludedAndRestored() {
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("TRADER JOES $12.00 excluded — reason: Duplicate."),
            "TRADER JOES $12.00 · excluded · Duplicate"
        )
        XCTAssertEqual(
            AuditFormatting.simplifyDetail("TRADER JOES $12.00 restored to the week as posted."),
            "TRADER JOES $12.00"
        )
    }

    func testSimplifyFactFirstLines() {
        // Fact-first redesign (owner, Nov 26, 2026): one short
        // structured line per entry, fact first, never a sentence,
        // merchants ALL CAPS as stored, " · " separators, " → "
        // for renames and money moves, no trailing period. Inputs
        // are the stored `audit_log` details (cents, ISO dates,
        // UUIDs) run through `formatDetail`, as the view does.
        XCTAssertEqual(
            AuditFormatting.formatDetail("Renamed \"CLOUDFLARE HQ\" to \"CLOUDFLARE\" (kind charge) (matches \"CLOUDFLARE\") — 2 row(s) updated, rule applies to new rows too."),
            "CLOUDFLARE HQ → CLOUDFLARE · 2 rows · applies to new rows"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Surplus 17999 cents for week 2026-11-08 paid toward the carried debt before the remainder became surplus."),
            "$179.99 → Carried Debt · Week of Nov 8, 2026"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("ROYAL FARMS 763 cents removed from recurring expenses — the transaction counts as a purchase again."),
            "ROYAL FARMS $7.63 · counts as a purchase again"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("ROYAL FARMS 763 cents tagged as a recurring expense (monthly) — no reason given."),
            "ROYAL FARMS $7.63 · recurring · monthly"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Same-source duplicate KEREN HATZEDAKA 200 cents (kind charity) shares dedupe_hash with a kept row; excluded as a duplicate."),
            "KEREN HATZEDAKA $2.00 · counted once"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Manual top-up 74000 cents: 0 cents covered shortfall, 74000 cents added to fund, 0 cents owed back after. Note: video-fixture savings top-up"),
            "$740.00"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Manual top-up 20000 cents saved as pending — not in checking yet. Note: From NYS"),
            "$200.00 · pending"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Paid 5000 cents toward the carried debt from the Extra Fund."),
            "$50.00 → Carried Debt · Extra Fund"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Cleared 112796 cents of carried debt by hand (partial clear of 112796 cents; 112796 cents owed before, 0 cents remain)."),
            "$1,127.96 cleared · $0.00 remains"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Requested $10.15 for Proof11 Bulk 015."),
            "$10.15 · Proof11 Bulk 015"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Fund debt hidden from Home."),
            "Debt"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Fund debt shown on Home again."),
            "Debt"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Fund debt renamed to \"Debt\"."),
            "debt → Debt"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Disconnected ycfried1@gmail.com from email alerts."),
            "ycfried1@gmail.com"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("chayasf1 was made an admin (co-admin)."),
            "chayasf1 · admin"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Re-linked refund 11111111-2222-3333-4444-555555555555 (WALMART -2416 cents) from excluded charge 11111111-2222-3333-4444-555555555555 to live charge 11111111-2222-3333-4444-555555555555 so the refund restores the counted purchase. Note: re-link"),
            "Re-linked refund (WALMART -$24.16) from excluded charge to live charge so the refund restores the counted purchase. Note: re-link"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Restored MOBILE CHECK DEPOSIT -350000 cents to verified (posted) by owner-approved one-off repair; Plaid removed[] reversal had no snapshot."),
            "MOBILE CHECK DEPOSIT -$3,500.00"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Income YEHOSHUA FRIEDMAN 300000 cents on 2026-11-23 at 1000 basis points commits 30000 cents to charity."),
            "YEHOSHUA FRIEDMAN $3,000.00 · $300.00 to charity"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Income Mobile Check Deposit 700000 cents reversed and replaced by Mobile Check Deposit 700000 cents at 1000 basis points, committing 70000 cents."),
            "Mobile Check Deposit $7,000.00 · $700.00 to charity"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Income YEHOSHUA FRIEDMAN 300000 cents on 2026-11-23 at 1000 basis points was excluded; 30000 cents deducted from charity owed."),
            "YEHOSHUA FRIEDMAN $3,000.00 · $300.00 off charity owed"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Cash gift 6768 cents on 2026-11-16 (Available 59532 cents after)."),
            "$67.68"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Gift TEST ORG 500 cents on 2026-11-17."),
            "TEST ORG $5.00"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Weekly allowance set to 37500 cents for week 2026-11-08."),
            "$375.00 · Week of Nov 8, 2026"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Default charity rate set to 1000 basis points (applies to future incomes only)."),
            "10% · future income only"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("Debt repayment rule set to off (applies to the current open week and future weeks; closed weeks keep their stored payment)."),
            "Off"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("TEA $5.00 on Nov 25, 2026."),
            "TEA $5.00"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("ERIE INSURANCE 198600 cents reclassified from transfer to charge — reason: Insurance."),
            "ERIE INSURANCE $1,986.00 · counts as a charge · Insurance"
        )
        XCTAssertEqual(
            AuditFormatting.formatDetail("CONG HANOE VHANETZACH $1.00 moved to trash — reason: Duplice."),
            "CONG HANOE VHANETZACH $1.00 · Duplice"
        )
    }

    func testActivityTitleAndGrouping() {
        // No unexplained count (owner, Nov 14, 2026): the stored
        // rows do not name which weeks were closed, so the title
        // carries no number — singular/plural only.
        XCTAssertEqual(AuditFormatting.activityTitle(action: "Weeks processed", count: 3), "Weeks Closed")
        XCTAssertEqual(AuditFormatting.activityTitle(action: "Weeks processed", count: 1), "Week Closed")
        XCTAssertEqual(AuditFormatting.activityTitle(action: "CSV import", count: 2), "CSV Import")
        XCTAssertEqual(AuditFormatting.activityTitle(action: "Transaction added by hand", count: 1), "Transaction Added by Hand")
        let entries = [
            AuditDisplayEntry(action: "Weeks processed", detail: "1 surplus released.", actor: "Admin", time: "Nov 8, 9:00 AM"),
            AuditDisplayEntry(action: "Weeks processed", detail: "1 surplus released.", actor: "Admin", time: "Nov 8, 9:00 AM"),
            AuditDisplayEntry(action: "CSV import", detail: "3 added.", actor: "Admin", time: "Nov 8, 9:01 AM"),
        ]
        let grouped = AuditFormatting.groupDayActivity(entries)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].count, 2)
        XCTAssertEqual(grouped[1].count, 1)
    }

    // No dot-colour test any more (owner, Nov 14, 2026): the dots
    // are one muted grey for every row — the colour key is gone,
    // and `dotClass` was deleted with it.

    func testHistoryPeriodLabel() {
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: nil, to: nil), "")
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: "2026-11-01", to: "2026-11-08"), "Showing Nov 1, 2026 to Nov 8, 2026.")
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: "2026-11-01", to: nil), "Showing from Nov 1, 2026 onward.")
        XCTAssertEqual(AuditFormatting.historyPeriodLabel(from: nil, to: "2026-11-08"), "Showing up to Nov 8, 2026.")
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
        // Server skip-reason slugs map to plain words (audit
        // S-P2-9); unknown keys fall back to a generic plain line,
        // never the raw slug.
        let (slugText, _) = BankSyncToast.text(
            error: nil, added: 0, updated: 0, skipped: 4, items: 1,
            duplicateRemoved: [], stale: nil, minutesSincePreviousSync: nil,
            skippedByReason: ["account-disconnected": 1, "invalid-amount": 2, "some-new-reason": 1],
            failedInstitutions: []
        )
        XCTAssertTrue(slugText.contains("account disconnected ×1"))
        XCTAssertTrue(slugText.contains("invalid amount ×2"))
        XCTAssertTrue(slugText.contains("another reason ×1"))
        XCTAssertFalse(slugText.contains("some-new-reason"))
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
        // Any other server error maps to plain words — the raw text
        // never reaches the user (audit S-P1-3).
        let (genericText, genericIsError) = EmailCheckMessage.text(
            topLevelError: nil, firstConnectionError: "Error: invalid_grant (server exploded)",
            stored: 0, duplicates: 0, quarantined: 0, unparseable: 0,
            stale: nil, minutesSincePreviousPoll: nil
        )
        XCTAssertTrue(genericIsError)
        XCTAssertEqual(genericText, "Email check failed. Try again.")
        XCTAssertFalse(genericText.contains("invalid_grant"))
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

    // MARK: - Wordmark

    func testStageWordmarkIsUniformBlue() {
        // Build 50 (owner, Nov 19–20, 2026): the whole STAGE
        // lockup — S logo, letters AND dots — is one uniform blue
        // #0288dd, so it reads as one word S · T · A · G · E. The
        // old spec colours (dark green letters #20392f, gold dots
        // #b08d57) are retired for the wordmark.
        XCTAssertEqual(DesignTokens.stageBlueHex, "#0288dd")
    }
}
