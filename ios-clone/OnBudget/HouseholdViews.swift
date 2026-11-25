// STAGE — HouseholdViews.swift
//
// Household screen (CLONE_SPEC §5, live.html:76-101,
// live.js:2622-2720). Same brand block and footer as Auth.
//
// Choice panel: heading "Your Household", subtext "Create a
// household as its owner, or join one with an invite code." Create
// Household (primary, full-width) opens the name
// panel (it does NOT call the RPC itself). An "or" divider, then
// the Join section: "Join a Household" label + "Invite Code" field
// label + invite-code input (placeholder "Invite Code from the
// Owner") + Join as Member (distinct outline, full-width).
//
// Build 74 (owner, Nov 24, 2026): the screen was "ugly beyond ..
// it's the old style and crammed" — the Create button a heavy
// slab, "Or Join" cramped against it, the invite field a plain
// grey box, Join a flat grey slab, "Signed in as / Sign Out"
// crammed under the panel, and the footer bunched at the top with
// a vast empty area below. Restyled to the sign-in screen's
// language: vertical balance (GeometryReader + spacers, the Nov 11
// fix for the same complaint), the "or" divider with real
// breathing room, Join as the outline treatment instead of the
// grey slab, the account line in its own separated section, and
// the same 48pt fields as sign-in.
// Owner follow-up, Nov 24 (~23:39): BOTH screens (choose + name)
// are "too big and empty" and need replanning, not just polish.
// The replan: the content column is 600pt centred on iPad (the
// width every sheet and cover uses), full-width on iPhone; each
// panel sits in a white card sized to what it holds; the logo
// sits on top, account section + footer below the card. And
// "The tiny sign out in the bottom left corner.." — Sign Out is
// now a proper full-width button (the Profile Settings treatment),
// not a tiny text link. Owner, Nov 24 (~23:46): "sign out should
// always be red" — it is the standard destructive red
// (FundsDangerButton), never the blue outline.
//
// Household creation was closed for the Nov 17, 2026 invite-only
// launch (server revoke + join-only UI) and RESTORED Nov 24, 2026
// at the owner's direction ("you have to remove the block") — the
// server re-grant and this UI were both put back, so a new user can
// start a household again.
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
    /// The boot-failure red box dismissed itself (4s timer / tap) —
    /// the panel keeps showing Try Again + a muted line instead.
    @State private var bootErrorBoxHidden = false
    @State private var busy: String?

    public init(appState: AppViewModel) { self.appState = appState }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public var body: some View {
        // Layout replan (owner, Nov 24, 2026 — build 74): both
        // screens were "too big and empty" — the content floated
        // on a vast background, and on iPad the buttons stretched
        // full-width into giant slabs. The replan, in the sign-in
        // screen's language: the content column is 600pt centred
        // on iPad (the width every sheet and cover in the app
        // uses), full-width on iPhone; the choice and name panels
        // sit in a white card sized to what they hold; the column
        // is vertically centred (GeometryReader + spacers, the
        // Nov 11 sign-in fix for the same bunched-at-top
        // complaint); the logo sits on top, the account section
        // and the footer below the card. Same functionality and
        // copy throughout.
        GeometryReader { geometry in
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 16) {
                        Spacer(minLength: 0)
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
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .frame(minHeight: geometry.size.height)
                    .frame(width: horizontalSizeClass == .regular ? 600 : nil)
                    Spacer(minLength: 0)
                }
            }
            .background(DesignTokens.background)
        }
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
    /// Build 74 (owner, Nov 24, 2026 — "Your Household" restyle):
    /// it used to sit crammed right under the panel with no
    /// breathing room — it now has its own separated section
    /// (divider + generous spacing, centred like the footer).
    /// Owner follow-up, Nov 24 (~23:39): "The tiny sign out in
    /// the bottom left corner.." — Sign Out was a tiny text link
    /// tucked in the corner. It is now a proper full-width button
    /// with a comfortable tap target — the standard destructive
    /// red (FundsDangerButton), per the owner's Nov 24 (~23:46)
    /// "sign out should always be red" rule — and the divider
    /// before it matches the profile menu, where a divider
    /// separates Sign Out from Settings.
    private var accountFooter: some View {
        VStack(spacing: 12) {
            Divider()
            // Owner follow-up, Nov 24 (~23:45): centre the
            // signed-in line — it was left-aligned while the footer
            // below it is centred. (The VStack is centre-aligned
            // by default; the explicit alignment states the intent.)
            if let email = appState.client.currentSession?.user.email, !email.isEmpty {
                Text("Signed in as \(email)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
                    .multilineTextAlignment(.center)
            }
            // Owner, Nov 24, 2026 — "sign out should always be
            // red": the standard destructive red (FundsDangerButton
            // — soft-red bg, #dc2626 text), the same treatment as
            // the Profile Settings Sign Out and every Delete/Remove.
            // (Was the blue outline from the build-74 restyle.)
            FundsDangerButton("Sign Out") { Task { await appState.signOut() } }
                .accessibilityIdentifier("household.signOut")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
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

            Button(busy == "create" ? "Creating…" : "Create Household") {
                showNamePanel = true
                message = nil
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("household.createHousehold")
            .disabled(busy != nil)
            .padding(.top, 4)

            // Build 74 (owner, Nov 24, 2026 — "Your Household"
            // restyle): "Or Join a Household" used to sit cramped
            // right against the Create button. The two paths are
            // now separated by a proper "or" divider with real
            // breathing room, and the join section gets its own
            // label + field label like the sign-in fields.
            orDivider
                .padding(.vertical, 12)

            // Owner follow-up, Nov 24 (~23:45): centre the
            // section label — the footer text is centred, so the
            // Join heading is too, instead of sitting left while
            // everything below the card is centred.
            Text("Join a Household")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .frame(maxWidth: .infinity, alignment: .center)
            FieldLabel("Invite Code", required: true, weight: .bold)
            TextField("Invite Code from the Owner", text: $joinCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("household.inviteCode")
                // Same 48pt field as the sign-in fields (build 68,
                // item 7/13): exactly 48pt tall, 14pt horizontal
                // padding — the old minHeight + 12pt vertical
                // padding rendered a taller, flatter box.
                .padding(.horizontal, 14)
                .frame(height: 48, alignment: .leading)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: joinCode) { message = nil }

            // Build 74: the old grey-fill tertiary read as a flat
            // grey slab under the solid blue Create button. Join is
            // now the distinct outline treatment (white bg,
            // brand-blue border + text) — the two buttons no longer
            // share a slab look (owner button rule, Nov 3–4).
            Button(busy == "join" ? "Joining…" : "Join as Member") { Task { await join() } }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityIdentifier("household.joinAsMember")
                .disabled(busy != nil)
                .padding(.top, 4)

            // The message sits under the Join button, next to the
            // field that caused it (audit F-P2-7; web renders
            // #householdMsg below Join too).
            if let message {
                if messageIsError { DismissableErrorBox(message) { self.message = nil } } else { InfoBox(message) }
            }
        }
        // Build 74 replan: the panel sits in a white card sized
        // to what it holds — the fund-card language (white,
        // hairline border, soft shadow), 16pt radius for a form
        // card — instead of floating loose on the background.
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .fundCardShadow()
    }

    /// "— or —" divider between the Create and Join paths.
    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(hex: "#e5e7eb"))
                .frame(height: 1)
            Text("or")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
            Rectangle()
                .fill(Color(hex: "#e5e7eb"))
                .frame(height: 1)
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
            // No "Joined. Loading…" message (build 74, B5):
            // loading is skeletons, never a "Loading…" line —
            // the Home skeletons take over as enterHousehold runs.
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
            FieldLabel("Household Name", required: true, weight: .bold)
            TextField("Household", text: $householdName)
                .accessibilityIdentifier("household.nameField")
                .onChange(of: householdName) { _, newValue in
                    if newValue.count > 80 { householdName = String(newValue.prefix(80)) }
                }
                // Same 48pt field as the sign-in fields (build 74):
                // exactly 48pt tall, 14pt horizontal padding.
                .padding(.horizontal, 14)
                .frame(height: 48, alignment: .leading)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let localError { ErrorBox(localError) }
            Button(busy ? "Creating…" : "Create Household") { Task { await create() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("household.createConfirm")
                .disabled(busy)
        }
        // Build 74 replan: same white card as the choice panel —
        // sized to what it holds, so the name screen reads as a
        // complete card instead of one field floating on a vast
        // background. The Back chevron sits top-left inside it.
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .fundCardShadow()
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
