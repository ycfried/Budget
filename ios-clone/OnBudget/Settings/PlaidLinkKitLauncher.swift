// OnBudget — Settings: real Plaid Link launcher (official LinkKit SDK).
//
// LinkKit 7.x, session-based API (Plaid docs, "Link - iOS", Nov 2026):
// `LinkTokenConfiguration(token:onSuccess:onExit:onEvent:onLoad:)` ->
// `Plaid.createPlaidLinkSession(configuration:)` (throws) ->
// `session.open(using: .viewController(...))`. The session MUST be
// retained for the duration of the flow, so this launcher is a class
// that holds the active session until onSuccess / onExit fires.
// Plaid Link handles bank credentials, MFA, and OAuth itself;
// OnBudget never sees credentials. No WKWebView wrapper.
//
// NOTE (Nov 9, 2026): the brief for this work assumed the old
// Handler API (`LinkKit.Configuration`, `LinkKit.createLink`) —
// LinkKit 7 removed it in favour of the session API above, so the
// implementation follows the current Plaid docs, not the brief.
// CI (build-for-testing) is the type-check: there is no Xcode here.

import LinkKit
import UIKit

/// Real `PlaidLinkLauncher` backed by the official Plaid LinkKit SDK.
final class PlaidLinkKitLauncher: PlaidLinkLauncher {
    /// Retained for the duration of the Link flow; cleared when the
    /// flow ends (success, exit, or setup failure).
    private var activeSession: PlaidLinkSession?

    func present(linkToken: String) async throws -> PlaidLinkOutcome {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let configuration = LinkTokenConfiguration(
                    token: linkToken,
                    onSuccess: { [self] success in
                        self.complete(
                            .success(
                                publicToken: success.publicToken,
                                institutionName: success.metadata.institution.name
                            ),
                            continuation: continuation
                        )
                    },
                    onExit: { [self] exit in
                        // Plain user cancel: `error` is nil, so the
                        // message is nil and the view shows nothing.
                        self.complete(
                            .exited(errorMessage: exit.error?.localizedDescription),
                            continuation: continuation
                        )
                    },
                    onEvent: nil,
                    onLoad: nil
                )
                do {
                    let session = try Plaid.createPlaidLinkSession(configuration: configuration)
                    self.activeSession = session
                    guard let presenter = Self.topViewController() else {
                        self.activeSession = nil
                        continuation.resume(throwing: PlaidLinkError.presentationUnavailable)
                        return
                    }
                    session.open(using: .viewController(presenter))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Ends the flow: releases the session (which breaks the
    /// session -> configuration -> callback -> self retain chain)
    /// and resumes the awaiting `present` call. LinkKit fires
    /// exactly one terminal callback per session, so the
    /// continuation resumes exactly once.
    private func complete(
        _ outcome: PlaidLinkOutcome,
        continuation: CheckedContinuation<PlaidLinkOutcome, Error>
    ) {
        activeSession = nil
        continuation.resume(returning: outcome)
    }

    /// The top-most presented view controller of the key window, so
    /// Link presents over whatever the user is looking at (Settings
    /// is itself a full-screen cover).
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            return nil
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
