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
//   confirm. Server re-checks: OWNER-ONLY (roles decision, Nov 11,
//   2026 — the PR #57 "never the last admin" guard is gone: only the
//   owner removes members, and the owner is always admin-capable),
//   own household only, never yourself. The owner sees Remove on
//   every OTHER member's row; never on their own row; admins and
//   members see no Remove.
// - Roles: Owner (the household creator, `households.owner_id`),
//   Admin (co-admin), Member. Owner or admin can promote a member to
//   admin; only the owner can change an admin back to member; the
//   owner's role never changes. RPC `set_household_member_role`.
//   Each role shows its label + a short plain note of what it can do.
// - Invite code: `PostgrestClient.inviteCode(householdId:)` (the
//   `households.invite_code` column — NEVER the household UUID).
//   OWNER-ONLY: only the owner fetches or sees it (Nov 11, 2026).
//   A failed read shows an error line, never "No invite code is set
//   up" (owner report, Nov 11: the app said that while PJM2HG
//   existed).
//   Copy writes the clipboard and flips to "Copied" for 2s; Share
//   uses the native share sheet with
//   "Join my household on OnBudget with invite code CODE".
// - Delete Account: two-step confirm, then
//   `EdgeFunctionsClient.deleteAccount()` (no household id — the
//   function derives it from the caller). On failure the server
//   restores the membership first; the alert says so in plain
//   language and never names the server step (audit S-P1-3).
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
    @Published var ownerId: UUID?
    @Published var inviteCode: String?
    @Published var inviteCodeLoadFailed = false
    /// True once the invite-code fetch has resolved (success or
    /// failure). Until then the section shows a spinner — never the
    /// "No invite code is set up" line for an unknown state (audit
    /// S-P1-1: the line flashed on every load while the fetch was
    /// still in flight).
    @Published var inviteCodeLoaded = false
    @Published var householdName: String?
    @Published var loadError: String?
    /// True after a failed load until a load succeeds. The members
    /// section shows the error + Retry while this is set — never a
    /// false "No members yet." (audit S-P1-2: the dismissable error
    /// box used to clear the failure into the empty state).
    @Published var loadFailed = false
    @Published var isLoading = false
    @Published var memberToRemove: MemberListRow?
    @Published var removeFailed = false
    @Published var roleChangeRequest: RoleChangeRequest?
    @Published var roleChangeFailed = false
    @Published var copiedCode = false
    @Published var showShareSheet = false
    @Published var deleteStep: DeleteStep?
    @Published var deleteFailed = false

    /// A pending promote/demote, captured for the confirm alert.
    struct RoleChangeRequest: Identifiable {
        let member: MemberListRow
        let toRole: HouseholdRole
        var id: String { "\(member.userId.uuidString)-\(toRole.rawValue)" }
    }

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
    var isOwner: Bool { context.isOwner }

    /// The role to SHOW for a member: Owner when the member's id is
    /// the household's owner id, else the stored role. The server
    /// never returns 'owner' as a role value.
    func displayRole(for member: MemberListRow) -> HouseholdRole {
        if let ownerId, member.userId == ownerId { return .owner }
        return member.role
    }

    /// The promote/demote action available on another member's row, if
    /// any: a member can be made Admin (by the owner or an admin); an
    /// admin (other than the owner) can be changed back to Member, but
    /// ONLY by the owner. Nil for your own row and for the owner.
    func roleAction(for member: MemberListRow) -> (label: String, toRole: HouseholdRole)? {
        guard !isOwnRow(member), displayRole(for: member) != .owner else { return nil }
        if member.role == .member, isAdmin {
            return ("Make Admin", .admin)
        }
        if member.role == .admin, isOwner {
            return ("Make Member", .member)
        }
        return nil
    }

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
            async let ownerTask = context.client.postgrest.householdOwnerId(householdId: context.householdId)
            async let nameTask = context.client.postgrest.householdName(householdId: context.householdId)
            members = try await membersTask
            // Fail soft: if the owner column is not there yet (the
            // roles migration has not been applied), the list still
            // loads — owner-only controls simply stay hidden until
            // the next load after the migration lands.
            ownerId = try? await ownerTask
            householdName = try await nameTask ?? householdName
            loadError = nil
            loadFailed = false
        } catch {
            loadError = settingsErrorMessage(error)
            loadFailed = true
        }
        // The invite code is owner-only (owner decision, Nov 11,
        // 2026): only the owner fetches it. A failed read is
        // tracked separately — it must NOT fall through to the
        // "No invite code is set up" line (owner report, Nov 11:
        // the app said that while PJM2HG existed). The fetch runs
        // even when the members fetch failed, so a members error
        // never leaves the invite section showing a false "not set
        // up" line either (audit S-P1-1).
        inviteCodeLoaded = false
        inviteCodeLoadFailed = false
        if context.isOwner {
            do {
                inviteCode = try await context.client.postgrest.inviteCode(householdId: context.householdId)
            } catch {
                inviteCode = nil
                inviteCodeLoadFailed = true
            }
        } else {
            inviteCode = nil
        }
        inviteCodeLoaded = true
    }

    // MARK: - Change role (promote / demote)

    func confirmRoleChange(_ member: MemberListRow, to role: HouseholdRole) {
        roleChangeRequest = RoleChangeRequest(member: member, toRole: role)
    }

    /// The request arrives as a parameter, captured by the alert's
    /// button — the same `.alert(item:)` pitfall as removeConfirmed
    /// (the binding is nilled when the alert dismisses, before an
    /// unstructured Task runs).
    func roleChangeConfirmed(_ request: RoleChangeRequest) async {
        roleChangeRequest = nil
        let label = displayName(for: request.member)
        do {
            try await context.client.rpcs.setHouseholdMemberRole(pUserId: request.member.userId, pRole: request.toRole)
            toast.show(request.toRole == .admin
                       ? "\(label) is now an admin."
                       : "\(label) is now a regular member.", kind: .success)
            await load()
        } catch {
            roleChangeFailed = true
        }
    }

    // MARK: - Remove member

    func confirmRemove(_ member: MemberListRow) {
        memberToRemove = member
    }

    /// The member arrives as a parameter, captured by the alert's
    /// button: `.alert(item:)` nils the `memberToRemove` binding
    /// when the alert dismisses, which happens BEFORE an unstructured
    /// `Task` runs — so re-reading the binding here always found nil
    /// and the removal silently never happened (owner report, Nov 11,
    /// 2026: Remove on "Jack friedman" did nothing). The same pitfall
    /// is fixed the same way in confirmSave / disconnectConfirmed.
    func removeConfirmed(_ member: MemberListRow) async {
        memberToRemove = nil
        let label = displayName(for: member)
        do {
            try await context.client.rpcs.removeHouseholdMember(pUserId: member.userId)
            toast.show("\(label) was removed from the household.", kind: .success)
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
            // nothing was deleted. The user stays signed in. The
            // failure is reported in plain language only — never
            // the server's step or error text (audit S-P1-3).
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
            Text("Only the owner can share the invite code.")
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
            // A reload failure shows above the list even when stale
            // rows are already on screen — never a silent stale list.
            // The error + Retry stay until a load succeeds; the
            // empty "No members yet." line only shows when the load
            // actually returned empty (audit S-P1-2).
            if viewModel.loadFailed {
                ErrorBox(viewModel.loadError ?? "Could not load members.")
                Button("Retry") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(TertiaryButtonStyle())
            }
            if viewModel.isLoading && viewModel.members.isEmpty {
                ProgressView()
            } else if !viewModel.members.isEmpty {
                ForEach(viewModel.members) { member in
                    memberRow(member)
                }
                rolesLegend
            } else if !viewModel.loadFailed {
                MutedLine(text: "No members yet.")
            }

            if viewModel.isOwner {
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
                    Task { await viewModel.removeConfirmed(member) }
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Could Not Remove Member", isPresented: $viewModel.removeFailed) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("Could not remove this member. Try again.")
        }
        .alert(item: $viewModel.roleChangeRequest) { request in
            let label = viewModel.displayName(for: request.member)
            let role = request.toRole
            return Alert(
                title: Text(role == .admin ? "Make Admin" : "Make Member"),
                message: Text(role == .admin
                              ? "Make \(label) an admin? \(HouseholdRole.admin.capabilityNote)"
                              : "Change \(label) to a regular member? \(HouseholdRole.member.capabilityNote)"),
                primaryButton: .default(Text(role == .admin ? "Make Admin" : "Make Member")) {
                    Task { await viewModel.roleChangeConfirmed(request) }
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Could Not Change Role", isPresented: $viewModel.roleChangeFailed) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("Could not change this member's role. Try again.")
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
            "Could Not Delete Account",
            isPresented: $viewModel.deleteFailed
        ) {
            Button("Close", role: .cancel) {
                viewModel.deleteFailed = false
            }
        } message: {
            Text("Could not delete your account. Nothing was deleted — try again.")
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
            RolePill(role: viewModel.displayRole(for: member))
            Spacer()
            if let action = viewModel.roleAction(for: member) {
                Button(action.label) {
                    viewModel.confirmRoleChange(member, to: action.toRole)
                }
                .buttonStyle(TertiaryButtonStyle())
                .accessibilityLabel("\(action.label) \(viewModel.displayName(for: member))")
            }
            if viewModel.isOwner && !viewModel.isOwnRow(member) {
                Button("Remove") {
                    viewModel.confirmRemove(member)
                }
                .buttonStyle(SmallDangerButtonStyle())
                .accessibilityLabel("Remove \(viewModel.displayName(for: member)) from the household")
            }
        }
    }

    /// The role legend: each role with its short plain note of what it
    /// can do (owner decision, Nov 11, 2026).
    private var rolesLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([HouseholdRole.owner, .admin, .member], id: \.rawValue) { role in
                Text("\(role.label) — \(role.capabilityNote)")
                    .font(.caption)
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var inviteCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Members join with the invite code below.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            if !viewModel.inviteCodeLoaded {
                ProgressView()
            } else if viewModel.inviteCodeLoadFailed {
                ErrorBox("Could not load the invite code. Try again.")
            } else if let code = viewModel.inviteCode, !code.isEmpty {
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
            HStack(spacing: 4) {
                Link("Privacy", destination: URL(string: "https://ycfried.github.io/Budget/privacy.html")!)
                Text("·")
                Link("Terms", destination: URL(string: "https://ycfried.github.io/Budget/terms.html")!)
            }
            .font(.subheadline)
            .foregroundStyle(DesignTokens.mid)
            .padding(.top, 4)
        }
    }
}
