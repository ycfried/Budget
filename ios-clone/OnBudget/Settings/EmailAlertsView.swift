// OnBudget — Settings: Email Alerts card (live web v66, §10.3).
//
// Gmail connect via `gmail-oauth-start` presented with
// `ASWebAuthenticationSession` (callback handled in-app; the OAuth
// server flow is owned by the Edge Functions — never rebuilt here).
// Status shows just "Connected" when healthy; disconnect via
// `gmail-disconnect`; manual "Check" triggers `gmail-poll`.
//
// Wiring (exact API calls):
// - Reads: `PostgrestClient.emailConnections(householdId:)` (the
//   `email_connections_public` view — status only, no token).
// - Connect: `EdgeFunctionsClient.gmailOAuthStart()` with NO
//   household id first (the function derives it from the caller's
//   admin membership). A 409 (multi-household admin) offers the
//   caller's own admin households in a "Choose Household" picker
//   (`PostgrestClient.adminMemberships(userId:)` +
//   `householdNames(ids:)`, current household first) and retries
//   with the picked id. `auth_url` opens in
//   `ASWebAuthenticationSession`; the callback carries
//   `?gmail=connected` / `?gmail=failed`.
// - Check: `gmailPoll(householdId:)` — the message is built from
//   `errors[]` (per-connection failures; a top-level-only read used
//   to report false success) plus the API stale flag.
// - Disconnect (per connection, admin-only): `gmailDisconnect(
//   householdId:connectionId:)` after a confirm.
//
// Gmail callback URL scheme — DONE on the app side (Nov 9, 2026),
// still OWED on the server + dashboard:
// - The `onbudget` scheme IS registered in the app target
//   (INFOPLIST_KEY_CFBundleURLTypes, Debug + Release), covering
//   both `onbudget://gmail-callback` and `onbudget://reset-password`.
//   An active `ASWebAuthenticationSession` (callbackURLScheme
//   "onbudget") completes on its own once the scheme is registered
//   — no onOpenURL forwarding to `GmailOAuthPresenter` is needed.
//   `OnBudgetApp.onOpenURL` routes `gmail-callback` URLs to
//   `AppViewModel.handleGmailDeepLink`, which records the outcome
//   for callbacks arriving outside an active session.
// - The app sends `client: "native"` to `gmail-oauth-start` so the
//   server can tell the native flow from the web flow.
// - STILL OWED (server, NOT deployed): branch
//   `gmail-callback-native-redirect` (off main) makes
//   `gmail-oauth-start` encode the client in the OAuth state
//   (`native:<nonce>`) and `gmail-oauth-callback` redirect native
//   states to `onbudget://gmail-callback?gmail=…` instead of
//   live.html. Until that ships + is deployed, the live flow still
//   returns to live.html and the native connect cannot complete.
// - STILL OWED (dashboard, parent): Supabase Auth → URL
//   Configuration → Redirect URLs — add `onbudget://reset-password`
//   and `onbudget://gmail-callback`. Full end-to-end Gmail connect
//   also needs a real Google account and cannot run on CI.

import SwiftUI
import UIKit
import AuthenticationServices
import OnBudgetKit

// MARK: - Gmail OAuth presenter

