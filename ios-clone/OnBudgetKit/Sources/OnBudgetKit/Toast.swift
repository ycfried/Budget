import Foundation

/// Toast style spec — owner rules: transient messages are bottom
/// toasts floating clear of the tab bar, never inside cards.
/// Information messages stay brand blue; SUCCESS messages are GREEN
/// (owner rule, Nov 11 2026 — native only, supersedes the web app's
/// brand-blue success toasts; the web app stays blue); errors use the
/// soft-red palette in `DesignTokens` instead.
/// This is the style spec (hex values + behaviour); the SwiftUI
/// rendering is built with the screens.
public enum ToastStyle {
    /// Toast kinds, mirroring the web app's toast kinds.
    public enum Kind: String {
        case info
        case success
        case error
    }

    /// Toast background: brand primary blue for info, GREEN for
    /// success, soft-red background for errors.
    public static func backgroundHex(for kind: Kind) -> String {
        switch kind {
        case .info:
            return DesignTokens.primaryHex
        case .success:
            return DesignTokens.successHex
        case .error:
            return DesignTokens.errorBackgroundHex
        }
    }

    /// Toast text: white on blue/green, dark red on soft-red.
    public static func textHex(for kind: Kind) -> String {
        switch kind {
        case .info, .success:
            return "#ffffff"
        case .error:
            return DesignTokens.errorTextHex
        }
    }

    /// Toasts sit at the bottom of the screen, floating clear of the
    /// tab bar.
    public static let placement = "bottom"

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
