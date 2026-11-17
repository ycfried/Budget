import Foundation

/// Pure push-notification helpers (no UserNotifications import — the
/// kit is Foundation-only; the permission prompt and the delegate live
/// in the app target).

/// The screen a notification tap opens, from the APNs payload's
/// `data.screen` field.
public enum NotificationScreen: String {
    /// Home (week closed, new week, over budget, budget increased).
    case week
    /// Transactions (new purchase / income / charity, large purchase).
    case purchases
    /// Funds (fund request waiting).
    case money
    /// Settings (member joined/left, Gmail expiring, bank broken).
    case settings
    /// Monthly statement (no viewer yet — lands on Home for now).
    case statement
}

/// A parsed APNs payload: the screen to open and the household it
/// belongs to. The tap is dropped when the household does not match
/// the signed-in user's household.
public struct NotificationPayload {
    public let screen: NotificationScreen
    public let householdId: UUID?

    /// Parses `userInfo` from a UNNotification (`data` is the custom
    /// payload dictionary push-notify sends alongside `aps`).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let data = userInfo["data"] as? [String: Any],
              let screenRaw = data["screen"] as? String,
              let screen = NotificationScreen(rawValue: screenRaw) else {
            return nil
        }
        self.screen = screen
        if let householdRaw = data["household_id"] as? String {
            self.householdId = UUID(uuidString: householdRaw)
        } else {
            self.householdId = nil
        }
    }
}

public enum PushNotifications {
    /// UserDefaults flag: the permission prompt has been shown once.
    /// A decline is respected forever — never re-prompted.
    public static let permissionAskedKey = "onbudget.pushPermissionAsked"

    /// APNs device tokens are raw bytes; the server stores the
    /// lowercase hex string.
    public static func deviceTokenHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
