import Foundation

/// Brand-blue toast spec — owner rules: transient messages are
/// brand-blue bottom toasts floating clear of the tab bar, never
/// inside cards. Success and information messages stay brand blue;
/// errors use the soft-red palette in `DesignTokens` instead.
/// This is the style spec (hex values + behaviour); the SwiftUI
/// rendering is built with the screens.
public enum ToastStyle {
    /// Toast kinds, mirroring the web app's toast kinds.
    public enum Kind: String {
        case info
        case success
        case error
    }

    /// Toast background: brand primary blue for info/success,
    /// soft-red background for errors.
    public static func backgroundHex(for kind: Kind) -> String {
        switch kind {
        case .info, .success:
            return DesignTokens.primaryHex
        case .error:
            return DesignTokens.errorBackgroundHex
        }
    }

    /// Toast text: white on brand blue, dark red on soft-red.
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
    public static let autoDismissSeconds = 3.0
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
