// STAGE — Settings: Account & Household card (live web v66, §10.5).
//
// Members list, invite code inline, Delete Account (two-step).
//
// Wiring (exact API calls):
// - Members: RPC `list_household_members()` — no full email, only
//   `email_prefix` as the name fallback. Display-name resolution:
//   stored display_name -> own auth-metadata name (re-read from the
//   server on every load, build 43) -> email_prefix ->
//   "Household member" (never the bare word "Member"). Real display
//   names render in the short "First L." form (build 43, Nov 17,
//   2026); the email-prefix and "Household member" fallbacks are
//   shown as-is, never shortened.
//   BUILD 43 ROOT CAUSE (item 9): the stored `display_name` is a
//   snapshot copied from auth metadata ONLY when the member row is
//   created (create/join RPCs, signup-display-name.sql) — nothing
//   ever updates it, and Save Name writes auth metadata
//   (`full_name`) only. The RPC returns that stale snapshot, and
//   the client can only fall back to auth metadata for its OWN row
//   (RLS hides other members' metadata), so another member's rename
//   falls through to the email prefix on this device — that is why
//   the wife still showed as "chayasf1" here. The client fix covers
//   the own row + refresh-on-rename; another member's rename needs
//   a SERVER change (sync `household_members.display_name` when the
//   metadata name changes, or have the RPC read auth metadata live).
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
//   Each role shows its label as plain muted-grey text, no pill
//   (build 43, Nov 17, 2026); what each role can do lives behind
//   the ⓘ next to the "Members" heading.
// - Invite code: `PostgrestClient.inviteCode(householdId:)` (the
//   `households.invite_code` column — NEVER the household UUID).
//   OWNER-ONLY: only the owner fetches or sees it (Nov 11, 2026).
//   Build 43 (Nov 17, 2026): the invite-code section sits ABOVE
//   the Household / Members section now, not below it.
//   A failed read shows an error line, never "No invite code is set
//   up" (owner report, Nov 11: the app said that while PJM2HG
//   existed).
//   Copy writes the clipboard and flips to "Copied" for 2s; Share
//   uses the native share sheet with
//   "Join my household on STAGE with invite code CODE".
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

/// Build 43 (owner, Nov 17, 2026 — item 10): member names show as
/// first name + last initial + "." (e.g. "Shuki Friedman" ->
/// "Shuki F."). Display formatting ONLY — the stored display name is
/// never changed. A single name part shows as-is (never fabricate
/// an initial); an already-short "Shuki F." stays "Shuki F.".
/// Shared with the sign-up name step (AuthViews.swift), which
/// derives the stored display name the same way.
func shortMemberName(_ fullName: String) -> String {
    let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: " ").map(String.init)
    guard parts.count >= 2, let first = parts.first, let last = parts.last, let initial = last.first else {
        return trimmed
    }
    return "\(first) \(initial.uppercased())."
}

