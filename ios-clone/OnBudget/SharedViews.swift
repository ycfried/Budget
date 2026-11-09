// OnBudget — SharedViews.swift
//
// Shared SwiftUI building blocks for the Auth + Home screens.
// Colours come from OnBudgetKit DesignTokens only — never hard-coded
// hex in a screen. Button rules (owner, Nov 3–4): two-button rows are
// primary blue first + grey tertiary second; pale #bfdbfe is ONLY the
// middle tier of a three-button row; no two adjacent buttons share a
// colour/treatment. Back buttons are light blue #3b82f6, bold 700,
// 15px. Errors are soft red (bg #fef2f2, text #dc2626, border
// #fecaca). Toasts are brand blue, bottom only, auto-dismiss 4s.
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

// MARK: - Buttons

/// Primary: #2f6bff fill, white text.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Grey tertiary: #e5e7eb fill, ink text. Second button in
/// two-button rows.
public struct TertiaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Color(hex: "#e5e7eb"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Pale middle tier: #bfdbfe fill, ink text. ONLY as the middle tier
/// of a three-button row — never beside another pale button.
public struct PaleButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.pale)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Small variant of the tertiary style for in-row actions.
public struct SmallTertiaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(hex: "#e5e7eb"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Back buttons: light blue #3b82f6, bold 700, 15px, no background,
/// no border. Text is always "← Back".
public struct BackButton: View {
    public let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            Text("← Back")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DesignTokens.mid)
        }
        .accessibilityLabel("Back")
    }
}

// MARK: - Error / info boxes

/// Inline soft-red error box (`.result.error` in the web app).
/// Sign-in / join failures stay in this box under the fields —
/// never in a toast, which vanishes before the fix.
public struct ErrorBox: View {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DesignTokens.errorText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DesignTokens.errorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignTokens.errorBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Inline info box (`.result`, info bg #eef4ff, ink text).
public struct InfoBox: View {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(DesignTokens.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(hex: "#eef4ff"))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Loading screen

/// Full-screen loading view (live.html:39-43): S-mark ring + logo,
/// "OnBudget", "Loading Your Household". Shown on first paint and
/// kept until the first data load completes or fails — never a blank
/// or half-built page, and never an endless spinner with no error.
public struct LoadingView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(DesignTokens.primary, lineWidth: 2)
                    .frame(width: 72, height: 72)
                Text("S")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(DesignTokens.primary)
            }
            Text("OnBudget")
                .font(.system(size: 28, weight: .bold, design: .default))
                .foregroundStyle(DesignTokens.ink)
            Text("Loading Your Household")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
    }
}

// MARK: - Toast

/// Bottom toast, floating clear of the tab bar. Success/info are
/// brand blue with white text; errors are soft red. Auto-dismiss
/// 4s (ToastStyle.autoDismissSeconds, CLONE_SPEC §2.3); tap
/// dismisses sooner.
public struct ToastBanner: View {
    public let toast: Toast
    public let onDismiss: () -> Void
    public init(toast: Toast, onDismiss: @escaping () -> Void) {
        self.toast = toast
        self.onDismiss = onDismiss
    }
    public var body: some View {
        Button(action: onDismiss) {
            Text(toast.message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.kind == .error ? DesignTokens.errorText : .white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    toast.kind == .error
                        ? DesignTokens.errorBackground : DesignTokens.primary
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            toast.kind == .error ? DesignTokens.errorBorder : Color.clear,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 120) // Clear of the tab bar (web: bottom 120px).
    }
}

/// Overlays the current toast at the bottom of any screen, with the
/// 4-second auto-dismiss (ToastStyle.autoDismissSeconds — the one
/// shared value, CLONE_SPEC §2.3).
public struct ToastOverlayModifier: ViewModifier {
    @Binding public var toast: Toast?
    public init(toast: Binding<Toast?>) { self._toast = toast }
    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                ToastBanner(toast: toast) { self.toast = nil }
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(ToastStyle.autoDismissSeconds))
                        if self.toast?.id == toast.id { self.toast = nil }
                    }
            }
        }
    }
}

public extension View {
    func toastOverlay(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastOverlayModifier(toast: toast))
    }
}

// MARK: - Cards

/// Standard white card: radius 20, hairline shadow (styles.css:388).
public struct Card<Content: View>: View {
    public let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                    radius: 2, x: 0, y: 1)
    }
}

