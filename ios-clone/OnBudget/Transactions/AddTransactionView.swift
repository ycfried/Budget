import SwiftUI
import OnBudgetKit

/// Add popup (CLONE_SPEC §8): the Transactions header's + button
/// opens an options popup. Admin sees Purchase (primary) / Donation
/// (pale); members see Purchase only. Choosing an option opens that
/// form; Back returns to the options and keeps the draft; Cancel
/// clears the draft AND closes. A successful submit returns to the
/// list. Popup scroll = popup only (native sheets scroll internally).
///
/// NOTE: the web options list also has Upload (CSV import, §8.3).
/// CSV import is out of scope for this workstream — the options list
/// gains Upload when that screen lands. No dead Upload row is shown.
public struct AddTransactionView: View {
    enum Step {
        case options
        case purchase
        case donation
    }

    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void

    @State private var step: Step = .options

    public init(viewModel: TransactionsViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .options:
                    optionsContent
                case .purchase:
                    AddPurchaseForm(viewModel: viewModel, onBack: { step = .options }, onDone: onDismiss)
                case .donation:
                    AddDonationForm(viewModel: viewModel, onBack: { step = .options }, onDone: onDismiss)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // T-P1-3: Cancel lives ONLY on the options screen.
                // On the form screens the form's own "← Back"
                // (BackButtonStyle) is the top-left button — the two
                // must never render side by side. The forms keep
                // their in-body Cancel, which discards the draft and
                // closes. T-P2-10: Cancel wears the owner Back
                // treatment here too.
                if step == .options {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { onDismiss() }
                            .buttonStyle(BackButtonStyle())
                    }
                }
            }
        }
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
                // 2026): pale #bfdbfe is ONLY the middle tier of a
                // three-button row — this is a vertical two-option
                // stack under Primary "Purchase".
                .buttonStyle(TertiaryButtonStyle())
            }
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

// MARK: - Shared form pieces

private struct FormField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            content
        }
    }
}

// MARK: - Purchase — Add a Transaction by Hand (§8.1)

/// Heading "Add a Transaction by Hand". Note: "Counts as pending
/// until the bank confirms it."
/// Fields: Merchant (max 80, required), Amount ($) (required),
/// Date (required), Card suffix (exactly 4 digits, required).
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
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var merchant: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    @State private var cardSuffix: String = ""
    @State private var errorMessage: String?
    @State private var showingDuplicateConfirm: Bool = false
    @State private var duplicateLabel: String = ""

    public init(viewModel: TransactionsViewModel, onBack: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
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

                FormField("Merchant") {
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

                FormField("Amount ($)") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 220, minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                FormField("Date") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                }

                FormField("Card Suffix") {
                    TextField("1005", text: $cardSuffix)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 220, minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .onChange(of: cardSuffix) { _, new in
                    let digits = new.filter(\.isNumber)
                    cardSuffix = String(digits.prefix(4))
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BackButton(action: onBack)
            }
        }
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
        cardSuffix = ""
        errorMessage = nil
        onDone()
    }

    /// Validation in the web's order (live.js:2724-2743).
    private func validated() -> (merchant: String, amountCents: Int, date: String, suffix: String)? {
        guard let cents = TransactionFormatting.parseDollarsStrict(amountText), cents > 0 else {
            errorMessage = "Amount: enter a positive amount."
            return nil
        }
        guard cardSuffix.count == 4, cardSuffix.allSatisfy(\.isNumber) else {
            errorMessage = "Card Suffix: enter exactly 4 digits. Never enter a full card number."
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
        return (trimmedMerchant, cents, dateStr, cardSuffix)
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
/// Fields: Organization (max 80, required), Amount ($), Date,
/// Card suffix (4 digits, placeholder "only if paid by card" —
/// optional), Note (Optional) (max 120). Submit: Record Gift.
/// Footnote: "Leave the card suffix blank for a cash gift. Never
/// enter a full card number."
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
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var organization: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    @State private var cardSuffix: String = ""
    @State private var note: String = ""
    @State private var errorMessage: String?
    @State private var showingDuplicateConfirm: Bool = false
    @State private var duplicateLabel: String = ""

    public init(viewModel: TransactionsViewModel, onBack: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Give to Charity")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Text("Counts as given at once, never as weekly spending. Admin only.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))

                FormField("Organization") {
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

                FormField("Amount ($)") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 220, minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                FormField("Date") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                }

                FormField("Card Suffix") {
                    TextField("only if paid by card", text: $cardSuffix)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 220, minHeight: 44, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .onChange(of: cardSuffix) { _, new in
                    let digits = new.filter(\.isNumber)
                    cardSuffix = String(digits.prefix(4))
                }

                FormField("Note (Optional)") {
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

                Text("Leave the card suffix blank for a cash gift. Never enter a full card number.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
        .scrollIndicators(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BackButton(action: onBack)
            }
        }
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
        cardSuffix = ""
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
        if !cardSuffix.isEmpty, !(cardSuffix.count == 4 && cardSuffix.allSatisfy(\.isNumber)) {
            errorMessage = "Card Suffix: enter exactly 4 digits. Never enter a full card number."
            return nil
        }
        return (trimmedOrg, cents, dateStr, cardSuffix, note.trimmingCharacters(in: .whitespaces))
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
            return "Charity isn't live yet — the database step still needs approval."
        }
        if case .adminOnly = error {
            return "Only the admin can record charity gifts."
        }
        return error.displayMessage
    }
}
