import Foundation
import OnBudgetKit

/// Client-side refund-link suggestions — a direct port of
/// `refundSuggestions.mjs` (live web v66) plus its `REFUND_SUGGESTION_REASONS`.
///
/// Matching mirrors the server matcher (`supabase/refund-linking.sql`):
/// same card suffix (a missing suffix never matches), purchase on or
/// before the refund, within 90 days, and the refund must fit in what
/// the purchase has left to refund (linked live refunds count against
/// it — a fully refunded purchase is never suggested). Merchant
/// matching: normalized names equal, one contains the other, or a
/// confirmed alias pair. A dismissed (refund, purchase) pair never
/// reappears.
///
/// NOTHING here links anything — Link calls the `link_refund` RPC,
/// whose server-side fit check stays the guard.

public enum RefundSuggestionReason: String, Equatable, CaseIterable {
    case onlyMatch = "only-match"
    case exactMulti = "exact-multi"
    case partial
    case differentMerchant = "different-merchant"

    /// Exact reason strings from `REFUND_SUGGESTION_REASONS`
    /// (`refundSuggestions.mjs`).
    public var text: String {
        switch self {
        case .onlyMatch:
            return "Only one purchase matches — same amount, card, and place."
        case .exactMulti:
            return "Same amount, card, and place — more than one purchase matches, pick the right one."
        case .partial:
            return "Partial refund — fits in what this purchase has left to refund."
        case .differentMerchant:
            return "Same amount and card, different place — check this is the right purchase before linking."
        }
    }
}

public struct RefundSuggestion: Equatable, Identifiable {
    public let refund: Transaction
    public let purchase: Transaction
    public let reason: RefundSuggestionReason

    public var id: String { "\(refund.id.uuidString)|\(purchase.id.uuidString)" }

    public init(refund: Transaction, purchase: Transaction, reason: RefundSuggestionReason) {
        self.refund = refund
        self.purchase = purchase
        self.reason = reason
    }
}

public enum RefundSuggestions {
    /// Same normalization as `canonical.ts` normalizeMerchant: UPPER,
    /// trimmed, whitespace collapsed.
    public static func normalizeMerchant(_ merchant: String) -> String {
        merchant.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Same rule as `canonical.ts` merchantsRelated: names that differ
    /// but one contains the other (and both are at least 4 chars).
    /// Identical names return false here — equality is checked separately.
    public static func merchantsRelated(_ a: String, _ b: String) -> Bool {
        let na = normalizeMerchant(a)
        let nb = normalizeMerchant(b)
        guard !na.isEmpty, !nb.isEmpty, na != nb else { return false }
        guard na.count >= 4, nb.count >= 4 else { return false }
        return na.contains(nb) || nb.contains(na)
    }

    /// Confirmed alias pairs, as read from `merchant_aliases`.
    public static func aliasSet(from rows: [MerchantAlias]) -> Set<String> {
        var set = Set<String>()
        for row in rows {
            let x = normalizeMerchant(row.nameA)
            let y = normalizeMerchant(row.nameB)
            guard !x.isEmpty, !y.isEmpty else { continue }
            set.insert("\(x)|\(y)")
            set.insert("\(y)|\(x)")
        }
        return set
    }

    public static func merchantMatches(_ a: String, _ b: String, aliasSet: Set<String>) -> Bool {
        let na = normalizeMerchant(a)
        let nb = normalizeMerchant(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if merchantsRelated(a, b) { return true }
        return aliasSet.contains("\(na)|\(nb)")
    }

    /// What a purchase still has left to refund: its amount minus live
    /// refunds already linked to it. Only positive room is a candidate.
    public static func remainingRefundRoom(purchaseAmountCents: Int, linkedTotalCents: Int) -> Int {
        purchaseAmountCents - linkedTotalCents
    }

    private static func daysBefore(_ isoDate: String, _ days: Int) -> String? {
        guard let date = MoneyFormat.date(from: isoDate) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let shifted = calendar.date(byAdding: .day, value: -days, to: date) else { return nil }
        return MoneyFormat.dateString(from: shifted)
    }

    /// Compute suggestions for unlinked refunds.
    /// - refunds: kind `refund`, `originalPurchaseId` nil, not
    ///   excluded/reversed (amount negative).
    /// - purchases: kind `charge` / `fund_charge`, not excluded/reversed.
    /// - linkedTotals: purchase id → sum of |amount| of live linked refunds.
    /// Sorted by refund date (newest first), then exact before partial
    /// before different-merchant, then purchase date (newest first).
    public static func compute(
        refunds: [Transaction],
        purchases: [Transaction],
        aliases: [MerchantAlias],
        dismissals: [RefundLinkDismissal],
        linkedTotals: [UUID: Int]
    ) -> [RefundSuggestion] {
        let aliasSet = aliasSet(from: aliases)
        let dismissed = Set(dismissals.map { "\($0.refundId.uuidString)|\($0.purchaseId.uuidString)" })
        var out: [RefundSuggestion] = []
        for refund in refunds {
            guard refund.amountCents < 0 else { continue }
            let refundAbs = abs(refund.amountCents)
            guard let since = daysBefore(refund.date, 90) else { continue }
            var exact: [Transaction] = []
            var partial: [Transaction] = []
            var differentMerchant: [Transaction] = []
            for purchase in purchases {
                guard purchase.amountCents > 0 else { continue }
                // Same card; a missing suffix on either side never matches
                // (same rule as link_refund P2-N8 / auto_link_refund).
                guard !refund.cardSuffix.isEmpty, !purchase.cardSuffix.isEmpty,
                      refund.cardSuffix == purchase.cardSuffix else { continue }
                guard purchase.date <= refund.date, purchase.date >= since else { continue }
                let room = remainingRefundRoom(
                    purchaseAmountCents: purchase.amountCents,
                    linkedTotalCents: linkedTotals[purchase.id] ?? 0
                )
                guard room > 0, refundAbs <= room else { continue }
                guard !dismissed.contains("\(refund.id.uuidString)|\(purchase.id.uuidString)") else { continue }
                let namesMatch = merchantMatches(refund.merchant, purchase.merchant, aliasSet: aliasSet)
                if refundAbs == purchase.amountCents {
                    if namesMatch { exact.append(purchase) } else { differentMerchant.append(purchase) }
                } else if refundAbs < purchase.amountCents {
                    // A partial refund whose merchant does not match is
                    // NOT suggested: too weak to be useful.
                    if namesMatch { partial.append(purchase) }
                }
            }
            if exact.count == 1 {
                out.append(RefundSuggestion(refund: refund, purchase: exact[0], reason: .onlyMatch))
            } else {
                for purchase in exact {
                    out.append(RefundSuggestion(refund: refund, purchase: purchase, reason: .exactMulti))
                }
            }
            for purchase in partial {
                out.append(RefundSuggestion(refund: refund, purchase: purchase, reason: .partial))
            }
            for purchase in differentMerchant {
                out.append(RefundSuggestion(refund: refund, purchase: purchase, reason: .differentMerchant))
            }
        }
        let strengthRank: [RefundSuggestionReason: Int] = [
            .onlyMatch: 0, .exactMulti: 0, .partial: 1, .differentMerchant: 2,
        ]
        out.sort { a, b in
            if a.refund.date != b.refund.date { return a.refund.date > b.refund.date }
            let ra = strengthRank[a.reason] ?? 9
            let rb = strengthRank[b.reason] ?? 9
            if ra != rb { return ra < rb }
            if a.purchase.date != b.purchase.date { return a.purchase.date > b.purchase.date }
            return false
        }
        return out
    }
}
