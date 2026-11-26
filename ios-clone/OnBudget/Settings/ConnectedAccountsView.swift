// STAGE — Settings: Bank Connection card (live web v66, §10.2).
//
// One row per account (bank favicon + brand monogram fallback, name
// bold, "Bank · plain type · ••mask", admin-only nickname + own
// Disconnect). Auto-sync toggle, Sync Transactions, Connect New
// Account via Plaid Link.
//
// Wiring (exact API calls):
// - Reads: `PostgrestClient.plaidItems(householdId:)` (public view),
//   `plaidAccounts(itemIds:)` (disconnected_at rows are NOT rendered),
//   `accountNicknames(householdId:)` (soft-fails: nicknames just
//   don't show), `autoSyncEnabled(householdId:)` (server truth;
//   a failed read leaves the switch off).
// - Nickname: RPC `set_account_nickname(p_household_id,
//   p_plaid_item_id, p_plaid_account_id, p_card_suffix, p_nickname)`
//   (nil clears).
// - Per-account disconnect: Edge Function `plaid-account-disconnect`
//   (app-level `disconnected_at`; sync skips disconnected accounts;
//   last-active disconnect also removes the Plaid item —
//   `item_disconnected` in the response). Whole-item disconnect
//   (items with no accounts at all): `plaid-disconnect`.
// - Sync: `EdgeFunctionsClient.plaidSyncAllowingPartialFailure(_:)`
//   (502 partial failure keeps counts + failed institutions; the
//   toast names them). One sync at a time — a repeat tap is ignored.
// - Auto-sync toggle: `plaid-webhook-register` (enabled true/false;
//   empty-string webhook clears it server-side). A partial failure
//   stores NOTHING — the switch stays where it was.
// - Connect: `plaid-link` -> link token, then Plaid Link, then
//   `plaid-exchange` (public token + institution name).
//
// PLAID LINK INTEGRATION POINT: the official Plaid iOS SDK
// (LinkKit 7.x) IS linked in this build — see
// `OnBudget/Settings/PlaidLinkKitLauncher.swift` (the real
// `PlaidLinkLauncher`, session-based API) and
// `ios-clone/docs/PLAID_INTEGRATION.md`. The app coordinator
// (`AppShellView`) passes the real launcher into `SettingsView`;
// `PlaidLinkNotLinkedLauncher` below remains only as the default
// for previews / call sites that have no SDK session. The Connect
// button NEVER fakes a connected state: without a successful Link
// session it shows an honest error toast (or nothing on cancel).

import SwiftUI
import OnBudgetKit

// MARK: - Plaid Link integration point

/// The result of a Plaid Link session.
enum PlaidLinkOutcome {
    /// The user approved a bank; `publicToken` goes to
    /// `plaid-exchange`, `institutionName` is Plaid's institution.
    case success(publicToken: String, institutionName: String?)
    /// Link closed with an error (or the user cancelled with a
    /// message). `nil` message = plain user cancel: show nothing.
    case exited(errorMessage: String?)
}

/// Presents Plaid Link for a link token and reports the outcome.
/// The real implementation uses the official Plaid iOS SDK
/// (LinkKit) — see `ios-clone/docs/PLAID_INTEGRATION.md`.
protocol PlaidLinkLauncher {
    func present(linkToken: String) async throws -> PlaidLinkOutcome
}

enum PlaidLinkError: Error, LocalizedError {
    /// The LinkKit package is not linked in this build yet.
    case sdkNotLinked
    /// Link was asked to open but there is no view controller to
    /// present it from.
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .sdkNotLinked:
            return "The bank connection is not set up in this build yet. Try again later."
        case .presentationUnavailable:
            return "Could not open the bank connection — there is no screen to present it from."
        }
    }
}

/// Placeholder launcher: throws `PlaidLinkError.sdkNotLinked`.
/// The Connect flow surfaces that message honestly and never claims
/// a bank was connected.
struct PlaidLinkNotLinkedLauncher: PlaidLinkLauncher {
    func present(linkToken: String) async throws -> PlaidLinkOutcome {
        throw PlaidLinkError.sdkNotLinked
    }
}

// MARK: - View model

/// One rendered row: an account on an item, or a whole item with no
/// accounts (which keeps the old whole-item Disconnect).
struct ConnectedAccountRow: Identifiable {
    let id: String
    let item: PlaidItemPublic
    let account: PlaidAccount?
    let nickname: String?
    let syncFailed: Bool

