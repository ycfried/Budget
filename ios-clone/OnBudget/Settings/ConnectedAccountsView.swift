// OnBudget — Settings: Bank Connection card (live web v66, §10.2).
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
// (LinkKit) is NOT linked in this build — there is no Xcode on this
// VM to verify the SDK wiring against, and an unverified SDK call
// would break the CI build. `PlaidLinkLauncher` is the seam: the
// token fetch, the Already-Connected guard, and the exchange are all
// wired; the launcher itself is `PlaidLinkNotLinkedLauncher` until
// the SDK is added. See `ios-clone/docs/PLAID_INTEGRATION.md` for the
// exact remaining steps. The Connect button NEVER fakes a connected
// state: without the SDK it shows an honest error toast.

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

    var errorDescription: String? {
        switch self {
        case .sdkNotLinked:
            return "Plaid Link isn't linked in this build yet — the LinkKit package still needs adding (see ios-clone/docs/PLAID_INTEGRATION.md)."
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
        "Connected \(MoneyFormat.fmtLong(String(item.createdAt.prefix(10))))"
    }
}

@MainActor
final class ConnectedAccountsViewModel: ObservableObject {
    @Published var rows: [ConnectedAccountRow] = []
    @Published var syncLine = "Not synced yet."
    @Published var syncStale = false
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published var autoSyncOn = false
    @Published var isTogglingAutoSync = false
    @Published var nicknameTarget: ConnectedAccountRow?
    @Published var nicknameText = ""
    @Published var nicknameFailed = false
    @Published var disconnectTarget: ConnectedAccountRow?
    @Published var disconnectFailed = false
    @Published var alreadyConnectedLines: [String]?
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
            // Auto-sync is server truth; a failed read leaves the
            // switch off rather than showing a wrong state.
            autoSyncOn = (try? await context.client.postgrest.autoSyncEnabled(householdId: context.householdId)) ?? false
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
                syncLine = "Last synced \(MoneyFormat.fmtDateTime(householdLastSync))"
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
        } catch {
            loadError = "Could not load bank accounts."
            syncLine = "Could not load bank accounts."
        }
    }

    // MARK: - Connect New Account

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
                alreadyConnectedLines = lines
                return
            }
        } catch {
            // Fail open: proceed to Link.
        }
        await startLink()
    }

    func connectAnywayConfirmed() async {
        alreadyConnectedLines = nil
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
            toast.showError("Could not start the bank connection: \(settingsErrorMessage(error)). If it says \"not configured,\" the bank connection is not set up on the server yet.")
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
                    toast.show("Connected. Tap \"Sync Transactions\" to pull transactions.")
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
            if let message {
                toast.showError("Bank connection closed: \(message)")
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
            toast.show(text, kind: isError ? .error : .info)
            await load()
        } catch {
            toast.showError("Sync failed: \(settingsErrorMessage(error))")
        }
    }

    // MARK: - Automatic Sync

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
                let why = first.error.map { ": \($0)" } ?? ""
                let more = failed.count > 1 ? " (+\(failed.count - 1) more)" : ""
                toast.showError("Automatic sync could not be \(target ? "turned on" : "turned off") — \(name) failed\(why)\(more). Nothing was changed; the switch stays \(target ? "off" : "on").")
                return
            }
            autoSyncOn = target
            toast.show(target
                ? "Automatic sync on. New transactions will be pulled in on your next refresh."
                : "Automatic sync off.")
            await load()
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
            nicknameFailed = true
        }
    }

    // MARK: - Disconnect

    func disconnectConfirmed() async {
        guard let row = disconnectTarget else { return }
        disconnectTarget = nil
        do {
            if let account = row.account {
                let result = try await context.client.functions.plaidAccountDisconnect(
                    householdId: context.householdId,
                    plaidItemId: row.item.plaidItemId,
                    plaidAccountId: account.plaidAccountId
                )
                guard result.disconnected else {
                    disconnectFailed = true
                    return
                }
            } else {
                let result = try await context.client.functions.plaidDisconnect(
                    householdId: context.householdId,
                    plaidItemId: row.item.plaidItemId
                )
                guard result.disconnected else {
                    disconnectFailed = true
                    return
                }
            }
            await load()
        } catch {
            disconnectFailed = true
        }
    }
}

