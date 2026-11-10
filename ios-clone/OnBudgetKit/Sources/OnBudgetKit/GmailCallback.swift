// OnBudgetKit — GmailCallback.swift
//
// Parses the native Gmail OAuth return URL:
// `onbudget://gmail-callback?gmail=connected|failed`.
//
// The `onbudget` scheme is registered in the app target
// (INFOPLIST_KEY_CFBundleURLTypes); the server redirects there for
// native flows only — see `gmail-oauth-start` / `gmail-oauth-callback`
// (branch gmail-callback-native-redirect, NOT deployed yet): the
// start function encodes the client in the OAuth state
// (`native:<nonce>`), and the callback redirects to
// `onbudget://gmail-callback` for native states and to live.html
// for web states. Until that server change ships, the callback can
// never arrive in this shape — the live flow still returns to
// live.html, which the native session cannot see.
//
// The live OAuth path needs no forwarding: an active
// `ASWebAuthenticationSession` with callbackURLScheme "onbudget"
// completes on its own once the scheme is registered. This parser
// is for the app-level deep-link route (`OnBudgetApp.onOpenURL` →
// `AppViewModel.handleGmailDeepLink`), which records a callback
// that arrives outside an active session (e.g. the session already
// finished, or a re-tap) so it is not silently dropped.

import Foundation

/// The outcome carried by a Gmail OAuth callback URL.
public enum GmailCallbackResult: Equatable {
    case connected
    case failed
}

public enum GmailCallback {
    public static let scheme = "onbudget"
    public static let host = "gmail-callback"

    /// The outcome of `url`, or nil when it is not a Gmail callback
    /// URL (wrong scheme/host, or no recognised `gmail` param).
    public static func result(from url: URL) -> GmailCallbackResult? {
        guard url.scheme == scheme, url.host == host else { return nil }
        switch URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "gmail" })?.value {
        case "connected":
            return .connected
        case "failed":
            return .failed
        default:
            return nil
        }
    }
}
