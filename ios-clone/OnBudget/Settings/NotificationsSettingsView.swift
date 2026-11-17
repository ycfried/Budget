import SwiftUI
import UserNotifications
import OnBudgetKit

// MARK: - Notifications (Nov 16, 2026)
//
// A Notifications card in Settings (after Profile): the system state
// row (On/Off + an "Open Settings" button when off) and one toggle
// per notification type, persisted per user in
// `notification_preferences` via `set_notification_preferences`.
// A decline is respected forever — the card never re-prompts; the
// only way back is the "Open Settings" button. A failed save reverts
// the toggle and shows a plain-language error (never raw server text).

final class NotificationsSettingsViewModel: ObservableObject {
    @Published var preferences = NotificationPreferences.allOn
    @Published var isLoading = true
    @Published var loadError: String?
    @Published var systemStatus: String = "Not Set"
    @Published var systemIsOn = false

    private let context: SettingsContext
    private let toast: ToastState

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        self.toast = toast
    }

    @MainActor
    func load() async {
        isLoading = true
        loadError = nil
        // System state (this device).
        let status = await PushNotificationCoordinator.shared.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            systemStatus = "On"
            systemIsOn = true
        case .denied:
            systemStatus = "Off"
            systemIsOn = false
        case .notDetermined:
            systemStatus = "Not Set"
            systemIsOn = false
        @unknown default:
            systemStatus = "Off"
            systemIsOn = false
        }
        // Per-user toggles.
        guard let userId = context.currentUserId else {
            loadError = "Could not load notification settings. Try again."
            isLoading = false
            return
        }
        do {
            if let saved = try await context.client.postgrest.notificationPreferences(
                householdId: context.householdId, userId: userId
            ) {
                preferences = saved
            }
            isLoading = false
        } catch {
            loadError = "Could not load notification settings. Try again."
            isLoading = false
        }
    }

    /// Save the toggles after a change. On failure the toggle reverts
    /// and a plain-language error shows — the UI never lies.
    @MainActor
    func save(_ newPreferences: NotificationPreferences, previous: NotificationPreferences) async {
        preferences = newPreferences
        do {
            preferences = try await context.client.rpcs.setNotificationPreferences(
                pHouseholdId: context.householdId, preferences: newPreferences
            )
        } catch {
            preferences = previous
            toast.show("Could not save notification settings. Try again.", kind: .error)
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct NotificationsSettingsView: View {
    @StateObject private var viewModel: NotificationsSettingsViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: NotificationsSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Notifications") {
            VStack(alignment: .leading, spacing: 12) {
                // System state row (this device).
                HStack {
                    Text("Notifications")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    Spacer()
                    Text(viewModel.systemStatus)
                        .font(.system(size: 15))
                        .foregroundStyle(viewModel.systemIsOn ? DesignTokens.ink : Color(hex: "#6b7280"))
                    if !viewModel.systemIsOn {
                        Button("Open Settings") {
                            viewModel.openSystemSettings()
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                    }
                }
                Text("Get a heads-up when a week closes or a new purchase comes in.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Divider()
                if viewModel.isLoading {
                    Text("Loading notification settings…")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                } else if let error = viewModel.loadError {
                    FundsErrorBox(error)
                    FundsSmallTertiaryButton("Try Again") {
                        Task { await viewModel.load() }
                    }
                } else {
                    // One toggle per trigger type, in Settings order.
                    // Each toggle saves on change and reverts on failure.
                    ForEach(NotificationPreferences.toggles.indices, id: \.self) { index in
                        let toggle = NotificationPreferences.toggles[index]
                        Toggle(isOn: Binding(
                            get: { viewModel.preferences[keyPath: toggle.keyPath] },
                            set: { newValue in
                                let previous = viewModel.preferences
                                var updated = viewModel.preferences
                                updated[keyPath: toggle.keyPath] = newValue
                                Task { await viewModel.save(updated, previous: previous) }
                            }
                        )) {
                            Text(toggle.label)
                                .font(.system(size: 15))
                                .foregroundStyle(DesignTokens.ink)
                        }
                        .tint(DesignTokens.primary)
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.notifications")
        .task { await viewModel.load() }
    }
}
