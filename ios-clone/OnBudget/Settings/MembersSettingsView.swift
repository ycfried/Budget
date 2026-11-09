// OnBudget — Settings: Account & Household card (live web v66, §10.5).
//
// Members list, invite code inline, Delete Account (two-step).
//
// Wiring (exact API calls):
// - Members: RPC `list_household_members()` — no full email, only
//   `email_prefix` as the name fallback. Display-name resolution:
//   stored display_name -> own auth-metadata name -> email_prefix ->
//   "Household member" (never the bare word "Member").
// - Remove: RPC `remove_household_member(p_user_id:)` after one
//   confirm. Server re-checks: admin-only, own household only, never
//   yourself, never the last admin. Admin sees Remove on every OTHER
//   member's row; never on their own row; members see no Remove.
// - Invite code: `PostgrestClient.inviteCode(householdId:)` (the
//   `households.invite_code` column — NEVER the household UUID).
//   Copy writes the clipboard and flips to "Copied" for 2s; Share
//   uses the native share sheet with
//   "Join my household on OnBudget with invite code CODE".
// - Delete Account: two-step confirm, then
//   `EdgeFunctionsClient.deleteAccount()` (no household id — the
//   function derives it from the caller). On failure the server
//   restores the membership first; the alert names the failing step.
//   On success: push-token unregister best-effort, then
//   `SupabaseClient.signOut()` (clears the session), then
//   `context.onAccountDeleted("Your account was deleted.")`.
//
// Join rate limit (5 failed attempts/hour, N13): the join form itself
// lives on the Household screen (Auth agent). A refused join surfaces
// `OnBudgetError.rateLimited` whose `userMessage` is the server text
// verbatim ("too many failed join attempts, try again later") —
// Settings never rewrites it.

import SwiftUI
import UIKit
import OnBudgetKit

@MainActor
final class MembersSettingsViewModel: ObservableObject {
    @Published var members: [MemberListRow] = []
    @Published var inviteCode: String?
    @Published var householdName: String?
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var memberToRemove: MemberListRow?
    @Published var removeFailed = false
    @Published var copiedCode = false
    @Published var showShareSheet = false
    @Published var deleteStep: DeleteStep?
    @Published var deleteFailed = false
    @Published var deleteFailedStep: String?

    enum DeleteStep: Identifiable {
        case confirmDelete
        case confirmEverything

        var id: String {
            switch self {
            case .confirmDelete: return "confirmDelete"
            case .confirmEverything: return "confirmEverything"
            }
        }
    }

    private let context: SettingsContext
    private let toast: ToastState

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        self.toast = toast
        self.householdName = context.householdName
    }

    var isAdmin: Bool { context.isAdmin }

    func displayName(for member: MemberListRow) -> String {
        let isOwnRow = member.userId == context.currentUserId
        return member.displayName(
            fallbackOwnMetadataName: context.displayName,
            isOwnRow: isOwnRow
        )
    }

    func isOwnRow(_ member: MemberListRow) -> Bool {
        member.userId == context.currentUserId
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let membersTask = context.client.rpcs.listHouseholdMembers()
            async let codeTask = context.client.postgrest.inviteCode(householdId: context.householdId)
            async let nameTask = context.client.postgrest.householdName(householdId: context.householdId)
            members = try await membersTask
            if context.isAdmin {
                inviteCode = try await codeTask
            }
            householdName = try await nameTask ?? householdName
            loadError = nil
        } catch {
            loadError = settingsErrorMessage(error)
        }
    }

    // MARK: - Remove member

    func confirmRemove(_ member: MemberListRow) {
        memberToRemove = member
    }

    func removeConfirmed() async {
        guard let member = memberToRemove else { return }
        memberToRemove = nil
        let label = displayName(for: member)
        do {
            try await context.client.rpcs.removeHouseholdMember(pUserId: member.userId)
            toast.show("\(label) was removed from the household.")
            await load()
        } catch {
            removeFailed = true
        }
    }

    // MARK: - Invite code

    func copyInviteCode() {
        guard let code = inviteCode else { return }
        UIPasteboard.general.string = code
        copiedCode = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedCode = false
        }
    }

    var shareText: String {
        guard let code = inviteCode else { return "" }
        return "Join my household on OnBudget with invite code \(code)"
    }

    // MARK: - Delete Account (two-step)

    func startDelete() {
        deleteStep = .confirmDelete
    }

    func confirmDeleteStepOne() {
        deleteStep = .confirmEverything
    }

    func confirmDeleteStepTwo() async {
        deleteStep = nil
        do {
            let result = try await context.client.functions.deleteAccount()
            guard result.deleted else {
                deleteFailedStep = result.step
                deleteFailed = true
                return
            }
            // Push-token unregister, best-effort: never blocks the
            // sign-out, and a missing token store is not a failure.
            if let unregister = context.unregisterPushToken {
                await unregister()
            }
            await context.client.signOut()
            context.onAccountDeleted("Your account was deleted.")
        } catch {
            // The server restores the membership first on failure —
            // nothing was deleted. The user stays signed in.
            if let budgetError = error as? OnBudgetError,
               case .serverError(_, let message) = budgetError {
                deleteFailedStep = message
            } else {
                deleteFailedStep = nil
            }
            deleteFailed = true
        }
    }
}

