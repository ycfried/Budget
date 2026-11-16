import SwiftUI
import OnBudgetKit

// OnBudget — Settings: Merchant Names card (build 30, task E).
//
// The saved merchant-name rules: one pattern maps to a clean
// display name plus an optional fixed kind. Rules apply to every
// transaction kind, to old rows on rename and to new rows at
// ingestion. Admin-only — members never see the card at all (owner
// rule, Nov 13, 2026: no greyed-out controls, only actions that
// work). The pattern itself is immutable server-side: to teach a
// different spelling, delete the rule and add a new one.
//
// Wiring:
// - List: `PostgrestClient.merchantRules(householdId:)`.
// - Add: RPC `create_merchant_rule`.
// - Edit: RPC `update_merchant_rule` (display name / kind / match).
// - Delete: RPC `delete_merchant_rule` after one confirm.
// - Rename from a transaction: the Actions sheet ("Rename
//   Merchant") teaches the same rules; this card manages them.

@MainActor
final class MerchantNamesSettingsViewModel: ObservableObject {
    @Published var rules: [MerchantRule] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var loadFailed = false
    /// The ONE alert this screen can show (build 30 lesson: SwiftUI
    /// only honours a single `.alert` on a view — see
    /// MembersSettingsView).
    @Published var alert: MerchantNamesAlert?
    @Published var isSaving = false

    enum MerchantNamesAlert: Identifiable {
        case deleteRule(MerchantRule)
        case failed(title: String, message: String)

        var id: String {
            switch self {
            case .deleteRule(let rule): return "delete-\(rule.id.uuidString)"
            case .failed(let title, _): return "failed-\(title)"
            }
        }
    }

