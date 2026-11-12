// OnBudget — HouseholdViews.swift
//
// Household screen (CLONE_SPEC §5, live.html:76-101,
// live.js:2622-2720). Same brand block and footer as Auth.
//
// Choice panel: heading "Your Household", subtext "Create a
// household as its owner, or join one with an invite code." Create
// Household (I Am the Owner) (primary, full-width) opens the name
// panel (it does NOT call the RPC itself). Label "Or Join a
// Household" + invite-code input (placeholder "Invite Code from
// the Owner") + Join as Member (tertiary, full-width).
//
// Boot failure (audit F-P1-1): when the membership read fails, the
// choice panel stays hidden and a persistent error + Retry shows
// instead — the user may already belong to a household whose read
// just failed. The screen also shows the signed-in email + a Sign
// Out link (audit F-P1-4): without them a wrong-account sign-in is
// a dead end with no escape and no way to tell which account it is.
//
// Name panel: heading "Name Your Household", Household Name field
// (max 80, placeholder "Household"), button row ← Back +
// Create Household (primary). Household name is REQUIRED (owner,
// Nov 4): blank fails before any call, no fallback to the default
// "Household". Create calls RPC create_household(p_name) — the ONLY
// path to admin; on success the client sets membership directly
// (it does NOT re-read membership).
//
// Join calls RPC join_household_by_code({code}). Empty code → "Enter
// the invite code from the household owner." Invalid code (error OR
// null return) → the web's exact text: "Join failed. Check the invite
// code and try again, or ask the household owner to share it again
// from Settings." Rate limit: max 5 failed attempts/hour — the
// server refusal maps to "Too many failed attempts. Try again
// later." Codes are reusable and non-expiring.
//
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

public struct HouseholdView: View {
    @ObservedObject var appState: AppViewModel

    @State private var joinCode = ""
    @State private var showNamePanel = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var busy: String?

    public init(appState: AppViewModel) { self.appState = appState }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AuthBrandHeader()
                if let bootError = appState.bootError {
                    bootErrorPanel(bootError)
                } else if showNamePanel {
                    namePanel
                } else {
                    choicePanel
                }
                accountFooter
                AuthFooter()
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .background(DesignTokens.background)
    }

    /// Persistent boot-failure panel (audit F-P1-1): the error stays
    /// on screen with a Retry; the choice panel stays hidden until
    /// membership is known to be absent.
    private func bootErrorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Household")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            ErrorBox(error)
            Button("Try Again") { Task { await appState.boot() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("household.retryBoot")
        }
    }

    /// The signed-in account + a way out (audit F-P1-4): without
    /// this, a wrong-account sign-in is a dead end — no Settings
    /// cover exists on this screen and the email is shown nowhere.
    private var accountFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let email = appState.client.currentSession?.user.email, !email.isEmpty {
                Text("Signed in as \(email)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            Button("Sign Out") { Task { await appState.signOut() } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.mid)
                .accessibilityIdentifier("household.signOut")
        }
        .padding(.top, 8)
    }

    // MARK: Choice panel

    private var choicePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Household")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Text("Create a household as its owner, or join one with an invite code.")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))

            Button(busy == "create" ? "Creating…" : "Create Household (I Am the Owner)") {
                showNamePanel = true
                message = nil
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("household.createHousehold")
            .disabled(busy != nil)

            Text("Or Join a Household")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 8)
            TextField("Invite Code from the Owner", text: $joinCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("household.inviteCode")
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Button(busy == "join" ? "Joining…" : "Join as Member") { Task { await join() } }
                .buttonStyle(TertiaryButtonStyle())
                .accessibilityIdentifier("household.joinAsMember")
                .disabled(busy != nil)

            // The message sits under the Join button, next to the
            // field that caused it (audit F-P2-7; web renders
            // #householdMsg below Join too).
            if let message {
                if messageIsError { ErrorBox(message) } else { InfoBox(message) }
            }
        }
    }

    // MARK: Name panel

    private var namePanel: some View {
        HouseholdNamePanel(
            onBack: { showNamePanel = false; message = nil },
            onCreated: { id in
                Task { await appState.enterHousehold(id: id, role: .admin) }
            },
            onError: { text in
                message = text
                messageIsError = true
            }
        )
    }

    // MARK: Join

    private func join() async {
        let code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            message = "Enter the invite code from the household owner."
            messageIsError = true
            return
        }
        guard appState.client.isSignedIn else {
            message = "Sign in first."
            messageIsError = true
            return
        }
        busy = "join"
        message = nil
        do {
            // Returns nil (not an error) for an invalid code — the
            // function returns NULL and logs the attempt instead of
            // raising, so the log survives.
            let householdId = try await appState.client.rpcs.joinHouseholdByCode(code: code)
            busy = nil
            guard let householdId else {
                message = "Join failed. Check the invite code and try again, or ask the household owner to share it again from Settings."
                messageIsError = true
                return
            }
            message = "Joined. Loading shared budget…"
            messageIsError = false
            await appState.enterHousehold(id: householdId, role: .member)
        } catch let error as OnBudgetError {
            // Rate-limit gets a plain sentence (audit F-P2-5 — the
            // server's lowercase unpunctuated text is not shown);
            // other refusals go through displayMessage.
            if case .rateLimited = error {
                message = "Too many failed attempts. Try again later."
            } else {
                message = error.displayMessage
            }
            messageIsError = true
            busy = nil
        } catch {
            message = "Join failed. Check the invite code and try again, or ask the household owner to share it again from Settings."
            messageIsError = true
            busy = nil
        }
    }
}

/// Name panel: "Name Your Household" + Household Name field +
/// ← Back + Create Household (primary).
public struct HouseholdNamePanel: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var householdName = ""
    @State private var localError: String?
    @State private var busy = false

    let onBack: () -> Void
    let onCreated: (UUID) -> Void
    let onError: (String) -> Void

    public init(onBack: @escaping () -> Void, onCreated: @escaping (UUID) -> Void, onError: @escaping (String) -> Void) {
        self.onBack = onBack
        self.onCreated = onCreated
        self.onError = onError
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Back goes top-left, same place on every screen (owner,
            // Nov 11, 2026) — never squeezed next to the primary
            // button at the bottom.
            HStack {
                BackButton(action: onBack)
                Spacer()
            }
            Text("Name Your Household")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Text("Household Name")
                .font(.system(size: 14, weight: .bold))
            TextField("Household", text: $householdName)
                .accessibilityIdentifier("household.nameField")
                .onChange(of: householdName) { _, newValue in
                    if newValue.count > 80 { householdName = String(newValue.prefix(80)) }
                }
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let localError { ErrorBox(localError) }
            Button(busy ? "Creating…" : "Create Household") { Task { await create() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("household.createConfirm")
                .disabled(busy)
        }
    }

    private func create() async {
        if let error = AuthValidation.householdNameError(householdName) {
            localError = error
            return
        }
        busy = true
        localError = nil
        do {
            let id = try await appState.client.rpcs.createHousehold(
                pName: householdName.trimmingCharacters(in: .whitespacesAndNewlines))
            busy = false
            // Success message (live.js:2622-2720); the app moves
            // straight to the app + refresh.
            appState.showToast("Household created. Share the invite code from Settings so the second account can join as member.", kind: .success)
            onCreated(id)
        } catch {
            localError = "Could not create household. Try again."
            onError("Could not create household. Try again.")
            busy = false
        }
    }
}