/// Build 43 (owner, Nov 17, 2026 — item 9): posted when the
/// signed-in user saves a new display name in Profile
/// (ProfileSettingsViewModel), so the Members list re-reads the name
/// instead of showing a stale row until the next cold load.
extension Notification.Name {
    static let displayNameDidChange = Notification.Name("OnBudget.displayNameDidChange")
}

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
    /// The ONE alert this screen can show. SwiftUI only honours a
    /// single `.alert` modifier on a view, so the six separate alerts
    /// this screen used to stack (remove confirm/failed, role
    /// confirm/failed, delete steps/failed) collapsed into one: the
    /// Remove / Make Admin confirms never appeared (owner report,
    /// Nov 15, 2026 — tapping did nothing). Build 30 folds them all
    /// into this single enum state, driven by one `.alert(item:)`.
    @Published var alert: MembersAlert?
    @Published var copiedCode = false
    @Published var showShareSheet = false
    /// Build 43 (owner, Nov 17, 2026 — item 9): the signed-in
    /// user's auth-metadata name, re-read from the server on every
    /// load (see load()) — fresher than the `context.displayName`
    /// snapshot taken when Settings was built.
    @Published var ownMetadataName: String?

    /// The single alert state for the Members screen (build 30).
    /// One `.alert(item:)` in the view switches over the case.
    enum MembersAlert: Identifiable {
        case removeMember(MemberListRow)
        case removeFailed
        case changeRole(RoleChangeRequest)
        case roleChangeFailed
        case delete(DeleteStep)
        case deleteFailed

        var id: String {
            switch self {
            case .removeMember(let member): return "remove-\(member.userId.uuidString)"
            case .removeFailed: return "removeFailed"
            case .changeRole(let request): return "role-\(request.id)"
            case .roleChangeFailed: return "roleChangeFailed"
            case .delete(let step): return "delete-\(step.id)"
            case .deleteFailed: return "deleteFailed"
            }
        }
    }

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

    /// Build 43 (owner, Nov 17, 2026 — items 9–10): the name shown
    /// for a member. Resolution, in order: the stored `display_name`
    /// the `list_household_members()` RPC returns; the signed-in
    /// user's own auth-metadata name (re-read on load, so a Profile
    /// rename shows without a cold restart) — own row only; then
    /// the email prefix; then "Household member". A real display
    /// name renders in the short "First L." form; the email prefix
    /// and the "Household member" fallback are NOT shortened
    /// ("Household member" must never render as "Household m.").
    /// The stored name itself is never changed here — formatting
    /// only. See the file header for why another member's rename
    /// can still fall through to the email prefix (server gap).
    func displayName(for member: MemberListRow) -> String {
        if let stored = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return shortMemberName(stored)
        }
        if isOwnRow(member) {
            let meta = (ownMetadataName ?? context.displayName)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let meta, !meta.isEmpty { return shortMemberName(meta) }
        }
        if let prefix = member.emailPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            return prefix
        }
        return "Household member"
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
        // Build 43 (owner, Nov 17, 2026 — item 9): re-read the
        // signed-in user's auth-metadata name on every load, so a
        // Profile rename shows in the Members list without a cold
        // restart. Best-effort — a failure keeps the `context`
        // snapshot and never fails the members load.
        if let user = try? await context.client.getUser() {
            ownMetadataName = user.displayName
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
        alert = .changeRole(RoleChangeRequest(member: member, toRole: role))
    }

    /// The request arrives as a parameter, captured by the alert's
    /// button — the same `.alert(item:)` pitfall as removeConfirmed
    /// (the binding is nilled when the alert dismisses, before an
    /// unstructured Task runs).
    func roleChangeConfirmed(_ request: RoleChangeRequest) async {
        alert = nil
        let label = displayName(for: request.member)
        do {
            try await context.client.rpcs.setHouseholdMemberRole(pUserId: request.member.userId, pRole: request.toRole)
            toast.show(request.toRole == .admin
                       ? "\(label) is now an admin."
                       : "\(label) is now a regular member.", kind: .success)
            await load()
        } catch {
            alert = .roleChangeFailed
        }
    }

    // MARK: - Remove member

    func confirmRemove(_ member: MemberListRow) {
        alert = .removeMember(member)
    }

    /// The member arrives as a parameter, captured by the alert's
    /// button: `.alert(item:)` nils the `memberToRemove` binding
    /// when the alert dismisses, which happens BEFORE an unstructured
    /// `Task` runs — so re-reading the binding here always found nil
    /// and the removal silently never happened (owner report, Nov 11,
    /// 2026: Remove on "Jack friedman" did nothing). The same pitfall
    /// is fixed the same way in confirmSave / disconnectConfirmed.
    func removeConfirmed(_ member: MemberListRow) async {
        alert = nil
        let label = displayName(for: member)
        do {
            try await context.client.rpcs.removeHouseholdMember(pUserId: member.userId)
            // Member-left notification (Nov 16, 2026): the server
            // notifies the remaining members. Best-effort — the
            // removal already succeeded, so a failure here is silent.
            do {
                _ = try await context.client.functions.pushNotify(payload: [
                    "type": "member_left",
                    "household_id": context.householdId.uuidString,
                    "user_id": member.userId.uuidString,
                    "name": label,
                ])
            } catch {
                // Silent: the removal already succeeded.
            }
            toast.show("\(label) was removed from the household.", kind: .success)
            await load()
        } catch {
            alert = .removeFailed
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
        return "Join my household on STAGE with invite code \(code)"
    }

    // MARK: - Delete Account (two-step)

    func startDelete() {
        alert = .delete(.confirmDelete)
    }

    func confirmDeleteStepOne() {
        alert = .delete(.confirmEverything)
    }

    func confirmDeleteStepTwo() async {
        alert = nil
        do {
            let result = try await context.client.functions.deleteAccount()
            guard result.deleted else {
                alert = .deleteFailed
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
            alert = .deleteFailed
        }
    }
}

/// Member-row action buttons (owner, Nov 15, 2026): "Make Admin"
/// and "Remove" share ONE size/format — same font, padding and
/// corner radius — and differ ONLY in colour (grey vs red). The old
/// pair mixed TertiaryButtonStyle (large, maxWidth .infinity, so it
/// grabbed the row and squeezed Remove off the right edge) with
/// SmallDangerButtonStyle (smaller, 1pt larger font), and the two
/// did not match. Both tones are content-sized and fixedSize in the
/// row, so neither compresses nor clips.
private struct MemberActionButtonStyle: ButtonStyle {
    enum Tone { case grey, red }
    let tone: Tone
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tone == .red ? DesignTokens.errorText : DesignTokens.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(tone == .red ? DesignTokens.errorBackground : Color(hex: "#e5e7eb"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct MembersSettingsView: View {
    @StateObject private var viewModel: MembersSettingsViewModel
    private let context: SettingsContext
    /// Build 43 (owner, Nov 17, 2026 — item 14): the two ⓘ alerts
    /// on this card. They live on inner stacks, not the card root —
    /// the card root already carries the single `.alert(item:)`
    /// for remove / role / delete.
    @State private var showingRolesInfo = false
    @State private var showingDeleteInfo = false

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        _viewModel = StateObject(wrappedValue: MembersSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Account & Household") {
            // Build 43 (owner, Nov 17, 2026 — item 15): the invite
            // code sits ABOVE the Household / Members section now,
            // not below it.
            if viewModel.isOwner {
                inviteCodeSection
            }

            if let name = viewModel.householdName, !name.isEmpty {
                Text("Household: \(name)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            // Build 43 (owner, Nov 17, 2026 — item 14): the role
            // explanations live behind the ⓘ now, not as inline
            // paragraphs under the list. Same ⓘ + alert pattern as
            // the fund descriptions in FundsShared.swift.
            HStack(spacing: 6) {
                Text("Members")
                    .font(.headline)
                Button { showingRolesInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Member Roles")
            }
            .padding(.top, 4)
            .alert("Roles", isPresented: $showingRolesInfo) {
                Button("OK") {}
            } message: {
                Text("Owner — Started the household — the only one who can remove members or see the invite code.\nAdmin — Full access except removing members.\nMember — Regular member.")
            }
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
                HStack {
                    Spacer()
                    BrandedLoader()
                    Spacer()
                }
                .padding(.top, 24)
            } else if !viewModel.members.isEmpty {
                ForEach(viewModel.members) { member in
                    memberRow(member)
                }
            } else if !viewModel.loadFailed {
                MutedLine(text: "No members yet.")
            }

            deleteAccountSection
        }
        .task { await viewModel.load() }
        // Build 43 (owner, Nov 17, 2026 — item 9): re-read the list
        // whenever Settings appears, and whenever the signed-in user
        // saves a new name in Profile on this same screen — otherwise
        // the rename only shows after a cold restart.
        .onAppear { Task { await viewModel.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .displayNameDidChange)) { _ in
            Task { await viewModel.load() }
        }
        // ONE alert for the whole screen (build 30): SwiftUI only
        // honours a single `.alert` modifier on a view, so the six
        // this screen used to stack meant only one ever fired — the
        // Remove / Make Admin confirms never appeared. Every case
        // below is one branch of `viewModel.alert`.
        .alert(item: $viewModel.alert) { alert in
            switch alert {
            case .removeMember(let member):
                let label = viewModel.displayName(for: member)
                return Alert(
                    title: Text("Remove Member"),
                    message: Text("Remove \(label) from the household? They will lose access to the household's data."),
                    primaryButton: .destructive(Text("Remove")) {
                        Task { await viewModel.removeConfirmed(member) }
                    },
                    secondaryButton: .cancel()
                )
            case .removeFailed:
                return Alert(
                    title: Text("Could Not Remove Member"),
                    message: Text("Could not remove this member. Try again."),
                    dismissButton: .cancel(Text("Close"))
                )
            case .changeRole(let request):
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
            case .roleChangeFailed:
                return Alert(
                    title: Text("Could Not Change Role"),
                    message: Text("Could not change this member's role. Try again."),
                    dismissButton: .cancel(Text("Close"))
                )
            case .delete(let step):
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
            case .deleteFailed:
                return Alert(
                    title: Text("Could Not Delete Account"),
                    message: Text("Could not delete your account. Nothing was deleted — try again."),
                    dismissButton: .cancel(Text("Close"))
                )
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
            // Build 43 (owner, Nov 17, 2026 — item 12): the role
            // shows as plain muted-grey text, no pill — the pills
            // made the rows look unequal. Plain grey #6b7280, no
            // background, no tint.
            Text(viewModel.displayRole(for: member).label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color(hex: "#6b7280"))
            Spacer()
            if let action = viewModel.roleAction(for: member) {
                Button(action.label) {
                    viewModel.confirmRoleChange(member, to: action.toRole)
                }
                .buttonStyle(MemberActionButtonStyle(tone: .grey))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("\(action.label) \(viewModel.displayName(for: member))")
            }
            if viewModel.isOwner && !viewModel.isOwnRow(member) {
                Button("Remove") {
                    viewModel.confirmRemove(member)
                }
                .buttonStyle(MemberActionButtonStyle(tone: .red))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Remove \(viewModel.displayName(for: member)) from the household")
            }
        }
    }

    @ViewBuilder
    private var inviteCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Build 43 (owner, Nov 17, 2026 — items 14–15): the
            // owner-only note stays with the code as a short
            // one-liner; the long role paragraphs moved behind ⓘ.
            Text("Only the owner can share the invite code.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            Text("Members join with this invite code.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            if !viewModel.inviteCodeLoaded {
                HStack {
                    Spacer()
                    BrandedLoader(size: 40)
                    Spacer()
                }
            } else if viewModel.inviteCodeLoadFailed {
                ErrorBox("Could not load the invite code. Try again.")
            } else if let code = viewModel.inviteCode, !code.isEmpty {
                // Compact chip (owner, Nov 15, 2026): the code used
                // to take a whole full-width line of its own. Now
                // the code, Copy and Share sit on one row; the
                // buttons are content-sized (fixedSize) so they do
                // not stretch across the row.
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(.headline, design: .monospaced))
                        .fontWeight(.semibold)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(Color(hex: "#eef4ff"))
                        .cornerRadius(10)
                    Button(viewModel.copiedCode ? "Copied" : "Copy") {
                        viewModel.copyInviteCode()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    Button("Share") {
                        viewModel.showShareSheet = true
                    }
                    .buttonStyle(TertiaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }
            } else {
                MutedLine(text: "No invite code is set up for this household yet.")
            }
        }
        .padding(.top, 4)
    }

    private var deleteAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Build 43 (owner, Nov 17, 2026 — item 14): the Delete
            // Account explanation lives behind the ⓘ, not as an
            // inline paragraph. Same ⓘ + alert pattern as the fund
            // descriptions in FundsShared.swift.
            HStack(spacing: 6) {
                Text("Delete Account")
                    .font(.headline)
                Button { showingDeleteInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Delete Account")
            }
            .padding(.top, 8)
            .alert("Delete Account", isPresented: $showingDeleteInfo) {
                Button("OK") {}
            } message: {
                Text("Deleting removes you from this household. If you are the last member, the household is deleted too. This cannot be undone.")
            }
            // Centred with room around it (owner, Nov 15, 2026) —
            // it sat left-aligned and tight against the text above.
            Button("Delete Account") {
                viewModel.startDelete()
            }
            .buttonStyle(DangerButtonStyle())
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            // Build 43 (owner, Nov 17, 2026 — item 13): Privacy ·
            // Terms moved out of this card into their own card at
            // the bottom of Settings (SettingsView).
        }
    }
}
