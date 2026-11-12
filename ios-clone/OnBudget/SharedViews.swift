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
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
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
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
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
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
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
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
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
            // The real logo (Assets.xcassets/AppLogo), not the "S"
            // placeholder ring (owner, Nov 11, 2026).
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
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


// MARK: - Transaction icons / state pills
//
// `TransactionIconView` + `StatePill` live in
// Transactions/TransactionIconView.swift (integration, Nov 9, 2026):
// that copy has the state-based pill colours (live.js:199-220) and
// the size parameter + `TransactionIconLookup` icon maps, so the
// simpler SharedViews copies were deleted. `SourcePill` lives there
// too. Call sites use `TransactionIconView(merchant:institutionName:)`
// or `StatePill(_ transaction:)`.
