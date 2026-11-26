// STAGE — Settings: Email Alerts card (live web v66, §10.3).
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
    @Published var loadError: String?
    /// True after a failed load until a load succeeds. The card
    /// shows the error + Retry while this is set — never a false
    /// "None." (audit S-P1-2).
    @Published var loadFailed = false
    @Published var isLoading = false
    /// Loading-state gate (Nov 26, 2026 — Funds-page pattern): true
    /// once the FIRST load has resolved (success or failure). The
    /// card shows skeletons shaped like its content until then.
    /// Before this the card rendered its heading, buttons and
    /// result area immediately, the error banner (if any) appeared
    /// at the top after the load, and the connection rows popped
    /// in between — pushing the Connect / Check buttons down after
    /// first paint. Reloads (Check Email Now, disconnect) keep the
    /// stale rows on screen; this flag stays true.
    @Published var hasLoaded = false
    @Published var isConnecting = false
    @Published var isChecking = false
    @Published var resultMessage: String?
    @Published var resultIsError = false
    /// The ONE alert this screen can show (build 30): the two
    /// `.alert` modifiers this screen used to stack (Disconnect
    /// confirm + failed) collapsed into one — SwiftUI only honours
    /// a single `.alert` on a view (same bug as the Members screen,
    /// Nov 15, 2026).
    @Published var alert: EmailAlertsAlert?

    /// The single alert state for the Email Alerts screen (build 30).
    enum EmailAlertsAlert: Identifiable {
        case disconnect(EmailConnectionPublic)
        case disconnectFailed

        var id: String {
            switch self {
            case .disconnect(let connection): return "disconnect-\(connection.id)"
            case .disconnectFailed: return "disconnectFailed"
            }
        }
    }
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

    /// Build 49 (owner, Nov 19, 2026): the banner line when any
    /// connection is in error state — email alerts have stopped and
    /// the app must say so out loud with a reconnect action, not a
    /// grey muted line and not silence. Nil when nothing is broken.
    var errorBannerMessage: String? {
        GmailErrorBanner.message(for: connections)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await context.client.postgrest.emailConnections(householdId: context.householdId)
            loadError = nil
            loadFailed = false
        } catch {
            loadError = "Could not load email connections."
            loadFailed = true
        }
        hasLoaded = true
    }

    /// Plain-language `last_error` (audit CF-2, Nov 12 2026): the
    /// stored string is a raw server/Gmail error and must never
    /// render verbatim. Same approach as `EmailCheckMessage`
    /// (S-P1-3(d)): auth/expired failures map to "reconnect";
    /// anything else maps to a generic plain line, never the raw
    /// text.
    static func plainLastError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("reauthorization") || lower.contains("invalid_grant")
            || lower.contains("expired") || lower.contains("revoked") {
            return "Email access expired — reconnect this email."
        }
        return "The last email check ran into a problem — try Check Email Now."
    }

    /// Warning lines for one connection (filterState.mjs
    /// `emailConnectionWarnings`): expiring grant / stale last poll.
    func warningLines(for connection: EmailConnectionPublic) -> [String] {        EmailConnectionWarnings.warnings(
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
            // falls back to the plain 409 message. The server's own
            // message never reaches the user — the sanitised
            // settings error text is used instead (audit S-P1-3).
            if let budgetError = error as? OnBudgetError,
               case .serverError(let status, _) = budgetError, status == 409 {
                if let picked = await pickAdminHousehold() {
                    do {
                        let retry = try await context.client.functions.gmailOAuthStart(householdId: picked, client: "native")
                        await openAuthURL(retry.authUrl)
                    } catch {
                        showStartFailure(settingsErrorMessage(error))
                    }
                } else {
                    resultMessage = "Could not start the email connection: \(settingsErrorMessage(error)). You administer more than one household — pick which household to connect this email to."
                    resultIsError = true
                }
                return
            }
            showStartFailure(settingsErrorMessage(error))
        }
    }

    private func showStartFailure(_ message: String) {
        resultMessage = "Could not start the email connection: \(message)."
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
            toast.show("Email connected — the app will check it for Amex alerts.", kind: .success)
            resultMessage = nil
            await load()
        case .failed:
            toast.showError("Email connection didn't go through — try again here.")
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
            // Build 49 (owner, Nov 19, 2026): a connection in error
            // state must never read as a successful check. The poll
            // normally reports the failure itself, but if it did not,
            // say so here — no more silent failure.
            if !resultIsError, let banner = GmailErrorBanner.message(for: connections) {
                resultMessage = banner
                resultIsError = true
            }
        } catch {
            resultMessage = "Email check failed: \(settingsErrorMessage(error))"
            resultIsError = true
        }
    }

    // MARK: - Disconnect

    func confirmDisconnect(_ connection: EmailConnectionPublic) {
        alert = .disconnect(connection)
    }

    /// The connection arrives as a parameter, captured by the alert's
    /// button: `.alert(item:)` nils the `alert` binding when the
    /// alert dismisses, which happens BEFORE an unstructured `Task`
    /// runs — so re-reading the binding here always found nil and
    /// the disconnect silently never happened (same pitfall as
    /// removeConfirmed, Nov 11, 2026).
    func disconnectConfirmed(_ connection: EmailConnectionPublic) async {
        alert = nil
        do {
            let result = try await context.client.functions.gmailDisconnect(
                householdId: context.householdId,
                connectionId: connection.id
            )
            guard result.disconnected else {
                alert = .disconnectFailed
                return
            }
            await load()
        } catch {
            alert = .disconnectFailed
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: EmailAlertsViewModel(context: context, toast: toast))
    }

    var body: some View {
        SettingsCard(title: "Email Alerts") {
            // Loading-state gate (Nov 26, 2026 — Funds-page
            // pattern): skeletons shaped like the card until the
            // first load resolves, so the error banner and the
            // connection rows never push the buttons down after
            // first paint.
            if !viewModel.hasLoaded {
                emailLoadingSkeleton
            } else {
            // Build 49 (owner, Nov 19, 2026): when a connection is in
            // error state, email alerts have stopped — say so out loud
            // at the top of the card with a reconnect action, not a
            // grey muted line buried in the row. The Reconnect button
            // is admin-only; members see the error but cannot reconnect.
            if let banner = viewModel.errorBannerMessage {
                VStack(alignment: .leading, spacing: 8) {
                    ErrorBox(banner)
                    if viewModel.isAdmin {
                        Button(viewModel.isConnecting ? "Connecting…" : "Reconnect Email") {
                            Task { await viewModel.connectTapped() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.isConnecting)
                    }
                }
                .padding(.bottom, 4)
            }
            Text("Connected Email")
                .font(.headline)
                .padding(.top, 4)
            // A reload failure shows above the list even when
            // connections are already on screen — never a silent
            // stale list, and never a grey muted line for an error.
            // The error + Retry stay until a load succeeds — never
            // a false "None." (audit S-P1-2).
            if viewModel.loadFailed {
                ErrorBox(viewModel.loadError ?? "Could not load email connections.")
                Button("Retry") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(TertiaryButtonStyle())
            }
            if viewModel.isLoading && viewModel.connections.isEmpty {
                // Reload with an empty list (first load is gated
                // above): connection-row skeletons, not the branded
                // loader — the loader is not shaped like the rows.
                // Enough rows to fill the visible page (owner,
                // Nov 26, 2026), not just the two-row list.
                ForEach(0..<connectionSkeletonRowCount, id: \.self) { _ in
                    connectionRowSkeleton
                }
            } else if !viewModel.connections.isEmpty {
                ForEach(viewModel.connections) { connection in
                    connectionRow(connection)
                }
            } else if !viewModel.loadFailed {
                MutedLine(text: viewModel.isAdmin ? "None — connect an email below." : "None — the admin connects email alerts.")
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
                    // Build 74 (B22): the shared InfoBox, not a
                    // hand-rolled blue box.
                    InfoBox(message)
                }
            }
            }
        }
        .task { await viewModel.load() }
        .onDisappear {
            // The Gmail callback line is a one-time delivery notice
            // (audit F-P1-7): clear it when leaving, after the live
            // connection status has been re-read — otherwise it
            // survives across launches indefinitely as stale state.
            appState.clearGmailCallbackResult()
        }
        // ONE dialog for the whole screen (build 30 — same stacked
        // `.alert` collapse as the Members screen; build 74: the
        // app-styled choice dialog, one modifier, one switch).
        .appConfirmDialog(item: $viewModel.alert) { alert in
            switch alert {
            case .disconnect(let connection):
                return AppConfirmDialog.Config(
                    title: "Disconnect Email",
                    message: "Disconnect \(connection.emailAddress)? The app will stop checking it. Past transactions stay in the list.",
                    primaryTitle: "Disconnect",
                    tone: .destructive,
                    onPrimary: { Task { await viewModel.disconnectConfirmed(connection) } }
                )
            case .disconnectFailed:
                return AppConfirmDialog.Config(
                    title: "Could Not Disconnect",
                    message: "Could not disconnect this email. Try again.",
                    primaryTitle: "Close",
                    secondaryTitle: nil,
                    onPrimary: {}
                )
            }
        }
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        // The picker is a NavigationStack + List, so it fills the
        // full screen and starts at the top. Build 70, items 2+5
        // (owner, Nov 24, 2026): the toolbar Cancel is now a back
        // chevron top left (the dismiss path), and swipe-right
        // dismisses too — Cancel was a redundant third way out.
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.householdChoices != nil },
            set: { if !$0 { viewModel.cancelHouseholdChoice() } }
        )) {
            if let choices = viewModel.householdChoices {
                householdPickerSheet(choices: choices)
            }
        }
    }

    /// Loading skeletons shaped like the loaded card (Nov 26,
    /// 2026): "Connected Email" heading, connection rows,
    /// Connect / Check buttons (admin only — `isAdmin` comes from
    /// the sync context, so the shape is known before the load).
    /// The rows fill the visible page (owner, Nov 26, 2026 —
    /// skeletons must fill the whole visible page, not just the
    /// two-row representative list); the card still settles
    /// shorter once the real (smaller) list lands — that
    /// one-time swap is accepted. A connection row is ~50pt tall
    /// in a 12pt-spaced stack (62pt pitch); the rows start
    /// ~160pt down the page (page title + card top + heading).
    private var connectionSkeletonRowCount: Int {
        SkeletonFill.rows(rowHeight: 62, above: 160)
    }

    private var emailLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(width: 150, height: 20)
            ForEach(0..<connectionSkeletonRowCount, id: \.self) { _ in
                connectionRowSkeleton
            }
            if viewModel.isAdmin {
                HStack(spacing: 12) {
                    SkeletonBlock(width: 140, height: 44, cornerRadius: 10)
                    SkeletonBlock(width: 150, height: 44, cornerRadius: 10)
                }
            }
        }
    }

    /// One connection-row skeleton: three text lines + Disconnect
    /// button, matching the loaded row's shape.
    private var connectionRowSkeleton: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 200, height: 14)
                SkeletonBlock(width: 100, height: 12)
                SkeletonBlock(width: 160, height: 12)
            }
            Spacer()
            SkeletonBlock(width: 92, height: 32, cornerRadius: 10)
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
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { viewModel.cancelHouseholdChoice() }
                }
            }
        }
        // iPad width (owner, Nov 12, 2026): 600pt width in the
        // regular size class in the full-screen cover; full-width
        // on iPhone.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 70, item 2: swipe-right dismisses the cover,
        // matching the back chevron. (No SheetHeader here, so the
        // gesture does not come from there.)
        .sheetSwipeBack()
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
                } else {
                    // A healthy row shows the bare word "Connected"
                    // (audit S-P2-4; standing rule: email status is
                    // just "Connected").
                    Text("Connected")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
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
                    Text(EmailAlertsViewModel.plainLastError(lastError))
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            Spacer()
            if viewModel.isAdmin {
                Button("Disconnect") {
                    viewModel.confirmDisconnect(connection)
                }
                .buttonStyle(SmallDangerButtonStyle())
                .accessibilityLabel("Disconnect \(connection.emailAddress)")
            }
        }
    }
}
