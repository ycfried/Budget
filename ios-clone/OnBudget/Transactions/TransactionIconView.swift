import SwiftUI
import OnBudgetKit

/// Transaction icon: the bank's Google favicon when the card suffix
/// maps to a connected institution, else the merchant favicon from
/// the curated keyword map. Any unmapped name, or a failed favicon
/// load, falls back to a brand-coloured monogram tile (white initial
/// on the merchant's brand colour, slate #475569 when unmapped) —
/// never a flat grey box alone, and never Clearbit (dead Nov 4, 2026).
public struct TransactionIconView: View {
    /// Institution name for the card suffix, when known (from the
    /// Settings bank list). When nil, the merchant icon is used.
    let institutionName: String?
    let merchant: String
    let size: CGFloat

    public init(institutionName: String? = nil, merchant: String, size: CGFloat = 40) {
        self.institutionName = institutionName
        self.merchant = merchant
        self.size = size
    }

    /// Merchant-first spelling, used by Home + Trash call sites
    /// (kept from the deleted SharedViews copy so they need no edit).
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
                    default:
                        // Loading or failed: the monogram underneath
                        // stays visible — never a blank tile.
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
            brandColor
            Text(TransactionIconLookup.initial(for: merchant))
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var brandColor: Color {
        if let name = institutionName,
           TransactionIconLookup.bankDomain(for: name) != nil {
            return Color(hex: TransactionIconLookup.bankBrandHex(for: name))
        }
        return Color(hex: TransactionIconLookup.merchantBrandHex(for: merchant))
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
