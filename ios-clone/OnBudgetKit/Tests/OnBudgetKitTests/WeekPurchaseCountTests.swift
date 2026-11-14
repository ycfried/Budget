import XCTest
@testable import OnBudgetKit

/// The hero's Purchases number (owner, Nov 14, 2026): only a charge
/// that is not reversed counts. A transfer between the household's
/// own accounts is not a purchase — the owner's screenshot showed
/// Purchases 15 with an "Internal Transfer Credit" row in the week,
/// and the hero spent figure inflated by a transfer stored as a
/// charge. The counting rule here is kind-based (Transaction.
/// countsAsPurchase), which is exactly what compute-week does
/// server-side (engine.mjs isExcludedFromMath): a row stored as
/// kind='transfer' never counts, in either place. A row whose
/// merchant says INTERNAL TRANSFER but whose kind is still 'charge'
/// DOES count here — that is the stale-kind case, and the fix for
/// it is reclassification to 'transfer' (supabase/
/// transfer-backfill.sql), not a name-based exception in the
/// counter: the counter and the server must agree.
final class WeekPurchaseCountTests: XCTestCase {
    private func txn(kind: TransactionKind, state: TransactionState = .verified,
                     merchant: String = "AMAZON", amount: Int = 1000) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: "2026-11-13", merchant: merchant,
                    amountCents: amount, cardSuffix: "1005", source: .plaid, state: state,
                    kind: kind, fundAllocationCents: 0, excluded: false, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: "2026-11-13T00:00:00Z")
    }

    func testChargeCounts() {
        XCTAssertTrue(txn(kind: .charge).countsAsPurchase)
        // A pending (provisional) charge still counts — the filter
        // excludes only reversed rows.
        XCTAssertTrue(txn(kind: .charge, state: .provisional).countsAsPurchase)
    }

    func testReversedChargeDoesNotCount() {
        XCTAssertFalse(txn(kind: .charge, state: .reversed).countsAsPurchase)
    }

    func testTransferNeverCounts() {
        // The owner's case: an internal-transfer row in the week.
        XCTAssertFalse(txn(kind: .transfer, merchant: "INTERNAL TRANSFER CREDIT: SAVINGS -5939",
                           amount: -900000).countsAsPurchase)
        XCTAssertFalse(txn(kind: .transfer, merchant: "INTERNAL TRANSFER",
                           amount: 900000).countsAsPurchase)
        XCTAssertFalse(txn(kind: .transfer, state: .provisional).countsAsPurchase)
    }

    func testOtherKindsNeverCount() {
        XCTAssertFalse(txn(kind: .refund).countsAsPurchase)
        XCTAssertFalse(txn(kind: .fundCharge).countsAsPurchase)
        XCTAssertFalse(txn(kind: .payment).countsAsPurchase)
        XCTAssertFalse(txn(kind: .cashback).countsAsPurchase)
        XCTAssertFalse(txn(kind: .income).countsAsPurchase)
        XCTAssertFalse(txn(kind: .charity).countsAsPurchase)
        XCTAssertFalse(txn(kind: .other("mystery")).countsAsPurchase)
    }

    func testStaleKindStillCountsByDesign() {
        // A row whose merchant says INTERNAL TRANSFER but whose kind
        // is still 'charge' counts — the kind is stale (frozen at
        // insert; re-delivery never overwrites it). This test pins
        // that behaviour so a future name-based exception cannot
        // silently diverge the counter from compute-week: the fix
        // for such a row is reclassifying its kind to 'transfer'.
        XCTAssertTrue(txn(kind: .charge, merchant: "INTERNAL TRANSFER CREDIT: SAVINGS -5939",
                          amount: -900000).countsAsPurchase)
    }

    func testWeekPurchaseTotal() {
        let rows = [
            txn(kind: .charge),
            txn(kind: .charge, state: .provisional),
            txn(kind: .transfer, merchant: "INTERNAL TRANSFER CREDIT: SAVINGS -5939", amount: -900000),
            txn(kind: .refund),
            txn(kind: .charge, state: .reversed),
        ]
        XCTAssertEqual(rows.filter(\.countsAsPurchase).count, 2)
    }
}
