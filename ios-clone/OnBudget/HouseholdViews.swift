// OnBudget — HouseholdViews.swift
//
// Household screen (CLONE_SPEC §5, live.html:76-101,
// live.js:2622-2720). Same brand block and footer as Auth.
//
// INVITE-ONLY (Nov 17, 2026 — App Store launch): the ONLY way into
// a household is an invite code shared by a household owner. The
// "Create Household (I Am the Owner)" path is REMOVED — the server
// revokes create_household() for app users in the same launch
// (supabase/invite-only-close-household-creation.sql), so a create
// button here would always fail. A new household can only be made
// by the owner via dashboard SQL (see that file). The screen is
// join-only: heading "Your Household", invite-code input
// (placeholder "Invite Code from the Owner") + Join as Member
// (primary, full-width).
//
// Boot failure (audit F-P1-1): when the membership read fails, the
// choice panel stays hidden and a persistent error + Retry shows
// instead — the user may already belong to a household whose read
// just failed. The screen also shows the signed-in email + a Sign
// Out link (audit F-P1-4): without them a wrong-account sign-in is
// a dead end with no escape and no way to tell which account it is.
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
    @State private var message: String?
    @State private var messageIsError = false
    /// The boot-failure red box dismissed itself (4s timer / tap) —
    /// the panel keeps showing Try Again + a muted line instead.
    @State private var bootErrorBoxHidden = false
    @State private var busy: String?

    public init(appState: AppViewModel) { self.appState = appState }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AuthBrandHeader()
                if let bootError = appState.bootError {
                    bootErrorPanel(bootError)
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
        .onChange(of: appState.bootError) { bootErrorBoxHidden = false }
    }

    /// Persistent boot-failure panel (audit F-P1-1): the error stays
    /// on screen with a Retry; the choice panel stays hidden until
    /// membership is known to be absent.
    private func bootErrorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Household")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            // The red box leaves after 4s (owner rule, Nov 11 2026)
            // but the recovery stays: the choice panel must NOT
            // appear while membership is unknown (audit F-P1-1), so
            // after dismissal a muted line + Try Again remain.
            if !bootErrorBoxHidden {
                DismissableErrorBox(error) { bootErrorBoxHidden = true }
            } else {
                Text("Could not load your household.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
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
            Text("Join your household with the invite code from the household owner.")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))

            TextField("Invite Code from the Owner", text: $joinCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("household.inviteCode")
                .padding(12)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: joinCode) { message = nil }

            Button(busy == "join" ? "Joining…" : "Join as Member") { Task { await join() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("household.joinAsMember")
                .disabled(busy != nil)

            // The message sits under the Join button, next to the
            // field that caused it (audit F-P2-7; web renders
            // #householdMsg below Join too).
            if let message {
                if messageIsError { DismissableErrorBox(message) { self.message = nil } } else { InfoBox(message) }
            }
        }
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
            // Member-joined notification (Nov 16, 2026): the server
            // notifies the other members. Best-effort — joining
            // already succeeded, so a failure here is silent and
            // must not surface as a join failure.
            if let userId = appState.client.currentSession?.user.id {
                do {
                    _ = try await appState.client.functions.pushNotify(payload: [
                        "type": "member_joined",
                        "household_id": householdId.uuidString,
                        "user_id": userId.uuidString,
                    ])
                } catch {
                    // Silent: joining already succeeded.
                }
            }
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
