import Foundation

/// Merchant / bank icon lookup — the curated keyword → domain maps
/// from live.js (v66), carried over verbatim. Icons come from
/// Google's favicon service (`google.com/s2/favicons`, sz=128); an
/// unmapped merchant, or a failed load, falls back to a brand-coloured
/// monogram tile (white initial on the merchant's brand colour, slate
/// #475569 when unmapped) — never a flat grey box alone, and never
/// Clearbit (dead since Nov 4, 2026).
public enum TransactionIconLookup {

    // MARK: - Bank logos (live.js:72-84)

    public static let bankDomains: [(keyword: String, domain: String)] = [
        ("american express", "americanexpress.com"),
        ("bank of america", "bankofamerica.com"),
        ("capital one", "capitalone.com"),
        ("chase", "chase.com"),
        ("citi", "citibank.com"),
        ("discover", "discover.com"),
        ("pnc", "pnc.com"),
        ("td", "td.com"),
        ("us bank", "usbank.com"),
        ("wells fargo", "wellsfargo.com"),
    ]

    public static let bankBrandColors: [(keyword: String, hex: String)] = [
        ("american express", "#2e77bc"),
        ("bank of america", "#e31837"),
        ("capital one", "#004977"),
        ("chase", "#117aca"),
        ("citi", "#003b70"),
        ("discover", "#f48120"),
        ("pnc", "#f58025"),
        ("td", "#00a651"),
        ("us bank", "#0c2074"),
        ("wells fargo", "#d71e28"),
    ]

    // MARK: - Merchant logos (live.js:106-124)

    public static let merchantDomains: [(keyword: String, domain: String)] = [
        ("trader joe", "traderjoes.com"),
        ("whole foods", "wholefoodsmarket.com"),
        ("home depot", "homedepot.com"),
        ("lowe", "lowes.com"),
        ("shoprite", "shoprite.com"),
        ("mcdonald", "mcdonalds.com"),
        ("starbucks", "starbucks.com"),
        ("chipotle", "chipotle.com"),
        ("amazon", "amazon.com"),
        ("walmart", "walmart.com"),
        ("target", "target.com"),
        ("costco", "costco.com"),
        ("apple", "apple.com"),
        ("cvs", "cvs.com"),
        ("walgreens", "walgreens.com"),
        ("exxon", "exxon.com"),
        ("shell", "shell.com"),
        ("uber", "uber.com"),
        ("lyft", "lyft.com"),
        ("netflix", "netflix.com"),
        ("spotify", "spotify.com"),
    ]

    public static let merchantBrandColors: [(keyword: String, hex: String)] = [
        ("amazon", "#ff9900"),
        ("walmart", "#0071dc"),
        ("target", "#cc0000"),
        ("costco", "#005daa"),
        ("starbucks", "#00704a"),
        ("chipotle", "#a81623"),
        ("mcdonald", "#da291c"),
        ("trader joe", "#d2232a"),
        ("whole foods", "#00674b"),
        ("home depot", "#f96302"),
        ("lowe", "#004990"),
        ("shoprite", "#d71920"),
        ("cvs", "#cc0000"),
        ("walgreens", "#e31837"),
        ("exxon", "#ed1c24"),
        ("shell", "#fbce07"),
        ("uber", "#000000"),
        ("lyft", "#ff00bf"),
        ("netflix", "#e50914"),
        ("spotify", "#1db954"),
        ("apple", "#000000"),
    ]

    public static let fallbackBrandHex = "#475569"

    // MARK: - Lookups

    public static func bankDomain(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased(), !name.isEmpty else { return nil }
        return bankDomains.first { name.contains($0.keyword) }?.domain
    }

    public static func bankBrandHex(for institutionName: String?) -> String {
        guard let name = institutionName?.lowercased(), !name.isEmpty else { return fallbackBrandHex }
        return bankBrandColors.first { name.contains($0.keyword) }?.hex ?? fallbackBrandHex
    }

    public static func merchantDomain(for merchant: String) -> String? {
        let name = merchant.lowercased()
        return merchantDomains.first { name.contains($0.keyword) }?.domain
    }

    public static func merchantBrandHex(for merchant: String) -> String {
        let name = merchant.lowercased()
        return merchantBrandColors.first { name.contains($0.keyword) }?.hex ?? fallbackBrandHex
    }

    /// Google favicon URL for a domain (live.js uses
    /// `google.com/s2/favicons?sz=128&domain=…`).
    public static func faviconURL(forDomain domain: String) -> URL? {
        URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(domain)")
    }

    /// The monogram initial for a merchant name.
    public static func initial(for merchant: String) -> String {
        merchant.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}
