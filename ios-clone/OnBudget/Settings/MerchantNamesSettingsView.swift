import SwiftUI
import OnBudgetKit

// STAG — Settings: Merchant Names card (build 30, task E).
//
// The saved merchant-name rules: one pattern maps to a clean
// display name plus a fixed kind (or none). Rules apply to every
// transaction kind, to old rows on rename and to new rows at
// ingestion. Admin-only — members never see the card at all (owner
// rule, Nov 13, 2026: no greyed-out controls, only actions that
// work). The pattern is editable (owner, Nov 15, 2026 — build 34):
// an Includes rule matches when the merchant name CONTAINS the
// pattern anywhere, so a short pattern (e.g. "BALTIMORE") catches
// more spellings; Exact uses the full original name. The original
// name stays visible as "Name as It Appears" for reference.
//
// Wiring:
// - List: `PostgrestClient.merchantRules(householdId:)`.
// - Add: RPC `create_merchant_rule`.
// - Edit: RPC `update_merchant_rule` (display name / kind / match /
//   pattern; saving re-applies the rule to matching rows).
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
                    pMatchType: matchType,
                    // Empty pattern keeps the existing one (the
                    // server never saves a blank pattern).
                    pPattern: pattern.isEmpty ? nil : pattern
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

/// Merchant Names as a Transactions subpage (owner, Nov 15, 2026 —
/// build 34): the editor moved out of Settings — it lives on the
/// Transactions page now, reached from the "Merchants" chip. Same
/// editor (list + Edit Name sheet), just hosted here with a back
/// button and title, like the other Transactions subpages.
struct MerchantNamesPageView: View {
    private let context: SettingsContext
    private let toast: ToastState
    private let onBack: () -> Void

    init(context: SettingsContext, toast: ToastState, onBack: @escaping () -> Void) {
        self.context = context
        self.toast = toast
        self.onBack = onBack
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Merchant Names")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.ink)
                MerchantNamesSettingsView(context: context, toast: toast)
            }
            .padding()
        }
    }
}

struct MerchantNamesSettingsView: View {
    @StateObject private var viewModel: MerchantNamesSettingsViewModel
    private let context: SettingsContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The rule being edited, or nil for the add form. The form
    /// opens as a sheet on Add or a row tap (build 33 — it used to
    /// render inline below the list, which was hard to use).
    @State private var editingRule: MerchantRule?
    @State private var showingForm = false
    @State private var patternText = ""
    /// The editable Pattern (build 34): what an Includes rule
    /// matches against. Defaults to the rule's current pattern;
    /// only shown when Match is Includes (see ruleForm).
    @State private var editablePatternText = ""
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
                    editablePatternText = ""
                    displayNameText = ""
                    matchType = "exact"
                    fixedKind = nil
                    showingForm = true
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            // The editor is a proper popup, not inline below the
            // list (owner, Nov 15, 2026 — build 33: the inline
            // editor was hard to use and not properly clickable,
            // though the idea and the fields were right). Same
            // fields, same behaviour — just presented full-screen
            // (build 43, item 17) with a header, like the other
            // editors.
            .fullScreenCover(isPresented: $showingForm) {
                // iPad width (owner, Nov 15, 2026 — build 34): same
                // treatment as the Weekly Budget sheet — 600pt width
                // in the regular size class, in a full-screen cover
                // (build 43, item 17). The content is a short fixed
                // form in a plain VStack (no ScrollView root); the
                // trailing Spacer below keeps it at the top of the
                // full screen (build 43, item 18).
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(title: editingRule == nil ? "Add a Name" : "Edit Name") {
                        showingForm = false
                        editingRule = nil
                    }
                    ruleForm
                    Spacer()
                }
                .padding()
                .frame(width: horizontalSizeClass == .regular ? 600 : nil)
                // The alert lives on the popup (delete confirm +
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
        parts.append(rule.matchType == "includes" ? "Includes" : "Exact")
        if let fixedKind = rule.fixedKind,
           let label = Self.fixedKindOptions.first(where: { $0.raw == fixedKind })?.label {
            parts.append("Always \(label)")
        }
        return parts.joined(separator: " · ")
    }

    private func startEditing(_ rule: MerchantRule) {
        editingRule = rule
        patternText = rule.patternText
        editablePatternText = rule.patternText
        displayNameText = TitleCase.apply(to: rule.displayName.lowercased())
        matchType = rule.matchType
        fixedKind = rule.fixedKind
        showingForm = true
    }

    private var ruleForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingRule == nil {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Name as It Appears", required: true)
                    TextField("", text: $patternText)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    FieldLabel("Name as It Appears", required: true)
                    // The original merchant name, for reference —
                    // the Pattern below is what the rule matches.
                    // (source_merchant, build 34; falls back to the
                    // pattern when the column is not there yet.)
                    Text(editingRule?.sourceMerchant ?? patternText)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            // Pattern (owner, Nov 15, 2026 — build 34): editable,
            // and ONLY shown when Match is Includes — Exact uses
            // the full "Name as It Appears" as the pattern, so
            // there is nothing to set. Defaults to the rule's
            // current pattern; shorten it (e.g. "BALTIMORE") so the
            // Includes match catches more spellings. Normalizes on
            // save and re-applies the rule to matching rows.
            if editingRule != nil, matchType == "includes" {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Pattern", required: true)
                    TextField("", text: $editablePatternText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Show As", required: true)
                TextField("", text: $displayNameText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Match")
                Picker("Match", selection: $matchType) {
                    Text("Exact").tag("exact")
                    Text("Includes").tag("includes")
                }
                .pickerStyle(.segmented)
                // What Includes means (owner, Nov 15, 2026 —
                // build 34): one short plain line, muted hint style.
                // Label only — it explains the match; the Includes
                // behaviour itself lives server-side.
                MutedLine(text: "Includes: the name must contain the pattern above, anywhere in the name.")
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
                        let display = displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !display.isEmpty else {
                            viewModel.alert = .failed(
                                title: "Could Not Save Name",
                                message: "Enter the name to show."
                            )
                            return
                        }
                        // Which pattern to save (owner, Nov 15, 2026
                        // — build 34): a new rule takes the pattern
                        // from "Name as It Appears"; an Includes edit
                        // takes the editable Pattern field (empty
                        // keeps the existing pattern — the server
                        // never saves a blank one); an Exact edit
                        // takes the full original name as the pattern.
                        let pattern: String
                        if let editingRule {
                            if matchType == "includes" {
                                pattern = editablePatternText.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else {
                                pattern = editingRule.sourceMerchant ?? patternText
                            }
                        } else {
                            pattern = patternText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !pattern.isEmpty else {
                                viewModel.alert = .failed(
                                    title: "Could Not Save Name",
                                    message: "Enter the name as it appears."
                                )
                                return
                            }
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
