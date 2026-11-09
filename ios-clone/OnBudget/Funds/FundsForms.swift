import SwiftUI
import OnBudgetKit

// MARK: - Add Money (top-up, admin only — spec §9.3)
//
// "Log cash already in checking — owed back is covered first."
// Manual top-ups cover the fund shortfall FIRST; the remainder
// increases spendable Available. The save preview MUST show the split
// before saving; fund history shows the split. Top-ups never touch
// weekly allowance / spending room / debt math. Admin-only;
// confirmation checkbox + double-tap protection.

public struct AddMoneyForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var amountText = ""
    @State private var note = ""
    @State private var confirmed = false
    @State private var fieldError: String?
    @State private var showConfirm = false

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    private var previewText: String {
        guard let cents = amountCents, cents > 0 else { return "Enter an amount to see the split." }
        guard let split = viewModel.topupPreview(amountCents: cents) else {
            return "Fund balance has not loaded yet — the server still covers anything owed back first when you save."
        }
        return "Split: \(MoneyFormat.formatCents(split.added)) added to fund · \(MoneyFormat.formatCents(split.covered)) covers owed back · Owed back after \(MoneyFormat.formatCents(split.after))."
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Add Money")
                FundsMuted(text: "Log cash already in checking — owed back is covered first.")
                FundsMoneyField("Amount ($)", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note (optional)")
                        .font(.system(size: 14, weight: .semibold))
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > 120 { note = String(newValue.prefix(120)) }
                        }
                }
                Toggle(isOn: $confirmed) {
                    Text("I have already put this money in checking")
                        .font(.system(size: 15))
                }
                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                HStack(spacing: 12) {
                    FundsPrimaryButton("Save Top-Up", isBusy: viewModel.busyAction == "topup") {
                        saveTapped()
                    }
                    FundsTertiaryButton("Cancel") {
                        amountText = ""
                        note = ""
                        confirmed = false
                        fieldError = nil
                        viewModel.toast = nil
                    }
                }
                FundsMuted(text: "Log each deposit only once.")
            }
        }
        .confirmationDialog(
            "Save Top-Up",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Save Top-Up")) {
                Task {
                    await viewModel.addTopup(amountCents: amountCents ?? 0, note: note.trimmingCharacters(in: .whitespaces))
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text(previewText)
        }
    }

    private func saveTapped() {
        guard let cents = amountCents, cents > 0 else {
            fieldError = "Enter a valid amount."
            return
        }
        guard confirmed else {
            fieldError = "Confirm you have already put this money in checking."
            return
        }
        fieldError = nil
        showConfirm = true
    }
}

// MARK: - Use Fund Money (admin only — spec §9.3)
//
// "Lowers the fund balance only." On "insufficient fund" the server
// error offers a typed-reason override retry ("Fund Is Short" sheet).

