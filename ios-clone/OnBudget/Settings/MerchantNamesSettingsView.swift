import PhotosUI
import SwiftUI
import UIKit
import OnBudgetKit

// STAGE — Settings: Merchant Rules card (build 30, task E).
//
// The saved merchant-name rules: one pattern maps to a clean
// display name plus a fixed kind (or none). Rules apply to every
// transaction kind, to old rows on rename and to new rows at
// ingestion. Admin-only — members never see the card at all (owner
// rule, Nov 13, 2026: no greyed-out controls, only actions that
// work). The Pattern is the single "what to match" field (owner,
// Nov 26, 2026 — build 99): an Includes rule matches when the
// merchant name CONTAINS the pattern anywhere, so a short pattern
// (e.g. "BALTIMORE") catches more spellings; Exact uses the full
// name as the pattern.
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
                toast.show("Rule updated.", kind: .success)
            } else {
                _ = try await context.client.rpcs.createMerchantRule(
                    pHouseholdId: context.householdId,
                    pPattern: pattern,
                    pMatchType: matchType,
                    pDisplayName: displayName,
                    pFixedKind: fixedKind
                )
                toast.show("Rule saved.", kind: .success)
            }
            await load()
            return true
        } catch {
            alert = .failed(title: "Could Not Save Rule", message: OnBudgetError.displayMessage(for: error))
            return false
        }
    }

    func deleteRule(_ rule: MerchantRule) async {
        do {
            try await context.client.rpcs.deleteMerchantRule(pRuleId: rule.id)
            toast.show("Rule removed.", kind: .success)
            await load()
        } catch {
            alert = .failed(title: "Could Not Remove Rule", message: OnBudgetError.displayMessage(for: error))
        }
    }

    /// Distinct raw merchant names for the household (build 99 —
    /// Merchant Rules): fetched once, shared by the "Choose a
    /// Merchant" popup and the "Known Icons" section — neither
    /// fetches the list twice. Loaded alongside the rules; the
    /// popup and the section show skeletons until it lands.
    @Published var allMerchants: [String] = []
    @Published var merchantsLoading = false
    @Published var merchantsLoaded = false

    /// Bumped whenever owner-managed icon state changes
    /// (confirm / change / remove / upload) so the icon lists
    /// below re-read UserDefaults — the lists are computed from
    /// `allMerchants` plus the lookup, and UserDefaults alone
    /// never notifies. Reading it in the computed properties
    /// subscribes the view to it.
    @Published var iconStateVersion = 0

    func noteIconStateChanged() { iconStateVersion += 1 }

    /// Merchants with no rule yet — the "Choose a Merchant"
    /// popup's list. A merchant is covered when any rule matches
    /// it (the same `matchingRule` the rename pre-fill uses).
    /// `allMerchants` arrives sorted, so the filter keeps the
    /// sort.
    var merchantsWithoutRules: [String] {
        _ = iconStateVersion
        return allMerchants.filter { MerchantDisplayName.matchingRule(for: $0, rules: rules) == nil }
    }

    /// Merchants with a resolved icon — the "Known Icons"
    /// section. A merchant counts when the lookup resolves a
    /// domain for it (curated, or a custom key from an Upload).
    var knownIconMerchants: [String] {
        _ = iconStateVersion
        return allMerchants.filter { TransactionIconLookup.merchantDomain(for: $0) != nil }
    }

    func loadMerchants() async {
        guard !merchantsLoaded else { return }
        merchantsLoading = true
        defer { merchantsLoading = false }
        do {
            allMerchants = try await context.client.postgrest.distinctMerchants(householdId: context.householdId)
            merchantsLoaded = true
        } catch {
            // A failed merchant fetch leaves the popup / Known
            // Icons empty — the rules list still loads, so this
            // is not a page-level error; the lists just show
            // their empty line.
            allMerchants = []
        }
    }
}