struct MembersSettingsView: View {
    @StateObject private var viewModel: MembersSettingsViewModel
    private let context: SettingsContext

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        _viewModel = StateObject(wrappedValue: MembersSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Account & Household") {
            Text("Only the admin can share the invite code.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            if let name = viewModel.householdName, !name.isEmpty {
                Text("Household: \(name)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Text("Members")
                .font(.headline)
                .padding(.top, 4)
            if viewModel.isLoading && viewModel.members.isEmpty {
                ProgressView()
            } else if let error = viewModel.loadError, viewModel.members.isEmpty {
                ErrorBox(message: error)
            } else if viewModel.members.isEmpty {
                MutedLine(text: "No members yet.")
            } else {
                ForEach(viewModel.members) { member in
                    memberRow(member)
                }
            }

            if viewModel.isAdmin {
                inviteCodeSection
            }

            deleteAccountSection
        }
        .task { await viewModel.load() }
        .alert(item: $viewModel.memberToRemove) { member in
            let label = viewModel.displayName(for: member)
            return Alert(
                title: Text("Remove Member"),
                message: Text("Remove \(label) from the household? They will lose access to the household's data."),
                primaryButton: .destructive(Text("Remove")) {
                    Task { await viewModel.removeConfirmed() }
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Could not remove member", isPresented: $viewModel.removeFailed) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("Could not remove this member. Try again.")
        }
        .alert(item: $viewModel.deleteStep) { step in
            switch step {
            case .confirmDelete:
                return Alert(
                    title: Text("Delete Account"),
                    message: Text("Delete your account and remove yourself from this household? If you are the last member, the household is deleted too. This cannot be undone."),
                    primaryButton: .destructive(Text("Delete Account")) {
                        viewModel.confirmDeleteStepOne()
                    },
                    secondaryButton: .cancel()
                )
            case .confirmEverything:
                return Alert(
                    title: Text("Delete Everything?"),
                    message: Text("This permanently deletes your account and, if you are the last member, the whole household. Are you sure?"),
                    primaryButton: .destructive(Text("Yes, Delete Everything")) {
                        Task { await viewModel.confirmDeleteStepTwo() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .alert(
            "Could not delete account",
            isPresented: $viewModel.deleteFailed
        ) {
            Button("Close", role: .cancel) {
                viewModel.deleteFailed = false
                viewModel.deleteFailedStep = nil
            }
        } message: {
            if let step = viewModel.deleteFailedStep, !step.isEmpty {
                Text("Could not delete your account. Nothing was deleted — try again. (step: \(step))")
            } else {
                Text("Could not delete your account. Nothing was deleted — try again.")
            }
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            ShareSheet(text: viewModel.shareText)
        }
    }

    private func memberRow(_ member: MemberListRow) -> some View {
        HStack(spacing: 8) {
            Text(viewModel.displayName(for: member) + (viewModel.isOwnRow(member) ? " (you)" : ""))
                .font(.subheadline)
                .fontWeight(.semibold)
            RolePill(role: member.role)
            Spacer()
            if viewModel.isAdmin && !viewModel.isOwnRow(member) {
                Button("Remove") {
                    viewModel.confirmRemove(member)
                }
                .buttonStyle(SmallDangerButtonStyle())
                .accessibilityLabel("Remove \(viewModel.displayName(for: member)) from the household")
            }
        }
    }

    @ViewBuilder
    private var inviteCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Members join with the invite code below.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            if let code = viewModel.inviteCode, !code.isEmpty {
                Text(code)
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#eef4ff"))
                    .cornerRadius(12)
                HStack(spacing: 12) {
                    Button(viewModel.copiedCode ? "Copied" : "Copy") {
                        viewModel.copyInviteCode()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Share") {
                        viewModel.showShareSheet = true
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
            } else {
                MutedLine(text: "No invite code is set up for this household yet.")
            }
        }
        .padding(.top, 4)
    }

    private var deleteAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete Account")
                .font(.headline)
                .padding(.top, 8)
            Text("Deleting removes you from this household. If you are the last member, the household is deleted too. This cannot be undone.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            Button("Delete Account") {
                viewModel.startDelete()
            }
            .buttonStyle(DangerButtonStyle())
            Text("Privacy · Terms")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.mid)
                .padding(.top, 4)
        }
    }
}
