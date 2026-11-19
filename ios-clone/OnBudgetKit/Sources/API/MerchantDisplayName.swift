/// Merchant display-name resolution for Activity feeds (build 41 —
/// owner, Nov 16, 2026: the Activity & Transactions feeds showed
/// RAW merchant names — "TOIREMORG", "=TENYADKALLAHGEMACH",
/// "TOIREM.ORG CHARITY" — while the Transactions list shows the
/// RENAMED display name). The Transactions list gets renamed names
/// because the SERVER rewrites `transactions.merchant` when a rule
/// is created and at ingestion; the Activity feeds also render
/// rows the server never rewrites — charity-income rows snapshot
/// the raw source at record time, and the shared FundTransactionRow
/// rendered `transaction.merchant` raw — so the feeds resolve the
/// name at RENDER time through the same rules.
///
/// This mirrors the server matcher exactly
/// (`supabase/functions/_shared/canonical.ts: matchMerchantRule`,
/// build 39 squash semantics): the key is the upper-cased name
/// with whitespace collapsed and leading non-alphanumerics
/// stripped; the squash is the key with all non-alphanumerics
/// removed. Tiers: 0 = key equality, 1 = includes/prefix rule whose
/// squashed pattern is contained in the squashed merchant, 2 =
/// squash equality. Lowest tier wins; ties go to the longest
/// pattern key. No rule matches → the merchant is returned
/// unchanged (display only — the data, the rules, and any merge
/// are untouched).
public enum MerchantDisplayName {
    /// `merchantRuleKey`: upper-case, collapse whitespace runs to
    /// one space, strip leading non-alphanumerics ("=TENYAD…" →
    /// "TENYAD…").
    public static func key(_ name: String) -> String {
        let collapsed = name.uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.drop(while: { !isAlphanumeric($0) }))
    }

    /// `merchantRuleSquash`: the key with every non-alphanumeric
    /// removed ("TOIREM.ORG CHARITY" → "TOIREMORGCHARITY").
    public static func squash(_ name: String) -> String {
        key(name).filter(isAlphanumeric)
    }

    /// The display name for a merchant under the household's rules:
    /// the best matching rule's display name, else the merchant
    /// unchanged. The caller Title-Cases the result through
    /// `TransactionFormatting.displayMerchant`, as the Transactions
    /// list does.
    public static func displayName(for merchant: String, rules: [MerchantRule]) -> String {
        matchingRule(for: merchant, rules: rules)?.displayName ?? merchant
    }

    /// The rule that `displayName` would use for a merchant (build
    /// 47 — the rename popup pre-fills from it: the stored display
    /// name, match type and bank name). Nil when no rule matches.
    /// Same tiers as `displayName` — it IS the `displayName`
    /// matcher, factored out so both stay in step.
    public static func matchingRule(for merchant: String, rules: [MerchantRule]) -> MerchantRule? {
        let merchantKey = key(merchant)
        guard !merchantKey.isEmpty else { return nil }
        let merchantSquash = squash(merchant)
        var best: MerchantRule?
        var bestTier = 99
        var bestLen = -1
        for rule in rules {
            let patternKey = key(rule.patternText)
            guard !patternKey.isEmpty else { continue }
            var tier = -1
            if patternKey == merchantKey {
                tier = 0
            } else if (rule.matchType == "includes" || rule.matchType == "prefix")
                        && merchantSquash.contains(squash(rule.patternText)) {
                tier = 1
            } else if squash(rule.patternText) == merchantSquash {
                tier = 2
            }
            guard tier >= 0 else { continue }
            if tier < bestTier || (tier == bestTier && patternKey.count > bestLen) {
                best = rule
                bestTier = tier
                bestLen = patternKey.count
            }
        }
        return best
    }

    /// ASCII alphanumerics only — the server's `[A-Z0-9]` class,
    /// not Swift's Unicode-aware `isLetter`/`isNumber` (an accented
    /// letter is not in `[A-Z0-9]`).
    private static func isAlphanumeric(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
}
