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
        // company, so the curated entry is the only mapping
        // (build 57 removed the auto-guess — there is no
        // guessed domain for it to win over any more).
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
        // out wrong, the catch-up loop below is the correction
        // path — fix the entry in the curated map (build 57
        // removed the auto-guess; there is no guessing any
        // more, so a wrong entry is fixed, not re-guessed).
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
        ("staples", "#cc0000"),
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

    /// The curated domain for a merchant, or nil when the merchant
    /// is unmapped. Build 99 (owner, Nov 26, 2026 — Merchant
    /// Rules, Known Icons): a domain the owner REMOVED (see
    /// `removedIconDomains`) returns nil here, so the merchant
    /// falls back to the monogram everywhere — the curated map
    /// itself is unchanged, this is a runtime exclusion on top of
    /// it. A custom icon key recorded by an Upload (see
    /// `customIconDomains`) is consulted when the curated map has
    /// no entry, so a merchant the owner gave an icon to resolves
    /// even without a curated domain.
    public static func merchantDomain(for merchant: String) -> String? {
        guard let domain = rawMerchantDomain(for: merchant) else { return nil }
        return removedIconDomains().contains(domain) ? nil : domain
    }

    /// The map lookup without the removed-icon exclusion — the
    /// curated keyword map first, then a custom icon key recorded
    /// by an Upload. `merchantDomain` above is the public entry
    /// point; `iconURL` uses this one so a removed domain can
    /// suppress even a curated override (HomeGoods).
    private static func rawMerchantDomain(for merchant: String) -> String? {
        if let domain = MerchantKeywordMatch.bestMatch(in: merchant, from: merchantDomains.map { (keyword: $0.keyword, value: $0.domain) }) {
            return domain
        }
        let key = customIconKey(for: merchant)
        return customIconDomains()[key]
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

    /// Curated higher-resolution logo sources (build 60, owner
    /// Nov 22, 2026). Google's favicon service caps at sz=128
    /// but serves each site's own favicon — HomeGoods' is only
    /// 48×48, so upscaling it to the ~40pt tile (80–120px at
    /// 2x/3x) blurs it, and no larger sz exists. A curated
    /// override points at a larger logo asset instead. Only
    /// entries verified here belong in this map — no guessing,
    /// no Clearbit (dead Nov 4, 2026).
    public static let merchantIconOverrides: [(keyword: String, url: String)] = [
        // HomeGoods: the site's own favicon is a 48×48 "HG"
        // tile (Google s2, verified Nov 22, 2026). Wikimedia
        // Commons hosts the real wordmark (280×94, public-domain
        // text logo, source www.homegoods.com) — wide enough to
        // render crisp at 3x in a 40pt tile. Verified Nov 22,
        // 2026 (fetched, 200, 280×94, the dark-red "HomeGoods"
        // wordmark with the roofline).
        ("homegoods", "https://upload.wikimedia.org/wikipedia/commons/8/88/Homegoods_logo.png"),
    ]

    /// The icon URL for a merchant: a curated higher-resolution
    /// override when one exists, otherwise the Google s2 favicon
    /// for the curated domain. Nil when the merchant is unmapped
    /// — the caller falls back to the monogram (build 57).
    /// Build 99 (owner, Nov 26, 2026 — Merchant Rules): a domain
    /// the owner REMOVED suppresses the icon entirely, even a
    /// curated override (HomeGoods has both a domain and an
    /// override URL) — the override check runs only after the
    /// removed-domain check.
    public static func iconURL(for merchant: String) -> URL? {
        if let raw = rawMerchantDomain(for: merchant),
           removedIconDomains().contains(raw) {
            return nil
        }
        if let override = MerchantKeywordMatch.bestMatch(in: merchant, from: merchantIconOverrides.map { (keyword: $0.keyword, value: $0.url) }) {
            return URL(string: override)
        }
        guard let domain = resolvedDomain(for: merchant) else { return nil }
        return faviconURL(forDomain: domain)
    }

    /// The monogram initial for a merchant name.
    public static func initial(for merchant: String) -> String {
        merchant.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: - Resolved domain (build 57, owner Nov 22, 2026)

    /// The domain to fetch a favicon for: the CURATED map above,
    /// ONLY. The auto-guess (build 52 — name → .com) and the
    /// remembered guesses are REMOVED: a guessed domain can be the
    /// wrong company, or a blurry generic image — THE Timepiece
    /// wore a blurry clock from thetimepiece.com, and the owner
    /// ruled (Nov 22, 2026) that a transaction with no merchant
    /// or available logo should rely on the DEFAULT monogram
    /// rather than a made-up or improper icon. So an unmapped
    /// merchant resolves to nil and the caller falls back to the
    /// monogram (build 53, owner Nov 21, 2026 — the bank logo is
    /// NOT a fallback for merchant rows any more; only bank rows
    /// show the bank logo, see TransactionIconView). The curated
    /// map is the only source of merchant domains now; a merchant
    /// that needs a logo gets a curated entry in a later build
    /// (the catch-up list below is how it is found).
    public static func resolvedDomain(for merchant: String) -> String? {
        merchantDomain(for: merchant)
    }

    /// One-time cleanup (build 57): remove the retired guessed-
    /// icon data left by builds 52–53 — the remembered guesses
    /// ("hb-merchant-guessed-domains") and the cleared-guess list
    /// ("hb-merchant-rejected-guesses"). Nothing reads them any
    /// more (resolvedDomain is curated-only now), so they are
    /// inert — but a device that remembered THE Timepiece's clock
    /// still carries it, and clearing it guarantees no stale
    /// guessed icon can ever resurface. Idempotent; safe to call
    /// on every launch (removing a missing key is a no-op).
    /// Called once from OnBudgetApp.init().
    public static func clearStaleGuessedIconData() {
        UserDefaults.standard.removeObject(forKey: "hb-merchant-guessed-domains")
        UserDefaults.standard.removeObject(forKey: "hb-merchant-rejected-guesses")
    }

    // MARK: - Owner-managed icon state (build 99, Merchant Rules)

    /// Domains whose icon the owner REMOVED from the Merchant
    /// Rules page ("Known Icons" → Remove Icon). `merchantDomain`
    /// returns nil for these, so the merchant shows the monogram
    /// instead of re-fetching the favicon, and `iconURL` returns
    /// nil even for a curated override. The curated map is NOT
    /// edited — this is a runtime exclusion on top of it. A
    /// removed domain can come back only by uploading a new icon
    /// for that merchant (Change / Upload clears the exclusion).
    private static let removedIconDomainsKey = "hb-merchant-removed-icon-domains"

    public static func removedIconDomains() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: removedIconDomainsKey) ?? [])
    }

    public static func recordRemovedIconDomain(_ domain: String) {
        var stored = removedIconDomains()
        stored.insert(domain.lowercased())
        UserDefaults.standard.set(Array(stored).sorted(), forKey: removedIconDomainsKey)
    }

    public static func clearRemovedIconDomain(_ domain: String) {
        var stored = removedIconDomains()
        stored.remove(domain.lowercased())
        UserDefaults.standard.set(Array(stored).sorted(), forKey: removedIconDomainsKey)
    }

    /// Domains whose icon the owner CONFIRMED ("Known Icons" →
    /// Confirm Icon). Confirming changes nothing about how the
    /// icon resolves — the bucket / disk cache already wins — it
    /// only records that the owner verified this icon, so the
    /// Merchant Rules page can show it as confirmed.
    private static let confirmedIconDomainsKey = "hb-merchant-confirmed-icon-domains"

    public static func confirmedIconDomains() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: confirmedIconDomainsKey) ?? [])
    }

    public static func recordConfirmedIconDomain(_ domain: String) {
        var stored = confirmedIconDomains()
        stored.insert(domain.lowercased())
        UserDefaults.standard.set(Array(stored).sorted(), forKey: confirmedIconDomainsKey)
    }

    /// Clear a confirmation (Remove Icon clears it — a
    /// replacement icon uploaded later must be confirmed
    /// afresh, not inherit the old icon's confirmation).
    public static func clearConfirmedIconDomain(_ domain: String) {
        var stored = confirmedIconDomains()
        stored.remove(domain.lowercased())
        UserDefaults.standard.set(Array(stored).sorted(), forKey: confirmedIconDomainsKey)
    }

    /// Merchant → icon-key map for merchants with NO curated
    /// domain, recorded when the owner uploads an icon for one
    /// ("Merchants Without an Icon" → Upload Icon). The key is
    /// the store-number-stripped, lowercased merchant name, so
    /// "WALMART #1234" and "WALMART #5678" share one entry; the
    /// value is the Storage key's domain part — a slug of the
    /// merchant name (see `iconSlug`), NOT a real DNS domain.
    /// The slug only matters as a Storage key (`<slug>.png`):
    /// the Storage layer is consulted before Google, so the
    /// uploaded icon resolves from the bucket and the Google
    /// favicon for the slug (which 404s) is never reached. The
    /// curated map always wins over this map — a later curated
    /// entry for the same merchant takes over.
    private static let customIconDomainsKey = "hb-merchant-custom-icon-domains"

    public static func customIconDomains() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: customIconDomainsKey) as? [String: String] ?? [:]
    }

    /// The custom-map key for a merchant: store number stripped,
    /// lowercased, trimmed — the same normalisation the
    /// needs-icon list uses, so variants of one merchant share
    /// one entry.
    public static func customIconKey(for merchant: String) -> String {
        stripStoreNumber(merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Record a slug as the icon key for a merchant (Upload Icon
    /// for a merchant with no curated domain). Returns false when
    /// the slug is already claimed by a DIFFERENT merchant — a
    /// slug collision must not silently steal another merchant's
    /// icon; the caller surfaces that as an error instead.
    @discardableResult
    public static func recordCustomIconDomain(_ slug: String, forMerchant merchant: String) -> Bool {
        let key = customIconKey(for: merchant)
        var stored = customIconDomains()
        if stored[key] == slug { return true }
        if stored.contains(where: { $0.value == slug && $0.key != key }) {
            return false
        }
        stored[key] = slug
        UserDefaults.standard.set(stored, forKey: customIconDomainsKey)
        return true
    }

    /// The Storage-key slug for a merchant name: lowercase
    /// alphanumerics joined with hyphens ("BELLUNO CAFE" →
    /// "belluno-cafe"). Nil when nothing slug-worthy remains
    /// (a name of pure punctuation) — the caller then cannot
    /// upload under a slug and must say so.
    public static func iconSlug(for merchant: String) -> String? {
        let stripped = stripStoreNumber(merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = stripped.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "-")
    }

    // MARK: Catch-up list (merchants with no icon yet)

    private static let needsIconKey = "hb-merchants-needing-icon"
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
        // merchant, so their variants collapse to one catch-up
        // entry instead of one per store. (Keys stored before
        // this change keep their old full-string form — they
        // simply re-record once.)
        stripStoreNumber(merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Record a merchant that has NO curated domain, so it can be
    /// added to the list in a later build. Idempotent; capped at
    /// the 100 most recent. The Merchants screen reads this back
    /// via `needsIconMerchants`. Build 53 (audit C4): a merchant
    /// already on the list is left alone — the old code rewrote
    /// UserDefaults on EVERY row appearance (moving the merchant
    /// to the front even when already listed). The stored display
    /// drops the store number ("WALMART #1234" → "WALMART"), so
    /// variants collapse to one row instead of one per store.
    public static func recordNeedsIcon(_ merchant: String) {
        guard merchantDomain(for: merchant) == nil else { return }
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
    /// curated domain, so a merchant drops off the list as soon
    /// as a later build maps it.
    public static func needsIconMerchants() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: needsIconKey) ?? []
        return stored.filter {
            merchantDomain(for: $0) == nil
        }
    }
}
