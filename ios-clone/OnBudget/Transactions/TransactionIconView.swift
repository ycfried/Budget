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
@MainActor
final class FaviconImageLoader: ObservableObject {
    static let shared = FaviconImageLoader()

    @Published private(set) var images: [URL: UIImage] = [:]
    private var inFlight: Set<URL> = []

    func image(for url: URL) -> UIImage? { images[url] }

    func load(_ url: URL) {
        if images[url] != nil || inFlight.contains(url) { return }
        inFlight.insert(url)
        Task {
            let image = await Self.fetch(url, retries: 1)
            inFlight.remove(url)
            if let image { images[url] = image }
        }
    }

    private static func fetch(_ url: URL, retries: Int) async -> UIImage? {
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
                    return image
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
                        .task(id: url) { faviconLoader.load(url) }
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

