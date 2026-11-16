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
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) { return image }
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
/// merchant's). The bank favicon is only the fallback, when the
/// merchant has no domain in the map; a loaded logo FILLS the whole
/// tile edge-to-edge (owner, Nov 12, 2026 — the Amex tiles in Recent
/// Transactions showed a white margin inside the tile): aspect-fill
/// + clip, cropping overflow, never stretched. No inner padding
/// between the image and the tile edge; the 1pt border and corner
/// radius stay. The source is Google's favicon service at sz=128,
/// which returns each site's largest icon (measured Nov 11, 2026:
/// Amex 32px, Walmart / Amazon 48px, Royal Farms 128px, Seven Mile
/// Market 168×107) — small sources are upscaled with high
/// interpolation, and sz=128 is already the max. The Amex source
/// itself carries no built-in white padding (verified Nov 12, 2026
/// from the served bytes: 32×32, mark touches all four edges), so
/// the margin the owner saw came entirely from this view's old
/// 14% inner padding + scaledToFit letterboxing, now removed. Any
/// unmapped name, or a failed favicon load, falls back to a monogram
/// tile: white initial on the real brand colour when the map knows
/// one, else a soft neutral tile (light slate `#e2e8f0`, dark slate
/// initial) — one designed system with the logo tiles (same size,
/// same corner radius), never a fake brand colour, never a blank
/// tile, and never Clearbit (dead Nov 4, 2026).
public struct TransactionIconView: View {
    /// Institution name for the card suffix, when known (from the
    /// Settings bank list). When nil, the merchant icon is used.
    let institutionName: String?
    let merchant: String
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
    public init(merchant: String, institutionName: String? = nil, size: CGFloat = 40) {
        self.institutionName = institutionName
        self.merchant = merchant
        self.size = size
    }

    public var body: some View {
        ZStack {
            monogram
            if let url = faviconURL {
                if let uiImage = faviconLoader.image(for: url) {
                    // Edge-to-edge fill (owner, Nov 12, 2026):
                    // scaledToFill + clip crops overflow so the
                    // logo reaches the tile edge on every side —
                    // no inner padding, no letterbox. Fill by
                    // cropping is not stretching: the aspect is
                    // never distorted, wide logos lose their
                    // sides, square logos (Amex) fill exactly.
                    // High interpolation softens the upscale of
                    // the small sources Google serves. The white
                    // background sits behind the image only, so
                    // a transparent source still reads on white
                    // instead of the monogram underneath.
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipped()
                        .background(Color.white)
                } else {
                    // Loading or failed: the monogram underneath
                    // stays visible — never a blank tile. The task
                    // triggers the (deduped, retried) load when the
                    // row appears; a cached image replaces this on
                    // the next render.
                    Color.clear
                        .task(id: url) { faviconLoader.load(url) }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    /// Merchant favicon first; the bank favicon only when the
    /// merchant has no domain in the map (owner, Nov 14, 2026 —
    /// bank-first made every row wear the Amex logo). The
    /// institution name is still passed in: it is the fallback,
    /// and the Settings bank tiles are untouched.
    private var faviconURL: URL? {
        if let domain = TransactionIconLookup.merchantDomain(for: merchant) {
            return TransactionIconLookup.faviconURL(forDomain: domain)
        }
        guard let domain = TransactionIconLookup.bankDomain(for: institutionName) else {
            return nil
        }
        return TransactionIconLookup.faviconURL(forDomain: domain)
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
    /// merchant first, bank only as the fallback (owner, Nov 14,
    /// 2026, same flip as the favicon above).
    private var brandHex: String? {
        if let hex = TransactionIconLookup.merchantBrandHex(for: merchant) {
            return hex
        }
        return TransactionIconLookup.bankBrandHex(for: institutionName)
    }
}

/// State pill: Posted (green-ish) / Pending (warn) / Reversed (rev) /
/// Excluded (warn) — live.js:199-220.
public struct StatePill: View {
    let transaction: Transaction

    public init(_ transaction: Transaction) {
        self.transaction = transaction
    }

    public var body: some View {
        Text(TransactionFormatting.stateWord(for: transaction))
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(pillBackground)
            .foregroundStyle(pillForeground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var pillBackground: Color {
        switch TransactionFormatting.stateWord(for: transaction) {
        case "Posted": return Color(hex: "#dcfce7")
        case "Pending", "Excluded": return Color(hex: "#fef3c7")
        case "Reversed": return Color(hex: "#fee2e2")
        default: return Color(hex: "#e5e7eb")
        }
    }

    private var pillForeground: Color {
        switch TransactionFormatting.stateWord(for: transaction) {
        case "Posted": return Color(hex: "#166534")
        case "Pending", "Excluded": return Color(hex: "#92400e")
        case "Reversed": return Color(hex: "#991b1b")
        default: return Color(hex: "#374151")
        }
    }
}

/// Source pill: Bank / By hand / File / Email. Each source has its
/// own colour (owner, Nov 14, 2026 — "should the bank and email
/// badges be different colors": yes): Bank keeps the blue, Email is
/// purple, By hand and File are neutral grey, so blue keeps meaning
/// Bank and purple keeps meaning Email. Colour is a redundant cue
/// only — the word is always there. The colours stay clear of the
/// state pills (Posted green, Pending amber, Reversed red).
public struct SourcePill: View {
    let transaction: Transaction

    public init(_ transaction: Transaction) {
        self.transaction = transaction
    }

    public var body: some View {
        Text(TransactionFormatting.sourceLabel(for: transaction.source))
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(pillBackground)
            .foregroundStyle(pillForeground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var pillBackground: Color {
        switch transaction.source {
        case .plaid: return Color(hex: "#eef4ff")
        case .amexAlert: return Color(hex: "#f3e8ff")
        case .manual, .csv: return Color(hex: "#f3f4f6")
        }
    }

    private var pillForeground: Color {
        switch transaction.source {
        case .plaid: return Color(hex: "#1e3a8a")
        case .amexAlert: return Color(hex: "#6b21a8")
        case .manual, .csv: return Color(hex: "#374151")
        }
    }
}
