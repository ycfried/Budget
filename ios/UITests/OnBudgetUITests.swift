import XCTest

@MainActor
final class OnBudgetUITests: XCTestCase {
    func testAdminDashboardAndNavigation() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["sampleAdmin"].tap()
        XCTAssertTrue(app.staticTexts["weeklyAvailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$212.50"].exists)
        app.tabBars.buttons["Purchases"].tap()
        XCTAssertTrue(app.navigationBars["Purchases"].exists)
        app.tabBars.buttons["Extra Fund"].tap()
        XCTAssertTrue(app.buttons["Allocate fund"].exists)
        app.tabBars.buttons["More"].tap()
        app.buttons["Savings"].tap()
        XCTAssertTrue(app.staticTexts["Earned, not transferred"].exists)
    }
    func testMemberHasNoFundApprovalControls() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["sampleMember"].tap()
        XCTAssertTrue(app.staticTexts["weeklyAvailable"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Extra Fund"].tap()
        XCTAssertFalse(app.buttons["Allocate fund"].exists)
        XCTAssertFalse(app.buttons["Approve or adjust split"].exists)
        XCTAssertTrue(app.buttons["Request fund use"].exists)
    }
    func testLiveLoginRemainsLockedWithoutConfiguration() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Read-only connection preparation"].tap()
        XCTAssertTrue(app.staticTexts["Live connection locked"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertFalse(app.buttons["Sign in"].exists)
        XCTAssertFalse(app.buttons["Restore saved session"].exists)
    }

}
