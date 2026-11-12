import Foundation

/// Title Case helper — owner rule (Nov 4 2026, reaffirmed): every
/// headline/header word starts with a capital, except minor words,
/// which stay lowercase unless they are the first word.
public enum TitleCase {
    /// Minor words, kept lowercase unless first in the title.
    /// (Audit X-P2-11, Nov 12 2026: `by`/`as`/`at`/`on`/`with`
    /// join the list, so "Filter by Date", "Add a Transaction by
    /// Hand" and "Sort by" render correctly; `as` used to survive
    /// only via the "Mark as Charity" exception below.)
    public static let minorWords: Set<String> = [
        "a", "an", "the", "and", "but", "or",
        "of", "for", "to", "in", "from",
        "by", "as", "at", "on", "with",
    ]

    /// Whole-title exceptions, matched case-insensitively.
    /// "Sign In": "In" would otherwise be lowercased as a minor word.
    /// "Mark as Charity": kept as the canonical spelling of that action.
    public static let exceptions: [String: String] = [
        "sign in": "Sign In",
        "mark as charity": "Mark as Charity",
    ]

    /// Convert a heading to Title Case per the owner rule.
    /// Extra whitespace is collapsed; an empty string stays empty.
    public static func apply(to string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let exception = exceptions[trimmed.lowercased()] {
            return exception
        }
        let words = trimmed.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        return words.enumerated().map { index, word in
            let lower = word.lowercased()
            if index > 0, minorWords.contains(lower) {
                return lower
            }
            return capitalise(word)
        }.joined(separator: " ")
    }

    /// Capitalise a word, one hyphen segment at a time (audit
    /// X-P2-14, Nov 12 2026: "Top-Up", not "Top-up"; "7-Eleven",
    /// not "7-eleven"). A segment keeps its own spelling when it
    /// is a short all-caps acronym ("CSV") or genuinely mixed case
    /// ("McDonald's"); anything else is lowercased first, so
    /// all-caps merchants ("TRADER JOES") still title-case down —
    /// `displayMerchant` relies on that.
    private static func capitalise(_ word: String) -> String {
        word.split(separator: "-", omittingEmptySubsequences: false)
            .map { segment in
                let text = String(segment)
                if isAcronym(text) || isMixedCase(text) {
                    return text
                }
                let lower = text.lowercased()
                return lower.prefix(1).uppercased() + String(lower.dropFirst())
            }
            .joined(separator: "-")
    }

    /// Short all-caps words are acronyms ("CSV", "CVS", "ATM",
    /// "ID"), not shouty merchants — merchants run longer
    /// ("TRADER", "AMAZON") and still title-case down.
    private static func isAcronym(_ segment: String) -> Bool {
        segment.count <= 3
            && segment.contains(where: { $0.isLetter })
            && segment == segment.uppercased()
            && segment != segment.lowercased()
    }

    /// Has both cases, with an uppercase past the first character
    /// ("McDonald's", "iPhone") — a deliberate spelling, not noise.
    private static func isMixedCase(_ segment: String) -> Bool {
        let hasUpperPastFirst = segment.dropFirst().contains(where: { $0.isUppercase })
        let hasLower = segment.contains(where: { $0.isLowercase })
        return hasUpperPastFirst && hasLower
    }
}
