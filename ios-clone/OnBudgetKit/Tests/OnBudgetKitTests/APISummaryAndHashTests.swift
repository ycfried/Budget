
// OnBudgetKitTests — APISummaryAndHashTests.swift
//
// Display-aggregation arithmetic (FundSummary / CharitySummary,
// mirroring live.js line-for-line), the pure-Swift SHA-256 vectors,
// and the dedupe-hash formats the client must match.

import Foundation
import XCTest
@testable import OnBudgetKit

final class APISummaryTests: XCTestCase {
    func testFundSummaryMirrorsLiveJS() {
        let householdId = UUID()
        func ledger(kind: String, amount: Int) -> FundLedgerEntry {
            FundLedgerEntry(id: nil, householdId: householdId, kind: kind, amountCents: amount,
                            weekStart: nil, requestId: nil, note: "", createdBy: nil, createdAt: nil)
        }
        func release(weekStart: String, surplus: Int, released: Int, status: String) -> SurplusRelease {
            SurplusRelease(id: nil, householdId: householdId, weekStart: weekStart,
                           surplusCents: surplus, releaseDate: "2026-11-15", status: status,
                           releasedCents: released, createdAt: nil, closedAt: nil)
        }
        let ledgerRows = [
            ledger(kind: "release", amount: 10000),
            ledger(kind: "allocation", amount: -3000),
            ledger(kind: "override_allocation", amount: -1000),
            ledger(kind: "adjustment", amount: 6000),
        ]
        let releases = [
            release(weekStart: "2026-11-01", surplus: 5000, released: 2000, status: "pending"),
            release(weekStart: "2026-10-25", surplus: 4000, released: 4000, status: "released"),
            release(weekStart: "2026-10-18", surplus: 700, released: 0, status: "held"),
        ]
        let summary = FundSummary.compute(ledger: ledgerRows, releases: releases, shortfallCents: 4000)
        XCTAssertEqual(summary.availableCents, 12000) // 10000 - 3000 - 1000 + 6000
        XCTAssertEqual(summary.spentCents, 4000)
        XCTAssertEqual(summary.pendingCents, 3000) // max(0, 5000 - 2000)
        XCTAssertEqual(summary.releasedTotalCents, 4000)
        XCTAssertEqual(summary.heldTotalCents, 700)
        XCTAssertEqual(summary.heldWeeks, 1)
        XCTAssertEqual(summary.pendingIncludingHeldCents, 3700)
        XCTAssertEqual(summary.totalCents, 15700)
        XCTAssertEqual(summary.shortfallCents, 4000)
    }

    func testReleasedFallsBackToSurplusWhenZero() {
        // live.js uses `released_cents || surplus_cents`: a 0 released
        // figure falls back to the surplus figure.
        let householdId = UUID()
        let releases = [
            SurplusRelease(id: nil, householdId: householdId, weekStart: "2026-10-25",
                           surplusCents: 4000, releaseDate: "2026-11-08", status: "released",
                           releasedCents: 0, createdAt: nil, closedAt: nil),
        ]
        let summary = FundSummary.compute(ledger: [], releases: releases, shortfallCents: 0)
        XCTAssertEqual(summary.releasedTotalCents, 4000)
    }