// MARK: - Transaction icons

/// Merchant / bank icon (live.js:55-177, Nov 4 Google-favicon rule).
/// Bank rows use the bank favicon when the card suffix maps to a
/// connected institution; otherwise the merchant favicon; any load
/// failure or unmapped name falls back to a brand-coloured monogram
/// tile (white initial, slate #475569 when unmapped). Never
/// Clearbit, never a flat grey box alone.
public struct TransactionIconView: View {
    private let merchant: String
    private let institutionName: String?

    public init(merchant: String, institutionName: String? = nil) {
        self.merchant = merchant
        self.institutionName = institutionName
    }

    private static let bankDomains: [(String, String)] = [
        ("american express", "americanexpress.com"), ("bank of america", "bankofamerica.com"),
        ("capital one", "capitalone.com"), ("chase", "chase.com"), ("citi", "citibank.com"),
        ("discover", "discover.com"), ("pnc", "pnc.com"), ("td", "td.com"),
        ("us bank", "usbank.com"), ("wells fargo", "wellsfargo.com"),
    ]

    private static let bankColors: [(String, String)] = [
        ("american express", "#2e77bc"), ("bank of america", "#e31837"),
        ("capital one", "#004977"), ("chase", "#117aca"), ("citi", "#003b70"),
        ("discover", "#f48120"), ("pnc", "#f58025"), ("td", "#00a651"),
        ("us bank", "#0c2074"), ("wells fargo", "#d71e28"),
    ]

    private static let merchantDomains: [(String, String)] = [
        ("trader joe", "traderjoes.com"), ("whole foods", "wholefoodsmarket.com"),
        ("home depot", "homedepot.com"), ("lowe", "lowes.com"), ("shoprite", "shoprite.com"),
        ("mcdonald", "mcdonalds.com"), ("starbucks", "starbucks.com"), ("chipotle", "chipotle.com"),
        ("amazon", "amazon.com"), ("walmart", "walmart.com"), ("target", "target.com"),
        ("costco", "costco.com"), ("apple", "apple.com"), ("cvs", "cvs.com"),
        ("walgreens", "walgreens.com"), ("exxon", "exxon.com"), ("shell", "shell.com"),
        ("uber", "uber.com"), ("lyft", "lyft.com"), ("netflix", "netflix.com"), ("spotify", "spotify.com"),
    ]

    private static let merchantColors: [(String, String)] = [
        ("amazon", "#ff9900"), ("walmart", "#0071dc"), ("target", "#cc0000"),
        ("costco", "#005daa"), ("starbucks", "#00704a"), ("chipotle", "#a81623"),
        ("mcdonald", "#da291c"), ("trader joe", "#d2232a"), ("whole foods", "#00674b"),
        ("home depot", "#f96302"), ("lowe", "#004990"), ("shoprite", "#d71920"),
        ("cvs", "#cc0000"), ("walgreens", "#e31837"), ("exxon", "#ed1c24"),
        ("shell", "#fbce07"), ("uber", "#000000"), ("lyft", "#ff00bf"),
        ("netflix", "#e50914"), ("spotify", "#1db954"), ("apple", "#000000"),
    ]

    private func match(_ name: String, in table: [(String, String)]) -> String? {
        let lower = name.lowercased()
        for (key, value) in table where lower.contains(key) { return value }
        return nil
    }

    public var body: some View {
        let name = institutionName ?? merchant
        let initial = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let domain = institutionName.map { match($0, in: Self.bankDomains) }
            ?? match(merchant, in: Self.merchantDomains)
        let brandHex = institutionName.map { match($0, in: Self.bankColors) ?? "#475569" }
            ?? (match(merchant, in: Self.merchantColors) ?? "#475569")
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: brandHex))
                .frame(width: 40, height: 40)
            if let domain, let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .frame(width: 28, height: 28)
                    default:
                        Text(initial.isEmpty ? "?" : initial)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Text(initial.isEmpty ? "?" : initial)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }
}

/// State pill: Posted / Pending / Reversed / Excluded (live.js:199-220).
/// "Reversed" renders as Reversed, never Posted.
public struct StatePill: View {
    public let label: String
    public init(label: String) { self.label = label }
    public var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Color(hex: "#eef4ff"))
            .foregroundStyle(DesignTokens.ink)
            .clipShape(Capsule())
    }
}
