import CryptoKit
import SwiftUI
import UIKit
import OnBudgetKit

/// Shared favicon loader (build 34): one in-flight fetch per URL,
/// in-memory cache, one retry after a short delay. Bare AsyncImage
/// fired a fetch per row and never retried a failure, so a burst of
/// list rows (or one flaky fetch) left merchant logos as monograms
/// permanently — the bank logo rendered only because it was already
/// cached from earlier screens. A load that still fails after the
/// retry simply never publishes an image, so the monogram stays —
/// the fallback for merchants with genuinely no logo. Rows that
/// reappear re-trigger a load (deduped while in flight), so a
/// transient failure recovers when the user scrolls back.
///
/// Build 94 (owner, Nov 25, 2026 — the BP logo disappeared): the
/// in-memory cache alone meant one failed Google fetch left the
/// monogram until the row reappeared, and an app restart lost every
/// logo. The loader is now TWO-LAYER persistent — load order, first
/// hit wins:
///   1. In-memory cache (fastest, as before).
///   2. On-device disk cache — Library/Caches/merchant-icons/,
///      keyed by the SHA-256 of the favicon URL. Survives restarts,
///      works offline. No expiry (logos rarely change); a curated
///      map change that changes the favicon URL changes the key.
///   3. Supabase Storage bucket `merchant-logos` (public read),
///      keyed by the curated domain (`bp.com.png`), so one device
///      seeding a logo makes it available to every device.
///   4. Google's favicon service (last resort, as before).
/// A Google fetch saves to disk AND seeds Storage in the background
/// (best-effort, deduped, never blocking, never loud on failure).
@MainActor
final class FaviconImageLoader: ObservableObject {
    static let shared = FaviconImageLoader()

    /// JWT provider for the authenticated Storage upload, wired once
    /// from AppState at launch (the client's validAccessToken, which
    /// refreshes when stale). Nil in previews / the widget — uploads
    /// are then skipped silently; reads from public Storage and
    /// Google still work.
    var tokenProvider: (() async throws -> String)?

    @Published private(set) var images: [URL: UIImage] = [:]
    private var inFlight: Set<URL> = []
    /// Domains confirmed present in Storage this session (downloaded
    /// from it, or uploaded successfully) — no further seed checks.
    private var storageSeededDomains: Set<String> = []
    /// Domains with a seed check/upload currently running.
    private var storageSeedInFlight: Set<String> = []

    func image(for url: URL) -> UIImage? { images[url] }

    /// Load a logo through the four layers. `domain` is the curated
    /// merchant/bank domain (the Storage key); nil skips the Storage
    /// layer — the disk cache (keyed by the favicon URL) still works.
    func load(_ url: URL, domain: String? = nil) {
        if images[url] != nil || inFlight.contains(url) { return }
        inFlight.insert(url)
        Task {
            let image = await resolve(url: url, domain: domain)
            inFlight.remove(url)
            if let image { images[url] = image }
        }
    }

    /// The four layers, first hit wins. A disk or Storage hit needs
    /// nothing further (disk already has it / Storage already has
    /// it); a Google hit saves to disk and seeds Storage.
    private func resolve(url: URL, domain: String?) async -> UIImage? {
        // Layer 2 (phone): the disk cache — survives restarts, works offline.
        if let data = await Task.detached { Self.readDiskData(for: url) }.value,
           let image = UIImage(data: data) {
            if let domain { ensureInStorage(data, domain: domain) }
            return image
        }
        // Layer 3 (platform): Supabase Storage, keyed by curated domain.
        if let domain,
           let data = await Self.fetchStorageData(forDomain: domain),
           let image = UIImage(data: data) {
            storageSeededDomains.insert(domain)
            await Self.saveToDisk(data, for: url)
            return image
        }
        // Layer 4 (last resort): Google's favicon service, as before.
        guard let result = await Self.fetch(url, retries: 1) else { return nil }
        await Self.saveToDisk(result.data, for: url)
        if let domain { ensureInStorage(result.data, domain: domain) }
        return result.image
    }

    // MARK: - Disk cache (phone layer)

