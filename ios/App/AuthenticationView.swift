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
                Section("Existing household connection") {
                    NavigationLink("Read-only connection preparation") { NativeReadPreparationView() }
                    Text("Live access remains locked pending approval. No real credentials are requested here.")
                        .font(.caption)
                }
                Section("Household onboarding preview") {
                    Text("An admin creates a household; the second person joins with a private invitation code. Both can read the audit log.")
                    Text("Create and join interfaces are available in sample settings.")
                }
            }.navigationTitle("Welcome")
        }
    }
}


/// Independent composition: real reads can never flow into the writable sample store.
struct NativeReadPreparationView: View {
    @State private var connection = NativeReadStore()
    @State private var email = ""
    @State private var password = ""
    @State private var relation: ReadRelation = .transactions
    var body: some View {
        Form {
            Section("Connection status") {
                Label(connection.configured ? "Read-only adapter prepared" : "Live connection locked", systemImage: "lock.shield")
                Text("First live connection requires approval of the endpoint and permission plan. This build has no configured destination or enabled network executor.")
                Text("Financial writes, bank sync, Gmail, account deletion and week close are unavailable.")
            }
            if connection.configured && !connection.signedIn {
                Section("Sign in to your household") {
                    TextField("Email", text: $email).textContentType(.username)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    Button("Restore saved session") { Task { await connection.restoreSession() } }.disabled(connection.loading)
                    Button("Sign in") {
                        let input = password; password = ""
                        Task { await connection.signIn(email: email, password: input) }
                    }.disabled(connection.loading)
                }
            }
            if connection.signedIn {
                Section("Household membership") {
                    if connection.memberships.isEmpty { Text("No household membership was returned. Creating or joining is unavailable in read-only mode.") }
                    ForEach(connection.memberships, id: \.householdID) { membership in
                        Button("\(membership.displayName ?? "Household member") · \(membership.role)") {
                            connection.select(membership.householdID)
                        }.disabled(connection.loading || membership.knownRole == nil)
                    }
                }
                if connection.selectedHousehold != nil {
                    Section("Server weekly summary") {
                        Button("Read weekly summary") { Task { await connection.loadWeek() } }.disabled(connection.loading)
                        if let week = connection.week {
                            Text("Available: \(amount(week.availableCents))")
                            Text("Incoming debt: \(amount(week.carriedDebtCents))")
                            Text("Current outgoing debt is not supplied by this endpoint.").font(.caption)
                        }
                    }
                    Section("Read-only records") {
                        Picker("Record collection", selection: $relation) {
                            ForEach(ReadRelation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.disabled(connection.loading)
                        Button("Read records") { Task { await connection.load(relation) } }.disabled(connection.loading)
                        if let page = connection.page {
                            Text("\(page.rows.count) records on this page · \(page.total) reported total")
                            Text("Separate reads are not a consistent financial snapshot. No ledger totals are calculated on this device.").font(.caption)
                            ForEach(Array(page.rows.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading) {
                                    Text(label(row))
                                    if case .value(.integer(let cents)) = row.field("amount_cents") {
                                        Text(Money(cents: cents).formatted).monospacedDigit()
                                    }
                                    if case .value(.string(let date)) = row.field("date") { Text(date).font(.caption) }
                                }.accessibilityElement(children: .combine)
                            }
                            if page.nextOffset != nil {
                                Text("Additional pages are outside the approved first validation window.").font(.caption)
                            }
                        }
                    }.onChange(of: relation) { _, _ in connection.clearDisplayedPage() }
                }
                Button("Clear local session") { password = ""; Task { await connection.signOut() } }
            }
            if connection.loading { ProgressView("Reading…") }
            if let error = connection.error { Text(error).accessibilityIdentifier("connectionError") }
        }.navigationTitle("Read-only connection")
            .onDisappear { password = "" }
            .scrollDismissesKeyboard(.interactively)
    }
    private func amount(_ field: APIField<Int64>) -> String {
        switch field {
        case .missing: "Not supplied"
        case .null: "Not available"
        case .value(let value): Money(cents: value).formatted
        }
    }
    private func label(_ row: APIRecord) -> String {
        for key in ["merchant", "action", "institution_name", "name", "kind", "week_start"] {
            if case .value(.string(let value)) = row.field(key) { return value }
        }
        return "Server record"
    }
}
