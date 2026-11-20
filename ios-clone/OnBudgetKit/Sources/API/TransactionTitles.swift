import Foundation

/// Transaction row titles (build 50, Nov 20, 2026 — moved here
/// from the app target's `TransactionFormatting` so the transfer
/// rule is unit-tested: the row title is ALWAYS the merchant
/// name).
///
/// For transfers between the user's own accounts the DIRECTION
/// and the OTHER account are derived, never the bank's wording:
/// the bank labelled a +$2,000 transfer "Transfer to Savings"
/// when the money actually came FROM savings into checking —
/// backwards. Direction comes from the signed amount (Plaid
/// stores money-out positive, money-in negative): money IN to
/// this account came "from" the other account, money OUT went
/// "to" it. The other account's last 4 digits come from the bank
/// description when it carries them (see `otherAccountLast4`);
/// when no digits are determinable the title is direction-only
/// ("Transfer from" / "Transfer to"), never a guess.
public enum TransactionTitles {
    /// The row's title: ALWAYS the merchant name (build 50,
    /// owner Nov 20, 2026). A transfer used to show the derived
    /// transfer title here ("Transfer to ••5939" — or a bare
    /// "Transfer to" with no destination), which HID the merchant
    /// — the owner reclassified a -$1,986 Erie Insurance row as
    /// a Transfer and the list read "Transfer to" instead of the
    /// merchant. The merchant stays visible for every kind; the
    /// kind is a badge on the row's bottom line, and the direction
    /// + other account live in the expanded detail panel
    /// (`transferDetailText`).
    public static func rowTitle(for transaction: Transaction) -> String {
        TitleCase.apply(to: transaction.merchant)
    }

    /// "Transfer from ••5939" / "Transfer to ••5939", or
    /// direction-only when the other account's digits cannot be
    /// derived, or bare "Transfer" for a zero amount (no direction
    /// to read). Title Case per the app rule — "from" / "to" stay
    /// lowercase as minor words, as in "Spend from Fund". Used
    /// ONLY in the expanded detail panel (build 50, owner Nov 20,
    /// 2026) — never as the row title, which is always the
    /// merchant name.
    public static func transferTitle(for transaction: Transaction) -> String {
        let direction: String?
        if transaction.amountCents < 0 {
            direction = "from"
        } else if transaction.amountCents > 0 {
            direction = "to"
        } else {
            direction = nil
        }
        guard let direction else { return "Transfer" }
        if let last4 = otherAccountLast4(for: transaction) {
            return TitleCase.apply(to: "Transfer \(direction) ••\(last4)")
        }
        return TitleCase.apply(to: "Transfer \(direction)")
    }

    /// The transfer text for the expanded detail panel (build 50,
    /// owner Nov 20, 2026): the full transfer title (direction +
    /// other account, "Transfer to ••5939") when the other
    /// account's digits are derivable, else bare "Transfer" —
    /// NEVER a dangling "Transfer to" / "Transfer from" with no
    /// destination. The direction is already visible in the row's
    /// signed amount.
    public static func transferDetailText(for transaction: Transaction) -> String {
        guard transaction.kind == .transfer else { return kindLabel(for: transaction) }
        if otherAccountLast4(for: transaction) != nil {
            return transferTitle(for: transaction)
        }
        return "Transfer"
    }

    /// Kind label in detail (live.js:990): Refund / Charity gift /
    /// Transfer / Transaction.
    public static func kindLabel(for transaction: Transaction) -> String {
        switch transaction.kind {
        case .refund: return "Refund"
        case .charity: return "Charity gift"
        case .transfer: return "Transfer"
        default: return "Transaction"
        }
    }

    /// The OTHER account's last 4 digits, parsed from the bank's
    /// merchant string — the model carries no other-account field:
    /// `cardSuffix` is THIS row's account, and `merchant` is the
    /// only text the bank supplies. A run of exactly 4 digits is a
    /// last-4 candidate ("Internal Transfer Credit: Savings -5939"
    /// → "5939"; "Transfer to Savings" carries none → nil). The
    /// LAST such run wins (the suffix trails the description), and
    /// a run equal to this row's own `cardSuffix` is skipped — it
    /// names this account, not the other one — so a description
    /// that only ever names this account falls back to
    /// direction-only rather than mislabelling it as the other
    /// account. Longer digit runs are not last-4s and are ignored.
    public static func otherAccountLast4(for transaction: Transaction) -> String? {
        var found: String? = nil
        var run = ""
        func flushRun() {
            if run.count == 4, run != transaction.cardSuffix {
                found = run
            }
            run = ""
        }
        for character in transaction.merchant {
            if character.isNumber {
                run.append(character)
            } else {
                flushRun()
            }
        }
        flushRun()
        return found
    }
}