    /// Library/Caches/merchant-icons/ — the OS may purge it under
    /// storage pressure, but it survives app restarts; the Storage
    /// layer is the backstop if it is ever purged.
    private nonisolated static var diskDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("merchant-icons", isDirectory: true)
    }

    /// Stable filename for a favicon URL: SHA-256 of the URL string.
    /// Merchants sharing a domain share a favicon URL, so they share
    /// a file; a curated override URL gets its own file (it is a
    /// different image than the Google favicon for that domain).
    private nonisolated static func diskURL(for faviconURL: URL) -> URL? {
        guard let directory = diskDirectory else { return nil }
        let digest = SHA256.hash(data: Data(faviconURL.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).png")
    }

    private nonisolated static func readDiskData(for faviconURL: URL) -> Data? {
        guard let file = diskURL(for: faviconURL) else { return nil }
        return try? Data(contentsOf: file)
    }

    private nonisolated static func writeDiskData(_ data: Data, for faviconURL: URL) {
        guard let file = diskURL(for: faviconURL) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
    }

    /// Disk writes run on a detached task — never on the main thread.
    private static func saveToDisk(_ data: Data, for faviconURL: URL) async {
        await Task.detached { Self.writeDiskData(data, for: faviconURL) }.value
    }

    // MARK: - Supabase Storage (platform layer)

    /// Public download URL for a domain's logo (`<domain>.png`).
    private static func storagePublicURL(forDomain domain: String) -> URL? {
        URL(string: "\(Configuration.supabaseURL)/storage/v1/object/public/merchant-logos/\(domain).png")
    }

    /// Upload endpoint for a domain's logo.
    private static func storageUploadURL(forDomain domain: String) -> URL? {
        URL(string: "\(Configuration.supabaseURL)/storage/v1/object/merchant-logos/\(domain).png")
    }

    /// Download a logo from Storage (public read, no auth). Only a
    /// 2xx response is a hit — anything else (404, network error)
    /// is a miss and the caller falls through to Google.
    private static func fetchStorageData(forDomain domain: String) async -> Data? {
        guard let url = storagePublicURL(forDomain: domain) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Best-effort seed: upload these bytes to Storage ONLY if
    /// Storage does not already hold a decodable logo for the
    /// domain (the GET is the dedup — a logo downloaded from
    /// Storage, or uploaded earlier this session, never re-uploads).
    /// Returns true when Storage now holds the logo. Every failure
    /// (no token, no network, bucket missing, denied) returns false
    /// silently — the logo already displays from disk/Google, and
    /// the next row appearance retries the seed.
    private static func uploadIfMissing(
        _ data: Data,
        domain: String,
        tokenProvider: (() async throws -> String)?
    ) async -> Bool {
        if let existing = await fetchStorageData(forDomain: domain),
           UIImage(data: existing) != nil {
            return true
        }
        return await uploadToStorage(data, domain: domain, tokenProvider: tokenProvider)
    }

    /// The raw Storage upload (POST + x-upsert, so it overwrites
    /// an existing file): the shared body of the best-effort seed
    /// above and the owner's explicit icon upload below. Returns
    /// false on any failure (no token, no network, denied) —
    /// the caller decides how loudly to fail.
    private static func uploadToStorage(
        _ data: Data,
        domain: String,
        tokenProvider: (() async throws -> String)?
    ) async -> Bool {
        guard let tokenProvider,
              let token = try? await tokenProvider(),
              let url = storageUploadURL(forDomain: domain) else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("image/png", forHTTPHeaderField: "Content-Type")
            request.setValue("true", forHTTPHeaderField: "x-upsert")
            request.httpBody = data
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
            return true
        } catch {
            return false
        }
    }

    /// Owner upload (build 99 — Merchant Rules, Known Icons):
    /// upload these PNG bytes as the merchant's icon, overwriting
    /// whatever the bucket holds for the domain. Used by Change
    /// Icon / Upload Icon — unlike the seed, this one is explicit
    /// and its result is shown to the owner (toast on success,
    /// error on failure). Marks the domain seeded on success so
    /// a later row appearance never re-uploads over it.
    public static func uploadIcon(data: Data, domain: String) async -> Bool {
        let ok = await uploadToStorage(data, domain: domain, tokenProvider: shared.tokenProvider)
        if ok { shared.storageSeededDomains.insert(domain) }
        return ok
    }

    /// Owner remove (build 99 — Merchant Rules, Known Icons):
    /// delete the bucket file for the domain. A 404 counts as
    /// success — the file is already gone, which is the end state
    /// the caller wants (e.g. the icon came from Google, not the
    /// bucket). Any other failure returns false and the caller
    /// shows the error.
    public static func deleteIcon(domain: String) async -> Bool {
        guard let tokenProvider = shared.tokenProvider,
              let token = try? await tokenProvider(),
              let url = storageUploadURL(forDomain: domain) else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if (200...299).contains(http.statusCode) || http.statusCode == 404 {
                shared.storageSeededDomains.remove(domain)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// Evict a logo from the in-memory and on-device disk caches
    /// (build 99 — Merchant Rules): after the owner uploads a
    /// replacement or removes the icon, the stale cached image
    /// must not keep rendering. The Storage layer is untouched —
    /// the caller uploads / deletes there. Pass the favicon URL
    /// the row actually renders (`TransactionIconLookup.iconURL`
    /// for the merchant, or the domain's Google favicon URL).
    public func evict(url: URL) {
        images.removeValue(forKey: url)
        Task.detached {
            guard let file = Self.diskURL(for: url) else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Fire-and-forget seed for a domain, deduped per session:
    /// skipped when the domain is already confirmed in Storage or a
    /// seed is already running; a failed seed retries the next time
    /// the row appears. Never blocks the UI, never fails loudly.
    private func ensureInStorage(_ data: Data, domain: String) {
        guard !storageSeededDomains.contains(domain),
              !storageSeedInFlight.contains(domain) else { return }
        storageSeedInFlight.insert(domain)
        Task {
            let ok = await Self.uploadIfMissing(data, domain: domain, tokenProvider: tokenProvider)
            storageSeedInFlight.remove(domain)
            if ok { storageSeededDomains.insert(domain) }
        }
    }

    private static func fetch(_ url: URL, retries: Int) async -> (image: UIImage, data: Data)? {
        for attempt in 0...retries {
            do {
                // Build 53 (audit C1): the HTTP status decides —
                // Google s2 answers a 404 WITH a decodable 16×16
                // globe PNG for a nonexistent domain, so decoding
                // without checking the status treated the globe as
                // a loaded favicon and a guessed domain got
                // remembered as confirmed. Only a 2xx response
                // carrying a decodable image is a real favicon.
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let image = UIImage(data: data) {
                    return (image, data)
                }
                // A non-2xx response, or a body that does not
                // decode, is a miss — fall through to the retry
                // below (a transient miss may succeed on retry; a
                // 404 simply fails again and returns nil).
            } catch {
                // Fall through to the retry below.
            }
            if attempt < retries {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return nil
    }
}

/// Transaction icon: the MERCHANT's Google favicon first — the
/// row is about where the money went, not which card paid (owner,
/// Nov 14, 2026: every row showed the Amex logo instead of the
/// merchant's). The bank favicon is ONLY for bank rows (a transfer
/// / card payment — the descriptor IS the bank's); an unmapped
/// merchant falls back to the monogram tile, never the bank logo
/// (owner, Nov 21, 2026: "Avraham Friedman" and "THE Timepiece"
/// wore the Amex logo, which said the bank was the merchant). A
/// loaded logo FITS the whole tile (owner, Nov 22, 2026 — this
/// REVERSES the Nov 12 edge-to-edge fill rule: fill cropped wide
/// logos, so Seven Mile Market showed "MIL" / "ARKE"): aspect-fit
/// / contain, the full logo visible, never cropped, never
/// stretched. A wide logo letterboxes on white; a square logo
/// (Amex) fills the tile exactly, as before. Showing the whole
/// logo matters more than filling the tile edge-to-edge. The 1pt
/// border and corner radius stay. The source is
/// Google's favicon service at sz=128, which returns each site's
/// largest icon (measured Nov 11, 2026: Amex 32px, Walmart / Amazon
/// 48px, Royal Farms 128px, Seven Mile Market 168×107) — small
/// sources are upscaled with high interpolation, and sz=128 is
/// already the max. (HomeGoods' own favicon is only 48×48, so
/// its icon comes from a curated higher-resolution override —
/// see TransactionIconLookup.merchantIconOverrides, build 60.)
/// Build 94 (owner, Nov 25, 2026): a fetched logo is no longer
/// memory-only — it persists in TWO layers (on-device disk cache
/// + Supabase Storage bucket `merchant-logos`, keyed by the curated
/// domain), so a known logo can never disappear again when the
/// live Google fetch fails; see FaviconImageLoader above.
/// The Amex source itself carries no built-in white padding
/// (verified Nov 12, 2026 from the served bytes: 32×32, mark
/// touches all four edges), so the margin the owner saw then
/// came entirely from this view's old 14% inner padding. Any
/// unmapped name, or a failed favicon load, falls back to a
/// monogram tile: white initial on the real brand colour when
/// the map knows one, else a soft neutral tile (light slate
/// `#e2e8f0`, dark slate initial) — one designed system with
/// the logo tiles (same size, same corner radius), never a fake
/// brand colour, never a blank tile, and never Clearbit (dead
/// Nov 4, 2026).
public struct TransactionIconView: View {
    /// Institution name for the card suffix, when known (from the
    /// Settings bank list). When nil, the merchant icon is used.
    let institutionName: String?
    let merchant: String
    /// True when this row is a BANK row (a transfer / card
    /// payment): the descriptor is the bank's, not a merchant's,
    /// so the bank logo is the right icon. False for merchant rows
    /// — an unmapped merchant gets the monogram, never the bank
    /// logo (owner, Nov 21, 2026).
    let isBankRow: Bool
    let size: CGFloat

    /// The shared favicon loader (build 34): cached images render
    /// instantly, and a failed load retries instead of leaving the
    /// monogram forever (see FaviconImageLoader above).
    @ObservedObject private var faviconLoader = FaviconImageLoader.shared

    /// Single initializer (merchant-first, the spelling every call
    /// site uses). A second institutionName-first init existed here
    /// and made a merchant-only call ambiguous — both inits matched
    /// it — so it was removed (CI run 42721951443); the one
    /// institutionName-first call site was reordered instead.
    public init(merchant: String, institutionName: String? = nil, isBankRow: Bool = false, size: CGFloat = 40) {
        self.institutionName = institutionName
        self.merchant = merchant
        self.isBankRow = isBankRow
        self.size = size
    }

    public var body: some View {
        ZStack {
            if let url = faviconURL {
                if let uiImage = faviconLoader.image(for: url) {
                    // Aspect fit (owner, Nov 22, 2026 — reverses
                    // the Nov 12 fill rule): the FULL logo is
                    // visible, never cropped — for this logo and
                    // for all current and future logos. A wide
                    // logo (Seven Mile Market, 168×107)
                    // letterboxes on white instead of losing its
                    // sides ("MIL" / "ARKE"); a square logo
                    // (Amex, Amazon) fills the tile exactly, as
                    // before. The white tile behind the image
                    // hides the monogram underneath, so the
                    // letterbox reads clean, never as a letter
                    // peeking out around the logo. The fitted
                    // size is pure math (fittedSize below) so
                    // the fit — not fill — is unit-tested. High
                    // interpolation softens the upscale of the
                    // small sources Google serves.
                    // Build 68 (owner, Nov 23, 2026 — item 2):
                    // the STAPLES logo rendered off-centre and
                    // clipped at the tile edges. The image is now
                    // drawn centred in the tile on both axes
                    // (explicit centred frame + scaledToFit, not
                    // just the ZStack default) at 90% of the
                    // fitted size, so no logo — Staples or any
                    // other — touches or crosses a tile edge.
                    // `fittedSize` itself is unchanged (its
                    // values are pinned by unit tests); the 10%
                    // breathing room is a render-only inset.
                    Color.white
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: fitted.width * 0.9, height: fitted.height * 0.9, alignment: .center)
                        .frame(width: size, height: size, alignment: .center)
                } else {
                    // Loading or failed: the monogram stays
                    // visible — never a blank tile. The task
                    // triggers the (deduped, retried) load when
                    // the row appears; a cached image replaces
                    // this on the next render.
                    monogram
                    Color.clear
                        .task(id: url) { faviconLoader.load(url, domain: logoDomain) }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .accessibilityHidden(true)
        // Build 52 (owner, Nov 20, 2026 — the smart plan's
        // catch-up loop): when this row appears, a merchant with
        // no curated domain is recorded (idempotent) so the
        // Merchants screen can list it for a later build. A
        // merchant drops off that list as soon as it gets a
        // curated domain. (Build 57 removed the auto-guess: no
        // guessed domain is ever fetched or remembered — an
        // unmapped merchant keeps the monogram.)
        .task(id: merchant) { TransactionIconLookup.recordNeedsIcon(merchant) }
    }

    /// Merchant icon first — a curated higher-resolution
    /// override when one exists (HomeGoods, build 60), otherwise
    /// the Google s2 favicon for the curated domain; the bank
    /// favicon only for a BANK row (owner, Nov 21, 2026 — the
    /// icon fallback rule: an unmapped merchant gets the
    /// monogram, never the bank logo).
    /// Build 57: the merchant domain is the CURATED one only —
    /// the auto-guess and remembered guesses are removed, so a
    /// merchant with no curated entry shows the monogram instead
    /// of a guessed logo. The institution name is still passed
    /// in: it is the bank row's logo, and the Settings bank
    /// tiles are untouched.
    private var faviconURL: URL? {
        if let url = TransactionIconLookup.iconURL(for: merchant) {
            return url
        }
        guard isBankRow,
              let domain = TransactionIconLookup.bankDomain(for: institutionName) else {
            return nil
        }
        return TransactionIconLookup.faviconURL(forDomain: domain)
    }

    /// The curated domain this logo is keyed by in the platform
    /// layer (Storage file `<domain>.png`). Mirrors faviconURL:
    /// merchant domain first, bank domain for bank rows. Nil when
    /// the merchant is unmapped (monogram) or the icon came from a
    /// curated override with no domain — the disk cache still works
    /// (it is keyed by the favicon URL), only the Storage layer is
    /// skipped.
    private var logoDomain: String? {
        if TransactionIconLookup.iconURL(for: merchant) != nil {
            return TransactionIconLookup.resolvedDomain(for: merchant)
        }
        guard isBankRow else { return nil }
        return TransactionIconLookup.bankDomain(for: institutionName)
    }

    /// The aspect-fit size of the loaded logo inside this tile —
    /// the full logo is visible, never cropped (owner, Nov 22,
    /// 2026). Falls back to the whole tile when no image is
    /// loaded (the monogram branch does not use it).
    private var fitted: CGSize {
        guard let url = faviconURL,
              let uiImage = faviconLoader.image(for: url) else {
            return CGSize(width: size, height: size)
        }
        return Self.fittedSize(imageSize: uiImage.size, tileSize: size)
    }

    /// Aspect-fit size for a source image inside a square tile —
    /// pure math, unit-tested in TransactionIconLookupTests.
    /// A wide source (168×107 in a 40pt tile) becomes 40×25.5;
    /// a square source fills the tile exactly; a tall source
    /// becomes 25.5×40. A fill would return the whole tile for
    /// a wide source — these tests pin fit, not fill. Ships in
    /// build 60 with the HomeGoods high-res override and the
    /// pending-gifts-off-Available rule.
    static func fittedSize(imageSize: CGSize, tileSize: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, tileSize > 0 else {
            return CGSize(width: tileSize, height: tileSize)
        }
        let scale = min(tileSize / imageSize.width, tileSize / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private var monogram: some View {
        ZStack {
            monogramBackground
            // The generic merchant icon: the merchant's initial as a
            // proper icon (rounded bold letter on the soft tile), not
            // a bare grey square (owner, Nov 11, 2026).
            Text(TransactionIconLookup.initial(for: merchant))
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(monogramForeground)
        }
    }

    /// Real brand colour when the map knows one; otherwise the soft
    /// neutral fallback tile — never an invented brand colour.
    private var monogramBackground: Color {
        if let hex = brandHex {
            return Color(hex: hex)
        }
        return Color(hex: TransactionIconLookup.fallbackTileHex)
    }

    /// White initial on a brand colour; dark slate initial on the
    /// soft fallback tile so it stays readable.
    private var monogramForeground: Color {
        if brandHex != nil {
            return .white
        }
        return Color(hex: TransactionIconLookup.fallbackBrandHex)
    }

    /// The brand colour for this row, when the map knows one —
    /// merchant only. Build 53 (owner, Nov 21, 2026): the bank's
    /// brand colour is NOT a fallback — it made an unmapped
    /// merchant's monogram look like a bank brand tile (an Amex-blue
    /// "A" for "Avraham Friedman"). An unmapped merchant gets the
    /// soft neutral tile; a bank row shows the bank logo, so its
    /// tile colour never renders.
    private var brandHex: String? {
        TransactionIconLookup.merchantBrandHex(for: merchant)
    }
}

/// State label: Posted / Pending / Reversed / Excluded as plain grey
/// text (owner, Nov 17, 2026 — build 42, badge Version A: no pills,
/// no tint). Was a coloured pill (Posted green, Pending amber,
/// Reversed red) — retired with the transaction colour code.
public struct StatePill: View {
    let transaction: Transaction

    public init(_ transaction: Transaction) {
        self.transaction = transaction
    }

    public var body: some View {
        Text(TransactionFormatting.stateWord(for: transaction))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DesignTokens.muted)
    }
}

