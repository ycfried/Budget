import SwiftUI
import OnBudgetKit

/// Add popup (CLONE_SPEC §8): the Transactions header's + button
/// opens an options popup. Admin sees Purchase (solid blue) /
/// Donation (grey fill) / Record Income (ink outline) — three
/// clearly distinct treatments, no two sharing a colour or looking
/// similar (standing button rule, strengthened Nov 23, 2026);
/// members see Purchase only. Choosing an option opens that
/// form; Back returns to the options and keeps the draft; Cancel
/// clears the draft AND closes. A successful submit returns to the
/// list. Popup scroll = popup only (native sheets scroll internally).
///
/// Build 65 (owner, Nov 23, 2026 — item 8): Record Income moved
/// here from the Tzedaka card — recording income is an income
/// action, not a charity action. It presents the same
/// CharityIncomeForm (same fields, validation and
/// `record_charity_income` RPC), driven by a FundsViewModel built
/// from this view model's client + household — the Funds tab's
/// view model is not reachable from this sheet, and the sheet's
/// call site (TransactionsView) passes only a
/// TransactionsViewModel, so the funds view model is built here.
///
/// NOTE: the web options list also has Upload (CSV import, §8.3).
/// CSV import is out of scope for this workstream — the options list
/// gains Upload when that screen lands. No dead Upload row is shown.
public struct AddTransactionView: View {
    enum Step {
        case options
        case purchase
        case donation
        case income
    }

    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var step: Step = .options
    /// Build 65: the funds view model behind the Record Income
    /// step (see the init — built from this view model's client +
    /// household, so the form saves through the same
    /// FundsViewModel.saveIncome RPC path as on the Funds page).
    /// It is a separate instance from the Funds tab's: it loads
    /// only what the income step needs, and nothing else observes
    /// it — its success toast is forwarded through this view
    /// model's confirmation funnel and its failure alert is shown
    /// by the income step itself.
    @StateObject private var fundsViewModel: FundsViewModel
    /// The income entry being corrected — always nil from this
    /// sheet (there is no Correct path here); the binding exists
    /// because CharityIncomeForm owns one. Kept as state so the
    /// form's correction machinery stays inert, never half-wired.
    @State private var correctingIncome: CharityIncome? = nil
    /// The funds view model loads its charity settings once, when
    /// the income step first appears (its default-rate preview
    /// must read the household's real rate, not the assumed 10%).
    @State private var didLoadFunds = false

    public init(viewModel: TransactionsViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        let fundsContext = FundsContext(
            client: viewModel.client,
            householdId: viewModel.householdId,
            // The income flow only ever consults `isAdmin`
            // (admin-only form; the charity-history guard in the
            // loads) — owner vs admin is not distinguished here.
            role: viewModel.isAdmin ? .admin : .member,
            // The shell always sets currentUserId (AppShellView
            // guards on it before building this view model). The
            // fallback is never sent by this flow: the income
            // RPCs take the household id only, and the loads never
            // read the user id — it is only used by fund-request /
            // audit paths this sheet never calls.
            userId: viewModel.currentUserId ?? UUID()
        )
        let fundsViewModel = FundsViewModel(context: fundsContext)
        fundsViewModel.fundNames = viewModel.fundNames
        self._fundsViewModel = StateObject(wrappedValue: fundsViewModel)
    }

    /// The charity fund's CURRENT display name (build 43, owner
    /// Nov 17, 2026 — item 16): the income form's heading reads
    /// it, never a hardcoded "Charity" — same helper as
    /// AddDonationForm's below.
    private var charityName: String { FundSectionID.charity.displayName(customNames: viewModel.fundNames) }

