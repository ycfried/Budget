import XCTest
@testable import OnBudgetKit

/// Gmail error banner (build 49, owner Nov 19, 2026): a connection
/// in `status == "error"` must surface as a banner with a reconnect
/// action — never silence, never a grey muted line. Fixtures only,
/// no network.
final class GmailErrorBannerTests: XCTestCase {
    private func connection(
        status: String,
        lastError: String? = nil
    ) -> EmailConnectionPublic {
        EmailConnectionPublic(
            id: UUID(),
            householdId: UUID(),
            provider: "google",
            emailAddress: "ycfried1@gmail.com",
            status: status,
            lastPollAt: "2026-11-19T03:05:00Z",
            lastError: lastError,
            createdAt: "2026-11-02T00:00:00Z",
            connectedAt: "2026-11-11T00:00:00Z"
        )
    }

    func testErrorConnectionShowsExpiredLine() {
        // The owner's real case: Testing-mode token expired, the
        // stored last_error is "reauthorization required".
        let message = GmailErrorBanner.message(for: [
            connection(status: "error", lastError: "reauthorization required"),
        ])
        XCTAssertEqual(
            message,
            "Email alerts aren't working — access expired. Reconnect to keep getting Amex alerts."
        )
    }

    func testErrorConnectionWithOtherErrorShowsGenericLine() {
        let message = GmailErrorBanner.message(for: [
            connection(status: "error", lastError: "poll failed"),
        ])
        XCTAssertEqual(
            message,
            "Email alerts aren't working — the last email check ran into a problem. Reconnect to keep getting Amex alerts."
        )
    }

    func testErrorConnectionWithNoLastErrorShowsGenericLine() {
        let message = GmailErrorBanner.message(for: [
            connection(status: "error", lastError: nil),
        ])
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("aren't working") ?? false)
    }

    func testHealthyConnectionShowsNothing() {
        XCTAssertNil(GmailErrorBanner.message(for: [
            connection(status: "connected", lastError: nil),
        ]))
    }

    func testNoConnectionsShowsNothing() {
        XCTAssertNil(GmailErrorBanner.message(for: []))
    }

    func testMixedConnectionsShowsBannerForTheErrorOne() {
        // One healthy connection must not hide a broken one.
        let message = GmailErrorBanner.message(for: [
            connection(status: "connected", lastError: nil),
            connection(status: "error", lastError: "invalid_grant"),
        ])
        XCTAssertEqual(
            message,
            "Email alerts aren't working — access expired. Reconnect to keep getting Amex alerts."
        )
    }

    func testErrorConnectionsFiltersToErrorStatusOnly() {
        let connections = [
            connection(status: "connected", lastError: nil),
            connection(status: "error", lastError: "reauthorization required"),
            connection(status: "error", lastError: "poll failed"),
        ]
        XCTAssertEqual(GmailErrorBanner.errorConnections(in: connections).count, 2)
        XCTAssertEqual(GmailErrorBanner.errorConnections(in: [connection(status: "connected")]).count, 0)
    }
}
