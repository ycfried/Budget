// OnBudgetKitTests — WidgetBackgroundRefreshTests.swift
//
// Widget background refresh (build 43, owner Nov 17, 2026): the
// pure logic only — the task identifier (it must match the value in
// the app's Info.plist and the BGTaskScheduler registration exactly)
// and the next-run date helper. The scheduling itself
// (BGTaskScheduler) cannot be exercised in a test run, and the
// refresh fetch needs a live session + backend, so neither is
// tested here.

import Foundation
import XCTest
@testable import OnBudgetKit

final class WidgetBackgroundRefreshTests: XCTestCase {
    func testTaskIdentifierIsTheWidgetRefreshIdentifier() {
        XCTAssertEqual(WidgetBackgroundRefresh.taskIdentifier, "com.onbudget.ios.widget-refresh")
    }

    func testNextBeginDateIsOneHourOut() {
        let now = Date(timeIntervalSince1970: 1_763_000_000)
        let next = WidgetBackgroundRefresh.nextBeginDate(from: now)
        XCTAssertEqual(next.timeIntervalSince(now), 3600, accuracy: 0.001)
    }

    func testRequestIntervalIsOneHour() {
        XCTAssertEqual(WidgetBackgroundRefresh.requestInterval, 3600)
    }
}