    public var body: some View {
        // No NavigationStack root (owner, Nov 14, 2026): the
        // toolbar "Cancel" truncated to "Ca…", and a NavigationStack
        // reports an unbounded ideal height, so a fitted sheet
        // rendered tall and mostly empty (build 24). A plain VStack
        // root + SheetHeader (X close, centred title) keeps the
        // content at the top of the full-screen popup (build 43,
        // item 17 — the cover is full-screen now, so no detents;
        // the forms are ScrollViews, so they start at the top).
        sheetContent
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(
                title: "Add Transaction",
                onClose: { onDismiss() },
                onBack: step == .options ? nil : { step = .options }
            )
            switch step {
            case .options:
                optionsContent
            case .purchase:
                AddPurchaseForm(viewModel: viewModel, onDone: onDismiss)
            case .donation:
                AddDonationForm(viewModel: viewModel, onDone: onDismiss)
            case .income:
                incomeStep
            }
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet. The trailing Spacer is gone: it
        // stretched the middle empty against the tall form sheet
        // (most visible on the two-button options screen).
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                step = .purchase
            } label: {
                optionRow(
                    title: "Purchase",
                    subtitle: "Add a transaction by hand"
                )
            }
            .buttonStyle(PrimaryButtonStyle())

            if viewModel.isAdmin {
                Button {
                    step = .donation
                } label: {
                    optionRow(
                        title: "Donation",
                        subtitle: "Record a gift by hand"
                    )
                }
                // Grey tertiary, not pale (audit SH-P2-2, Nov 12
                // 2026; B3, Nov 23, 2026): the pale middle tier is
                // retired for three-button groups, and pale blue
                // would sit too close to the solid-blue Purchase
                // under the strengthened rule. Grey fill is
                // clearly distinct from solid blue and from the
                // ink outline below.
                .buttonStyle(TertiaryButtonStyle())
                // Build 65 (owner, Nov 23, 2026 — item 8): Record
                // Income moved here from the Tzedaka card. Admin
                // only, like Donation — the form itself is
                // admin-only by construction.
                Button {
                    step = .income
                } label: {
                    optionRow(
                        title: "Record Income",
                        subtitle: "Record money received by hand"
                    )
                }
                // Ink outline (white bg, ink border + text) — the
                // third treatment in this stack. Solid blue
                // (Purchase) and grey fill (Donation) are taken;
                // a brand-blue outline would sit too close to the
                // solid blue, and a pale fill too close to it as
                // well, so the outline is ink — clearly distinct
                // from both under the strengthened button rule.
                .buttonStyle(InkOutlineButtonStyle())
            }
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the options in the
            // full-screen cover — without it the two buttons
            // centre themselves vertically in the full screen.
            // (The purchase / donation steps are ScrollViews, so
            // they start at the top without one.)
            Spacer()
        }
    }

    /// Build 65 (owner, Nov 23, 2026 — item 8): Record Income,
    /// moved here from the Tzedaka card. The same CharityIncomeForm
    /// the Funds page uses — same fields, validation and
    /// `record_charity_income` RPC — driven by the funds view model
    /// built in the init. The form is NOT a ScrollView itself, so
    /// this step wraps it in one (the Funds page scrolls it; the
    /// sheet does not). Back returns to the options; the form's
    /// Cancel closes the whole sheet, like Purchase/Donation.
    private var incomeStep: some View {
        ScrollView {
            CharityIncomeForm(
                viewModel: fundsViewModel,
                fundName: charityName,
                correcting: $correctingIncome,
                onClose: onDismiss,
                onSaved: {
                    // The form's save raises the success toast on
                    // the funds view model; forward it through
                    // this view model's confirmation funnel
                    // (app-shell toast when wired, else the local
                    // one) BEFORE dismissing — dismissing first
                    // would drop the observation, and
                    // Purchase/Donation confirm the same way.
                    if let toast = fundsViewModel.toast {
                        viewModel.showConfirmation(toast.message, kind: toast.kind)
                        fundsViewModel.toast = nil
                    }
                    onDismiss()
                }
            )
        }
        .scrollIndicators(.hidden)
        // The funds view model's default-rate preview needs the
        // household's real charity settings (not the assumed 10%):
        // load them once, when this step first appears. A failed
        // load leaves the 10% fallback — the save itself still
        // uses the server's default rate.
        .task {
            if !didLoadFunds {
                didLoadFunds = true
                await fundsViewModel.refresh()
            }
        }
        // A failed save raises an alert on the funds view model
        // (same as on the Funds page); show it here, since nothing
        // else observes that view model from this sheet. The typed
        // input stays in the form (F-P1-4).
        .alert(
            fundsViewModel.alertTitle ?? "Could Not Complete",
            isPresented: Binding(
                get: { fundsViewModel.alertMessage != nil },
                set: { if !$0 { fundsViewModel.alertMessage = nil; fundsViewModel.alertTitle = nil } }
            )
        ) {
            Button(TitleCase.apply(to: "Close"), role: .cancel) {}
        } message: {
            Text(fundsViewModel.alertMessage ?? "")
        }
    }

    private func optionRow(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 14))
                    .opacity(0.75)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.6)
        }
    }
}

