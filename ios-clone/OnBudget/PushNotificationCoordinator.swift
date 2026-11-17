import Foundation
import UIKit
import UserNotifications
import OnBudgetKit

/// Push-notification coordinator (Nov 16, 2026). Owns the permission
/// prompt, the APNs device token, and tap routing. The AppDelegate
/// forwards system events here; AppViewModel owns the routing and
/// registration closures and marks the app ready after boot.
@MainActor
public final class PushNotificationCoordinator {
    public static let shared = PushNotificationCoordinator()

    /// Route a notification tap: (screen, householdId).
    public var routeToScreen: ((NotificationScreen, UUID?) -> Void)?
    /// Register (or unregister) a device token with the server.
    public var registerToken: ((String, Bool) async -> Void)?

    /// The last APNs device token hex, for sign-out unregister.
    public private(set) var lastDeviceTokenHex: String?

    /// True once AppViewModel has booted into .app. A tap that
    /// arrives before then is stashed in `pendingPayload`.
    public var isAppReady = false

    /// A notification tap that arrived before the app finished
    /// booting (cold start). AppViewModel consumes it after boot.
    public var pendingPayload: NotificationPayload?

    /// The APNs environment for this build: TestFlight / App Store
    /// use production APNs; development builds use the sandbox.
    public var currentEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private init() {}

    /// Ask for permission once, after first sign-in, when Home first
    /// appears with a household loaded. Never at first launch, never
    /// before the value is clear. A decline is respected forever —
    /// never re-prompted, no banner. No custom pre-prompt dialog:
    /// the system prompt is the ask.
    public func requestPermissionIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: PushNotifications.permissionAskedKey) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            UserDefaults.standard.set(true, forKey: PushNotifications.permissionAskedKey)
            return
        }
        UserDefaults.standard.set(true, forKey: PushNotifications.permissionAskedKey)
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            // Silent: a failed prompt is not the user's problem.
        }
    }

    /// Re-register the token on launch when already authorized
    /// (tokens rotate). A no-op when not authorized or when APNs has
    /// not issued a token yet.
    public func reregisterIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs issued (or re-issued) a device token.
    public func didRegister(deviceToken: Data) {
        let hex = PushNotifications.deviceTokenHex(deviceToken)
        lastDeviceTokenHex = hex
        Task { await registerToken?(hex, false) }
    }

    public func didFailToRegister(error: Error) {
        // Silent: push is best-effort; the app works without it.
    }

    /// A notification tap. Routes when the app is ready; otherwise
    /// stashes it for AppViewModel to consume after boot.
    public func didReceive(payload: NotificationPayload) {
        if isAppReady {
            routeToScreen?(payload.screen, payload.householdId)
        } else {
            pendingPayload = payload
        }
    }

    /// The system authorization state, for the Settings Notifications
    /// card.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
