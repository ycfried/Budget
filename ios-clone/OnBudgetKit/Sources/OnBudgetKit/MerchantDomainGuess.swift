// OnBudgetKit — MerchantDomainGuess.swift
//
// Build 52 (owner, Nov 20, 2026): the auto-guess half of the smart
// merchant-icon plan. When a merchant has no curated domain, the app
// tries the obvious domain (name → .com) and fetches the Google
// favicon; if it loads, the app uses it and remembers it. Pure
// Foundation — unit-tested in this package.
//
// HONEST LIMIT: the guess can be wrong — "Erie" → erie.com is a
// different company; the right one is erieinsurance.com. The
// curated list (TransactionIconLookup.merchantDomains) is consulted
// FIRST and wins for the tricky ones; the guess is only a fallback.
// A guessed domain is remembered only after its favicon loads, and
// the catch-up loop (merchants that still don't resolve, surfaced in
// the Merchants screen) is what fixes the misses in the next build.
// The list alone will never be complete — the auto-guess +
// catch-up loop is the part that actually solves it long-term.

import Foundation

public enum MerchantDomainGuess {
    /// Generic words that carry no brand meaning — stripped from the
    /// END of a merchant name before guessing (a shop called
    /// "Acme Markets" guesses acme.com, not acmemarkets.com).
    private static let trailingGenericWords: Set<String> = [
        "store", "stores", "market", "markets", "shop", "shops",
        "restaurant", "restaurants", "cafe", "supermarket",
        "supercenter", "center", "centre", "inc", "llc", "co",
        "company", "group",
    ]

    /// The obvious .com domain for a merchant name, or nil when
    /// there is nothing sensible to guess (generic transfer /
    /// payment descriptors, or a name too short to be a brand).
    public static func guessedDomain(for merchant: String) -> String? {
        let lower = merchant.lowercased()
        // Generic transfer descriptors are not brands — never guess.
        if lower.contains("transfer") || lower.contains("payment") {
            return nil
        }
        // Split into words on anything that isn't a letter or
        // digit; drop pure numbers (store numbers, card suffixes).
        var words = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        // A leading "the" is not part of the brand.
        if words.first == "the" { words.removeFirst() }
        // Strip trailing generic words.
        while let last = words.last, trailingGenericWords.contains(last) {
            words.removeLast()
        }
        let joined = words.joined()
        guard joined.count >= 4 else { return nil }
        return joined + ".com"
    }
}
