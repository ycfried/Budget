// OnBudgetKit — WeekTransactionsNetting.swift
//
// Build 53 (audit C6, Nov 21, 2026): the week-mode refund netting,
// extracted from TransactionsViewModel / TransactionFormatting so
// it has unit tests. Pure functions over the loaded rows — no
// network, no UI. The callers decide WHEN to use them (week mode
// only); these functions only decide WHAT the rows say.

import Foundation

public enum WeekTransactionsNetting {
    /// Charges in `shown` that have a live linked refund in
    /// `loaded`: a refund that is not trashed and not reversed,
    /// pointing at the charge. A refund pointing at a row that is
    /// not shown marks nothing. A refund dated in a LATER week
    /// still marks its charge — the week fetch pulls those refunds
    /// in on purpose (see PostgrestClient.refundsFromDate).
    public static func refundedChargeIds(loaded: [Transaction], shown: [Transaction]) -> Set<UUID> {
        let refunded = Set(loaded.compactMap { tx -> UUID? in
            guard tx.kind == .refund, !tx.isInTrash, tx.state != .reversed else { return nil }
            return tx.originalPurchaseId
        })
        return Set(shown.map(\.id)).intersection(refunded)
    }

    /// Refund amounts linked to the shown charges, for refunds that
    /// are NOT themselves in the shown list: the week list is
    /// spending-only, so a linked refund is not a row, but the
    /// week's total must still net it out. Keyed by the charge's
    /// id. Only refunds not in `shown` are included — a refund
    /// that IS shown is already subtracted by `spendingTotal`'s
    /// refund arm, so nothing is subtracted twice.
    public static func hiddenLinkedRefundAmounts(loaded: [Transaction], shown: [Transaction]) -> [UUID: Int] {
        let shownIds = Set(shown.map(\.id))
        var byPurchase: [UUID: Int] = [:]
        for tx in loaded where tx.kind == .refund && !tx.isInTrash && tx.state != .reversed {
            guard !shownIds.contains(tx.id), let purchaseId = tx.originalPurchaseId else { continue }
            byPurchase[purchaseId, default: 0] += abs(tx.amountCents)
        }
        return byPurchase.filter { shownIds.contains($0.key) }
    }

    /// The spending total over `shown` (TransactionFormatting
    /// .shownTotal's non-charity arm, same rule): charges + fund
    /// charges − refunds, minus the hidden linked refunds for
    /// refunded charges whose refund is not itself a shown row.
    /// Trashed and reversed rows never count.
    public static func spendingTotal(shown: [Transaction], linkedRefundAmounts: [UUID: Int] = [:]) -> Int {
        shown.filter {
            !$0.isInTrash && $0.state != .reversed
                && ($0.kind == .charge || $0.kind == .fundCharge || $0.kind == .refund)
        }.reduce(0) { sum, tx in
            let base = tx.kind == .refund ? -abs(tx.amountCents) : tx.amountCents
            return sum + base - (linkedRefundAmounts[tx.id] ?? 0)
        }
    }
}