/// Presents the Google consent flow in an
/// `ASWebAuthenticationSession` and reports the callback result.
/// The session is cancelled silently when the user dismisses it.
/// (Not `@MainActor`: `ASWebAuthenticationPresentationContextProviding`
/// requires a nonisolated `presentationAnchor(for:)`.)
final class GmailOAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<GmailOAuthResult, Never>?

    enum GmailOAuthResult {
        case connected
        case failed
        case cancelled
    }

    /// Starts the session for `authURL`. Returns `.connected` when
    /// the callback carries `gmail=connected`, `.failed` for
    /// `gmail=failed`, `.cancelled` when the user dismisses it.
    func start(authURL: URL) async -> GmailOAuthResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "onbudget"
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                if let callbackURL {
                    let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "gmail" }?.value
                    if query == "connected" {
                        self.finish(.connected)
                        return
                    }
                    if query == "failed" {
                        self.finish(.failed)
                        return
                    }
                    // A callback without the gmail param is not a
                    // success — the server flow decides what the card
                    // shows on the next refresh.
                    self.finish(.failed)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    self.finish(.cancelled)
                } else {
                    self.finish(.failed)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    private func finish(_ result: GmailOAuthResult) {
        session = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - View model

@MainActor
final class EmailAlertsViewModel: ObservableObject {
    @Published var connections: [EmailConnectionPublic] = []
    @Published var statusLine = "No email connected yet."
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var isConnecting = false
    @Published var isChecking = false
    @Published var resultMessage: String?
    @Published var resultIsError = false
    @Published var connectionToDisconnect: EmailConnectionPublic?
    @Published var disconnectFailed = false
    @Published var householdChoices: [HouseholdChoice]?
    private var householdChoiceContinuation: CheckedContinuation<UUID?, Never>?

    /// One option in the "Choose Household" picker.
    struct HouseholdChoice: Identifiable {
        let id: UUID
        let label: String
    }

    private let context: SettingsContext
    private let toast: ToastState
    private let oauthPresenter: GmailOAuthPresenter

    init(context: SettingsContext, toast: ToastState, oauthPresenter: GmailOAuthPresenter = GmailOAuthPresenter()) {
        self.context = context
        self.toast = toast
        self.oauthPresenter = oauthPresenter
    }

    var isAdmin: Bool { context.isAdmin }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await context.client.postgrest.emailConnections(householdId: context.householdId)
            statusLine = connections.isEmpty ? "No email connected yet." : ""
            loadError = nil
        } catch {
            statusLine = "Could not load email connections."
            loadError = "Could not load email connections."
        }
    }

    /// Warning lines for one connection (filterState.mjs
    /// `emailConnectionWarnings`): expiring grant / stale last poll.
    func warningLines(for connection: EmailConnectionPublic) -> [String] {
        EmailConnectionWarnings.warnings(
            status: connection.status,
            connectedAt: connection.connectedAt,
            createdAt: connection.createdAt,
            lastPollAt: connection.lastPollAt
        ).map { warning in
            if warning == "expiring" {
                return "Email access expires about 7 days after connecting — reconnect soon to keep alerts coming."
            }
            return "Not checked since \(OnBudgetKit.MoneyFormat.fmtDateTime(connection.lastPollAt ?? "")) — if new alerts stop arriving, reconnect."
        }
    }

    // MARK: - Connect Email

    func connectTapped() async {
        guard isAdmin, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        resultMessage = "Getting a secure email connection…"
        resultIsError = false
        do {
            let start = try await context.client.functions.gmailOAuthStart(client: "native")
            await openAuthURL(start.authUrl)
        } catch {
            // 409: the caller administers more than one household and
            // must name one. Offer the picker; a failed list read
            // falls back to the plain 409 message.
            if let budgetError = error as? OnBudgetError,
               case .serverError(let status, let message) = budgetError, status == 409 {
                if let picked = await pickAdminHousehold() {
                    do {
                        let retry = try await context.client.functions.gmailOAuthStart(householdId: picked, client: "native")
                        await openAuthURL(retry.authUrl)
                    } catch {
                        showStartFailure(settingsErrorMessage(error))
                    }
                } else {
                    resultMessage = "Could not start the email connection: \(message). You administer more than one household — pick which household to connect this email to."
                    resultIsError = true
                }
                return
            }
            showStartFailure(settingsErrorMessage(error))
        }
    }

    private func showStartFailure(_ message: String) {
        resultMessage = "Could not start the email connection: \(message). If it says \"not configured,\" the email connection is not set up on the server yet."
        resultIsError = true
    }

    private func openAuthURL(_ authURLString: String) async {
        guard let authURL = URL(string: authURLString) else {
            showStartFailure("unknown error")
            return
        }
        let result = await oauthPresenter.start(authURL: authURL)
        switch result {
        case .connected:
            toast.show("Email connected — the app will check it for Amex alerts.")
            resultMessage = nil
            await load()
        case .failed:
            toast.showError("Email connection didn't go through — try again from Funds.")
            resultMessage = nil
        case .cancelled:
            resultMessage = nil
        }
    }

    /// The multi-household picker (live.js `pickAdminHousehold`):
    /// the caller's own admin memberships + household names, current
    /// household first. Returns nil when there is nothing to pick
    /// (fewer than 2 admin households, or a failed read), or when
    /// the user cancels the picker.
    private func pickAdminHousehold() async -> UUID? {
        guard let userId = context.currentUserId else { return nil }
        do {
            let memberships = try await context.client.postgrest.adminMemberships(userId: userId)
            let ids = Array(Set(memberships.map { $0.householdId }))
            guard ids.count >= 2 else { return nil }
            var ordered = ids
            if let current = ordered.firstIndex(of: context.householdId) {
                ordered.remove(at: current)
                ordered.insert(context.householdId, at: 0)
            }
            // Names are a label-only nicety: a failed name read still
            // offers the choice (rows read 'Household').
            let names = (try? await context.client.postgrest.householdNames(ids: ordered)) ?? []
            let nameById = Dictionary(uniqueKeysWithValues: names.map { ($0.id, $0.name) })
            let options = ordered.map { id in
                let name = (nameById[id] ?? "").trimmingCharacters(in: .whitespaces)
                return HouseholdChoice(id: id, label: name.isEmpty ? "Household" : name)
            }
            return await withCheckedContinuation { continuation in
                householdChoiceContinuation = continuation
                householdChoices = options
            }
        } catch {
            return nil
        }
    }

    func chooseHousehold(_ id: UUID) {
        householdChoices = nil
        householdChoiceContinuation?.resume(returning: id)
        householdChoiceContinuation = nil
    }

    func cancelHouseholdChoice() {
        householdChoices = nil
        householdChoiceContinuation?.resume(returning: nil)
        householdChoiceContinuation = nil
    }

    // MARK: - Check Email Now

    func checkNow() async {
        guard isAdmin, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        resultMessage = "Checking email…"
        resultIsError = false
        do {
            let result = try await context.client.functions.gmailPoll(householdId: context.householdId)
            let (text, isError) = EmailCheckMessage.text(
                topLevelError: nil,
                firstConnectionError: result.firstError?.error,
                stored: result.stored,
                duplicates: result.duplicates,
                quarantined: result.quarantined,
                unparseable: result.unparseable,
                stale: result.stale,
                minutesSincePreviousPoll: result.minutesSincePreviousPoll
            )
            resultMessage = text
            resultIsError = isError
            await load()
        } catch {
            resultMessage = "Email check failed: \(settingsErrorMessage(error))"
            resultIsError = true
        }
    }

    // MARK: - Disconnect

    func disconnectConfirmed() async {
        guard let connection = connectionToDisconnect else { return }
        connectionToDisconnect = nil
        do {
            let result = try await context.client.functions.gmailDisconnect(
                householdId: context.householdId,
                connectionId: connection.id
            )
            guard result.disconnected else {
                disconnectFailed = true
                return
            }
            await load()
        } catch {
            disconnectFailed = true
        }
    }
}

