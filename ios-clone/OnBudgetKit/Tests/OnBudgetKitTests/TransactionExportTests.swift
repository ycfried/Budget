import XCTest
@testable import OnBudgetKit

/// Transaction export (build 45, Nov 18, 2026): the file content
/// is decided in the kit, so the kit pins it — CSV columns and
/// escaping, the display-signed amounts (income stored negative
/// reads positive), human-readable labels (never raw enum values),
/// totals math, the PDF statement model, and the generator's
/// filter discipline (it exports exactly the rows it is given —
/// the app applies `TransactionFilters` before calling in, and the
/// generator never re-expands a filtered list).
final class TransactionExportTests: XCTestCase {
    private func txn(
        date: String = "2026-11-11",
        merchant: String = "TRADER JOES",
        amount: Int = 1234,
        suffix: String = "1005",
        source: TransactionSource = .plaid,
        state: TransactionState = .verified,
        kind: TransactionKind = .charge
    ) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: date, merchant: merchant,
                    amountCents: amount, cardSuffix: suffix, source: source, state: state,
                    kind: kind, fundAllocationCents: 0, excluded: false, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: "2026-11-11T00:00:00Z")
    }

    // MARK: - Display-signed amounts

    func testIncomeStoredNegativeReadsPositive() {
        // The owner's $3,500 check: stored -350000, kind income.
        let income = txn(merchant: "CHECK DEPOSIT", amount: -350_000, suffix: "0000", kind: .income)
        XCTAssertEqual(TransactionExport.displaySignedCents(for: income), 350_000)
        XCTAssertEqual(TransactionExport.amountText(for: income), "+$3,500.00")
        XCTAssertEqual(TransactionExport.amountDecimalText(for: income), "3500.00")
    }

    func testRefundAndCashbackReadPositive() {
        XCTAssertEqual(TransactionExport.amountDecimalText(for: txn(amount: -2500, kind: .refund)), "25.00")
        XCTAssertEqual(TransactionExport.amountDecimalText(for: txn(amount: -100, kind: .cashback)), "1.00")
        XCTAssertEqual(TransactionExport.amountText(for: txn(amount: -2500, kind: .refund)), "+$25.00")
    }

    func testChargeKeepsStoredSign() {
        XCTAssertEqual(TransactionExport.amountDecimalText(for: txn(amount: 1234)), "12.34")
        XCTAssertEqual(TransactionExport.amountText(for: txn(amount: 1234)), "$12.34")
        XCTAssertEqual(TransactionExport.amountDecimalText(for: txn(amount: -500)), "-5.00")
        XCTAssertEqual(TransactionExport.amountText(for: txn(amount: -500)), "-$5.00")
    }

    func testTransferFlipsPlaidSign() {
        // Money out, stored positive → "-100.00"; money in, stored
        // negative → "+90.00" (owner, Nov 15, 2026 — the signs were
        // backwards until the flip).
        let outTx = txn(merchant: "TRANSFER TO SAVINGS", amount: 10_000, kind: .transfer)
        XCTAssertEqual(TransactionExport.displaySignedCents(for: outTx), -10_000)
        XCTAssertEqual(TransactionExport.amountText(for: outTx), "-$100.00")
        XCTAssertEqual(TransactionExport.amountDecimalText(for: outTx), "-100.00")
        let inTx = txn(merchant: "INTERNAL TRANSFER CREDIT: SAVINGS -5939", amount: -9000, kind: .transfer)
        XCTAssertEqual(TransactionExport.amountText(for: inTx), "+$90.00")
        XCTAssertEqual(TransactionExport.amountDecimalText(for: inTx), "90.00")
    }

    func testZeroIsZeroForEveryKind() {
        for kind in [TransactionKind.charge, .income, .refund, .transfer, .charity] {
            XCTAssertEqual(TransactionExport.amountDecimalText(for: txn(amount: 0, kind: kind)), "0.00")
            XCTAssertEqual(TransactionExport.amountText(for: txn(amount: 0, kind: kind)), "$0.00")
        }
    }

    // MARK: - Labels

    func testKindNamesAreHumanReadableTitleCase() {
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .charge)), "Charge")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .fundCharge)), "Fund Charge")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .income)), "Income")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .charity)), "Charity")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .refund)), "Refund")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .transfer)), "Transfer")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .payment)), "Payment")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .cashback)), "Cashback")
        XCTAssertEqual(TransactionExport.kindName(for: txn(kind: .other("mystery_kind"))), "Mystery Kind")
    }

    func testSourceNamesAreHumanReadable() {
        XCTAssertEqual(TransactionExport.sourceName(for: txn(source: .plaid)), "Bank")
        XCTAssertEqual(TransactionExport.sourceName(for: txn(source: .amexAlert)), "Email")
        XCTAssertEqual(TransactionExport.sourceName(for: txn(source: .csv)), "CSV")
        XCTAssertEqual(TransactionExport.sourceName(for: txn(source: .manual)), "Manual")
        XCTAssertEqual(TransactionExport.sourceName(for: txn(source: .restored)), "Restored")
    }

    func testFundNameUsesCurrentDisplayNames() {
        let renamed = ["spending": "Weekly Spending", "fund": "Savings", "charity": "Tzedaka"]
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .charge), fundNames: renamed), "Weekly Spending")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .fundCharge), fundNames: renamed), "Savings")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .charity), fundNames: renamed), "Tzedaka")
        // Defaults when nothing is renamed.
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .charge)), "Spending")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .fundCharge)), "Extra Fund")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .charity)), "Charity")
        // Rows that belong to no fund never guess one.
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .income)), "—")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .refund)), "—")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .transfer)), "—")
        XCTAssertEqual(TransactionExport.fundName(for: txn(kind: .payment)), "—")
    }

    // Build 65 (merchant names ALL CAPS, display-only): the
    // export merchant name is uppercased, matching the app list
    // — the expectations below read ALL CAPS, not Title Case.
    func testMerchantUppercasesAndTransferTitlesDeriveDirection() {
        XCTAssertEqual(TransactionExport.merchantDisplay(for: txn(merchant: "TRADER JOES")), "TRADER JOES")
        XCTAssertEqual(
            TransactionExport.merchantDisplay(for: txn(merchant: "INTERNAL TRANSFER CREDIT: SAVINGS -5939", amount: -9000, kind: .transfer)),
            "TRANSFER FROM ••5939"
        )
        XCTAssertEqual(
            TransactionExport.merchantDisplay(for: txn(merchant: "TRANSFER TO SAVINGS", amount: 10_000, kind: .transfer)),
            "TRANSFER TO"
        )
        XCTAssertEqual(
            TransactionExport.merchantDisplay(for: txn(merchant: "TRANSFER", amount: 0, kind: .transfer)),
            "TRANSFER"
        )
    }

    func testCardDisplayUsesCashForNoCard() {
        XCTAssertEqual(TransactionExport.cardDisplay(for: txn(suffix: "1005")), "••1005")
        XCTAssertEqual(TransactionExport.cardDisplay(for: txn(suffix: "0000")), "Cash")
    }

    // MARK: - CSV

    func testCSVHeaderAndRowContent() {
        let rows = [
            txn(date: "2026-11-11", merchant: "TRADER JOES", amount: 1234, suffix: "1005"),
            txn(date: "2026-11-17", merchant: "CHECK DEPOSIT", amount: -350_000, suffix: "0000", kind: .income),
            txn(date: "2026-11-12", merchant: "TENYAD KALLAH GEMACH", amount: 200, suffix: "0000", kind: .charity),
        ]
        let csv = TransactionExport.csvString(transactions: rows)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(lines[0]), "Date,Merchant,Amount,Kind,Source,Fund,Card")
        XCTAssertEqual(String(lines[1]), "2026-11-11,TRADER JOES,12.34,Charge,Bank,Spending,••1005")
        XCTAssertEqual(String(lines[2]), "2026-11-17,CHECK DEPOSIT,3500.00,Income,Bank,—,Cash")
        XCTAssertEqual(String(lines[3]), "2026-11-12,TENYAD KALLAH GEMACH,2.00,Charity,Bank,Charity,Cash")
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testCSVQuotesCommaQuoteAndNewlineMerchants() {
        XCTAssertEqual(TransactionExport.csvField("Plain Merchant"), "Plain Merchant")
        XCTAssertEqual(TransactionExport.csvField("Smith, Jones"), "\"Smith, Jones\"")
        XCTAssertEqual(TransactionExport.csvField("Say \"Hi\""), "\"Say \"\"Hi\"\"\"")
        XCTAssertEqual(TransactionExport.csvField("Line One\nLine Two"), "\"Line One\nLine Two\"")
        // A merchant with a comma lands quoted inside the row —
        // uppercased, like every exported merchant (build 65).
        let csv = TransactionExport.csvString(transactions: [txn(merchant: "SMITH, JONES LLC")])
        XCTAssertTrue(csv.contains(",\"SMITH, JONES LLC\",12.34,"))
    }

    func testCSVOfEmptyListIsHeaderOnly() {
        XCTAssertEqual(TransactionExport.csvString(transactions: []), "Date,Merchant,Amount,Kind,Source,Fund,Card\n")
    }

    func testCSVExportsExactlyTheRowsGiven() {
        // Filter discipline: the generator never re-expands. Given
        // one spending row, the file holds one row — the caller
        // (the app, after `TransactionFilters.apply`) owns the
        // selection, and the generator cannot add rows back.
        let spending = txn(merchant: "TRADER JOES", amount: 1234)
        let csv = TransactionExport.csvString(transactions: [spending])
        XCTAssertFalse(csv.contains("Gemach"))
        XCTAssertTrue(csv.contains("TRADER JOES"))
    }

    // MARK: - Totals

    func testTotalsSplitInOutAndNet() {
        let rows = [
            txn(amount: 1234, kind: .charge),          // out 12.34
            txn(amount: -350_000, kind: .income),      // in 3500.00
            txn(amount: -2500, kind: .refund),         // in 25.00
            txn(amount: 10_000, kind: .transfer),      // out 100.00 (flipped)
            txn(amount: 200, kind: .charity),          // out 2.00
        ]
        let totals = TransactionExport.totals(transactions: rows)
        XCTAssertEqual(totals.totalInCents, 352_500)
        XCTAssertEqual(totals.totalOutCents, 11_434)
        XCTAssertEqual(totals.netCents, 341_066)
    }

    func testTotalsOfEmptyListAreZero() {
        let totals = TransactionExport.totals(transactions: [])
        XCTAssertEqual(totals.totalInCents, 0)
        XCTAssertEqual(totals.totalOutCents, 0)
        XCTAssertEqual(totals.netCents, 0)
    }

    func testBarePositiveChargeCountsAsOutNotIn() {
        // Regression (run 44447736279): a charge displays as a
        // bare "$12.34" — no minus — but it is money out. A
        // sign-based split counted it as money in.
        let totals = TransactionExport.totals(transactions: [txn(amount: 1234, kind: .charge)])
        XCTAssertEqual(totals.totalInCents, 0)
        XCTAssertEqual(totals.totalOutCents, 1234)
        XCTAssertEqual(totals.netCents, -1234)
        // And a payment is money out too, not money in.
        let paid = TransactionExport.totals(transactions: [txn(amount: 5000, kind: .payment)])
        XCTAssertEqual(paid.totalInCents, 0)
        XCTAssertEqual(paid.totalOutCents, 5000)
    }

    // MARK: - PDF statement model

    func testPDFStatementHeaderRowsAndTotals() {
        let rows = [
            txn(date: "2026-11-11", merchant: "TRADER JOES", amount: 1234),
            txn(date: "2026-11-17", merchant: "CHECK DEPOSIT", amount: -350_000, suffix: "0000", kind: .income),
        ]
        let statement = TransactionExport.pdfStatement(
            transactions: rows, householdName: "Simcha House!", generatedDate: "2026-11-18"
        )
        XCTAssertEqual(statement.householdName, "Simcha House!")
        XCTAssertEqual(statement.dateRange, "Nov 11, 2026 – Nov 17, 2026")
        XCTAssertEqual(statement.generatedLine, "Generated Nov 18, 2026")
        XCTAssertEqual(statement.rows.count, 2)
        XCTAssertEqual(statement.rows[0].date, "Nov 11, 2026")
        XCTAssertEqual(statement.rows[0].merchant, "TRADER JOES")
        XCTAssertEqual(statement.rows[0].amount, "$12.34")
        XCTAssertEqual(statement.rows[0].kind, "Charge")
        XCTAssertEqual(statement.rows[1].amount, "+$3,500.00")
        XCTAssertEqual(statement.rows[1].kind, "Income")
        XCTAssertEqual(statement.totalInText, "$3,500.00")
        XCTAssertEqual(statement.totalOutText, "$12.34")
        // Net is money in overall here: the PDF prints a
        // positive net with a "+" (`signedNetText`, build 74) —
        // the list total's `netTotalText` prints it bare, but
        // that convention is inverted for the statement (a
        // negative net there means more out than in).
        XCTAssertEqual(statement.netText, "+$3,487.66")
    }

    func testPDFStatementSingleDateAndEmptyRange() {
        let one = TransactionExport.pdfStatement(
            transactions: [txn(date: "2026-11-11")], householdName: "H", generatedDate: "2026-11-18"
        )
        XCTAssertEqual(one.dateRange, "Nov 11, 2026")
        let empty = TransactionExport.pdfStatement(
            transactions: [], householdName: "H", generatedDate: "2026-11-18"
        )
        XCTAssertEqual(empty.dateRange, "All Transactions")
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(empty.totalInText, "$0.00")
        XCTAssertEqual(empty.netText, "$0.00")
    }

    func testPDFStatementHasNoRawEnumValuesOrIds() {
        let rows = [txn(amount: 500, source: .amexAlert, kind: .fundCharge)]
        let statement = TransactionExport.pdfStatement(
            transactions: rows, householdName: "Simcha House!", generatedDate: "2026-11-18"
        )
        XCTAssertEqual(statement.rows[0].kind, "Fund Charge")
        XCTAssertFalse(statement.rows[0].merchant.contains("fund_charge"))
        XCTAssertFalse(statement.rows[0].merchant.contains("amex_alert"))
    }

    // MARK: - Charts (build 59, Nov 22, 2026)

    func testChartsInVsOutAndKindAndCharityShare() {
        let rows = [
            txn(amount: 1234, kind: .charge),          // out 12.34
            txn(amount: -350_000, kind: .income),      // in 3500.00
            txn(amount: -2500, kind: .refund),         // in 25.00
            txn(amount: 10_000, kind: .transfer),      // out 100.00
            txn(amount: 200, kind: .charity),          // out 2.00
        ]
        let charts = TransactionExport.charts(transactions: rows)
        XCTAssertEqual(charts.count, 3)

        // 1. In vs Out: in 3525.00 deep blue, out 114.34 ink.
        XCTAssertEqual(charts[0].title, "Money In vs Out")
        XCTAssertEqual(charts[0].totalCents, 363_934)
        XCTAssertEqual(charts[0].slices[0].label, "Money In")
        XCTAssertEqual(charts[0].slices[0].cents, 352_500)
        XCTAssertEqual(charts[0].slices[0].colorHex, "#1d4ed8")
        XCTAssertEqual(charts[0].slices[1].label, "Money Out")
        XCTAssertEqual(charts[0].slices[1].cents, 11_434)
        XCTAssertEqual(charts[0].slices[1].colorHex, "#0f172a")

        // 2. Spending by kind: biggest first, brand colours.
        XCTAssertEqual(charts[1].title, "Spending by Kind")
        XCTAssertEqual(charts[1].totalCents, 11_434)
        XCTAssertEqual(charts[1].slices[0].label, "Transfer")
        XCTAssertEqual(charts[1].slices[0].cents, 10_000)
        XCTAssertEqual(charts[1].slices[0].colorHex, "#3b82f6")
        XCTAssertEqual(charts[1].slices[1].label, "Charge")
        XCTAssertEqual(charts[1].slices[1].cents, 1234)
        XCTAssertEqual(charts[1].slices[1].colorHex, "#0f172a")
        XCTAssertEqual(charts[1].slices[2].label, "Charity")
        XCTAssertEqual(charts[1].slices[2].cents, 200)
        XCTAssertEqual(charts[1].slices[2].colorHex, "#2f6bff")

        // 3. Tzedaka share: charity blue vs everything else.
        XCTAssertEqual(charts[2].title, "Tzedaka Share")
        XCTAssertEqual(charts[2].totalCents, 11_434)
        XCTAssertEqual(charts[2].slices[0].label, "Tzedaka")
        XCTAssertEqual(charts[2].slices[0].cents, 200)
        XCTAssertEqual(charts[2].slices[0].colorHex, "#2f6bff")
        XCTAssertEqual(charts[2].slices[1].label, "Everything Else")
        XCTAssertEqual(charts[2].slices[1].cents, 11_234)
        XCTAssertEqual(charts[2].slices[1].colorHex, "#e5e7eb")
    }

    func testChartsMatchTotalsAndTable() {
        // The charts are built from the same rows as the table,
        // so their totals can never drift from the footer.
        let rows = [
            txn(amount: 5000, kind: .charge),
            txn(amount: -100_000, kind: .income),
            txn(amount: 750, kind: .charity),
        ]
        let statement = TransactionExport.pdfStatement(
            transactions: rows, householdName: "H", generatedDate: "2026-11-22"
        )
        XCTAssertEqual(statement.charts[0].totalCents,
                       statement.totals.totalInCents + statement.totals.totalOutCents)
        XCTAssertEqual(statement.charts[1].totalCents, statement.totals.totalOutCents)
        XCTAssertEqual(statement.charts[2].totalCents, statement.totals.totalOutCents)
        // The charity slice is the same money as the charity row.
        XCTAssertEqual(statement.charts[2].slices[0].cents, 750)
    }

    func testChartsOmitEmptyAndZeroSlices() {
        // Nothing to chart at all.
        XCTAssertTrue(TransactionExport.charts(transactions: []).isEmpty)
        // Income only: the In vs Out chart would be one slice
        // (build 74 — a single-slice chart is omitted, not drawn
        // as a dot), so there is no Summary at all.
        let incomeOnly = TransactionExport.charts(transactions: [
            txn(amount: -100_000, kind: .income),
        ])
        XCTAssertTrue(incomeOnly.isEmpty)
        // No charity: no Tzedaka Share chart — and Spending by
        // Kind is a single charge slice, so it is omitted too;
        // only Money In vs Out remains.
        let noCharity = TransactionExport.charts(transactions: [
            txn(amount: 5000, kind: .charge),
            txn(amount: -100_000, kind: .income),
        ])
        XCTAssertEqual(noCharity.count, 1)
        XCTAssertEqual(noCharity[0].title, "Money In vs Out")
        XCTAssertFalse(noCharity.contains { $0.title == "Tzedaka Share" })
    }

    func testDonationsOnlyExportHasNoSummaryAndNegativeNet() {
        // Build 74 (owner, Nov 25, 2026): the Tzedaka-gifts
        // export — $0 in, $834.85 out, all charity. Every chart
        // would be a single 100% slice, so there is no Summary
        // at all; the net is negative (more out than in), not
        // "+$834.85".
        let rows = [
            txn(amount: 50_000, kind: .charity),
            txn(amount: 33_485, kind: .charity),
        ]
        let statement = TransactionExport.pdfStatement(
            transactions: rows, householdName: "H", generatedDate: "2026-11-22"
        )
        XCTAssertTrue(statement.charts.isEmpty)
        XCTAssertEqual(statement.totalInText, "$0.00")
        XCTAssertEqual(statement.totalOutText, "$834.85")
        XCTAssertEqual(statement.netText, "-$834.85")
    }

    func testRowColorsFollowTheTransactionColourCode() {
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: -100_000, kind: .income)), "#1d4ed8")
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: -2500, kind: .refund)), "#1d4ed8")
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: 200, kind: .charity)), "#2f6bff")
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: 1234, kind: .charge)), "#0f172a")
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: 5000, kind: .payment)), "#0f172a")
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: 10_000, kind: .transfer)), "#6b7280")
        XCTAssertEqual(TransactionExport.rowColorHex(for: txn(amount: 0, kind: .charge)), "#0f172a")
        // An excluded row reads grey whatever its kind.
        let excluded = txn(amount: -100_000, state: .excluded, kind: .income)
        XCTAssertEqual(TransactionExport.rowColorHex(for: excluded), "#6b7280")
        // The statement carries the colour on each row.
        let statement = TransactionExport.pdfStatement(
            transactions: [txn(amount: -100_000, kind: .income), txn(amount: 200, kind: .charity)],
            householdName: "H", generatedDate: "2026-11-22"
        )
        XCTAssertEqual(statement.rows[0].colorHex, "#1d4ed8")
        XCTAssertEqual(statement.rows[1].colorHex, "#2f6bff")
        // One chart only (build 74): Money In vs Out — Spending
        // by Kind would be a single charity slice and Tzedaka
        // Share would be 100% Tzedaka, so both are omitted.
        XCTAssertEqual(statement.charts.count, 1)
    }

    // MARK: - Filenames

    func testExportFileNamesCarryTheDateAndFormat() {
        XCTAssertEqual(TransactionExportFormat.csv.fileName(generatedDate: "2026-11-18"), "transactions-2026-11-18.csv")
        XCTAssertEqual(TransactionExportFormat.pdf.fileName(generatedDate: "2026-11-18"), "transactions-2026-11-18.pdf")
        XCTAssertEqual(TransactionExportFormat.csv.label, "CSV")
        XCTAssertEqual(TransactionExportFormat.pdf.label, "PDF")
        XCTAssertEqual(TransactionExportScope.filtered.label, "Filtered")
        XCTAssertEqual(TransactionExportScope.all.label, "All")
    }
}
