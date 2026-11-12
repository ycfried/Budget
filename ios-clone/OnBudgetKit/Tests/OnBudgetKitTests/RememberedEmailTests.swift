// OnBudgetKitTests — RememberedEmailTests.swift
//
// Unit tests for the Remember-me email store (`RememberedEmail`):
// save/load/clear against an isolated UserDefaults suite — no UI,
// no real defaults touched, no email ever logged. The ticked /
// unticked behaviour at this level: ticked saves, so a later
// sign-in screen pre-fills from `load()`; unticked clears, so
// `load()` is nil and the screen opens empty.

import Foundation
import XCTest
@testable import OnBudgetKit

final class RememberedEmailTests: XCTestCase {
    private static let suiteName = "com.onbudget.tests.RememberedEmail"

    private var defaults: UserDefaults!
    private var remembered: RememberedEmail!

    override func setUp() {
        super.setUp()
        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite \(Self.suiteName)")
            return
        }
        defaults = suite
        defaults.removePersistentDomain(forName: Self.suiteName)
        remembered = RememberedEmail(defaults: defaults)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testLoadReturnsNilWhenNothingSaved() {
        XCTAssertNil(remembered.load())
    }

    func testTickedSavesSoSignInPrefills() {
        remembered.save("user@example.com")
        XCTAssertEqual(remembered.load(), "user@example.com")
    }

    func testUntickedClearsSoSignInOpensEmpty() {
        remembered.save("user@example.com")
        remembered.clear()
        XCTAssertNil(remembered.load())
    }

    func testSaveTrimsWhitespace() {
        remembered.save("  user@example.com \n")
        XCTAssertEqual(remembered.load(), "user@example.com")
    }

    func testSaveBlankClearsInsteadOfStoringEmpty() {
        remembered.save("user@example.com")
        remembered.save("   ")
        XCTAssertNil(remembered.load())
    }

    func testClearWhenNothingSavedIsANoOp() {
        remembered.clear()
        XCTAssertNil(remembered.load())
    }

    func testDefaultKeyIsVersioned() {
        XCTAssertEqual(RememberedEmail.defaultsKey, "onbudget.rememberedEmail.v1")
    }
}