/// Merchant Rules as a Transactions subpage (owner, Nov 15, 2026 —
/// build 34): the editor moved out of Settings — it lives on the
/// Transactions page now, reached from the "Merchants" chip. Same
/// editor (list + Edit Rule sheet), just hosted here with a back
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
                Text("Merchant Rules")
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
    private let toast: ToastState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The rule being edited, or nil for the add form. The form
    /// opens as a sheet on Add or a row tap (build 33 — it used to
    /// render inline below the list, which was hard to use).
    @State private var editingRule: MerchantRule?
    @State private var showingForm = false
    /// The editable Pattern (build 34): what the rule matches
    /// against. For an edit it defaults to the rule's current
    /// pattern; for a new rule it starts empty (blank form) or
    /// pre-filled from the chosen merchant (Choose a Merchant).
    /// Shown for both match types since build 99 (the old "Name
    /// as It Appears" field is gone — the Pattern is the single
    /// "what to match" field).
    @State private var editablePatternText = ""
    @State private var displayNameText = ""
    @State private var matchType = "exact"
    @State private var fixedKind: String?

    /// Build 52 — the catch-up list: merchants with no icon yet,
    /// collected as transaction rows render. Loaded when the card
    /// appears; hidden when empty.
    @State private var needsIcon: [String] = []
    /// Build 68 (item 22): the "no icon yet" explainer behind ⓘ.
    @State private var showingNeedsIconInfo = false

    /// Build 99 (owner, Nov 26, 2026 — Merchant Rules): the
    /// "Choose a Merchant" popup — merchants with no rule yet.
    @State private var showingMerchantPicker = false
    /// Build 99: the icon action sheet — `.known` for a Known
    /// Icons row (Confirm / Change / Remove), `.upload` for a
    /// Merchants Without an Icon row (Upload Icon only).
    @State private var iconSheet: IconSheetKind?
    /// Build 99: the Remove-icon destructive confirm.
    @State private var showingRemoveIconConfirm = false
    /// Build 99: the photo picker — what the picked image is
    /// for, and whether an upload is in flight.
    @State private var iconPickerItem: PhotosPickerItem?
    @State private var showingIconPicker = false
    @State private var iconUploadTarget: IconUploadTarget?
    @State private var isUploadingIcon = false

    /// Which merchant an icon upload is for, and the Storage
    /// key's domain part. `isSlug` is true when the domain is a
    /// slug for a merchant with no curated domain — the custom
    /// map entry is recorded only after the upload succeeds.
    private struct IconUploadTarget {
        let merchant: String
        let domain: String
        let isSlug: Bool
    }

    /// The icon action sheet's merchant.
    private enum IconSheetKind: Identifiable {
        case known(merchant: String)
        case upload(merchant: String)

        var id: String {
            switch self {
            case .known(let merchant): return "known-\(merchant)"
            case .upload(let merchant): return "upload-\(merchant)"
            }
        }

        var merchant: String {
            switch self {
            case .known(let merchant), .upload(let merchant): return merchant
            }
        }
    }

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
        self.toast = toast
        _viewModel = StateObject(wrappedValue: MerchantNamesSettingsViewModel(context: context, toast: toast))
    }

    var body: some View {
        // Admin-only: members never see the card.
        if context.isAdmin {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Merchant Rules") {
                    MutedLine(text: "Rules you taught the app. A renamed merchant stays renamed on old and new rows.")
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
                        MutedLine(text: "No merchant rules yet. Rename a merchant from any transaction to teach the app.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.rules) { rule in
                                Button {
                                    startEditing(rule)
                                } label: {
                                    // Build 99 (owner, Nov 26, 2026 —
                                    // Merchant Rules): the row reads
                                    // like a transaction row now — the
                                    // merchant icon tile on the left
                                    // (logo, or the monogram fallback)
                                    // is the drop of colour the
                                    // plain-text rows were missing.
                                    // Same 40pt icon and 10pt
                                    // icon/text gap as
                                    // TransactionRowView.
                                    HStack(alignment: .top, spacing: 10) {
                                        TransactionIconView(merchant: rule.displayName, size: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(TransactionFormatting.displayMerchant(rule.displayName))
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(DesignTokens.ink)
                                            ruleDetailLine(rule)
                                                .font(.system(size: 14))
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
                    // Build 99 (owner, Nov 26, 2026 — Merchant
                    // Rules): the add buttons no longer live in
                    // this card — a lone button at the bottom of
                    // the rules list sat smack in the middle of
                    // the page, separating the two groups. Both
                    // add buttons are together at the very bottom
                    // of the page now (see below).
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
                        SheetHeader(title: editingRule == nil ? "Add a Rule" : "Edit Rule") {
                            showingForm = false
                            editingRule = nil
                        }
                        ruleForm
                        Spacer()
                    }
                    .padding()
                    .frame(width: horizontalSizeClass == .regular ? 600 : nil)
                    // The dialog lives on the popup (delete confirm +
                    // save failures both come from this form).
                    // Build 74: the app-styled choice dialog — the
                    // system alert rendered both buttons blue (and
                    // its destructive red differed from #dc2626).
                    .appConfirmDialog(item: $viewModel.alert) { alert in
                        switch alert {
                        case .deleteRule(let rule):
                            return AppConfirmDialog.Config(
                                title: "Remove This Rule?",
                                message: "“\(TransactionFormatting.displayMerchant(rule.displayName))” will stop renaming “\(rule.patternText)” — old rows keep their current names.",
                                primaryTitle: "Remove",
                                tone: .destructive,
                                onPrimary: { Task { await viewModel.deleteRule(rule) } }
                            )
                        case .failed(let title, let message):
                            return AppConfirmDialog.Config(
                                title: title,
                                message: message,
                                primaryTitle: "Close",
                                secondaryTitle: nil,
                                onPrimary: {}
                            )
                        }
                    }
                }
                .task {
                    await viewModel.load()
                    await viewModel.loadMerchants()
                    needsIcon = TransactionIconLookup.needsIconMerchants()
                }
                // Build 52 (owner, Nov 20, 2026 — the smart plan's
                // catch-up loop): merchants that still have no icon
                // — they show their first letter instead. The list
                // is collected as transaction rows render; a
                // merchant drops off it as soon as a later build
                // maps it in the curated map. (Build 57 removed
                // the auto-guess, so there is no guessed logo to
                // load any more.) Hidden entirely when empty —
                // nothing to catch up on.
                if !needsIcon.isEmpty {
                    SettingsCard(title: "Merchants Without an Icon") {
                        // Build 68 (item 22): the explainer lives
                        // behind a blue ⓘ now, not as an inline
                        // paragraph — the short line beside it is
                        // all that stays visible.
                        HStack(spacing: 6) {
                            Text("Waiting for an icon.")
                                .font(.subheadline)
                                .foregroundStyle(DesignTokens.muted)
                            Button { showingNeedsIconInfo = true } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(DesignTokens.primary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About Merchants Without an Icon")
                        }
                        .alert("Merchants Without an Icon", isPresented: $showingNeedsIconInfo) {
                            Button("OK") {}
                        } message: {
                            Text("These merchants don't have an icon yet. Tap one to upload an icon for it.")
                        }
                        VStack(spacing: 0) {
                            ForEach(needsIcon, id: \.self) { name in
                                // Build 68 (item 22): each merchant
                                // shows its monogram initial tile —
                                // the same fallback the transaction
                                // rows use — instead of a bare name
                                // with no tile at all.
                                // Build 99 (owner, Nov 26, 2026 —
                                // Merchant Rules): the row is
                                // tappable — it offers Upload Icon
                                // for this merchant (same photo
                                // picker + bucket upload as Change
                                // Icon, keyed by the merchant's
                                // domain or a slug of its name).
                                Button {
                                    iconSheet = .upload(merchant: name)
                                } label: {
                                    HStack(spacing: 12) {
                                        TransactionIconView(merchant: name, size: 40)
                                        Text(TransactionFormatting.displayMerchant(name))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(DesignTokens.ink)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color(hex: "#6b7280"))
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if name != needsIcon.last {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                // Build 99 (owner, Nov 26, 2026 — Merchant
                // Rules): the complement to "Merchants Without
                // an Icon" — merchants that DO have a resolved
                // icon, so the owner can confirm, change or
                // remove each one. Always shown (never an empty
                // section): while the merchant list loads it
                // shows skeleton rows; with no known icons it
                // shows one short line. The two icon sections
                // sit together, and the add buttons stay at the
                // very bottom of the page.
                SettingsCard(title: "Known Icons") {
                    if viewModel.merchantsLoading && viewModel.allMerchants.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(0..<3, id: \.self) { _ in
                                HStack(spacing: 12) {
                                    SkeletonBlock(width: 40, height: 40, cornerRadius: 10)
                                    SkeletonBlock(width: 140, height: 14)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    } else if viewModel.knownIconMerchants.isEmpty {
                        MutedLine(text: "No merchant icons yet.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.knownIconMerchants, id: \.self) { name in
                                Button {
                                    iconSheet = .known(merchant: name)
                                } label: {
                                    HStack(spacing: 12) {
                                        TransactionIconView(merchant: name, size: 40)
                                        Text(TransactionFormatting.displayMerchant(name))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(DesignTokens.ink)
                                        Spacer()
                                        // A confirmed icon wears a
                                        // small blue check — the
                                        // only visible trace of the
                                        // Confirm action (the
                                        // resolution itself is
                                        // unchanged by confirming).
                                        if let domain = TransactionIconLookup.merchantDomain(for: name),
                                           TransactionIconLookup.confirmedIconDomains().contains(domain) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(DesignTokens.primary)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color(hex: "#6b7280"))
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if name != viewModel.knownIconMerchants.last {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                // Build 99 (owner, Nov 26, 2026 — Merchant
                // Rules): both add buttons together at the
                // very bottom of the page, so no button sits
                // in the middle separating the groups. "Add a
                // Rule" is the blank form; "Choose a Merchant"
                // opens the popup of merchants with no rule
                // yet. Two distinct treatments (primary solid
                // blue on top, tertiary outline below) — never
                // two buttons sharing a colour or look.
                VStack(spacing: 12) {
                    Button("Add a Rule") {
                        startAddingRule()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Choose a Merchant") {
                        showingMerchantPicker = true
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
            .sheet(isPresented: $showingMerchantPicker) {
                merchantPickerSheet
            }
            .sheet(item: $iconSheet) { kind in
                iconSheetContent(kind)
            }
        }
    }

    /// The rule's subtitle — same three pieces as before (bank
    /// name in quotes, match type Includes/Exact, and "Always X"
    /// when a fixed kind is set), tidied up: the "Always X" part
    /// renders in that kind's existing transaction colour, so the
    /// kind reads at a glance. Build 99 (owner, Nov 26, 2026 —
    /// Merchant Rules). The colour is the shared four-colour
    /// transaction rule (TransactionFormatting.amountDisplay):
    /// money in deep blue, charity primary blue, transfers and
    /// payments grey, spending ink. No new colours, no pills.
    private func ruleDetailLine(_ rule: MerchantRule) -> Text {
        let grey = Color(hex: "#6b7280")
        var line = Text("“\(rule.patternText)”").foregroundStyle(grey)
        line = line + Text(" · \(rule.matchType == "includes" ? "Includes" : "Exact")").foregroundStyle(grey)
        if let fixedKind = rule.fixedKind,
           let label = Self.fixedKindOptions.first(where: { $0.raw == fixedKind })?.label {
            line = line + Text(" · Always \(label)").foregroundStyle(kindColor(for: fixedKind))
        }
        return line
    }

    private func kindColor(for fixedKind: String) -> Color {
        switch fixedKind {
        case "income", "refund", "cashback": return DesignTokens.deep
        case "charity": return DesignTokens.primary
        case "transfer", "payment": return DesignTokens.muted
        default: return DesignTokens.ink
        }
    }

    private func startEditing(_ rule: MerchantRule) {
        editingRule = rule
        editablePatternText = rule.patternText
        displayNameText = rule.displayName
        matchType = rule.matchType
        fixedKind = rule.fixedKind
        showingForm = true
    }

    /// Open the blank rule editor (build 99 — "Add a Rule").
    private func startAddingRule() {
        editingRule = nil
        editablePatternText = ""
        displayNameText = ""
        matchType = "exact"
        fixedKind = nil
        showingForm = true
    }

    /// Open the rule editor pre-filled for a merchant with no
    /// rule yet (build 99 — "Choose a Merchant"): the Pattern is
    /// the merchant's bank name (shorten it to the words to
    /// include), the display name starts as the merchant name,
    /// and Match defaults to Includes so the rule catches the
    /// merchant's spelling variants.
    private func startRule(for merchant: String) {
        editingRule = nil
        editablePatternText = merchant
        displayNameText = TransactionFormatting.displayMerchant(merchant)
        matchType = "includes"
        fixedKind = nil
        showingForm = true
    }

    // MARK: - Choose a Merchant popup (build 99)

    /// "Choose a Merchant": the merchants with no rule yet.
    /// Skeleton rows while the list loads, one short line when
    /// every merchant already has a rule. Tapping a row opens
    /// the rule editor pre-filled for that merchant. Back
    /// button top-left + swipe-to-dismiss, like every sheet.
    private var merchantPickerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Choose a Merchant") {
                showingMerchantPicker = false
            } onBack: {
                showingMerchantPicker = false
            }
            if viewModel.merchantsLoading && viewModel.allMerchants.isEmpty {
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonBlock(width: 40, height: 40, cornerRadius: 10)
                            SkeletonBlock(width: 160, height: 14)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            } else if viewModel.merchantsWithoutRules.isEmpty {
                MutedLine(text: "Every merchant already has a rule.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.merchantsWithoutRules, id: \.self) { name in
                            Button {
                                showingMerchantPicker = false
                                startRule(for: name)
                            } label: {
                                HStack(spacing: 12) {
                                    TransactionIconView(merchant: name, size: 40)
                                    Text(TransactionFormatting.displayMerchant(name))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(DesignTokens.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color(hex: "#6b7280"))
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if name != viewModel.merchantsWithoutRules.last {
                                Divider()
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
        .presentationDetents([.medium, .large])
    }

    // MARK: - Icon action sheet (build 99)

    /// The icon action sheet: the merchant's icon large at the
    /// top, the name below it, then the actions. Known icons get
    /// Confirm / Change / Remove; a merchant without an icon
    /// gets Upload Icon only. Three distinct treatments
    /// (primary solid blue, tertiary outline, destructive
    /// soft-red) plus a muted Cancel — no two share a colour
    /// or look. Back button top-left + swipe-to-dismiss.
    private func iconSheetContent(_ kind: IconSheetKind) -> some View {
        let merchant = kind.merchant
        return VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Merchant Icon") {
                iconSheet = nil
            } onBack: {
                iconSheet = nil
            }
            VStack(alignment: .center, spacing: 10) {
                TransactionIconView(merchant: merchant, size: 64)
                Text(TransactionFormatting.displayMerchant(merchant))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                switch kind {
                case .known:
                    Button("Confirm Icon") {
                        confirmIcon(for: merchant)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isUploadingIcon)
                    Button("Change Icon") {
                        beginIconUpload(for: merchant)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(isUploadingIcon)
                    Button("Remove Icon") {
                        showingRemoveIconConfirm = true
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(isUploadingIcon)
                case .upload:
                    Button("Upload Icon") {
                        beginIconUpload(for: merchant)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isUploadingIcon)
                }
                Button("Cancel") {
                    iconSheet = nil
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            Spacer()
        }
        .padding()
        .presentationDetents([.medium])
        // The photo picker lives on this sheet (not the page
        // behind it) — a picker presented from a view under an
        // open sheet does not reliably appear. The onChange
        // fires when the owner picks an image.
        .photosPicker(isPresented: $showingIconPicker, selection: $iconPickerItem, matching: .images)
        .onChange(of: iconPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedIcon(newItem) }
        }
        .appConfirmDialog(
            isPresented: $showingRemoveIconConfirm,
            title: "Remove This Icon?",
            message: "“\(TransactionFormatting.displayMerchant(merchant))” will show its initial tile instead of a logo.",
            primaryTitle: "Remove",
            tone: .destructive
        ) {
            Task { await removeIcon(for: merchant) }
        }
    }

    /// Re-read the icon lists after an icon mutation (confirm /
    /// change / remove / upload): the catch-up list from
    /// UserDefaults, and the computed lists via the version bump
    /// (the lookup reads UserDefaults, which never notifies).
    private func refreshIconLists() {
        needsIcon = TransactionIconLookup.needsIconMerchants()
        viewModel.noteIconStateChanged()
    }

    /// Confirm Icon: record that the owner verified this
    /// merchant's icon. The resolution itself is unchanged —
    /// the bucket / disk cache already wins — this only records
    /// the verification, so the row wears its blue check.
    private func confirmIcon(for merchant: String) {
        guard let domain = TransactionIconLookup.merchantDomain(for: merchant) else {
            toast.show("That merchant has no icon to confirm.", kind: .error)
            return
        }
        TransactionIconLookup.recordConfirmedIconDomain(domain)
        toast.show("Icon confirmed.", kind: .success)
        refreshIconLists()
    }

    /// Start an icon upload for a merchant: resolve the Storage
    /// key, then open the photo library picker. A curated domain
    /// wins; otherwise a slug of the merchant name is the key
    /// (recorded as the merchant's custom icon key only after
    /// the upload succeeds). A slug already claimed by another
    /// merchant, or a name that cannot be slugged, surfaces an
    /// error instead of overwriting or guessing.
    private func beginIconUpload(for merchant: String) {
        if let domain = TransactionIconLookup.merchantDomain(for: merchant) {
            iconUploadTarget = IconUploadTarget(merchant: merchant, domain: domain, isSlug: false)
            iconPickerItem = nil
            showingIconPicker = true
            return
        }
        guard let slug = TransactionIconLookup.iconSlug(for: merchant) else {
            toast.show("Couldn't make an icon key for this merchant.", kind: .error)
            return
        }
        let key = TransactionIconLookup.customIconKey(for: merchant)
        if TransactionIconLookup.customIconDomains().contains(where: { $0.value == slug && $0.key != key }) {
            toast.show("That icon key is already used by another merchant.", kind: .error)
            return
        }
        iconUploadTarget = IconUploadTarget(merchant: merchant, domain: slug, isSlug: true)
        iconPickerItem = nil
        showingIconPicker = true
    }

    /// The picked image, uploaded as a PNG to the
    /// `merchant-logos` bucket under the target's domain key.
    /// The image is downscaled to 512px on its longest side
    /// first (a phone photo is far larger than a 40pt tile
    /// needs). The custom map entry (slug) is recorded only
    /// after the upload succeeds, so a failed upload never
    /// leaves a merchant resolving to a key with no file. A
    /// re-upload clears a removal, and the stale cached image
    /// is evicted so the new one renders immediately.
    private func handlePickedIcon(_ item: PhotosPickerItem) async {
        guard let target = iconUploadTarget else { return }
        iconPickerItem = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let png = iconPNGData(from: data) else {
            toast.show("Couldn't read that image. Try another.", kind: .error)
            return
        }
        isUploadingIcon = true
        defer { isUploadingIcon = false }
        let ok = await FaviconImageLoader.uploadIcon(data: png, domain: target.domain)
        guard ok else {
            toast.show("Couldn't upload the icon. Try again.", kind: .error)
            return
        }
        if target.isSlug {
            TransactionIconLookup.recordCustomIconDomain(target.domain, forMerchant: target.merchant)
        }
        TransactionIconLookup.clearRemovedIconDomain(target.domain)
        if let url = TransactionIconLookup.iconURL(for: target.merchant) {
            FaviconImageLoader.shared.evict(url: url)
        }
        if let googleURL = TransactionIconLookup.faviconURL(forDomain: target.domain) {
            FaviconImageLoader.shared.evict(url: googleURL)
        }
        iconSheet = nil
        toast.show(target.isSlug ? "Icon uploaded." : "Icon updated.", kind: .success)
        refreshIconLists()
    }

    /// Remove Icon: delete the bucket file for the domain (a
    /// 404 counts as success — the icon may have come from
    /// Google, not the bucket), record the domain as removed
    /// so the lookup shows the monogram, evict the cached
    /// image, and put the merchant on the catch-up list so it
    /// can be given a new icon. A real delete failure keeps
    /// the icon and shows an error — never a half-removal.
    private func removeIcon(for merchant: String) async {
        guard let domain = TransactionIconLookup.merchantDomain(for: merchant) else {
            toast.show("That merchant has no icon to remove.", kind: .error)
            return
        }
        // Capture the favicon URL BEFORE recording the removal —
        // afterwards the lookup returns nil for this merchant.
        let iconURL = TransactionIconLookup.iconURL(for: merchant)
        let googleURL = TransactionIconLookup.faviconURL(forDomain: domain)
        isUploadingIcon = true
        defer { isUploadingIcon = false }
        let deleted = await FaviconImageLoader.deleteIcon(domain: domain)
        guard deleted else {
            toast.show("Couldn't remove the icon. Try again.", kind: .error)
            return
        }
        TransactionIconLookup.recordRemovedIconDomain(domain)
        TransactionIconLookup.clearConfirmedIconDomain(domain)
        if let iconURL { FaviconImageLoader.shared.evict(url: iconURL) }
        if let googleURL { FaviconImageLoader.shared.evict(url: googleURL) }
        TransactionIconLookup.recordNeedsIcon(merchant)
        iconSheet = nil
        toast.show("Icon removed.", kind: .success)
        refreshIconLists()
    }

    /// A picked image as PNG data, downscaled to 512px on its
    /// longest side — a phone photo is far larger than a 40pt
    /// tile needs, and the bucket file should stay small. Nil
    /// when the data is not a readable image.
    private func iconPNGData(from imageData: Data) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let maxSide: CGFloat = 512
        guard max(size.width, size.height) > maxSide else { return image.pngData() }
        let scale = maxSide / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.pngData()
    }

    private var ruleForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pattern (build 99 — Merchant Rules): the single
            // "what to match" field, shown for BOTH match types
            // and for both add and edit. The old "Name as It
            // Appears" field is gone (owner, Nov 26, 2026 — it
            // duplicated the Pattern and confused the form):
            // for Exact this is the full name to match exactly;
            // for Includes, the words the name must contain —
            // shorten it (e.g. "BALTIMORE") so the Includes
            // match catches more spellings. Normalizes on save
            // and re-applies the rule to matching rows.
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Pattern", required: true)
                TextField("", text: $editablePatternText)
                    // Build 68 (item 7/13): 48pt field, 14pt
                    // horizontal padding, 12pt radius.
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48, alignment: .leading)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Show As", required: true)
                TextField("", text: $displayNameText)
                    // Build 68 (item 7/13): 48pt field, 14pt
                    // horizontal padding, 12pt radius.
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48, alignment: .leading)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#e5e7eb"), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Match")
                // Build 74 (B4): the Funds slider (SquarishPicker),
                // not a segmented pill — 48pt tall, like the
                // segmented control it replaces.
                SquarishPicker([("exact", "Exact"), ("includes", "Includes")], selection: $matchType, minHeight: 48)
                // What Includes means (owner, Nov 15, 2026 —
                // build 34): one short plain line, muted hint style.
                // Label only — it explains the match; the Includes
                // behaviour itself lives server-side.
                MutedLine(text: "Includes: the name must contain the pattern above, anywhere in the name.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Always Count as")
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
                Button(editingRule == nil ? "Save Rule" : "Save Changes") {
                    Task {
                        let display = displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !display.isEmpty else {
                            viewModel.alert = .failed(
                                title: "Could Not Save Rule",
                                message: "Enter the name to show."
                            )
                            return
                        }
                        // Which pattern to save (build 99 —
                        // Merchant Rules): the Pattern field is
                        // the single source, for both match types
                        // and for add and edit. A new rule
                        // requires it; an edit with an empty
                        // Pattern keeps the existing pattern (the
                        // server never saves a blank one). The old
                        // "Name as It Appears" field and the
                        // Exact-edit sourceMerchant fallback are
                        // gone with it.
                        let pattern = editablePatternText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if editingRule == nil {
                            guard !pattern.isEmpty else {
                                viewModel.alert = .failed(
                                    title: "Could Not Save Rule",
                                    message: "Enter the pattern to match."
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
                // Build 70, item 5 (owner, Nov 24, 2026): the
                // Cancel button is gone — the SheetHeader X +
                // swipe-right dismiss without saving, so Cancel
                // was a third redundant way out.
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
