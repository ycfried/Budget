import XCTest
@testable import OnBudget
import OnBudgetKit

/// Actions sheet labels + colours (build 62, owner Nov 22, 2026):
/// "change spending to purchase", "change mark as tzedaka to just
/// plain tzedaka.. the description should say what it is", "The
/// word should just name the category", and "This page needs a bit
/// more color.. too many options that all look the same.. things
/// need to be easier and nicer to spot.."
/// Shipped in build 62 under the owner's blanket TestFlight approval.
///
/// The label names the category; the subline says what it does;
/// each option is colour-coded from the transaction colour code
/// with an SF Symbol, so it is easy to spot at a glance. These
/// tests pin the pure label/style mapping (static on
/// TransactionActionsSheet) so a future change cannot silently
/// reintroduce "Spending" or "Mark as Tzedaka", or un-colour the
/// rows. The group composition itself (which actions a charity
/// row offers) is verified by code review + the owner's device
/// check — the sheet needs a view model to build, so it is not
/// unit-tested here.
final class TransactionActionsSheetTests: XCTestCase {

    // MARK: - Labels name the category

    func testChargeLabelIsPurchaseNotSpending() {
        XCTAssertEqual(
            TransactionActionsSheet.kindLabel(.charge, charityName: "Tzedaka"),
            "Purchase"
        )
    }

    func testCharityLabelIsJustTheFundName() {
        // Not "Mark as Tzedaka" — the label names the category;
        // the subline says what it does.
        XCTAssertEqual(
            TransactionActionsSheet.kindLabel(.charity, charityName: "Tzedaka"),
            "Tzedaka"
        )
    }

    func testCharityLabelFollowsARenamedFund() {
        XCTAssertEqual(
            TransactionActionsSheet.kindLabel(.charity, charityName: "Ma'aser"),
            "Ma'aser"
        )
    }

    func testOtherKindLabelsArePlainCategoryNames() {
        let charityName = "Tzedaka"
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.income, charityName: charityName), "Income")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.refund, charityName: charityName), "Refund")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.transfer, charityName: charityName), "Transfer")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.fundCharge, charityName: charityName), "Fund Charge")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.payment, charityName: charityName), "Payment")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.cashback, charityName: charityName), "Cashback")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.expense, charityName: charityName), "Expense")
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.other("custom_kind"), charityName: charityName), "Other")
    }

    // MARK: - Sublines say what the option does

    func testChargeSublineSaysPurchase() {
        XCTAssertEqual(
            TransactionActionsSheet.kindSubline(.charge),
            "Count it as a purchase"
        )
    }

    func testCharitySublineSaysWhatItDoes() {
        XCTAssertEqual(
            TransactionActionsSheet.kindSubline(.charity),
            "Count it as a charity gift"
        )
    }

    // Build 67 (owner, Nov 23, 2026): Expense names the category
    // and its subline says what it does — out of weekly spending,
    // into the recurring living costs.
    func testExpenseLabelAndSubline() {
        XCTAssertEqual(
            TransactionActionsSheet.kindLabel(.expense, charityName: "Tzedaka"),
            "Expense"
        )
        XCTAssertEqual(
            TransactionActionsSheet.kindSubline(.expense),
            "Count it as a recurring living cost, out of weekly spending"
        )
    }

    // MARK: - Colour-coded, distinguishable options

    func testPurchaseIsInkWithABagIcon() {
        let style = TransactionActionsSheet.kindStyle(.charge)
        XCTAssertEqual(style.colorHex, DesignTokens.inkHex)
        XCTAssertEqual(style.icon, "bag")
    }

    func testIncomeIsDeepBlue() {
        let style = TransactionActionsSheet.kindStyle(.income)
        XCTAssertEqual(style.colorHex, DesignTokens.deepHex)
        XCTAssertEqual(style.icon, "arrow.down.left")
    }

    func testTzedakaIsPrimaryBlueWithAHeartIcon() {
        let style = TransactionActionsSheet.kindStyle(.charity)
        XCTAssertEqual(style.colorHex, DesignTokens.primaryHex)
        XCTAssertEqual(style.icon, "heart")
    }

    func testMoneyInKindsAreDeepBlue() {
        // Refunds and cashback are money in, like income.
        XCTAssertEqual(TransactionActionsSheet.kindStyle(.refund).colorHex, DesignTokens.deepHex)
        XCTAssertEqual(TransactionActionsSheet.kindStyle(.cashback).colorHex, DesignTokens.deepHex)
    }

    func testTransferAndPaymentAreMutedGrey() {
        XCTAssertEqual(TransactionActionsSheet.kindStyle(.transfer).colorHex, DesignTokens.mutedHex)
        XCTAssertEqual(TransactionActionsSheet.kindStyle(.payment).colorHex, DesignTokens.mutedHex)
    }

    func testFundChargeIsFundAmber() {
        XCTAssertEqual(TransactionActionsSheet.kindStyle(.fundCharge).colorHex, DesignTokens.fundHex)
    }

    // Build 67: Expense is money out, so ink like a purchase —
    // with a house icon, so it is spottable as a living cost.
    func testExpenseIsInkWithAHouseIcon() {
        let style = TransactionActionsSheet.kindStyle(.expense)
        XCTAssertEqual(style.colorHex, DesignTokens.inkHex)
        XCTAssertEqual(style.icon, "house")
    }

    func testEveryKindHasAnIcon() {
        // Every kind must be spottable by icon as well as colour —
        // no empty icon string anywhere.
        for kind: TransactionKind in [.charge, .refund, .fundCharge, .transfer, .payment, .cashback, .income, .charity, .expense, .other("custom_kind")] {
            XCTAssertFalse(
                TransactionActionsSheet.kindStyle(kind).icon.isEmpty,
                "\(kind) must have an icon"
            )
        }
    }

    // Build 67: the expanded detail's Type row reads "Expense"
    // for an expense-tagged row, agreeing with the Actions sheet.
    // `Transaction` has no public memberwise init (the app decodes
    // rows from Supabase JSON), so the row is decoded from JSON
    // here — the same shape the app receives.
    func testTypeLabelReadsExpense() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "household_id": UUID().uuidString,
            "date": "2026-11-23",
            "merchant": "TIDEWATER PROPERTY MANAGEMENT",
            "amount_cents": 16000,
            "card_suffix": "1005",
            "source": "plaid",
            "state": "verified",
            "kind": "expense",
            "fund_allocation_cents": 0,
            "excluded": false,
            "exclude_reason": "",
            "late": false,
            "external_id": NSNull(),
            "dedupe_hash": "h",
            "original_purchase_id": NSNull(),
            "pre_exclusion_state": NSNull(),
            "plaid_pending_transaction_id": NSNull(),
            "plaid_transaction_id": NSNull(),
            "created_at": "2026-11-23T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let transaction = try JSONDecoder().decode(Transaction.self, from: data)
        XCTAssertEqual(TransactionFormatting.typeLabel(for: transaction), "Expense")
    }
}