    func testCharitySummaryMirrorsLiveJS() {
        let householdId = UUID()
        let income = [
            CharityIncome(id: UUID(), householdId: householdId, sourceLabel: "Pay",
                          amountCents: 50000, incomeDate: "2026-11-01", rateBp: 1000,
                          status: "active", replacesId: nil, note: "", createdBy: nil, createdAt: nil),
            CharityIncome(id: UUID(), householdId: householdId, sourceLabel: "Reversed",
                          amountCents: 10000, incomeDate: "2026-11-01", rateBp: 1000,
                          status: "reversed", replacesId: nil, note: "", createdBy: nil, createdAt: nil),
        ]
        func txn(kind: TransactionKind, state: TransactionState, amount: Int, date: String) -> Transaction {
            Transaction(id: UUID(), householdId: householdId, date: date, merchant: "ORG",
                        amountCents: amount, cardSuffix: "0000", source: .manual, state: state,
                        kind: kind, fundAllocationCents: 0, excluded: false, excludeReason: "",
                        late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                        preExclusionState: nil, plaidPendingTransactionId: nil,
                        plaidTransactionId: nil, createdAt: "2026-11-02T00:00:00Z")
        }
        let gifts = [
            txn(kind: .charity, state: .verified, amount: 200, date: "2026-11-03"),
            txn(kind: .charity, state: .provisional, amount: 500, date: "2026-11-04"),
            txn(kind: .charity, state: .verified, amount: 999, date: "2026-10-31"), // pre-Nov: excluded
        ]
        let summary = CharitySummary.compute(activeIncome: income, charityTransactions: gifts, defaultRateBp: 1000)
        XCTAssertEqual(summary.committedCents, 5000) // 10% of 50000; reversed row ignored
        XCTAssertEqual(summary.givenCents, 200) // pending gift not counted yet
        XCTAssertEqual(summary.pendingGiftCents, 500)
        XCTAssertEqual(summary.remainingCents, 4800)
    }

    func testFundRequestApprovedCents() {
        let householdId = UUID()
        let approved = FundRequest(id: UUID(), householdId: householdId, transactionId: nil,
                                   requestedBy: UUID(), amountCents: 5000, note: "",
                                   status: "approved", remainderCents: 0, decidedBy: nil,
                                   decidedAt: nil, createdAt: "2026-11-02T00:00:00Z")
        XCTAssertEqual(approved.approvedCents, 5000)
        let split = FundRequest(id: UUID(), householdId: householdId, transactionId: nil,
                                requestedBy: UUID(), amountCents: 5000, note: "",
                                status: "split", remainderCents: 2000, decidedBy: nil,
                                decidedAt: nil, createdAt: "2026-11-02T00:00:00Z")
        XCTAssertEqual(split.approvedCents, 3000)
        let pending = FundRequest(id: UUID(), householdId: householdId, transactionId: nil,
                                  requestedBy: UUID(), amountCents: 5000, note: "",
                                  status: "pending", remainderCents: 0, decidedBy: nil,
                                  decidedAt: nil, createdAt: "2026-11-02T00:00:00Z")
        XCTAssertNil(pending.approvedCents)
    }
}

final class SHA256Tests: XCTestCase {
    func testFIPSVectors() {
        XCTAssertEqual(
            SHA256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testManualDedupeHashFormat() {
        // live.js: SHA-256 of "date|MERCHANT-UPPERCASE|amountCents|suffix".
        let insert = ManualTransactionInsert(
            householdId: UUID(), date: "2026-11-02",
            merchant: "amazon", amountCents: 1059, cardSuffix: "1005"
        )
        XCTAssertEqual(insert.merchant, "AMAZON")
        XCTAssertEqual(insert.dedupeHash, SHA256.hex("2026-11-02|AMAZON|1059|1005"))
        XCTAssertEqual(insert.dedupeHash.count, 64)
        let other = ManualTransactionInsert(
            householdId: UUID(), date: "2026-11-02",
            merchant: "amazon", amountCents: 1060, cardSuffix: "1005"
        )
        XCTAssertNotEqual(insert.dedupeHash, other.dedupeHash)
    }

    func testCSVDedupeRowHashFormat() {
        let row = TransactionDedupeRow(merchant: "Amazon", amountCents: 1059, date: "2026-11-02", cardSuffix: "1005")
        XCTAssertEqual(row.dedupeHash, SHA256.hex("2026-11-02|AMAZON|1059|1005"))
    }

    func testCharityGiftHashIncludesNonce() {
        // live.js: "charity|date|merchant|amount|suffix|nonce" with a
        // fresh nonce per submit, so identical gifts never collide.
        let first = RPCClient.charityGiftDedupeHash(date: "2026-11-03", merchant: "TOIREMORG", amountCents: 200, cardSuffix: "0000")
        let second = RPCClient.charityGiftDedupeHash(date: "2026-11-03", merchant: "TOIREMORG", amountCents: 200, cardSuffix: "0000")
        XCTAssertNotEqual(first.hash, second.hash)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(first.hash, SHA256.hex("charity|2026-11-03|TOIREMORG|200|0000|\(first.nonce)"))
    }
}
