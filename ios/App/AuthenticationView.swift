import SwiftUI
import OnBudgetCore

struct AuthenticationView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var form = false
    @State private var mode = "Sign in"
    private let modes = ["Sign in", "Create account", "Reset password"]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image("OwnerMark").resizable().scaledToFit().frame(width: 56, height: 56).accessibilityHidden(true)
                        Text("OnBudget").font(.largeTitle.bold()).foregroundStyle(Brand.blue)
                    }
                    Text("One household. One weekly allowance.").font(.headline)
                    SampleNotice()
                    Text("Explore the native app with invented data. Never enter real login details in this build.")
                }
                Section("Explore a sample household") {
                    Button("Continue as sample admin") { Task { await model.openSample(.admin) } }
                        .accessibilityIdentifier("sampleAdmin")
                    Button("Continue as sample member") { Task { await model.openSample(.member) } }
                        .accessibilityIdentifier("sampleMember")
                }.disabled(model.loading || model.opening || model.closing)
                if model.opening || model.closing { ProgressView(model.closing ? "Clearing sample session…" : "Opening sample household…") }
                Section {
                    Toggle("Preview authentication forms", isOn: $form)
                    if form {
                        Picker("Action", selection: $mode) { ForEach(modes, id: \.self) { Text($0) } }
                        TextField("Sample email only", text: $email).textContentType(.emailAddress)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if mode != "Reset password" {
                            SecureField("Sample password only", text: $password)
                        }
                        Button("Preview \(mode.lowercased())") {
                            defer { password = "" }
                            do {
                                _ = try Credentials(email: email, password: mode == "Reset password" ? "sample-only" : password)
                                model.notify("Form validated locally. Authentication is disconnected; use a sample household.")
                            } catch { model.notify(error.localizedDescription) }
                        }
                    }
                } footer: { Text("No authentication request is sent. Native recovery links and secure sessions require an approved staging adapter.") }
                Section("Household onboarding preview") {
                    Text("An admin creates a household; the second person joins with a private invitation code. Both can read the audit log.")
                    Text("Create and join interfaces are available in sample settings.")
                }
            }.navigationTitle("Welcome")
        }
    }
}