// MARK: - View

struct ConnectedAccountsView: View {
    @StateObject private var viewModel: ConnectedAccountsViewModel

    init(context: SettingsContext, toast: ToastState, plaidLauncher: PlaidLinkLauncher = PlaidLinkNotLinkedLauncher()) {
        _viewModel = StateObject(wrappedValue: ConnectedAccountsViewModel(context: context, toast: toast, plaidLauncher: plaidLauncher))
    }

    var body: some View {
        SettingsCard(title: "Bank Connection") {
            Text("Look only — it never moves, sends, or changes anything.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))

            if viewModel.isAdmin {
                HStack(spacing: 12) {
                    Button(viewModel.isConnecting ? "Connecting…" : "Connect New Account") {
                        Task { await viewModel.connectTapped() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isConnecting)
                    Button(viewModel.isSyncing ? "Syncing…" : "Sync Transactions") {
                        Task { await viewModel.syncTapped() }
                    }
                    .buttonStyle(TertiaryButtonStyle())
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
                .disabled(viewModel.isTogglingAutoSync)
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
            if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView()
            } else if let error = viewModel.loadError {
                ErrorBox(message: error)
            } else if viewModel.rows.isEmpty {
                MutedLine(text: "None.")
            } else {
                ForEach(viewModel.rows) { row in
                    accountRow(row)
                }
            }
        }
        .task { await viewModel.load() }
        .alert(item: Binding(
            get: { viewModel.alreadyConnectedLines.map { AlreadyConnectedAlert(lines: $0) } },
            set: { if $0 == nil { viewModel.alreadyConnectedLines = nil } }
        )) { alert in
            Alert(
                title: Text("Already Connected?"),
                message: Text("You already have \(alert.lines.count == 1 ? "this bank connection" : "these bank connections"):\n\(alert.lines.joined(separator: "\n"))\n\nConnecting the same account again will create a duplicate. You do not need to reconnect an account that is already syncing — only continue if you are connecting a different account."),
                primaryButton: .default(Text("Connect Anyway")) {
                    Task { await viewModel.connectAnywayConfirmed() }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $viewModel.disconnectTarget) { row in
            if row.account != nil {
                let label = "\(row.displayName)\(row.account?.mask.map { " ••\($0)" } ?? "")"
                return Alert(
                    title: Text("Disconnect Account"),
                    message: Text("Disconnect \(label)? This stops syncing this account only. Other accounts on the same bank connection keep syncing. Past transactions stay in the list. To sync this account again later, reconnect the bank from the Bank Connection card."),
                    primaryButton: .destructive(Text("Disconnect")) {
                        Task { await viewModel.disconnectConfirmed() }
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("Disconnect Bank"),
                message: Text("Disconnect \(row.item.institutionName ?? "this bank")? The app will stop syncing this connection. Past transactions stay in the list."),
                primaryButton: .destructive(Text("Disconnect")) {
                    Task { await viewModel.disconnectConfirmed() }
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Could not disconnect", isPresented: $viewModel.disconnectFailed) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("Could not disconnect this account. Try again.")
        }
        .alert("Could not save nickname", isPresented: $viewModel.nicknameFailed) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("Could not save this nickname. Try again.")
        }
        .sheet(item: $viewModel.nicknameTarget) { row in
            nicknameSheet(for: row)
        }
    }

    private struct AlreadyConnectedAlert: Identifiable {
        let lines: [String]
        var id: String { lines.joined(separator: "|") }
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
                    Button(row.nickname == nil ? "Add nickname" : "Edit nickname") {
                        viewModel.editNickname(row)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            Spacer()
            if viewModel.isAdmin {
                Button("Disconnect") {
                    viewModel.disconnectTarget = row
                }
                .buttonStyle(SmallDangerButtonStyle())
                .accessibilityLabel("Disconnect \(row.displayName)")
            }
        }
    }

    private func nicknameSheet(for row: ConnectedAccountRow) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Give this account a short name (up to 40 characters). Leave it blank to remove the nickname. The nickname is only a label — it never changes bank links, matching, or week math.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                TextField("Nickname", text: $viewModel.nicknameText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button("Save") {
                        Task { await viewModel.saveNickname() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel") {
                        viewModel.nicknameTarget = nil
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Nickname")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
