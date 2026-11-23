import XCTest
@testable import OnBudget
import OnBudgetKit

/// Actions sheet labels + colours (build 62, owner Nov 22, 2026):
/// "change spending to purchase", "change mark as tzedaka to just
/// plain tzedaka.. the description should say what it is", "The
/// word should just name the category", and "This page needs a bit
/// more color.. too many options that all look the same.. things
/// need to be easier and nicer to spot.."
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
        XCTAssertEqual(TransactionActionsSheet.kindLabel(.other, charityName: charityName), "Other")
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

    func testEveryKindHasAnIcon() {
        // Every kind must be spottable by icon as well as colour —
        // no empty icon string anywhere.
        for kind: TransactionKind in [.charge, .refund, .fundCharge, .transfer, .payment, .cashback, .income, .charity, .other] {
            XCTAssertFalse(
                TransactionActionsSheet.kindStyle(kind).icon.isEmpty,
                "\(kind) must have an icon"
            )
        }
    }
}
