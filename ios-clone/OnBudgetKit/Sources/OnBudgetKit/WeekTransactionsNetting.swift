// OnBudgetKit — WeekTransactionsNetting.swift
//
// Build 53 (audit C6, Nov 21, 2026): the week-mode refund netting,
// extracted from TransactionsViewModel / TransactionFormatting so
// it has unit tests. Pure functions over the loaded rows — no
// network, no UI. The callers decide WHEN to use them (week mode
// only); these functions only decide WHAT the rows say.
//
// Build 64 (owner rule, Nov 23, 2026 — supersedes the audit's
// fund-first logic): a refund restores to the CLASSIFICATION of
// the charge it links to — a refund on a spending charge reduces
// the week's spending; a refund on a fund charge goes back to the
// fund and never touches spending. Cover with Savings is always
// the WHOLE charge, never part of it, so a split purchase cannot
// happen and "fund-first" is moot: a charge counts at gross
// (amount − fund_allocation, allocation 0), a fund charge counts
// 0 toward spending (amount − fund_allocation, allocation the
// whole amount). A PENDING refund counts RIGHT AWAY, same as a
// pending charge (owner, Nov 22, 2026 — pending transactions
// count toward the totals immediately); it auto-reverses if it
// disappears, via the Plaid-removed path. The total is floored
// at 0, and each charge's netting is capped at that charge, so a
// refund larger than its purchase can never drive the total
// negative. Home (compute-week C) and Transactions must compute
// the same total under this rule.
//
// NOTE: the server engine (compute-week/engine.mjs) still
// excludes provisional refunds from C
// (`isExcludedFromMath`: refund + provisional → excluded), so
// until the server is updated to the same owner rule, Home and
// Transactions will still differ for a week with a pending
// refund. The client side here is the owner's rule; the server
// side is a separate change (supabase/, not this repo's app).

import Foundation

public enum WeekTransactionsNetting {
    /// Charges in `shown` that have a live linked refund in
    /// `loaded`: a refund that is not trashed and not reversed,
    /// pointing at the charge. A refund pointing at a row that is
    /// not shown marks nothing. A refund dated in a LATER week
    /// still marks its charge — the week fetch pulls those refunds
    /// in on purpose (see PostgrestClient.refundsFromDate).
    /// Build 64 (owner rule): a PENDING refund marks its charge
    /// too — pending refunds count right away, same as pending
    /// charges.
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
    /// Build 64 (owner rule): PENDING refunds are included —
    /// they count right away. Only trashed and reversed refunds
    /// are left out. Whether the amount actually nets against
    /// spending is decided by `spendingTotal` (a refund on a
    /// fund charge goes back to the fund, never to spending),
    /// which clamps each charge's hidden amount to that charge's
    /// net contribution.
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
    /// .shownTotal's non-charity arm, same rule): the owner's
    /// rule (build 64, Nov 23, 2026), NOT the audit's fund-first
    /// logic:
    /// - A charge counts `amount − fund_allocation` (gross for a
    ///   plain charge; a split cannot happen, so the allocation
    ///   is 0 or the whole amount).
    /// - A fund charge counts `amount − fund_allocation` = 0: the
    ///   whole charge is covered by the fund, so it is not
    ///   weekly spending.
    /// - A refund linked to a charge nets against that charge's
    ///   contribution, CUMULATIVE and CAPPED at the charge — two
    ///   partial refunds ($30 + $30 on a $50 charge) net $50,
    ///   order-independent, never more. A refund on a fund
    ///   charge nets 0 (its contribution is 0): it goes back to
    ///   the fund, not to spending.
    /// - A refund with no linked charge in `shown` (unlinked, or
    ///   its purchase is not shown) nets in full, like the
    ///   server's unlinked-refund rule.
    /// - PENDING refunds count right away, same as pending
    ///   charges; trashed and reversed rows never count.
    /// - The total is floored at 0.
    public static func spendingTotal(shown: [Transaction], linkedRefundAmounts: [UUID: Int] = [:]) -> Int {
        /// A charge's net contribution to weekly spending:
        /// gross minus whatever the fund covers (0 for a plain
        /// charge, the whole amount for a fund charge).
        func netContribution(of tx: Transaction) -> Int {
            max(0, tx.amountCents - tx.fundAllocationCents)
        }
        let live = shown.filter {
            !$0.isInTrash && $0.state != .reversed
                && ($0.kind == .charge || $0.kind == .fundCharge || $0.kind == .refund)
        }
        // Each shown charge's contribution, and the running total.
        var contributionByPurchase: [UUID: Int] = [:]
        var total = 0
        for tx in live where tx.kind == .charge || tx.kind == .fundCharge {
            let contribution = netContribution(of: tx)
            contributionByPurchase[tx.id] = contribution
            total += contribution
        }
        // Linked refunds, cumulative per purchase: the hidden
        // amounts (refunds not themselves shown) plus the shown
        // refund rows linked to a shown charge. Each purchase
        // nets at most its own contribution.
        var refundedByPurchase: [UUID: Int] = [:]
        for (purchaseId, amount) in linkedRefundAmounts where contributionByPurchase[purchaseId] != nil {
            refundedByPurchase[purchaseId, default: 0] += amount
        }
        var unlinkedRefundTotal = 0
        for tx in live where tx.kind == .refund {
            if let purchaseId = tx.originalPurchaseId,
               contributionByPurchase[purchaseId] != nil {
                refundedByPurchase[purchaseId, default: 0] += abs(tx.amountCents)
            } else {
                // Unlinked, or its purchase is not shown: nets in
                // full (the server's unlinked-refund rule); the
                // floor at 0 below is the cap.
                unlinkedRefundTotal += abs(tx.amountCents)
            }
        }
        for (purchaseId, refunded) in refundedByPurchase {
            total -= min(refunded, contributionByPurchase[purchaseId] ?? 0)
        }
        total -= unlinkedRefundTotal
        return max(0, total)
    }
}