/// Ink outline option (build 65): white bg, ink #0f172a border +
/// text, same sizing as Primary / Tertiary. The third treatment in
/// the + Add three-option stack — solid blue and grey fill are
/// taken, and a brand-blue outline would sit too close to the solid
/// blue under the strengthened button rule.
private struct InkOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DesignTokens.ink, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Shared form pieces

private struct FormField<Content: View>: View {
    let label: String
    let required: Bool
    let content: Content

    init(_ label: String, required: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.required = required
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label, required: required)
            content
        }
    }
}

/// Card / Account dropdown (owner, Nov 15, 2026): replaces the
/// free-text Card Suffix field. Options are the household's
/// connected accounts (institution + ••mask, from the view model),
/// Cash ("0000"), and an "Add last 4…" entry that types 4 digits
/// in context and adds them to the list (persisted per household
/// in the view model). The saved value stays just the 4 digits,
/// as before. `selection` is nil until the user picks — nil reads
/// as `defaultSuffix`, so the first connected account (purchase)
/// or Cash (donation) is used when the picker is never touched.
/// Full-width, so a long institution name never truncates.
private struct CardAccountField: View {
    @Bindable var viewModel: TransactionsViewModel
    @Binding var selection: String?
    let defaultSuffix: String

    private static let addCustomTag = "__add_custom__"
    @State private var showingAddCustom = false
    @State private var customText = ""
    @State private var customError: String?