public struct UseFundForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var amountText = ""
    @State private var note = ""
    @State private var fieldError: String?
    @State private var showConfirm = false
    @State private var showOverride = false
    @State private var overrideReason = ""
    @State private var pendingCents: Int?

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Use Fund Money")
                FundsMuted(text: "Lowers the fund balance only.")
                FundsMoneyField("Amount ($)", text: $amountText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note (optional)")
                        .font(.system(size: 14, weight: .semibold))
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                if let fieldError {
                    FundsErrorBox(fieldError)
                }
                HStack(spacing: 12) {
                    FundsPrimaryButton("Record It") {
                        guard let cents = amountCents, cents > 0 else {
                            fieldError = "Enter a valid amount."
                            return
                        }
                        fieldError = nil
                        pendingCents = cents
                        showConfirm = true
                    }
                    FundsTertiaryButton("Cancel") {
                        amountText = ""
                        note = ""
                        fieldError = nil
                    }
                }
            }
        }
        .confirmationDialog(
            "Record Fund Spending",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Record It")) {
                Task { await record(overrideReason: nil) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents {
                Text("Record \(MoneyFormat.formatCents(pendingCents)) of fund spending?")
            }
        }
        .alert("Fund Is Short", isPresented: $showOverride) {
            TextField("Reason for overriding", text: $overrideReason)
            Button(TitleCase.apply(to: "Record Anyway")) {
                Task { await record(overrideReason: overrideReason.trimmingCharacters(in: .whitespaces)) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let pendingCents {
                Text("The fund does not cover \(MoneyFormat.formatCents(pendingCents)). Record it anyway with a typed reason — it will be logged.")
            }
        }
    }

    private func record(overrideReason: String?) async {
        guard let cents = pendingCents else { return }
        do {
            try await viewModel.allocateFund(amountCents: cents, note: note.trimmingCharacters(in: .whitespaces), overrideReason: overrideReason)
            amountText = ""
            note = ""
            pendingCents = nil
        } catch let error as OnBudgetError {
            if case .insufficientFund = error, overrideReason == nil {
                showOverride = true
            } else {
                viewModel.alertTitle = "Could Not Record"
                viewModel.alertMessage = error.userMessage
            }
        } catch {
            viewModel.alertTitle = "Could Not Record"
            viewModel.alertMessage = error.localizedDescription
        }
    }
}

// MARK: - Ask for Fund Money (all roles — spec §9.3)
//
// "The admin approves or declines each request." Below the form:
// the fund-request queue (max 50, newest first), each row expandable
// to detail; pending requests show admin-only Approve / Decline.

public struct AskFundForm: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var amountText = ""
    @State private var note = ""
    @State private var fieldError: String?

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var amountCents: Int? { MoneyFormat.parseDollarsStrict(amountText) }

    public var body: some View {
        VStack(spacing: 16) {
            FundsCard {
                VStack(alignment: .leading, spacing: 12) {
                    FundsHeading("Ask for Fund Money")
                    FundsMuted(text: "The admin approves or declines each request.")
                    FundsMoneyField("Amount ($)", text: $amountText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Note (optional)")
                            .font(.system(size: 14, weight: .semibold))
                        TextField("", text: $note)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let fieldError {
                        FundsErrorBox(fieldError)
                    }
                    HStack(spacing: 12) {
                        FundsPrimaryButton("Send Request", isBusy: viewModel.busyAction == "request") {
                            guard let cents = amountCents, cents > 0 else {
                                fieldError = "Enter a valid amount."
                                return
                            }
                            fieldError = nil
                            Task {
                                await viewModel.createFundRequest(
                                    amountCents: cents,
                                    note: note.trimmingCharacters(in: .whitespaces),
                                    transactionId: nil
                                )
                                amountText = ""
                                note = ""
                            }
                        }
                        FundsTertiaryButton("Cancel") {
                            amountText = ""
                            note = ""
                            fieldError = nil
                        }
                    }
                }
            }
            FundRequestQueue(viewModel: viewModel)
        }
    }
}

public struct FundRequestQueue: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var expandedId: UUID?
    @State private var approving: FundRequest?
    @State private var approveAmountText = ""
    @State private var approveError: String?
    @State private var showOverride = false
    @State private var overrideReason = ""
    @State private var declining: FundRequest?

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Fund Requests")
                if let error = viewModel.fundRequestsError {
                    FundsErrorBox(error)
                } else if viewModel.fundRequests.isEmpty {
                    FundsMuted(text: "No fund requests yet.")
                } else {
                    ForEach(viewModel.fundRequests) { request in
                        fundRequestRow(request)
                        if request.id != viewModel.fundRequests.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .sheet(item: $approving) { request in
            ApproveRequestSheet(
                request: request,
                amountText: $approveAmountText,
                error: approveError,
                onApprove: { Task { await approveTapped(overrideReason: nil) } },
                onCancel: { approving = nil; approveError = nil }
            )
        }
        .alert("Fund Is Short", isPresented: $showOverride) {
            TextField("Reason for overriding", text: $overrideReason)
            Button(TitleCase.apply(to: "Approve Anyway")) {
                Task { await approveTapped(overrideReason: overrideReason.trimmingCharacters(in: .whitespaces)) }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            if let cents = MoneyFormat.parseDollarsStrict(approveAmountText) {
                Text("The fund does not cover \(MoneyFormat.formatCents(cents)). You can still approve with a typed reason — it will be logged.")
            }
        }
        .confirmationDialog(
            "Decline Request",
            isPresented: Binding(
                get: { declining != nil },
                set: { if !$0 { declining = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(TitleCase.apply(to: "Decline"), role: .destructive) {
                if let declining {
                    Task { await viewModel.declineRequest(declining) }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("Decline this fund request?")
        }
    }

    private func statusLabel(_ request: FundRequest) -> String {
        if request.status == "split" {
            return "Split — \(MoneyFormat.formatCents(request.remainderCents)) remaining"
        }
        return request.status.uppercased()
    }

    private func statusSentence(_ request: FundRequest) -> String {
        switch request.status {
        case "pending":
            return "Waiting on the admin decision. You can track it here — its status changes when the admin approves or declines it."
        case "approved":
            return "Approved — the fund balance above already reflects it."
        case "split":
            return "Split approval — see the approved and remaining amounts above."
        default:
            return "Declined by the admin."
        }
    }

    @ViewBuilder
    private func fundRequestRow(_ request: FundRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expandedId = expandedId == request.id ? nil : request.id
            } label: {
                HStack {
                    Text("\(MoneyFormat.formatCents(request.amountCents)) · \(statusLabel(request)) · \(request.note)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Text(expandedId == request.id ? "⌃" : "⌄")
                        .foregroundStyle(DesignTokens.primary)
                }
            }
            .buttonStyle(.plain)
            if expandedId == request.id {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requested: \(MoneyFormat.formatCents(request.amountCents)) · Status: \(statusLabel(request))")
                    Text("Fund available now: \(viewModel.fundSummary.map { MoneyFormat.formatCents($0.availableCents) } ?? "…")")
                    if let approved = request.approvedCents {
                        if request.status == "split" {
                            Text("Approved: \(MoneyFormat.formatCents(approved)) of \(MoneyFormat.formatCents(request.amountCents)) requested — \(MoneyFormat.formatCents(request.remainderCents)) is still unapproved and needs a new request.")
                        } else {
                            Text("Approved: \(MoneyFormat.formatCents(approved)) (in full).")
                        }
                    }
                    Text("Note: \(request.note.isEmpty ? "—" : request.note)")
                    Text("Requested: \(MoneyFormat.fmtDateTime(request.createdAt))")
                    Text(statusSentence(request))
                }
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
                if viewModel.context.isAdmin && request.status == "pending" {
                    HStack(spacing: 12) {
                        FundsSmallPrimaryButton("Approve", isBusy: viewModel.busyAction != nil) {
                            approveAmountText = String(format: "%.2f", Double(request.amountCents) / 100.0)
                            approveError = nil
                            approving = request
                        }
                        FundsQuietButton("Decline", isBusy: viewModel.busyAction != nil) {
                            declining = request
                        }
                    }
                }
            }
            if let approveError, approving?.id == request.id {
                FundsErrorBox(approveError)
            }
        }
    }

    private func approveTapped(overrideReason: String?) async {
        guard let request = approving else { return }
        guard let cents = MoneyFormat.parseDollarsStrict(approveAmountText), cents > 0 else {
            approveError = "Invalid amount — enter a positive amount."
            return
        }
        guard cents <= request.amountCents else {
            approveError = "Too much — you cannot approve more than the requested \(MoneyFormat.formatCents(request.amountCents))."
            return
        }
        do {
            try await viewModel.approveRequest(request, amountCents: cents, overrideReason: overrideReason)
            approving = nil
            approveAmountText = ""
        } catch let error as OnBudgetError {
            if case .insufficientFund = error, overrideReason == nil {
                showOverride = true
            } else {
                approveError = error.userMessage
            }
        } catch {
            approveError = error.localizedDescription
        }
    }
}

// MARK: - Approve sheet (spec §9.3)
//
// "Approve from the Fund": "Approve how much of this $X request?
// Enter less for a split approval." Amount prefilled with the full
// amount. ≤0 or non-numeric → "Invalid amount"; > requested → "Too much".

public struct ApproveRequestSheet: View {
    public let request: FundRequest
    @Binding public var amountText: String
    public let error: String?
    public let onApprove: () -> Void
    public let onCancel: () -> Void

    public init(
        request: FundRequest,
        amountText: Binding<String>,
        error: String?,
        onApprove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self._amountText = amountText
        self.error = error
        self.onApprove = onApprove
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                FundsMuted(text: "Approve how much of this \(MoneyFormat.formatCents(request.amountCents)) request? Enter less for a split approval.")
                FundsMoneyField("Amount ($)", text: $amountText)
                if let error {
                    FundsErrorBox(error)
                }
                HStack(spacing: 12) {
                    FundsPrimaryButton("Approve", action: onApprove)
                    FundsTertiaryButton("Cancel", action: onCancel)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(TitleCase.apply(to: "Approve from the Fund"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