// MARK: - View

struct EmailAlertsView: View {
    @StateObject private var viewModel: EmailAlertsViewModel
    /// The last Gmail callback recorded at the app level
    /// (onbudget://gmail-callback arriving outside an active
    /// ASWebAuthenticationSession). Shown below so such a return is
    /// visible on the card that owns the Gmail connection instead
    /// of being silently dropped.
    @EnvironmentObject private var appState: AppViewModel

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: EmailAlertsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Email Alerts") {
            Text("Look only — it never moves, sends, or changes anything.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))

            Text("Connected Email")
                .font(.headline)
                .padding(.top, 4)
            if viewModel.isLoading && viewModel.connections.isEmpty {
                ProgressView()
            } else if let error = viewModel.loadError, viewModel.connections.isEmpty {
                ErrorBox(error)
            } else if viewModel.connections.isEmpty {
                MutedLine(text: viewModel.isAdmin ? "None — connect an email below." : "None — the admin connects email alerts.")
            } else {
                ForEach(viewModel.connections) { connection in
                    connectionRow(connection)
                }
            }
            if !viewModel.statusLine.isEmpty {
                MutedLine(text: viewModel.statusLine)
            }
            if let callback = appState.gmailCallbackResult {
                MutedLine(text: callback == .connected ? "Gmail return: Connected" : "Gmail return: Failed")
            }

            if viewModel.isAdmin {
                HStack(spacing: 12) {
                    Button(viewModel.isConnecting ? "Connecting…" : "Connect Email") {
                        Task { await viewModel.connectTapped() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isConnecting)
                    Button(viewModel.isChecking ? "Checking…" : "Check Email Now") {
                        Task { await viewModel.checkNow() }
                    }
                    .buttonStyle(TertiaryButtonStyle())
                    .disabled(viewModel.isChecking)
                }
            }

            if let message = viewModel.resultMessage {
                if viewModel.resultIsError {
                    ErrorBox(message)
                } else {
                    Text(message)
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "#eef4ff"))
                        .cornerRadius(12)
                }
            }
        }
        .task { await viewModel.load() }
        .alert(item: $viewModel.connectionToDisconnect) { connection in
            Alert(
                title: Text("Disconnect Email"),
                message: Text("Disconnect \(connection.emailAddress)? The app will stop checking it. Past transactions stay in the list."),
                primaryButton: .destructive(Text("Disconnect")) {
                    Task { await viewModel.disconnectConfirmed() }
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Could not disconnect", isPresented: $viewModel.disconnectFailed) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("Could not disconnect this email. Try again.")
        }
        .sheet(isPresented: Binding(
            get: { viewModel.householdChoices != nil },
            set: { if !$0 { viewModel.cancelHouseholdChoice() } }
        )) {
            if let choices = viewModel.householdChoices {
                householdPickerSheet(choices: choices)
            }
        }
    }

    private func householdPickerSheet(choices: [EmailAlertsViewModel.HouseholdChoice]) -> some View {
        NavigationStack {
            List(choices) { choice in
                Button(choice.label) {
                    viewModel.chooseHousehold(choice.id)
                }
            }
            .navigationTitle("Choose Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelHouseholdChoice()
                    }
                }
            }
        }
    }

    private func connectionRow(_ connection: EmailConnectionPublic) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.emailAddress)
                    .font(.subheadline)
                    .fontWeight(.bold)
                if connection.status == "error" {
                    Text("Needs reconnect — access was revoked or expired.")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                // No standalone "Connected" line: under a
                // "Connected Email" heading it repeats the heading.
                // Only a real problem gets a line.
                ForEach(viewModel.warningLines(for: connection), id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                if let lastPollAt = connection.lastPollAt {
                    Text("Last checked \(OnBudgetKit.MoneyFormat.fmtDateTime(lastPollAt))")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                if let lastError = connection.lastError {
                    Text(lastError)
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            Spacer()
            if viewModel.isAdmin {
                Button("Disconnect") {
                    viewModel.connectionToDisconnect = connection
                }
                .buttonStyle(SmallDangerButtonStyle())
                .accessibilityLabel("Disconnect \(connection.emailAddress)")
            }
        }
    }
}