    private var effectiveSuffix: String { selection ?? defaultSuffix }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { effectiveSuffix },
            set: { new in
                if new == Self.addCustomTag {
                    customText = ""
                    customError = nil
                    showingAddCustom = true
                } else {
                    selection = new
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Card / Account", selection: selectionBinding) {
                ForEach(viewModel.cardAccountOptions, id: \.suffix) { option in
                    Text(option.label).tag(option.suffix)
                }
                Text("Add last 4…").tag(Self.addCustomTag)
            }
            .pickerStyle(.menu)
            .tint(DesignTokens.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if showingAddCustom {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Last 4 digits", text: $customText)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 220, minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onChange(of: customText) { _, new in
                            let digits = new.filter(\.isNumber)
                            customText = String(digits.prefix(4))
                        }
                    if let customError {
                        SoftErrorBox(customError)
                    }
                    HStack(spacing: 12) {
                        Button("Add") {
                            let digits = customText.filter(\.isNumber)
                            guard digits.count == 4 else {
                                customError = "Enter exactly 4 digits."
                                return
                            }
                            viewModel.addCustomCardSuffix(digits)
                            selection = digits
                            showingAddCustom = false
                        }
                        .buttonStyle(SmallPrimaryButtonStyle())
                        Button("Cancel") { showingAddCustom = false }
                            .buttonStyle(SmallTertiaryButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Purchase — Add a Transaction by Hand (§8.1)

/// Heading "Add a Transaction by Hand". Note: "Counts as pending
/// until the bank confirms it."
/// Fields: Merchant (max 80, required), Amount (required),
/// Date (required), Card / Account (connected account, Cash, or an
/// added last 4; required — defaults to the first connected
/// account).
/// Buttons: Add Transaction (primary) + Cancel (tertiary).
/// Footnote: "Never enter a full card number."
/// Validation, in order, each naming the field: amount must be a
/// positive number ("Amount: enter a positive amount."); suffix
/// exactly 4 digits ("Card Suffix: enter exactly 4 digits. Never
/// enter a full card number."); merchant required; date required;
/// date must be ≥ 2026-11-01 ("Date: transactions start Nov 1, 2026.
/// Pick a date on or after Nov 1, 2026."); date must not be in the
/// future (native-only guard, T-P2-13 — the web spec has none).
/// Duplicate warning: "Possible Duplicate" — "A transaction already
/// exists for MERCHANT $X on DATE. Add it again anyway?", Confirm
/// "Add Anyway".
/// Purchases-only: no refund option here (owner decision Nov 3).
public struct AddPurchaseForm: View {
    @Bindable var viewModel: TransactionsViewModel
    let onDone: () -> Void

    @State private var merchant: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    /// Nil until the user picks — nil reads as the first connected
    /// account (`viewModel.defaultCardSuffix`).
    @State private var cardSuffix: String? = nil
    @State private var errorMessage: String?
    @State private var showingDuplicateConfirm: Bool = false
    @State private var duplicateLabel: String = ""

    public init(viewModel: TransactionsViewModel, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a Transaction by Hand")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Text("Counts as pending until the bank confirms it.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))

                FormField("Merchant", required: true) {
                    TextField("Merchant", text: $merchant)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .textInputAutocapitalization(.words)
                }
                .onChange(of: merchant) { _, new in
                    if new.count > 80 { merchant = String(new.prefix(80)) }
                }

                FormField("Amount", required: true) {
                    DollarTextField(text: $amountText)
                }

                FormField("Date") {
                    DateField(date: $date)
                }

                FormField("Card / Account") {
                    CardAccountField(
                        viewModel: viewModel,
                        selection: $cardSuffix,
                        defaultSuffix: viewModel.defaultCardSuffix
                    )
                }

                if let errorMessage {
                    SoftErrorBox(errorMessage)
                }

                TwoButtonRow {
                    Button("Add Transaction") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.isSaving)
                } secondary: {
                    Button("Cancel") { clearAndClose() }
                        .buttonStyle(TertiaryButtonStyle())
                }

                Text("Never enter a full card number.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
        .scrollIndicators(.hidden)
        // No toolbar Back here (owner, Nov 14, 2026): the sheet
        // has no NavigationStack any more — the back chevron lives
        // in the SheetHeader above this form.
        .alert("Possible Duplicate", isPresented: $showingDuplicateConfirm) {
            Button("Add Anyway") {
                Task { await save(force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A transaction already exists for \(duplicateLabel). Add it again anyway?")
        }
    }

    private var dateString: String {
        TransactionFormatting.string(from: date)
    }

    private func clearAndClose() {
        merchant = ""
        amountText = ""
        cardSuffix = nil
        errorMessage = nil
        onDone()
    }

    /// Validation in the web's order (live.js:2724-2743).
    private func validated() -> (merchant: String, amountCents: Int, date: String, suffix: String)? {
        guard let cents = TransactionFormatting.parseDollarsStrict(amountText), cents > 0 else {
            errorMessage = "Amount: enter a positive amount."
            return nil
        }
        // The dropdown only ever yields a 4-digit suffix, so this
        // guard is defense-in-depth; it never fires from the picker.
        let suffix = cardSuffix ?? viewModel.defaultCardSuffix
        guard suffix.count == 4, suffix.allSatisfy(\.isNumber) else {
            errorMessage = "Card / Account: enter exactly 4 digits. Never enter a full card number."
            return nil
        }
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespaces)
        guard !trimmedMerchant.isEmpty else {
            errorMessage = "Merchant: enter a merchant."
            return nil
        }
        let dateStr = dateString
        guard dateStr >= TransactionFormatting.dataFloorDate else {
            errorMessage = "Date: transactions start Nov 1, 2026. Pick a date on or after Nov 1, 2026."
            return nil
        }
        // T-P2-13: no future dates on hand-entered rows (a deliberate
        // native divergence — the web spec has no upper-bound check).
        guard dateStr <= TransactionFormatting.nyTodayString() else {
            errorMessage = "Date can't be in the future."
            return nil
        }
        return (trimmedMerchant, cents, dateStr, suffix)
    }

    private func save(force: Bool = false) {
        guard let values = validated() else { return }
        errorMessage = nil
        Task {
            let outcome = await viewModel.savePurchase(
                merchant: values.merchant,
                amountCents: values.amountCents,
                date: values.date,
                cardSuffix: values.suffix,
                force: force
            )
            switch outcome {
            case .saved:
                clearAndClose()
            case .possibleDuplicate:
                duplicateLabel = "\(TransactionFormatting.displayMerchant(values.merchant)) \(TransactionFormatting.formatCents(values.amountCents)) on \(TransactionFormatting.fmtLong(values.date))"
                showingDuplicateConfirm = true
            case .failed(let error):
                errorMessage = error.displayMessage
            }
        }
    }
}

// MARK: - Donation — Give to Charity (§8.2)

/// Heading "Give to Charity". Note: "Counts as given at once, never
/// as weekly spending. Admin only." Admin-only (server-enforced).
/// Fields: Organization (max 80, required), Amount, Date,
/// Card / Account (connected account, Cash, or an added last 4 —
/// defaults to Cash), Note (max 120). Submit: Record Gift.
/// Validation: positive amount; organization required; date required;
/// date ≥ 2026-11-01 ("Date: gifts before November 2026 are outside
/// the charity period."); date must not be in the future (native-only
/// guard, T-P2-13 — the web spec has none); suffix if present exactly
/// 4 digits.
/// Duplicate warning mirrors the manual form ("Record this gift anyway?").
/// Missing-RPC error → "Charity isn't live yet — the database step
/// still needs approval."; admin-only refusal → "Only the admin can
/// record charity gifts."
public struct AddDonationForm: View {
    @Bindable var viewModel: TransactionsViewModel
    let onDone: () -> Void

    @State private var organization: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    /// Nil until the user picks — nil reads as Cash ("0000").
    @State private var cardSuffix: String? = nil
    @State private var note: String = ""
    @State private var errorMessage: String?
    @State private var showingDuplicateConfirm: Bool = false
    @State private var duplicateLabel: String = ""

    public init(viewModel: TransactionsViewModel, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDone = onDone
    }

    /// The charity fund's CURRENT display name (build 43, owner
    /// Nov 17, 2026 — item 16): the heading and the missing-RPC
    /// error read it, never a hardcoded "Charity". The view model
    /// carries the household's fund names (synced by
    /// TransactionsView).
    private var charityName: String { FundSectionID.charity.displayName(customNames: viewModel.fundNames) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Give to \(charityName)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Text("Counts as given at once, never as weekly spending. Admin only.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))

                FormField("Organization", required: true) {
                    TextField("Organization", text: $organization)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .textInputAutocapitalization(.words)
                }
                .onChange(of: organization) { _, new in
                    if new.count > 80 { organization = String(new.prefix(80)) }
                }

                FormField("Amount", required: true) {
                    DollarTextField(text: $amountText)
                }

                FormField("Date") {
                    DateField(date: $date)
                }

                FormField("Card / Account") {
                    CardAccountField(
                        viewModel: viewModel,
                        selection: $cardSuffix,
                        defaultSuffix: "0000"
                    )
                }

                FormField("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .onChange(of: note) { _, new in
                    if new.count > 120 { note = String(new.prefix(120)) }
                }

                if let errorMessage {
                    SoftErrorBox(errorMessage)
                }

                TwoButtonRow {
                    Button("Record Gift") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.isSaving)
                } secondary: {
                    Button("Cancel") { clearAndClose() }
                        .buttonStyle(TertiaryButtonStyle())
                }
            }
        }
        .scrollIndicators(.hidden)
        // No toolbar Back here (owner, Nov 14, 2026): the sheet
        // has no NavigationStack any more — the back chevron lives
        // in the SheetHeader above this form.
        .alert("Possible Duplicate", isPresented: $showingDuplicateConfirm) {
            Button("Record Anyway") {
                Task { await save(force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A gift already exists for \(duplicateLabel). Record this gift anyway?")
        }
    }

    private var dateString: String {
        TransactionFormatting.string(from: date)
    }

    private func clearAndClose() {
        organization = ""
        amountText = ""
        cardSuffix = nil
        note = ""
        errorMessage = nil
        onDone()
    }

    private func validated() -> (organization: String, amountCents: Int, date: String, suffix: String, note: String)? {
        guard let cents = TransactionFormatting.parseDollarsStrict(amountText), cents > 0 else {
            errorMessage = "Amount: enter a positive amount."
            return nil
        }
        let trimmedOrg = organization.trimmingCharacters(in: .whitespaces)
        guard !trimmedOrg.isEmpty else {
            errorMessage = "Organization: enter an organization."
            return nil
        }
        let dateStr = dateString
        guard dateStr >= TransactionFormatting.dataFloorDate else {
            errorMessage = "Date: gifts before November 2026 are outside the charity period."
            return nil
        }
        // T-P2-13: no future dates on hand-entered rows (a deliberate
        // native divergence — the web spec has no upper-bound check).
        guard dateStr <= TransactionFormatting.nyTodayString() else {
            errorMessage = "Date can't be in the future."
            return nil
        }
        // The dropdown only ever yields a 4-digit suffix ("0000"
        // for Cash), so this guard is defense-in-depth.
        let suffix = cardSuffix ?? "0000"
        if !(suffix.count == 4 && suffix.allSatisfy(\.isNumber)) {
            errorMessage = "Card / Account: enter exactly 4 digits. Never enter a full card number."
            return nil
        }
        return (trimmedOrg, cents, dateStr, suffix, note.trimmingCharacters(in: .whitespaces))
    }

    private func save(force: Bool = false) {
        guard let values = validated() else { return }
        errorMessage = nil
        Task {
            let outcome = await viewModel.saveDonation(
                organization: values.organization,
                amountCents: values.amountCents,
                date: values.date,
                cardSuffix: values.suffix,
                note: values.note,
                force: force
            )
            switch outcome {
            case .saved:
                clearAndClose()
            case .possibleDuplicate:
                duplicateLabel = "\(TransactionFormatting.displayMerchant(values.organization)) \(TransactionFormatting.formatCents(values.amountCents)) on \(TransactionFormatting.fmtLong(values.date))"
                showingDuplicateConfirm = true
            case .failed(let error):
                errorMessage = donationErrorMessage(error)
            }
        }
    }

    /// Missing-RPC and admin-only refusals get the web's exact
    /// wording (live.js:4300-4310); other refusals go through
    /// `displayMessage` (specific refusals keep their text; raw
    /// server text becomes a generic line).
    private func donationErrorMessage(_ error: OnBudgetError) -> String {
        if case .notFound = error {
            return "\(charityName) isn't live yet — the database step still needs approval."
        }
        if case .adminOnly = error {
            return "Only the admin can record charity gifts."
        }
        return error.displayMessage
    }
}
