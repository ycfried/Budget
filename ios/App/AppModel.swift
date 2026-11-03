import SwiftUI
import OnBudgetCore
import WidgetKit

typealias AppModel = HouseholdStore

/// Shared entitlement is optional until the owner approves Apple capabilities.
/// Without a configured App Group, widgets intentionally show no household data.
enum WidgetCache {
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "OnBudgetAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
    }
    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: "displaySnapshot")
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func clear() {
        defaults?.removeObject(forKey: "displaySnapshot")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
