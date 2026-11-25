import Foundation

/// Toast style spec — owner rules: transient popup notifications
/// (owner, Nov 20, 2026 — build 50: a nicer-looking popup, NOT a
/// blocking modal, placed at the top where it looks best — never
/// forced to the bottom, never centered). A green check leads
/// success, a red X leads errors; auto-dismiss 4s, tap anywhere
/// else or the top-corner X closes early.
/// Information messages are SOFT LIGHT BLUE (owner, Nov 25, 2026 —
/// build 77: the solid brand-blue bar did not match the soft-tint
/// success/error toasts); SUCCESS messages are GREEN (owner rule,
/// Nov 11 2026 — native only, supersedes the web app's brand-blue
/// success toasts; the web app stays blue); errors use the
/// soft-red palette in `DesignTokens` instead.
/// Success toasts use the Posted status badge treatment (owner,
/// Nov 15, 2026): light green background #dcfce7 with dark green
/// text #166534 — NOT the solid #22c55e bar they used to be.
/// Owner, Nov 24, 2026 — build 74: the green top toast is THE one
/// confirmation style for the whole app (the Nov 23 branded
/// confirmation popup card is retired; toasts stay on top, which
/// also reverses the Nov 11 "toasts at the bottom" rule).
/// Destructive/choice confirmations (Delete Account, Remove
/// Expense, …) stay as dialogs — they need a user choice, not
/// just feedback.
/// This is the style spec (hex values + behaviour); the SwiftUI
/// rendering is built with the screens.
public enum ToastStyle {
    /// Toast kinds, mirroring the web app's toast kinds.
    public enum Kind: String {
        case info
        case success
        case error
    }

    /// Toast background: soft light blue for info, the Posted
    /// badge's light green for success, soft-red background for
    /// errors.
    public static func backgroundHex(for kind: Kind) -> String {
        switch kind {
        case .info:
            return DesignTokens.toastInfoBackgroundHex
        case .success:
            return DesignTokens.toastSuccessBackgroundHex
        case .error:
            return DesignTokens.errorBackgroundHex
        }
    }

    /// Toast text: dark blue on the light-blue info background,
    /// the Posted badge's dark green on the light-green success
    /// background, dark red on soft-red.
    public static func textHex(for kind: Kind) -> String {
        switch kind {
        case .info:
            return DesignTokens.toastInfoTextHex
        case .success:
            return DesignTokens.toastSuccessTextHex
        case .error:
            return DesignTokens.errorTextHex
        }
    }

    /// Toasts sit at the top of the screen as a popup (owner,
    /// Nov 20, 2026 — build 50: top, where it looks best — never
    /// forced to the bottom, never centered).
    public static let placement = "top"

    /// Toasts are transient: they dismiss on their own after this long.
    /// 4s per CLONE_SPEC §2.3 — the single shared value; the SwiftUI
    /// overlay sleeps on this, never on its own literal.
    public static let autoDismissSeconds = 4.0
}

/// A toast message, as produced by app actions and shown per `ToastStyle`.
public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public let message: String
    public let kind: ToastStyle.Kind

    public init(message: String, kind: ToastStyle.Kind = .info) {
        self.message = message
        self.kind = kind
    }
}
