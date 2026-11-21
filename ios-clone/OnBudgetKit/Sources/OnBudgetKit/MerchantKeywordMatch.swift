// OnBudgetKit — MerchantKeywordMatch.swift
//
// Build 53 (audit C2, Nov 21, 2026): word-boundary keyword matching
// for the merchant / bank icon maps (TransactionIconLookup).
//
// The old lookup was substring-based, first match wins — so "apple"
// (line 59 of the map) matched "APPLEBEE'S" before "applebee"
// (line 179) ever got a look, and "sonic" matched "PANASONIC",
// "ups" matched "CUPS", "bp" matched inside any word containing
// "bp". A keyword now matches only at a WORD BOUNDARY — the
// character before the match (if any) and after it (if any) must
// not be a letter or digit — and among the keywords that match,
// the LONGEST wins, so a specific entry beats its prefix. Pure
// Foundation — unit-tested in this package.

import Foundation

public enum MerchantKeywordMatch {
    /// True when `keyword` appears in `name` at a word boundary.
    /// Case-insensitive (both sides are lowercased first). A
    /// keyword that appears only inside a longer word — "sonic" in
    /// "PANASONIC", "ups" in "CUPS", "apple" in "APPLEBEE'S" —
    /// does not match.
    public static func matches(_ keyword: String, in name: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        let lower = name.lowercased()
        let key = keyword.lowercased()
        var searchFrom = lower.startIndex
        while let range = lower.range(of: key, range: searchFrom..<lower.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == lower.startIndex {
                beforeOK = true
            } else {
                let before = lower[lower.index(before: range.lowerBound)]
                beforeOK = !before.isLetter && !before.isNumber
            }
            let afterOK: Bool
            if range.upperBound == lower.endIndex {
                afterOK = true
            } else {
                let after = lower[range.upperBound]
                afterOK = !after.isLetter && !after.isNumber
            }
            if beforeOK && afterOK { return true }
            searchFrom = lower.index(after: range.lowerBound)
        }
        return false
    }

    /// The value for the LONGEST keyword that matches `name` at a
    /// word boundary, or nil when none matches. The first longest
    /// wins on a tie (the map never has two same-length keywords
    /// for one name that point at different domains).
    public static func bestMatch(in name: String, from entries: [(keyword: String, value: String)]) -> String? {
        var best: (keyword: String, value: String)?
        for entry in entries {
            guard matches(entry.keyword, in: name) else { continue }
            if let current = best, entry.keyword.count <= current.keyword.count { continue }
            best = entry
        }
        return best?.value
    }
}
