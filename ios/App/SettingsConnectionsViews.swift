import SwiftUI
import OnBudgetCore

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    private let integrations = UnconnectedIntegrations()
    var body: some View {
        List {
            Section { SnapshotNotice(); Text("No account can be linked in this build.").font(.caption) }
            Section("Source health") { ForEach(model.snapshot?.sources ?? []) { FreshnessView(source: $0) } }
            Section("Bank · native Link interface") {
                Text("Transactions only. No payments or transfers. Account masks are hints, not guaranteed additional-cardholder attribution.").font(.caption)
                if model.isAdmin {
                    Button("Preview bank connect") { unavailable { try await integrations.beginLink() } }
                    Button("Preview bank disconnect", role: .destructive) { unavailable { try await integrations.disconnect() } }
                    Button("Preview bank sync") { Task { await model.submit(.bankSync) } }.disabled(!model.canWrite)
                } else { Text("Bank management is admin only.") }
            }
            Section("Email") {
                Text("Native Gmail connection is deferred until verification, per the owner handoff. The interface is prepared, but no consent or mailbox request is possible.").font(.caption)
                // Deliberately no Gmail connect action. Preserve the later owner decision.
            }
        }.navigationTitle("Connections")
    }
    private func unavailable(_ operation: @escaping @Sendable () async throws -> Void) {
        Task { do { try await operation() } catch { model.notify(error.localizedDescription) } }
    }
}
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: EditorMode?
    @State private var householdName = ""
    @State private var sampleCode = ""
    @State private var delete = false
    @State private var password = ""
    var body: some View {
        @Bindable var model = model
        List {
            Section { SnapshotNotice(); LabeledContent("Role", value: model.session?.role.rawValue ?? "Signed out") }
            Section("Preview scenarios") {
                Picker("Scenario", selection: $model.scenario) {
                    ForEach(SampleScenario.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.onChange(of: model.scenario) { _, _ in Task { await model.refresh() } }
                Text("Offline/read errors retain last-known data. Lost-response mode saves once, then supports a safe retry.").font(.caption)
            }
            if model.isAdmin {
                Section("Budget settings") {
                    Button("Change allowance") { editor = .allowance }
                    Button("Add temporary increase") { editor = .temporary }
                }.disabled(!model.canWrite)
            }
            Section("Household interface preview") {
                TextField("Sample household name", text: $householdName)
                Button("Preview create household") { model.notify("Create-household interface only. Already in a sample household; no server request sent.") }
                TextField("Sample invitation code (not a real code)", text: $sampleCode)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Preview join household") {
                    model.notify("Join interface only. Reusable codes and server throttling will be preserved; no code is sent.")
                    sampleCode = ""
                }
                Text("Invitations remain reusable and non-expiring. Real invites will come from the server and are not stored in this preview.").font(.caption)
            }
            Section("Account interface preview") {
                SecureField("Sample new password only", text: $password)
                Button("Preview password change") {
                    model.notify(password.count >= 8 ? "Valid sample length. No password was saved." : "Use at least eight characters.")
                    password = ""
                }
                Button("Clear sample account", role: .destructive) { delete = true }
                Button("Sign out of sample") { Task { await model.signOut() } }
            }
            Section("Sample action receipts") {
                if model.sampleActions.isEmpty { Text("No actions recorded this session.") }
                ForEach(Array(model.sampleActions.enumerated()), id: \.offset) { Text($0.element) }
            }
            Section("Audit · visible to both roles") {
                ForEach(model.snapshot?.audit ?? []) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.action).font(.headline)
                        Text(event.actor).font(.caption.bold())
                        Text(event.detail).font(.caption)
                        Text(event.date, format: .dateTime.month().day().hour().minute()).font(.caption)
                    }
                }
            }
            Section("Privacy & support") {
                Text("All data is invented. This build has no network transport, analytics, account credentials, or payment capability. Sample form input stays in memory.")
                Text("Privacy policy, support URL, legal review, signing and real-device testing remain release requirements.").font(.caption)
            }
        }.navigationTitle("Settings & audit")
            .sheet(item: $editor) { ActionEditor(mode: $0) }
            .confirmationDialog("Clear the sample session and widget cache? No real account will be deleted.", isPresented: $delete, titleVisibility: .visible) {
                Button("Clear sample", role: .destructive) { Task { await model.signOut() } }
            }
    }
}