    private let context: SettingsContext
    private let toast: ToastState

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        self.toast = toast
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rules = try await context.client.postgrest.merchantRules(householdId: context.householdId)
            loadError = nil
            loadFailed = false
        } catch {
            loadError = OnBudgetError.displayMessage(for: error)
            loadFailed = true
        }
    }

    func saveRule(pattern: String, displayName: String, matchType: String, fixedKind: String?, editing: MerchantRule?) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            if let editing {
                try await context.client.rpcs.updateMerchantRule(
                    pRuleId: editing.id,
                    pDisplayName: displayName,
                    pFixedKind: fixedKind,
                    pMatchType: matchType
                )
                toast.show("Name updated.", kind: .success)
            } else {
                _ = try await context.client.rpcs.createMerchantRule(
                    pHouseholdId: context.householdId,
                    pPattern: pattern,
                    pMatchType: matchType,
                    pDisplayName: displayName,
                    pFixedKind: fixedKind
                )
                toast.show("Name saved.", kind: .success)
            }
            await load()
            return true
        } catch {
            alert = .failed(title: "Could Not Save Name", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    func deleteRule(_ rule: MerchantRule) async {
        do {
            try await context.client.rpcs.deleteMerchantRule(pRuleId: rule.id)
            toast.show("Name removed.", kind: .success)
            await load()
        } catch {
            alert = .failed(title: "Could Not Remove Name", message: OnBudgetError.displayMessage(for: error))
        }
    }
}

struct MerchantNamesSettingsView: View {
    @StateObject private var viewModel: MerchantNamesSettingsViewModel
    private let context: SettingsContext

    /// The rule being edited, or nil for the add form. The form
    /// opens as a sheet on Add or a row tap (build 33 — it used to
    /// render inline below the list, which was hard to use).
    @State private var editingRule: MerchantRule?
    @State private var showingForm = false
    @State private var patternText = ""
    @State private var displayNameText = ""
    @State private var matchType = "exact"
    @State private var fixedKind: String?

    /// Fixed-kind options: the server's kind values with plain
    /// labels (same list as the transaction Actions sheet).
    private static let fixedKindOptions: [(raw: String, label: String)] = [
        ("charge", "Charge"),
        ("refund", "Refund"),
        ("fund_charge", "Fund Charge"),
        ("payment", "Payment"),
        ("cashback", "Cash Back"),
        ("charity", "Charity"),
        ("transfer", "Transfer"),
        ("income", "Income"),
    ]

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        _viewModel = StateObject(wrappedValue: MerchantNamesSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        // Admin-only: members never see the card.
        if context.isAdmin {
            SettingsCard(title: "Merchant Names") {
                MutedLine(text: "Names you taught the app. A renamed merchant stays renamed on old and new rows.")
                if let loadError = viewModel.loadError {
                    DismissableErrorBox(loadError) {
                        viewModel.loadError = nil
                    }
                    Button("Try Again") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(TertiaryButtonStyle())
                } else if viewModel.isLoading && viewModel.rules.isEmpty {
                    HStack {
                        Spacer()
                        BrandedLoader()
                        Spacer()
                    }
                    .padding(.top, 8)
                } else if viewModel.rules.isEmpty {
                    MutedLine(text: "No merchant names taught yet. Rename a merchant from any transaction to teach the app.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.rules) { rule in
                            Button {
                                startEditing(rule)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(TitleCase.apply(to: rule.displayName.lowercased()))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(DesignTokens.ink)
                                        Text(ruleDetailLine(rule))
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(hex: "#6b7280"))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color(hex: "#6b7280"))
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if rule.id != viewModel.rules.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                Button("Add a Name") {
                    editingRule = nil
                    patternText = ""
                    displayNameText = ""
                    matchType = "exact"
                    fixedKind = nil
                    showingForm = true
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            // The editor is a proper sheet, not inline below the
            // list (owner, Nov 15, 2026 — build 33: the inline
            // editor was hard to use and not properly clickable,
            // though the idea and the fields were right). Same
            // fields, same behaviour — just presented as a sheet
            // with a header, like the other editors.
            .sheet(isPresented: $showingForm) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(title: editingRule == nil ? "Add a Name" : "Edit Name") {
                            showingForm = false
                            editingRule = nil
                        }
                        ruleForm
                    }
                    .padding()
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(.white)
                // The alert lives on the sheet (delete confirm +
                // save failures both come from this form).
                .alert(item: $viewModel.alert) { alert in
                    switch alert {
                    case .deleteRule(let rule):
                        return Alert(
                            title: Text("Remove This Name?"),
                            message: Text("“\(TitleCase.apply(to: rule.displayName.lowercased()))” will stop renaming “\(rule.patternText)” — old rows keep their current names."),
                            primaryButton: .destructive(Text("Remove")) {
                                Task { await viewModel.deleteRule(rule) }
                            },
                            secondaryButton: .cancel()
                        )
                    case .failed(let title, let message):
                        return Alert(
                            title: Text(title),
                            message: Text(message),
                            dismissButton: .cancel(Text("Close"))
                        )
                    }
                }
            }
            .task {
                await viewModel.load()
            }
        }
    }

    private func ruleDetailLine(_ rule: MerchantRule) -> String {
        var parts = ["“\(rule.patternText)”"]
        parts.append(rule.matchType == "prefix" ? "Starts With" : "Exact")
        if let fixedKind = rule.fixedKind,
           let label = Self.fixedKindOptions.first(where: { $0.raw == fixedKind })?.label {
            parts.append("Always \(label)")
        }
        return parts.joined(separator: " · ")
    }

    private func startEditing(_ rule: MerchantRule) {
        editingRule = rule
        patternText = rule.patternText
        displayNameText = TitleCase.apply(to: rule.displayName.lowercased())
        matchType = rule.matchType
        fixedKind = rule.fixedKind
        showingForm = true
    }

    private var ruleForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingRule == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name as It Appears")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField("", text: $patternText)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name as It Appears")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    // The pattern is immutable server-side: to
                    // teach a different spelling, delete this rule
                    // and add a new one.
                    Text(patternText)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Show As")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                TextField("", text: $displayNameText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Match")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Picker("Match", selection: $matchType) {
                    Text("Exact").tag("exact")
                    Text("Starts With").tag("prefix")
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Always Count As")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Picker("", selection: $fixedKind) {
                    Text("No Fixed Kind").tag(nil as String?)
                    ForEach(Self.fixedKindOptions, id: \.0) { option in
                        Text(option.label).tag(option.raw as String?)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack(spacing: 12) {
                Button(editingRule == nil ? "Save Name" : "Save Changes") {
                    Task {
                        let pattern = patternText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let display = displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !pattern.isEmpty, !display.isEmpty else {
                            viewModel.alert = .failed(
                                title: "Could Not Save Name",
                                message: "Enter both the name as it appears and the name to show."
                            )
                            return
                        }
                        if await viewModel.saveRule(
                            pattern: pattern,
                            displayName: display,
                            matchType: matchType,
                            fixedKind: fixedKind,
                            editing: editingRule
                        ) {
                            showingForm = false
                            editingRule = nil
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isSaving)
                Button("Cancel") {
                    showingForm = false
                    editingRule = nil
                }
                .buttonStyle(TertiaryButtonStyle())
                if let editingRule {
                    Spacer()
                    Button("Delete") {
                        viewModel.alert = .deleteRule(editingRule)
                    }
                    .buttonStyle(TertiaryButtonStyle())
                }
            }
        }
    }
}
