import Foundation

/// Merchant / bank icon lookup — the curated keyword → domain maps
/// from live.js (v66), carried over verbatim, plus the local
/// merchants from the owner's Nov 11, 2026 feedback (Royal Farms,
/// Seven Mile Market, Kosher Town — domains verified by web search,
/// see the merchant map below). Icons come from Google's favicon
/// service (`google.com/s2/favicons`, sz=128); an unmapped merchant,
/// or a failed load, falls back to a monogram tile — a soft neutral
/// tile when no brand colour is known (never a fake brand colour),
/// or the merchant's real brand colour when the map knows one —
/// and never Clearbit (dead since Nov 4, 2026).
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
        // Local / regional merchants (owner feedback, Nov 11, 2026).
        // Domains verified by web search Nov 11, 2026 — do not
        // change them without re-verifying:
        // - Royal Farms: royalfarms.com (chain's own site and press
        //   releases; NOT royalfarmsstores.com).
        // - Seven Mile Market (Pikesville): sevenmilemarket.com
        //   (Wikipedia infobox + the store's own ads). "7 mile"
        //   covers bank descriptors written "7 MILE MARKET".
        // - Kosher Town: koshertown.com is Koshertown Supermarket,
        //   459 Albany Ave, Brooklyn, NY — the only "Kosher Town"
        //   with a verifiable website found. No Baltimore Kosher
        //   Town turned up; if the owner's store is a different
        //   local shop, remove this entry rather than guessing.
        ("royal farms", "royalfarms.com"),
        ("seven mile", "sevenmilemarket.com"),
        ("7 mile", "sevenmilemarket.com"),
        ("kosher town", "koshertown.com"),
        ("koshertown", "koshertown.com"),
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

    // No brand colour is invented for the local merchants above
    // (Royal Farms, Seven Mile Market, Kosher Town): their hexes
    // were not verified, so they are deliberately absent here and
    // their monograms use the soft neutral tile below instead.

    /// Dark slate `#475569` — the monogram initial on the soft
    /// fallback tile. (Before Nov 11, 2026 this was the whole tile;
    /// the tile itself is now `fallbackTileHex`.)
    public static let fallbackBrandHex = "#475569"

    /// Soft neutral tile `#e2e8f0` (slate-200) for any merchant or
    /// bank with no known brand colour. Same size and corner radius
    /// as the logo tiles, so a list mixing real logos and monograms
    /// reads as one designed system — a deliberate placeholder,
    /// never a fake brand colour and never a flat grey box.
    public static let fallbackTileHex = "#e2e8f0"

    // MARK: - Lookups

    public static func bankDomain(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased(), !name.isEmpty else { return nil }
        return bankDomains.first { name.contains($0.keyword) }?.domain
    }

    /// The brand colour hex for an institution name, or nil when
    /// the bank is unmapped or has no known brand colour — the
    /// caller then uses the soft neutral fallback tile.
    public static func bankBrandHex(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased(), !name.isEmpty else { return nil }
        return bankBrandColors.first { name.contains($0.keyword) }?.hex
    }

    public static func merchantDomain(for merchant: String) -> String? {
        let name = merchant.lowercased()
        return merchantDomains.first { name.contains($0.keyword) }?.domain
    }

    /// The brand colour hex for a merchant, or nil when the merchant
    /// is unmapped or has no known brand colour — the caller then
    /// uses the soft neutral fallback tile.
    public static func merchantBrandHex(for merchant: String) -> String? {
        let name = merchant.lowercased()
        return merchantBrandColors.first { name.contains($0.keyword) }?.hex
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
