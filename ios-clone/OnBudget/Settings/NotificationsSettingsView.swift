import SwiftUI
import UserNotifications
import OnBudgetKit

// MARK: - Notifications (Nov 16, 2026)
//
// A Notifications card in Settings (after Profile): an "Open
// Settings" button when this device has notifications off, a master
// "All Notifications" on/off, and one toggle per notification type,
// persisted per user in `notification_preferences` via
// `set_notification_preferences`. When the master is off the
// per-type toggles do not appear at all (never greyed out). A decline
// is respected forever — the card never re-prompts; the only way back
// is the "Open Settings" button. A failed save reverts the toggle and
// shows a plain-language error (never raw server text).
// Build 43 (owner, Nov 17, 2026): the "On"/"Off" system-status text
// is gone (the master toggle already shows the state); the 15
// per-type toggles are grouped into collapsible categories below.

final class NotificationsSettingsViewModel: ObservableObject {
    @Published var preferences = NotificationPreferences.allOn
    @Published var isLoading = true
    @Published var loadError: String?
    // Build 43 (owner, Nov 17, 2026): the "On"/"Off" system-status
    // text is gone — the master toggle already shows the state — so
    // the `systemStatus` string is gone too. `systemIsOn` stays: it
    // decides whether the "Open Settings" button shows, which is the
    // only way back after a decline.
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
        // System state (this device) — only whether it is on matters
        // now (Build 43: the status text is gone).
        let status = await PushNotificationCoordinator.shared.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            systemIsOn = true
        case .denied:
            systemIsOn = false
        case .notDetermined:
            systemIsOn = false
        @unknown default:
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
    /// Build 68 (item 14): the notifications explainer behind ⓘ.
    @State private var showingAboutInfo = false

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: NotificationsSettingsViewModel(context: context, toast: toast))
    }

    // Build 43 (owner, Nov 17, 2026): the 15 per-type toggles are
    // grouped into collapsible categories instead of one flat list.
    // The labels and key paths mirror
    // `NotificationPreferences.toggles` exactly — same 15 toggles,
    // same bindings, only the presentation is regrouped. All
    // categories start collapsed; tapping a header expands or
    // collapses it instantly (standing rule: no animation).
    private struct NotificationCategory {
        let title: String
        let toggles: [(label: String, keyPath: WritableKeyPath<NotificationPreferences, Bool>)]
    }

    private static let categories: [NotificationCategory] = [
        NotificationCategory(title: "Budget & Weeks", toggles: [
            ("Week Closed", \.weekClosed),
            ("New Week", \.newWeek),
            ("Over Budget", \.overBudget),
            ("Budget Increased", \.budgetIncreased),
        ]),
        NotificationCategory(title: "Money", toggles: [
            ("New Purchase", \.newPurchase),
            ("New Income", \.newIncome),
            ("Charity Gift", \.newCharity),
            ("Large Purchase", \.largePurchase),
        ]),
        NotificationCategory(title: "Members", toggles: [
            ("Member Joined", \.memberJoined),
            ("Member Left", \.memberLeft),
        ]),
        NotificationCategory(title: "Connections", toggles: [
            ("Gmail Connection Expiring", \.gmailExpiring),
            ("Bank Connection Broken", \.bankBroken),
        ]),
        NotificationCategory(title: "Review", toggles: [
            ("Fund Request Waiting", \.fundRequest),
            ("Needs Review", \.needsReview),
            ("Monthly Statement", \.monthlyStatement),
        ]),
    ]

    @State private var expandedCategories: Set<String> = []

    private func toggleCategory(_ title: String) {
        // Instant, no animation (standing rule).
        if expandedCategories.contains(title) {
            expandedCategories.remove(title)
        } else {
            expandedCategories.insert(title)
        }
    }

    /// One per-type toggle, with its existing save-on-change and
    /// revert-on-failure behavior — unchanged from the flat list.
    @ViewBuilder
    private func perTypeToggle(_ toggle: (label: String, keyPath: WritableKeyPath<NotificationPreferences, Bool>)) -> some View {
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

    var body: some View {
        SettingsCard(title: "Notifications") {
            VStack(alignment: .leading, spacing: 12) {
                // Build 43 (owner, Nov 17, 2026): the "On" text at
                // the top right is gone — redundant, the "All
                // Notifications" toggle below already shows the
                // state. Only the "Open Settings" button remains,
                // when this device has notifications off.
                HStack {
                    Text("Notifications")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    // Build 68 (item 14): the explainer lives behind
                    // this blue ⓘ, not as an inline line under the
                    // heading.
                    Button { showingAboutInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Notifications")
                    Spacer()
                    if !viewModel.systemIsOn {
                        Button("Open Settings") {
                            viewModel.openSystemSettings()
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                    }
                }
                .alert("Notifications", isPresented: $showingAboutInfo) {
                    Button("OK") {}
                } message: {
                    Text("Get a heads-up when a week closes or a new purchase comes in.")
                }
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
                    // Master on/off (Nov 16, ~11:56 PM): off means the
                    // server sends this user nothing, whatever the
                    // per-type toggles say.
                    Toggle(isOn: Binding(
                        get: { viewModel.preferences.notificationsEnabled },
                        set: { newValue in
                            let previous = viewModel.preferences
                            var updated = viewModel.preferences
                            updated.notificationsEnabled = newValue
                            Task { await viewModel.save(updated, previous: previous) }
                        }
                    )) {
                        Text("All Notifications")
                            .font(.system(size: 15))
                            .foregroundStyle(DesignTokens.ink)
                    }
                    .tint(DesignTokens.primary)
                    // Per-type toggles appear only while the master is
                    // on — when it is off they are meaningless, and the
                    // standing rule is that an action the user cannot
                    // perform must NOT appear (never a greyed-out row).
                    if viewModel.preferences.notificationsEnabled {
                        // Build 43 (owner, Nov 17, 2026): the
                        // per-type toggles grouped into collapsible
                        // categories. The master toggle above stays
                        // outside the categories, unchanged.
                        ForEach(Array(Self.categories.enumerated()), id: \.element.title) { index, category in
                            VStack(alignment: .leading, spacing: 0) {
                                // Whole header row is the toggle;
                                // the chevron is only a hint.
                                Button {
                                    toggleCategory(category.title)
                                } label: {
                                    HStack {
                                        Text(category.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(DesignTokens.ink)
                                        Spacer()
                                        Text("⌄")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(DesignTokens.primary)
                                            .rotationEffect(.degrees(expandedCategories.contains(category.title) ? 180 : 0))
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(category.title), \(expandedCategories.contains(category.title) ? "expanded" : "collapsed")")
                                if expandedCategories.contains(category.title) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(category.toggles, id: \.label) { toggle in
                                            perTypeToggle(toggle)
                                        }
                                    }
                                    .padding(.leading, 12)
                                    .padding(.top, 4)
                                }
                            }
                            if index < Self.categories.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.notifications")
        .task { await viewModel.load() }
    }
}
