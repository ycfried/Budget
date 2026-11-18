import UIKit
import UserNotifications
import OnBudgetKit

/// AppDelegate (Nov 16, 2026): the push-notification plumbing. The
/// app is SwiftUI (@main in OnBudgetApp); this delegate is attached
/// via @UIApplicationDelegateAdaptor and forwards APNs events to the
/// PushNotificationCoordinator. It owns no UI and no navigation.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Widget background refresh (build 43, owner Nov 17, 2026):
        // register the BGAppRefreshTask handler early — registration
        // must happen before the app finishes launching, or iOS
        // never delivers the task — and schedule the first run.
        // The task fetches fresh widget numbers in the background
        // when iOS schedules it (a few times a day, at iOS's
        // discretion); it is not a timer.
        WidgetBackgroundRefreshTask.register()
        WidgetBackgroundRefreshTask.schedule()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationCoordinator.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationCoordinator.shared.didFailToRegister(error: error)
        }
    }

    /// A notification that arrives while the app is open: show the
    /// banner (and play the sound), like a notification that arrived
    /// while the app was closed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// A notification tap: hand the payload to the coordinator, which
    /// routes it (or stashes it for after boot on a cold start).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let payload = NotificationPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            PushNotificationCoordinator.shared.didReceive(payload: payload)
        }
    }
}
