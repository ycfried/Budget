import XCTest
@testable import OnBudgetKit

/// Push notifications (Nov 16, 2026): pure-logic tests for the kit
/// pieces — token hex, payload parsing, preference defaults and
/// round-trip. The permission prompt, the APNs delegate, and the
/// server send are proven by the simulator run and by the TS tests,
/// not here.
final class PushNotificationsTests: XCTestCase {
    func testDeviceTokenHex() {
        XCTAssertEqual(PushNotifications.deviceTokenHex(Data([0x00, 0xAB, 0xFF, 0x10])), "00abff10")
        XCTAssertEqual(PushNotifications.deviceTokenHex(Data()), "")
    }

    func testPermissionAskedKey() {
        XCTAssertEqual(PushNotifications.permissionAskedKey, "onbudget.pushPermissionAsked")
    }

    func testNotificationScreenRawValues() {
        XCTAssertEqual(NotificationScreen(rawValue: "week"), .week)
        XCTAssertEqual(NotificationScreen(rawValue: "purchases"), .purchases)
        XCTAssertEqual(NotificationScreen(rawValue: "money"), .money)
        XCTAssertEqual(NotificationScreen(rawValue: "settings"), .settings)
        XCTAssertEqual(NotificationScreen(rawValue: "statement"), .statement)
        XCTAssertNil(NotificationScreen(rawValue: "unknown"))
    }

    func testNotificationPayloadParsing() {
        let householdId = UUID()
        let payload = NotificationPayload(userInfo: [
            "data": [
                "screen": "purchases",
                "household_id": householdId.uuidString,
                "type": "new_purchase",
            ] as [String: Any],
        ] as [AnyHashable: Any])
        XCTAssertEqual(payload?.screen, .purchases)
        XCTAssertEqual(payload?.householdId, householdId)
    }

    func testNotificationPayloadMissingScreenIsNil() {
        let payload = NotificationPayload(userInfo: [
            "data": ["household_id": UUID().uuidString] as [String: Any],
        ] as [AnyHashable: Any])
        XCTAssertNil(payload)
    }

    func testNotificationPayloadMissingHouseholdIsNilHousehold() {
        let payload = NotificationPayload(userInfo: [
            "data": ["screen": "week"] as [String: Any],
        ] as [AnyHashable: Any])
        XCTAssertEqual(payload?.screen, .week)
        XCTAssertNil(payload?.householdId)
    }

    func testNotificationPreferencesAllOnByDefault() {
        let prefs = NotificationPreferences.allOn
        XCTAssertTrue(prefs.weekClosed)
        XCTAssertTrue(prefs.newWeek)
        XCTAssertTrue(prefs.overBudget)
        XCTAssertTrue(prefs.newPurchase)
        XCTAssertTrue(prefs.newIncome)
        XCTAssertTrue(prefs.newCharity)
        XCTAssertTrue(prefs.monthlyStatement)
        XCTAssertTrue(prefs.memberJoined)
        XCTAssertTrue(prefs.memberLeft)
        XCTAssertTrue(prefs.gmailExpiring)
        XCTAssertTrue(prefs.fundRequest)
        XCTAssertTrue(prefs.largePurchase)
        XCTAssertTrue(prefs.bankBroken)
        XCTAssertTrue(prefs.budgetIncreased)
    }

    func testNotificationPreferencesToggleCount() {
        // Fourteen toggles — one per trigger type.
        XCTAssertEqual(NotificationPreferences.toggles.count, 14)
    }

    func testNotificationPreferencesRoundTrip() throws {
        var prefs = NotificationPreferences.allOn
        prefs.newPurchase = false
        prefs.budgetIncreased = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: data)
        XCTAssertEqual(decoded, prefs)
        XCTAssertFalse(decoded.newPurchase)
        XCTAssertFalse(decoded.budgetIncreased)
        XCTAssertTrue(decoded.weekClosed)
    }

    func testNotificationPreferencesMissingKeysDecodeAsTrue() throws {
        // A row written before a new toggle column existed decodes
        // with that toggle on — the client keeps working if the
        // migration lags behind the app.
        let json = #"{"week_closed": false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: json)
        XCTAssertFalse(decoded.weekClosed)
        XCTAssertTrue(decoded.newPurchase)
        XCTAssertTrue(decoded.budgetIncreased)
        XCTAssertTrue(decoded.fundRequest)
    }

    func testNotificationPreferencesSnakeCaseKeys() throws {
        let prefs = NotificationPreferences(weekClosed: false, fundRequest: false, largePurchase: false)
        let data = try JSONEncoder().encode(prefs)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"week_closed\""))
        XCTAssertTrue(json.contains("\"fund_request\""))
        XCTAssertTrue(json.contains("\"large_purchase\""))
        XCTAssertTrue(json.contains("\"bank_broken\""))
        XCTAssertTrue(json.contains("\"budget_increased\""))
    }
}