    var displayName: String {
        if let account {
            return nickname ?? account.name ?? "Account"
        }
        return item.institutionName ?? "Bank"
    }

    var metaLine: String {
        guard let account else { return "" }
        let plainType = account.plainType
        return [
            item.institutionName ?? "Bank",
            plainType,
            account.mask.map { "••\($0)" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var connectedLine: String {
        "Connected \(OnBudgetKit.MoneyFormat.fmtLong(String(item.createdAt.prefix(10))))"
    }
}

@MainActor
final class ConnectedAccountsViewModel: ObservableObject {
    @Published var rows: [ConnectedAccountRow] = []
    @Published var syncLine = "Not synced yet."
    @Published var syncStale = false
    @Published var loadError: String?
    /// True after a failed load until a load succeeds. The card
    /// shows the error + Retry while this is set — never a false
    /// "None." (audit S-P1-2).
    @Published var loadFailed = false
    @Published var isLoading = false
    /// Loading-state gate (Nov 26, 2026 — Funds-page pattern): true
    /// once the FIRST load has resolved (success or failure). The
    /// card shows skeletons shaped like its content until then.
    /// Before this the card rendered immediately with the
    /// auto-sync toggle defaulting OFF, the sync line reading
    /// "Not synced yet.", and the rows popping in below — the
    /// toggle flipped, the line changed, and the Email Alerts card
    /// underneath slid down as the rows landed. Reloads keep the
    /// stale rows on screen; this flag stays true.
    @Published var hasLoaded = false
    @Published var isSyncing = false
    @Published var autoSyncOn = false
    /// True when the server value could not be read: the toggle keeps
    /// its previous value, is disabled, and shows a note — it must
    /// never silently show OFF while syncs are running (owner report,
    /// Nov 11, 2026: toggle OFF, last synced 6:00 PM).
    @Published var autoSyncUnknown = false
    @Published var isTogglingAutoSync = false
    @Published var nicknameTarget: ConnectedAccountRow?
    @Published var nicknameText = ""
    /// The ONE alert this screen can show (build 30): the four
    /// `.alert` modifiers this screen used to stack (Already
    /// Connected, Disconnect confirm/failed, Nickname failed)
    /// collapsed into one — SwiftUI only honours a single `.alert`
    /// on a view, so only one ever fired (same bug as the Members
    /// screen, Nov 15, 2026).
    @Published var alert: ConnectedAccountsAlert?

    /// The single alert state for the Connected Accounts screen
    /// (build 30). One `.alert(item:)` in the view switches over
    /// the case.
    enum ConnectedAccountsAlert: Identifiable {
        case alreadyConnected([String])
        case disconnect(ConnectedAccountRow)
        case disconnectFailed
        case nicknameFailed

        var id: String {
            switch self {
            case .alreadyConnected(let lines): return "already-\(lines.joined(separator: "|"))"
            case .disconnect(let row): return "disconnect-\(row.id)"
            case .disconnectFailed: return "disconnectFailed"
            case .nicknameFailed: return "nicknameFailed"
            }
        }
    }
    @Published var isConnecting = false

    private let context: SettingsContext
    private let toast: ToastState
    private let plaidLauncher: PlaidLinkLauncher

    init(context: SettingsContext, toast: ToastState, plaidLauncher: PlaidLinkLauncher = PlaidLinkNotLinkedLauncher()) {
        self.context = context
        self.toast = toast
        self.plaidLauncher = plaidLauncher
    }

    var isAdmin: Bool { context.isAdmin }

    // MARK: - Load

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await context.client.postgrest.plaidItems(householdId: context.householdId)
            let itemIds = items.map { $0.plaidItemId }
            let accounts = try await context.client.postgrest.plaidAccounts(itemIds: itemIds)
            // Nicknames fail soft: the list still renders without them.
            let nicknames = (try? await context.client.postgrest.accountNicknames(householdId: context.householdId)) ?? []
            // Auto-sync is server truth. A failed read keeps the
            // previous value and disables the toggle with a note —
            // it never silently shows OFF.
            if let enabled = try? await context.client.postgrest.autoSyncEnabled(householdId: context.householdId) {
                autoSyncOn = enabled
                autoSyncUnknown = false
            } else {
                autoSyncUnknown = true
            }
            let nicknameByAccount: [String: String] = Dictionary(
                nicknames.compactMap { nick in
                    guard let name = nick.nickname else { return nil }
                    return ("\(nick.plaidItemId)|\(nick.plaidAccountId)", name)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let syncTimes = items.compactMap { $0.lastSyncAt }.sorted()
            let householdLastSync = syncTimes.last
            if let householdLastSync {
                syncLine = "Last synced \(OnBudgetKit.MoneyFormat.fmtDateTime(householdLastSync))"
            } else {
                syncLine = "Not synced yet."
            }
            let activeSyncTimes = items.filter { $0.status != "disconnected" }.compactMap { $0.lastSyncAt }.sorted()
            if let stalest = activeSyncTimes.first,
               let stalestDate = ISO8601DateFormatter().date(from: stalest) {
                syncStale = Date().timeIntervalSince(stalestDate) > 180 * 60
            } else {
                syncStale = false
            }
            var built: [ConnectedAccountRow] = []
            for item in items where item.isActive {
                let itemAccounts = accounts.filter { $0.plaidItemId == item.plaidItemId && !$0.isDisconnected }
                if itemAccounts.isEmpty {
                    // Only items with NO accounts at all get a
                    // whole-item row (and its whole-item Disconnect).
                    let hasAnyAccount = accounts.contains { $0.plaidItemId == item.plaidItemId }
                    if !hasAnyAccount {
                        built.append(ConnectedAccountRow(
                            id: "item:\(item.plaidItemId)", item: item, account: nil,
                            nickname: nil, syncFailed: false
                        ))
                    }
                    continue
                }
                for account in itemAccounts {
                    let syncFailed = item.lastSyncAt != nil && householdLastSync != nil
                        && item.lastSyncAt! < householdLastSync!
                    built.append(ConnectedAccountRow(
                        id: "account:\(item.plaidItemId)|\(account.plaidAccountId)",
                        item: item, account: account,
                        nickname: nicknameByAccount["\(item.plaidItemId)|\(account.plaidAccountId)"],
                        syncFailed: syncFailed
                    ))
                }
            }
            rows = built
            loadError = nil
            loadFailed = false
        } catch {
            loadError = "Could not load bank accounts."
            loadFailed = true
        }
        hasLoaded = true
    }

    // MARK: - Connect Account

    func connectTapped() async {
        guard isAdmin, !isConnecting else { return }
        // Already Connected? guard (fails OPEN — a failed read never
        // blocks a first or legitimate connection).
        do {
            let activeItems = try await context.client.postgrest.activePlaidItems(householdId: context.householdId)
            if !activeItems.isEmpty {
                let accounts = try await context.client.postgrest.plaidAccounts(itemIds: activeItems.map { $0.plaidItemId })
                let lines = activeItems.map { item in
                    let parts = accounts
                        .filter { $0.plaidItemId == item.plaidItemId }
                        .map { "\($0.name ?? "Account")\($0.mask.map { " ••\($0)" } ?? "")" }
                    return "\(item.institutionName ?? "Bank") — \(parts.isEmpty ? "no accounts listed yet" : parts.joined(separator: ", "))"
                }
                alert = .alreadyConnected(lines)
                return
            }
        } catch {
            // Fail open: proceed to Link.
        }
        await startLink()
    }

    func connectAnywayConfirmed() async {
        alert = nil
        await startLink()
    }

    private func startLink() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        toast.show("Getting a secure bank connection…")
        let linkToken: PlaidLinkToken
        do {
            linkToken = try await context.client.functions.plaidLink(householdId: context.householdId)
        } catch {
            toast.showError("Could not start the bank connection: \(settingsErrorMessage(error)).")
            return
        }
        let outcome: PlaidLinkOutcome
        do {
            outcome = try await plaidLauncher.present(linkToken: linkToken.linkToken)
        } catch {
            toast.showError(settingsErrorMessage(error))
            return
        }
        switch outcome {
        case .success(let publicToken, let institutionName):
            toast.show("Bank approved — finishing the secure connection…")
            do {
                let exchanged = try await context.client.functions.plaidExchange(
                    householdId: context.householdId,
                    publicToken: publicToken,
                    institutionName: institutionName
                )
                if exchanged.connected {
                    // Build 50 (owner, Nov 20, 2026): a new bank
                    // connection enables automatic sync (Plaid
                    // webhooks) right away — the owner decided
                    // webhooks are worth it (Nov 17), and the
                    // webhook used to need a manual toggle flip in
                    // Settings. Best-effort: a failed register
                    // never fails the connection itself, and the
                    // toggle stays available in Settings. The
                    // toast only claims auto-sync is on when the
                    // register actually succeeded.
                    var autoSyncEnabled = false
                    do {
                        let result = try await context.client.functions.plaidWebhookRegister(
                            householdId: context.householdId, enabled: true)
                        autoSyncEnabled = !result.results.isEmpty && result.results.allSatisfy(\.ok)
                    } catch {
                        autoSyncEnabled = false
                    }
                    if autoSyncEnabled {
                        toast.show("Connected. Automatic sync is on — new transactions will be pulled in on your next refresh.", kind: .success)
                    } else {
                        toast.show("Connected. Tap \"Sync Transactions\" to pull transactions.", kind: .success)
                    }
                    await load()
                } else if exchanged.duplicate {
                    toast.show("This bank is already connected — the duplicate connection was removed. Past transactions stay.")
                } else {
                    toast.showError("Connection could not be finished: unknown error")
                }
            } catch {
                toast.showError("Connection could not be finished: \(settingsErrorMessage(error))")
            }
        case .exited(let message):
            // The SDK's exit text is internal wording — never shown.
            // Nil message = the user cancelled: show nothing.
            if message != nil {
                toast.showError("The bank connection didn't finish. Try again.")
            }
        }
    }

    // MARK: - Sync Transactions

    func syncTapped() async {
        guard isAdmin, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        toast.show("Syncing bank transactions…")
        do {
            let outcome = try await context.client.functions.plaidSyncAllowingPartialFailure(householdId: context.householdId)
            let (text, isError): (String, Bool)
            switch outcome {
            case .success(let result):
                (text, isError) = BankSyncToast.text(
                    error: nil, added: result.added, updated: result.updated,
                    skipped: result.skipped, items: result.items,
                    duplicateRemoved: result.duplicateRemoved ?? [],
                    stale: result.stale, minutesSincePreviousSync: result.minutesSincePreviousSync,
                    skippedByReason: result.skippedByReason, failedInstitutions: []
                )
            case .partial(let partial):
                (text, isError) = BankSyncToast.text(
                    error: nil, added: partial.result.added, updated: partial.result.updated,
                    skipped: partial.result.skipped, items: partial.result.items,
                    duplicateRemoved: partial.result.duplicateRemoved ?? [],
                    stale: partial.result.stale, minutesSincePreviousSync: partial.result.minutesSincePreviousSync,
                    skippedByReason: partial.result.skippedByReason,
                    failedInstitutions: partial.failedInstitutions
                )
            }
            toast.show(text, kind: isError ? .error : .success)
            await load()
        } catch {
            toast.showError("Sync failed: \(settingsErrorMessage(error))")
        }
    }

    // MARK: - Automatic Sync

    /// Toggles automatic sync. The success message is shown ONLY
    /// after a fresh server read confirms the new flag value — never
    /// on the write's optimistic return. The owner's build showed a
    /// success banner and then the switch fell back to OFF, because
    /// the post-write reload re-read a broken flag value; a banner
    /// must never claim success the server has not confirmed.
    func setAutoSync(target: Bool) async {
        guard isAdmin, !isTogglingAutoSync else { return }
        isTogglingAutoSync = true
        defer { isTogglingAutoSync = false }
        toast.show(target ? "Enabling automatic sync…" : "Turning off automatic sync…")
        do {
            let result = try await context.client.functions.plaidWebhookRegister(
                householdId: context.householdId, enabled: target
            )
            guard !result.results.isEmpty else {
                toast.showError("No bank connection yet — connect a bank account first.")
                return
            }
            let failed = result.results.filter { !$0.ok }
            if !failed.isEmpty {
                let first = failed[0]
                let name = first.institution ?? "A bank connection"
                let more = failed.count > 1 ? " (+\(failed.count - 1) more)" : ""
                // Plain language only — the server's per-item error
                // text never reaches the user (audit S-P1-3).
                toast.showError("Automatic sync could not be \(target ? "turned on" : "turned off") — \(name) failed\(more). Nothing was changed; the switch stays \(target ? "off" : "on").")
                return
            }
            // Confirm against the server before claiming anything:
            // load() re-reads households.auto_sync_enabled, so after
            // it autoSyncOn IS the server value (or autoSyncUnknown
            // when the read failed, with the old value kept).
            await load()
            if autoSyncUnknown {
                toast.showError("Automatic sync could not be confirmed — the switch was not changed. Check your connection and try again.")
                return
            }
            if autoSyncOn == target {
                toast.show(target
                    ? "Automatic sync on. New transactions will be pulled in on your next refresh."
                    : "Automatic sync off.", kind: .success)
            } else {
                toast.showError("Automatic sync could not be \(target ? "turned on" : "turned off") — the switch stays \(target ? "off" : "on"). Try again.")
            }
        } catch {
            toast.showError("Could not \(target ? "enable" : "turn off") automatic sync: \(settingsErrorMessage(error))")
        }
    }

    // MARK: - Nickname

    func editNickname(_ row: ConnectedAccountRow) {
        nicknameTarget = row
        nicknameText = row.nickname ?? ""
    }

    func saveNickname() async {
        guard let row = nicknameTarget, let account = row.account else { return }
        let trimmed = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        do {
            try await context.client.rpcs.setAccountNickname(
                pHouseholdId: context.householdId,
                pPlaidItemId: row.item.plaidItemId,
                pPlaidAccountId: account.plaidAccountId,
                pCardSuffix: account.mask,
                pNickname: nickname
            )
            nicknameTarget = nil
            await load()
        } catch {
            alert = .nicknameFailed
        }
    }

    // MARK: - Disconnect

    func confirmDisconnect(_ row: ConnectedAccountRow) {
        alert = .disconnect(row)
    }

    /// The row arrives as a parameter, captured by the alert's
    /// button: `.alert(item:)` nils the `alert` binding when the
    /// alert dismisses, which happens BEFORE an unstructured `Task`
    /// runs — so re-reading the binding here always found nil and
    /// the disconnect silently never happened (same pitfall as
    /// removeConfirmed, Nov 11, 2026).
    func disconnectConfirmed(_ row: ConnectedAccountRow) async {
        alert = nil
        do {
            if let account = row.account {
                let result = try await context.client.functions.plaidAccountDisconnect(
                    householdId: context.householdId,
                    plaidItemId: row.item.plaidItemId,
                    plaidAccountId: account.plaidAccountId
                )
                guard result.disconnected else {
                    alert = .disconnectFailed
                    return
                }
            } else {
                let result = try await context.client.functions.plaidDisconnect(
                    householdId: context.householdId,
                    plaidItemId: row.item.plaidItemId
                )
                guard result.disconnected else {
                    alert = .disconnectFailed
                    return
                }
            }
            await load()
        } catch {
            alert = .disconnectFailed
        }
    }
}

// MARK: - View

struct ConnectedAccountsView: View {
    @StateObject private var viewModel: ConnectedAccountsViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Build 68 (item 14): the nickname explainer behind the ⓘ.
    @State private var showingNicknameInfo = false

    init(context: SettingsContext, toast: ToastState, plaidLauncher: PlaidLinkLauncher = PlaidLinkNotLinkedLauncher()) {
        _viewModel = StateObject(wrappedValue: ConnectedAccountsViewModel(context: context, toast: toast, plaidLauncher: plaidLauncher))
    }

    var body: some View {
        SettingsCard(title: "Bank Connection") {
            // Loading-state gate (Nov 26, 2026 — Funds-page
            // pattern): skeletons shaped like the card until the
            // first load resolves, so the toggle never flashes the
            // wrong OFF, the sync line never flashes "Not synced
            // yet.", and the rows never push the card below down.
            if !viewModel.hasLoaded {
                connectedLoadingSkeleton
            } else {
            if viewModel.isAdmin {
                HStack(spacing: 12) {
                    Button(viewModel.isConnecting ? "Connecting…" : "Connect Account") {
                        Task { await viewModel.connectTapped() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("bank.connect")
                    .disabled(viewModel.isConnecting)
                    Button(viewModel.isSyncing ? "Syncing…" : "Sync Transactions") {
                        Task { await viewModel.syncTapped() }
                    }
                    .buttonStyle(TertiaryButtonStyle())
                    .accessibilityIdentifier("bank.sync")
                    .disabled(viewModel.isSyncing)
                }

                Toggle(isOn: Binding(
                    get: { viewModel.autoSyncOn },
                    set: { newValue in Task { await viewModel.setAutoSync(target: newValue) } }
                )) {
                    Text("Automatic Sync")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .tint(DesignTokens.primary)
                .disabled(viewModel.isTogglingAutoSync || viewModel.autoSyncUnknown)
                if viewModel.autoSyncUnknown {
                    Text("Could not check automatic sync.")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }

            Text(viewModel.syncLine)
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            if viewModel.syncStale {
                Text("Bank sync is stale — the last sync was over 3 hours ago.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignTokens.errorText)
            }

            Text("Connected Accounts")
                .font(.headline)
                .padding(.top, 4)
            // A failed load shows the error + Retry and stays there
            // until a load succeeds — never a false "None." (audit
            // S-P1-2). Stale rows still render underneath the error.
            if viewModel.loadFailed {
                ErrorBox(viewModel.loadError ?? "Could not load bank accounts.")
                Button("Retry") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(TertiaryButtonStyle())
            }
            if viewModel.isLoading && viewModel.rows.isEmpty {
                // Reload with an empty list (first load is gated
                // above): account-row skeletons, not the branded
                // loader — the loader is not shaped like the rows.
                accountRowSkeleton
                accountRowSkeleton
            } else if !viewModel.rows.isEmpty {
                ForEach(viewModel.rows) { row in
                    accountRow(row)
                }
            } else if !viewModel.loadFailed {
                MutedLine(text: "None.")
            }
            }
        }
        .task { await viewModel.load() }
        // ONE dialog for the whole screen (build 30 — same stacked
        // `.alert` collapse as the Members screen: only one of the
        // four stacked modifiers ever fired; build 74: the
        // app-styled choice dialog, one modifier, one switch).
        .appConfirmDialog(item: $viewModel.alert) { alert in
            switch alert {
            case .alreadyConnected(let lines):
                return AppConfirmDialog.Config(
                    title: "Already Connected?",
                    message: "You already have \(lines.count == 1 ? "this bank connection" : "these bank connections"):\n\(lines.joined(separator: "\n"))\n\nConnecting the same account again will create a duplicate. You do not need to reconnect an account that is already syncing — only continue if you are connecting a different account.",
                    primaryTitle: "Connect Anyway",
                    onPrimary: { Task { await viewModel.connectAnywayConfirmed() } }
                )
            case .disconnect(let row):
                if row.account != nil {
                    let label = "\(row.displayName)\(row.account?.mask.map { " ••\($0)" } ?? "")"
                    return AppConfirmDialog.Config(
                        title: "Disconnect Account",
                        message: "Disconnect \(label)? This stops syncing this account only. Other accounts on the same bank connection keep syncing. Past transactions stay in the list. To sync this account again later, reconnect the bank from the Bank Connection card.",
                        primaryTitle: "Disconnect",
                        tone: .destructive,
                        onPrimary: { Task { await viewModel.disconnectConfirmed(row) } }
                    )
                }
                return AppConfirmDialog.Config(
                    title: "Disconnect Bank",
                    message: "Disconnect \(row.item.institutionName ?? "this bank")? The app will stop syncing this connection. Past transactions stay in the list.",
                    primaryTitle: "Disconnect",
                    tone: .destructive,
                    onPrimary: { Task { await viewModel.disconnectConfirmed(row) } }
                )
            case .disconnectFailed:
                return AppConfirmDialog.Config(
                    title: "Could Not Disconnect",
                    message: "Could not disconnect this account. Try again.",
                    primaryTitle: "Close",
                    secondaryTitle: nil,
                    onPrimary: {}
                )
            case .nicknameFailed:
                return AppConfirmDialog.Config(
                    title: "Could Not Save Nickname",
                    message: "Could not save this nickname. Try again.",
                    primaryTitle: "Close",
                    secondaryTitle: nil,
                    onPrimary: {}
                )
            }
        }
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(item: $viewModel.nicknameTarget) { row in
            nicknameSheet(for: row)
                // iPad width (owner, Nov 12, 2026): same treatment
                // as the Weekly Budget sheet — 600pt width in the
                // regular size class, in a full-screen cover.
        }
    }

    /// Loading skeletons shaped like the loaded card (Nov 26,
    /// 2026): Connect/Sync buttons + auto-sync toggle row (admin
    /// only — `isAdmin` comes from the sync context, so the shape
    /// is known before the load), sync line, "Connected Accounts"
    /// heading, two account rows. Two rows is representative; the
    /// real row count is only knowable after the load, so a
    /// household with more accounts still sees the card grow from
    /// skeleton to content.
    private var connectedLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isAdmin {
                HStack(spacing: 12) {
                    SkeletonBlock(width: 150, height: 44, cornerRadius: 10)
                    SkeletonBlock(width: 150, height: 44, cornerRadius: 10)
                }
                SkeletonBlock(width: 220, height: 32)
            }
            SkeletonBlock(width: 200, height: 16)
            SkeletonBlock(width: 170, height: 20)
            accountRowSkeleton
            accountRowSkeleton
        }
    }

    /// One account-row skeleton: bank logo tile + three text lines
    /// + Disconnect button, matching the loaded row's shape.
    private var accountRowSkeleton: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBlock(width: 40, height: 40, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 150, height: 14)
                SkeletonBlock(width: 180, height: 12)
                SkeletonBlock(width: 120, height: 12)
            }
            Spacer()
            SkeletonBlock(width: 92, height: 32, cornerRadius: 10)
        }
    }

    private func accountRow(_ row: ConnectedAccountRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BankLogoView(institutionName: row.item.institutionName)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.subheadline)
                    .fontWeight(.bold)
                if !row.metaLine.isEmpty {
                    Text(row.metaLine)
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#6b7280"))
                } else if row.account == nil {
                    MutedLine(text: "Account details unavailable.")
                }
                Text(row.connectedLine)
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                if row.syncFailed {
                    Text("Sync failed")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignTokens.errorText)
                }
                if viewModel.isAdmin, row.account != nil {
                    Button(row.nickname == nil ? "Add Nickname" : "Edit Nickname") {
                        viewModel.editNickname(row)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            Spacer()
            if viewModel.isAdmin {
                Button("Disconnect") {
                    viewModel.confirmDisconnect(row)
                }
                .buttonStyle(SmallDangerButtonStyle())
                .accessibilityLabel("Disconnect \(row.displayName)")
            }
        }
    }

    private func nicknameSheet(for row: ConnectedAccountRow) -> some View {
        // No NavigationStack root (owner, Nov 14, 2026 — same
        // sheet-sizing rule as the Actions sheet): a NavigationStack
        // reports an unbounded ideal height, so the fitted sheet
        // rendered tall and mostly empty. Plain VStack + SheetHeader
        // keeps the content at the top of the full-screen popup.
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Nickname", onClose: { viewModel.nicknameTarget = nil })
            // Build 68 (item 14): the long nickname explainer lives
            // behind a blue ⓘ — only a short line stays visible.
            HStack(spacing: 6) {
                Text("A short name for this account.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                Button { showingNicknameInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Nicknames")
            }
            .alert("Nickname", isPresented: $showingNicknameInfo) {
                Button("OK") {}
            } message: {
                Text("Give this account a short name (up to 40 characters). Leave it blank to remove the nickname. The nickname is only a label — it never changes bank links, matching, or week math.")
            }
            TextField("Nickname", text: $viewModel.nicknameText)
                // Light-grey filled field, no hard border (owner,
                // Nov 15, 2026): the .roundedBorder white box with
                // its thin grey border read stark against the soft
                // popup. Same treatment as the Search field
                // ("Search transactions", owner Nov 12, 2026):
                // systemGray6 fill, comfortably rounded, no border.
                // Build 68 (item 7/13): 48pt+ tall, 14pt horizontal
                // / 14pt vertical padding, 12pt radius.
                .font(.system(size: 17))
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            // Build 70, item 5 (owner, Nov 24, 2026): the Cancel
            // button is gone — the SheetHeader X + swipe-right
            // dismiss without saving, so Cancel was a third
            // redundant way out.
            Button("Save") {
                Task { await viewModel.saveNickname() }
            }
            .buttonStyle(PrimaryButtonStyle())
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // full-screen cover — without it the short form
            // centres itself vertically in the full screen.
            Spacer()
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }
}
