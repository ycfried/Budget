import SwiftUI
import OnBudgetKit

/// Shared button treatments + toast banner for the Transactions
/// screens, per CLONE_SPEC §§1.1–1.3, 2.3.
///
/// Button rules (owner, Nov 3–4):
/// - Two-button rows: primary blue FIRST + grey tertiary SECOND.
/// - Pale #bfdbfe is ONLY the middle tier of a three-button row.
/// - No two adjacent buttons may share the same colour/treatment.
/// - Back buttons: light blue #3b82f6, bold 700, 15px, no bg/border.
/// - Title Case on every button label (minor words lower unless
///   first; exceptions "Sign In", "Mark as Charity").
/// - Errors: soft red (bg #fef2f2, text #dc2626, border #fecaca).
/// - Toasts: bottom only, clear of the tab bar, auto-dismiss 4s,
///   tap dismisses sooner; success/info brand blue, errors soft red.
///
/// NOTE (scaffold mismatch, Nov 9): `ToastStyle.autoDismissSeconds`
/// in OnBudgetKit is 3.0, but the spec (§2.3) and the task brief both
/// say 4s. This view uses 4s; the scaffold constant should be fixed
/// to 4.0 by its owner.

public struct PrimaryButtonStyle: ButtonStyle {
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

public struct TertiaryButtonStyle: ButtonStyle {
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

/// Pale #bfdbfe — ONLY as the middle tier of a three-button row.
public struct PaleButtonStyle: ButtonStyle {
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

public struct SmallPrimaryButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(DesignTokens.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

public struct SmallTertiaryButtonStyle: ButtonStyle {
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

/// Quiet text button (no bg, muted grey) — e.g. "See all", page links.
public struct QuietButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(hex: "#6b7280"))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Back link: light blue #3b82f6, bold 700, 15px, no bg, no border.
public struct BackButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(DesignTokens.mid)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Two / three-button rows

/// Two-button row: primary first, grey tertiary second.
public struct TwoButtonRow<Primary: View, Secondary: View>: View {
    let primary: Primary
    let secondary: Secondary

    public init(@ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.primary = primary()
        self.secondary = secondary()
    }

    public var body: some View {
        HStack(spacing: 12) {
            primary
            secondary
        }
    }
}

/// Three-button row: primary / pale middle / grey tertiary.
public struct ThreeButtonRow<First: View, Middle: View, Last: View>: View {
    let first: First
    let middle: Middle
    let last: Last

    public init(
        @ViewBuilder first: () -> First,
        @ViewBuilder middle: () -> Middle,
        @ViewBuilder last: () -> Last
    ) {
        self.first = first()
        self.middle = middle()
        self.last = last()
    }

    public var body: some View {
        HStack(spacing: 12) {
            first
            middle
            last
        }
    }
}

// MARK: - Soft-red error box (inline `.result.error`)

public struct SoftErrorBox: View {
    let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DesignTokens.errorText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.errorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignTokens.errorBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Toast

/// Toast manager: one toast at a time, bottom only, auto-dismiss 4s,
/// tap dismisses sooner. Success/info are brand blue; errors soft red.
@MainActor
@Observable
public final class ToastManager {
    public var toast: Toast?

    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ message: String, kind: ToastStyle.Kind = .success) {
        dismissTask?.cancel()
        toast = Toast(message: message, kind: kind)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.toast = nil
            }
        }
    }

    public func showError(_ message: String) {
        show(message, kind: .error)
    }

    public func dismiss() {
        dismissTask?.cancel()
        toast = nil
    }
}

public struct ToastBanner: View {
    let toast: Toast
    let onTap: () -> Void

    public init(toast: Toast, onTap: @escaping () -> Void) {
        self.toast = toast
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            Text(toast.message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: ToastStyle.textHex(for: toast.kind)))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(Color(hex: ToastStyle.backgroundHex(for: toast.kind)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            toast.kind == .error ? DesignTokens.errorBorder : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        // Bottom, floating clear of the tab bar (spec §2.3: bottom 120px).
        .padding(.bottom, 120)
    }
}
