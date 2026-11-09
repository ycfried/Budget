import Foundation

/// Title Case helper — owner rule (Nov 4 2026, reaffirmed): every
/// headline/header word starts with a capital, except minor words,
/// which stay lowercase unless they are the first word.
public enum TitleCase {
    /// Minor words, kept lowercase unless first in the title.
    public static let minorWords: Set<String> = [
        "a", "an", "the", "and", "but", "or",
        "of", "for", "to", "in", "from",
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
            return lower.prefix(1).uppercased() + String(lower.dropFirst())
        }.joined(separator: " ")
    }
}
