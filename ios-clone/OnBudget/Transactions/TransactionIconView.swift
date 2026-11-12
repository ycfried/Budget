import SwiftUI
import OnBudgetKit

/// Transaction icon: the bank's Google favicon when the card suffix
/// maps to a connected institution, else the merchant favicon from
/// the curated keyword map. Any unmapped name, or a failed favicon
/// load, falls back to a monogram tile: white initial on the real
/// brand colour when the map knows one, else a soft neutral tile
/// (light slate `#e2e8f0`, dark slate initial) — one designed system
/// with the logo tiles (same size, same corner radius), never a fake
/// brand colour, never a blank tile, and never Clearbit (dead Nov 4, 2026).
public struct TransactionIconView: View {
    /// Institution name for the card suffix, when known (from the
    /// Settings bank list). When nil, the merchant icon is used.
    let institutionName: String?
    let merchant: String
    let size: CGFloat

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
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: size * 0.72, height: size * 0.72)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .background(Color.white)
                    case .empty, .failure:
                        // Loading or failed: the monogram underneath
                        // stays visible — never a blank tile.
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    /// Bank favicon wins when the suffix maps to a known institution;
    /// otherwise the merchant favicon (live.js `iconForTx`).
    private var faviconURL: URL? {
        if let domain = TransactionIconLookup.bankDomain(for: institutionName) {
            return TransactionIconLookup.faviconURL(forDomain: domain)
        }
        guard let domain = TransactionIconLookup.merchantDomain(for: merchant) else {
            return nil
        }
        return TransactionIconLookup.faviconURL(forDomain: domain)
    }

    private var monogram: some View {
        ZStack {
            monogramBackground
            Text(TransactionIconLookup.initial(for: merchant))
                .font(.system(size: size * 0.45, weight: .bold))
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

    /// The brand colour for this row, when the map knows one.
    private var brandHex: String? {
        if let name = institutionName,
           TransactionIconLookup.bankDomain(for: name) != nil {
            return TransactionIconLookup.bankBrandHex(for: name)
        }
        return TransactionIconLookup.merchantBrandHex(for: merchant)
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
            .clipShape(Capsule())
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

/// Source pill: Bank / By hand / File / Email alert.
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
            .background(Color(hex: "#eef4ff"))
            .foregroundStyle(Color(hex: "#1e3a8a"))
            .clipShape(Capsule())
    }
}
