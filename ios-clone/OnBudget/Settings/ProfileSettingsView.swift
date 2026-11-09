// OnBudget — Settings: Profile card (live web v66, §10.1).
//
// Display name + email; Save Name + Save Email BOTH primary blue;
// Change Password grey tertiary. Sign-out. Delete Account lives in
// the Account & Household card (MembersSettingsView) per the web,
// where it sits under the members list.
//
// Wiring (exact API calls):
// - Save Name: `SupabaseClient.updateDisplayName(_:)` — auth metadata
//   only (`full_name`), no SQL, no new column.
// - Save Email: `SupabaseClient.updateEmail(_:)` — the sign-in email
//   does NOT change until the new address is confirmed.
// - Change Password: `SupabaseClient.changePassword(_:)` (min 8 chars,
//   checked before the call).
// - Sign Out: `SupabaseClient.signOut()` then `context.onSignOut()`.
// - Delete Account: see MembersSettingsView (two-step confirm,
//   `EdgeFunctionsClient.deleteAccount()`, push-token unregister
//   best-effort, then sign-out + "Your account was deleted.").

import SwiftUI
import OnBudgetKit

@MainActor
final class ProfileSettingsViewModel: ObservableObject {
    @Published var name: String
    @Published var email: String
    @Published var isSavingName = false
    @Published var isSavingEmail = false
    @Published var isSigningOut = false
    @Published var showChangePassword = false
    @Published var newPassword = ""
    @Published var showNewPassword = false
    @Published var passwordAlert: PasswordAlert?

    enum PasswordAlert: Identifiable {
        case tooShort
        case changed
        case failed

        var id: String {
            switch self {
            case .tooShort: return "tooShort"
            case .changed: return "changed"
            case .failed: return "failed"
            }
        }
    }

    private let context: SettingsContext
    private let toast: ToastState

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        self.toast = toast
        self.name = context.displayName ?? ""
        self.email = context.email ?? ""
    }

    // MARK: - Save Name

    func saveName() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast.showError("Enter a name to save.")
            return
        }
        guard !isSavingName else { return }
        isSavingName = true
        defer { isSavingName = false }
        do {
            _ = try await context.client.updateDisplayName(trimmed)
            name = trimmed
            toast.show("Name saved — it now shows in your profile.")
        } catch {
            toast.showError("Could not save your name. Try again.")
        }
    }

    // MARK: - Save Email

    func saveEmail() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MoneyFormat.isValidEmail(trimmed) else {
            toast.showError("Enter a valid email address.")
            return
        }
        if let current = context.email, trimmed == current {
            toast.show("That is already your sign-in email.")
            return
        }
        guard !isSavingEmail else { return }
        isSavingEmail = true
        defer { isSavingEmail = false }
        do {
            _ = try await context.client.updateEmail(trimmed)
            toast.show("Confirmation sent to \(trimmed) — your sign-in email stays as it is until you confirm it.")
        } catch {
            toast.showError("Could not change your email. Try again.")
        }
    }

    // MARK: - Change Password

    func submitNewPassword() async {
        guard newPassword.count >= 8 else {
            passwordAlert = .tooShort
            return
        }
        do {
            try await context.client.changePassword(newPassword)
            newPassword = ""
            showChangePassword = false
            passwordAlert = .changed
        } catch {
            passwordAlert = .failed
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        // Best-effort push-token unregister (APNS_DESIGN §3): a
        // failure here must never block signing out.
        if let unregister = context.unregisterPushToken {
            await unregister()
        }
        await context.client.signOut()
        isSigningOut = false
        context.onSignOut()
    }
}

struct ProfileSettingsView: View {
    @StateObject private var viewModel: ProfileSettingsViewModel

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: ProfileSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Profile") {
            LabeledField(label: "Name", text: $viewModel.name, placeholder: "Your name", autocapitalization: .words)
            Button(viewModel.isSavingName ? "Saving…" : "Save Name") {
                Task { await viewModel.saveName() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isSavingName)

            LabeledField(label: "Email", text: $viewModel.email, placeholder: "you@example.com", keyboardType: .emailAddress, autocapitalization: .never)
            Button(viewModel.isSavingEmail ? "Saving…" : "Save Email") {
                Task { await viewModel.saveEmail() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isSavingEmail)

            Text("Password")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.ink)
                .padding(.top, 4)
            Button("Change Password") {
                viewModel.showChangePassword = true
            }
            .buttonStyle(TertiaryButtonStyle())

            Button(viewModel.isSigningOut ? "Signing Out…" : "Sign Out") {
                Task { await viewModel.signOut() }
            }
            .buttonStyle(TertiaryButtonStyle())
            .disabled(viewModel.isSigningOut)
            .padding(.top, 4)
        }
        .sheet(isPresented: $viewModel.showChangePassword) {
            changePasswordSheet
        }
        .alert(item: $viewModel.passwordAlert) { alert in
            switch alert {
            case .tooShort:
                return Alert(
                    title: Text("Password too short"),
                    message: Text("Enter a password of at least 8 characters."),
                    dismissButton: .default(Text("Close"))
                )
            case .changed:
                return Alert(
                    title: Text("Password changed"),
                    message: Text("Your password is updated."),
                    dismissButton: .default(Text("Close"))
                )
            case .failed:
                return Alert(
                    title: Text("Could not change password"),
                    message: Text("Could not change your password. Try again."),
                    dismissButton: .default(Text("Close"))
                )
            }
        }
    }

    private var changePasswordSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enter a new password for this account. Password requirement: at least 8 characters.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                HStack {
                    Group {
                        if viewModel.showNewPassword {
                            TextField("New password", text: $viewModel.newPassword)
                        } else {
                            SecureField("New password", text: $viewModel.newPassword)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button(viewModel.showNewPassword ? "Hide" : "Show") {
                        viewModel.showNewPassword.toggle()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                HStack(spacing: 12) {
                    Button("Change Password") {
                        Task { await viewModel.submitNewPassword() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel") {
                        viewModel.newPassword = ""
                        viewModel.showChangePassword = false
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
