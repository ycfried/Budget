import Foundation
import OnBudgetKit

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
        // Added Nov 14, 2026 (owner: rows showed the bank logo
        // because these merchants were unmapped): PayPal
        // ("MARK PAYPAL" rows contain "paypal"), T-Mobile, Sunoco
        // and Tello. Sunoco / Tello have a domain but no verified
        // brand colour, so their monograms stay on the neutral
        // tile — same rule as the local merchants below.
        ("paypal", "paypal.com"),
        ("t-mobile", "t-mobile.com"),
        ("sunoco", "sunoco.com"),
        ("tello", "tello.com"),
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
        // Build 52 (owner, Nov 20, 2026 — the five missing
        // merchants): TJ Maxx, Homegoods, Carters, Erie Insurance
        // and Nordstrom showed the bank logo because they were
        // never in the map. Domains verified live via Google s2
        // favicons Nov 20, 2026 (all 200, real brand favicons).
        // "tjmaxx" covers descriptors written "TJMAXX" (no
        // space); "carter" covers "CARTERS" / "CARTER'S";
        // "erie" is the insurer — erie.com is a different
        // company, so the curated entry must win over the
        // auto-guess (see guessedDomain below).
        ("tj maxx", "tjmaxx.com"),
        ("tjmaxx", "tjmaxx.com"),
        ("homegoods", "homegoods.com"),
        ("carter", "carters.com"),
        ("erie", "erieinsurance.com"),
        ("nordstrom", "nordstrom.com"),
        // Build 52 — broad expansion (owner, Nov 20, 2026: "make
        // an extensive list of everything we can imagine"). Major
        // national brands, grouped by category. Domains are the
        // brands' well-known sites; no brand colours are added
        // here (not verified) — their monograms stay on the
        // neutral tile when a favicon fails. If a domain turns
        // out wrong, the auto-guess + catch-up loop below is the
        // correction path — fix the entry, do not guess a new one.
        // Grocery.
        ("kroger", "kroger.com"),
        ("safeway", "safeway.com"),
        ("publix", "publix.com"),
        ("aldi", "aldi.us"),
        ("wegmans", "wegmans.com"),
        ("food lion", "foodlion.com"),
        ("harris teeter", "harristeeter.com"),
        ("meijer", "meijer.com"),
        ("heb", "heb.com"),
        ("sprouts", "sprouts.com"),
        ("winco", "wincofoods.com"),
        ("giant food", "giantfoodstores.com"),
        ("stop & shop", "stopandshop.com"),
        ("stop and shop", "stopandshop.com"),
        // Retail.
        ("best buy", "bestbuy.com"),
        ("kohls", "kohls.com"),
        ("jcpenney", "jcpenney.com"),
        ("macys", "macys.com"),
        ("dicks", "dickssportinggoods.com"),
        ("dollar tree", "dollartree.com"),
        ("dollar general", "dollargeneral.com"),
        ("family dollar", "familydollar.com"),
        ("five below", "fivebelow.com"),
        ("hobby lobby", "hobbylobby.com"),
        ("michaels", "michaels.com"),
        ("joann", "joann.com"),
        ("petsmart", "petsmart.com"),
        ("petco", "petco.com"),
        ("barnes", "barnesandnoble.com"),
        ("gamestop", "gamestop.com"),
        ("office depot", "officedepot.com"),
        ("staples", "staples.com"),
        // Gas.
        ("bp", "bp.com"),
        ("chevron", "chevron.com"),
        ("mobil", "mobil.com"),
        ("speedway", "speedway.com"),
        ("wawa", "wawa.com"),
        ("7-eleven", "7-eleven.com"),
        ("7eleven", "7-eleven.com"),
        ("circle k", "circlek.com"),
        ("marathon", "marathon.com"),
        ("citgo", "citgo.com"),
        ("gulf", "gulf.com"),
        // Restaurants / fast food.
        ("chick-fil-a", "chick-fil-a.com"),
        ("wendy", "wendys.com"),
        ("burger king", "burgerking.com"),
        ("taco bell", "tacobell.com"),
        ("kfc", "kfc.com"),
        ("panera", "panerabread.com"),
        ("dunkin", "dunkindonuts.com"),
        ("subway", "subway.com"),
        ("pizza hut", "pizzahut.com"),
        ("dominos", "dominos.com"),
        ("papa johns", "papajohns.com"),
        ("olive garden", "olivegarden.com"),
        ("applebee", "applebees.com"),
        ("outback", "outback.com"),
        ("red lobster", "redlobster.com"),
        ("cracker barrel", "crackerbarrel.com"),
        ("ihop", "ihop.com"),
        ("denny", "dennys.com"),
        ("sonic", "sonicdrivein.com"),
        ("five guys", "fiveguys.com"),
        ("shake shack", "shakeshack.com"),
        ("jersey mike", "jerseymikes.com"),
        ("firehouse", "firehousesubs.com"),
        // Pharmacy.
        ("rite aid", "riteaid.com"),
        // Streaming / subscriptions.
        ("hulu", "hulu.com"),
        ("disney", "disneyplus.com"),
        ("youtube", "youtube.com"),
        ("audible", "audible.com"),
        ("peloton", "onepeloton.com"),
        // Shipping.
        ("usps", "usps.com"),
        ("ups", "ups.com"),
        ("fedex", "fedex.com"),
        // Telecom / cable.
        ("verizon", "verizon.com"),
        ("at&t", "att.com"),
        ("xfinity", "xfinity.com"),
        ("comcast", "xfinity.com"),
        // Insurance.
        ("geico", "geico.com"),
        ("progressive", "progressive.com"),
        ("state farm", "statefarm.com"),
        ("allstate", "allstate.com"),
        ("nationwide", "nationwide.com"),
        ("liberty mutual", "libertymutual.com"),
        ("usaa", "usaa.com"),
        // Utilities.
        ("bge", "bge.com"),
        ("pepco", "pepco.com"),
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
        ("paypal", "#003087"),
        ("t-mobile", "#e20074"),
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

    /// Build 53 (audit C2): word-boundary, longest-first matching
    /// (MerchantKeywordMatch) — a plain substring first-match made
    /// "apple" win over "applebee", "sonic" match "PANASONIC",
    /// "ups" match "CUPS". The same helper serves all four maps.
    public static func bankDomain(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased(), !name.isEmpty else { return nil }
        return MerchantKeywordMatch.bestMatch(in: name, from: bankDomains.map { (keyword: $0.keyword, value: $0.domain) })
    }

    /// The brand colour hex for an institution name, or nil when
    /// the bank is unmapped or has no known brand colour — the
    /// caller then uses the soft neutral fallback tile.
    public static func bankBrandHex(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased(), !name.isEmpty else { return nil }
        return MerchantKeywordMatch.bestMatch(in: name, from: bankBrandColors.map { (keyword: $0.keyword, value: $0.hex) })
    }

    public static func merchantDomain(for merchant: String) -> String? {
        MerchantKeywordMatch.bestMatch(in: merchant, from: merchantDomains.map { (keyword: $0.keyword, value: $0.domain) })
    }

    /// The brand colour hex for a merchant, or nil when the merchant
    /// is unmapped or has no known brand colour — the caller then
    /// uses the soft neutral fallback tile.
    public static func merchantBrandHex(for merchant: String) -> String? {
        MerchantKeywordMatch.bestMatch(in: merchant, from: merchantBrandColors.map { (keyword: $0.keyword, value: $0.hex) })
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

    // MARK: - Smart plan (build 52, owner Nov 20, 2026)

    /// The domain to fetch a favicon for, in priority order:
    /// (1) the CURATED map above — it wins for the tricky ones
    /// (Erie → erieinsurance.com, not erie.com); (2) a guess the
    /// app already confirmed (its favicon loaded once — remembered
    /// in UserDefaults, per device); (3) the auto-guess
    /// (MerchantDomainGuess — name → .com). Nil when there is
    /// nothing sensible to try; the caller then falls back to the
    /// monogram (build 53, owner Nov 21, 2026 — the bank logo is
    /// NOT a fallback for merchant rows any more; only bank rows
    /// show the bank logo, see TransactionIconView). A rejected
    /// guess (cleared in the Merchants screen) suppresses the
    /// auto-guess, so the wrong logo does not come straight back.
    public static func resolvedDomain(for merchant: String) -> String? {
        if let domain = merchantDomain(for: merchant) { return domain }
        if let domain = rememberedDomain(for: merchant) { return domain }
        if isGuessRejected(for: merchant) { return nil }
        return MerchantDomainGuess.guessedDomain(for: merchant)
    }

    /// Whether the resolved domain for this merchant is a GUESS
    /// (not curated, not remembered) — the icon view records it
    /// only when its favicon actually loads.
    public static func isGuessedDomain(for merchant: String) -> Bool {
        merchantDomain(for: merchant) == nil
            && rememberedDomain(for: merchant) == nil
            && !isGuessRejected(for: merchant)
            && MerchantDomainGuess.guessedDomain(for: merchant) != nil
    }

    // MARK: Remembered guesses (per device, UserDefaults)

    private static let guessedDomainsKey = "hb-merchant-guessed-domains"
    private static let needsIconKey = "hb-merchants-needing-icon"
    /// Guesses the user cleared in the Merchants screen (build 53,
    /// audit C3): a cleared guess is never re-fetched or
    /// re-remembered — the merchant stays on the monogram until a
    /// curated entry maps it properly (the curated map is consulted
    /// first, so it overrides a rejection).
    private static let rejectedGuessesKey = "hb-merchant-rejected-guesses"
    private static let needsIconCap = 100

    /// Strip a trailing store-number suffix (" #1234" / " 1234") —
    /// the digits are a store number, not part of the brand. Case
    /// is preserved; the caller lowercases for the key. A name
    /// that IS a number, or digits glued to a word ("7-eleven"),
    /// is left alone.
    private static func stripStoreNumber(_ name: String) -> String {
        var digitStart = name.endIndex
        while digitStart > name.startIndex, name[name.index(before: digitStart)].isNumber {
            digitStart = name.index(before: digitStart)
        }
        guard digitStart < name.endIndex, digitStart > name.startIndex else { return name }
        let before = name[name.index(before: digitStart)]
        guard before == " " || before == "#" else { return name }
        var cut = digitStart
        while cut > name.startIndex {
            let ch = name[name.index(before: cut)]
            guard ch == "#" || ch == " " else { break }
            cut = name.index(before: cut)
        }
        return String(name[..<cut])
    }

    private static func normalizedMerchant(_ merchant: String) -> String {
        // Build 53 (audit C4): the key is the brand, not the
        // store — "WALMART #1234" and "WALMART #5678" are the same
        // merchant, so their variants guess and remember together
        // instead of each guessing separately. (Keys remembered
        // before this change keep their old full-string form and
        // simply re-guess once — a one-time re-remember, not a
        // data loss.)
        stripStoreNumber(merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A guess this device already confirmed (its favicon loaded).
    public static func rememberedDomain(for merchant: String) -> String? {
        let stored = UserDefaults.standard.dictionary(forKey: guessedDomainsKey) as? [String: String] ?? [:]
        return stored[normalizedMerchant(merchant)]
    }

    /// Remember a guessed domain — ONLY after its favicon loaded,
    /// and never for a merchant the curated map already covers or
    /// whose guess was rejected (cleared in the Merchants screen).
    public static func rememberGuessedDomain(_ domain: String, for merchant: String) {
        guard merchantDomain(for: merchant) == nil, !isGuessRejected(for: merchant) else { return }
        var stored = UserDefaults.standard.dictionary(forKey: guessedDomainsKey) as? [String: String] ?? [:]
        stored[normalizedMerchant(merchant)] = domain
        UserDefaults.standard.set(stored, forKey: guessedDomainsKey)
    }

    // MARK: - Guessed domains, unverified (build 53, audit C3)

    /// Merchants whose icon is a remembered GUESS, with the guessed
    /// domain — unverified, for the Merchants screen to surface. A
    /// remembered guess only means "its favicon loaded once"; it
    /// can still be the WRONG company (erie.com loads a real
    /// favicon for the wrong company — only the curated "erie"
    /// entry shields it), so no guessed domain is ever treated as
    /// confirmed. Sorted by merchant name; the stored keys are
    /// normalized (lowercased), and the screen Title-Cases them
    /// like the no-icon list.
    public static func unverifiedGuessedMerchants() -> [(merchant: String, domain: String)] {
        let stored = UserDefaults.standard.dictionary(forKey: guessedDomainsKey) as? [String: String] ?? [:]
        return stored.map { (merchant: $0.key, domain: $0.value) }.sorted { $0.merchant < $1.merchant }
    }

    /// Whether this merchant's auto-guess was cleared (rejected) in
    /// the Merchants screen: its favicon is not fetched and the
    /// guess is not remembered again.
    public static func isGuessRejected(for merchant: String) -> Bool {
        let rejected = UserDefaults.standard.stringArray(forKey: rejectedGuessesKey) ?? []
        return rejected.contains(normalizedMerchant(merchant))
    }

    /// Clear a guessed domain for a merchant AND suppress
    /// re-guessing it: the merchant falls back to the monogram and
    /// returns to the "without an icon" list, until a curated entry
    /// (next build) maps it properly — the curated map is consulted
    /// first, so it overrides the rejection.
    public static func clearGuessedDomain(for merchant: String) {
        let key = normalizedMerchant(merchant)
        var stored = UserDefaults.standard.dictionary(forKey: guessedDomainsKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: key)
        UserDefaults.standard.set(stored, forKey: guessedDomainsKey)
        var rejected = UserDefaults.standard.stringArray(forKey: rejectedGuessesKey) ?? []
        if !rejected.contains(key) { rejected.append(key) }
        UserDefaults.standard.set(rejected, forKey: rejectedGuessesKey)
    }

    // MARK: Catch-up loop (merchants that still don't resolve)

    /// Record a merchant that has NO curated domain and NO
    /// remembered guess, so it can be added to the list in a later
    /// build. Idempotent; capped at the 100 most recent. The
    /// Merchants screen reads this back via `needsIconMerchants`.
    /// Build 53 (audit C4): a merchant already on the list is
    /// left alone — the old code rewrote UserDefaults on EVERY row
    /// appearance (moving the merchant to the front even when
    /// already listed). The stored display drops the store number
    /// ("WALMART #1234" → "WALMART"), so variants collapse to one
    /// row instead of one per store.
    public static func recordNeedsIcon(_ merchant: String) {
        guard merchantDomain(for: merchant) == nil,
              rememberedDomain(for: merchant) == nil else { return }
        let display = stripStoreNumber(merchant.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !display.isEmpty else { return }
        var stored = UserDefaults.standard.stringArray(forKey: needsIconKey) ?? []
        guard !stored.contains(where: { normalizedMerchant($0) == normalizedMerchant(display) }) else { return }
        stored.insert(display, at: 0)
        if stored.count > needsIconCap { stored = Array(stored.prefix(needsIconCap)) }
        UserDefaults.standard.set(stored, forKey: needsIconKey)
    }

    /// Merchants that still have no icon — the catch-up list for
    /// the Merchants screen. Filtered to those that STILL have no
    /// curated or remembered domain, so a merchant drops off the
    /// list as soon as a later build maps it or its guess is
    /// confirmed.
    public static func needsIconMerchants() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: needsIconKey) ?? []
        return stored.filter {
            merchantDomain(for: $0) == nil && rememberedDomain(for: $0) == nil
        }
    }
}
