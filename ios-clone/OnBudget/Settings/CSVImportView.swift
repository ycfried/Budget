// OnBudget — CSV import (Add Upload, live web v66, §8.3).
//
// File picker (UIDocumentPickerViewController for .csv), preview
// with per-row New/Duplicate marking, confirm imports only the new
// rows, then reloads and verifies counts. Malformed rows are flagged
// in the preview and skipped.
//
// Wiring (exact API calls):
// - Dedupe: `PostgrestClient.transactionsForCSVDedupe(householdId:)`
//   — the WHOLE history via `fetchAllPages` (paged, 1000/page). A
//   duplicate past the newest 1000 is flagged Duplicate, not New.
//   A failed dedupe page errors LOUDLY (no preview, Confirm stays
//   disabled) instead of silently marking every row New.
// - Confirm (admin-only gate — "Only the admin can import
//   transactions." for members): `PostgrestClient.
//   insertCSVTransactions(_:)` with `CSVTransactionInsert` rows
//   (`source: 'csv'`, `state: 'provisional'`, `kind:
//   classifyCsvKind(merchant, amount)`, `dedupe_hash =
//   sha256(date | MERCHANT | amount | suffix)`), then an audit row
//   "CSV import" ("`N` added, `M` not inserted.") and a toast
//   "Imported `N` transaction(s) as provisional."
// - Parse + classification are the kit ports of `parseCsvLive` /
//   `classifyCsvKind` (OnBudgetKit.CSVParsing) — same header rules,
//   quote-aware split, `YYYY-MM-DD` or `MM/DD/YYYY` dates, `$`,
//   commas and `(…)` negatives, suffix = last 4 digits of Card
//   Ending else `0000`. Rows before 2026-11-01 are skipped with an
//   error line; unparseable rows are skipped the same way.
// - Nothing is inserted on file pick. No auto-link call after
//   import (service-role-only; a call would 403).

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OnBudgetKit

/// One previewed CSV row.
struct CSVPreviewRow: Identifiable {
    let row: ParsedCSVRow
    let isDuplicate: Bool
    var id: String { "\(row.date)|\(row.merchant)|\(row.amountCents)|\(row.suffix)" }
}

@MainActor
final class CSVImportViewModel: ObservableObject {
    @Published var fileName = "No file selected"
    @Published var previewRows: [CSVPreviewRow] = []
    @Published var parseErrors: [String] = []
    @Published var resultMessage: String?
    @Published var resultIsError = false
    @Published var isReading = false
    @Published var isImporting = false
    @Published var showPicker = false

    var newRows: [ParsedCSVRow] {
        previewRows.filter { !$0.isDuplicate }.map { $0.row }
    }

    var duplicateCount: Int { previewRows.filter { $0.isDuplicate }.count }
    var hasPreview: Bool { !previewRows.isEmpty || !parseErrors.isEmpty }

    private let context: SettingsContext
    private let toast: ToastState

    init(context: SettingsContext, toast: ToastState) {
        self.context = context
        self.toast = toast
    }

    // MARK: - File pick + preview

    /// A nil url here means the picker itself failed to deliver a
    /// file (not a cancel — cancels never reach this function).
    func filePicked(_ url: URL?) {
        guard let url else {
            showPickerError("No file reached the app from the picker. Try saving the file to Files first, then picking it from Files.")
            return
        }
        fileName = url.lastPathComponent
        previewRows = []
        parseErrors = []
        resultMessage = nil
        Task { await readAndPreview(url: url) }
    }

    private func readAndPreview(url: URL) async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            showPickerError("No file reached the app from the picker. Try saving the file to Files first, then picking it from Files.")
            return
        }
        let parsed = CSVParsing.parseCSV(text)
        // Whole-history dedupe (paged). A failed page throws into
        // this handler — loud error, never a silently all-New preview.
        let existingKeys: Set<String>
        do {
            let existing = try await context.client.postgrest.transactionsForCSVDedupe(householdId: context.householdId)
            existingKeys = Set(existing.map {
                CSVParsing.csvRowKey(merchant: $0.merchant, date: $0.date, amountCents: $0.amountCents, suffix: $0.cardSuffix)
            })
        } catch {
            previewRows = []
            parseErrors = []
            // The FILE read fine — this is the whole-history dedupe
            // fetch that failed (audit CF-4, Nov 12 2026): saying
            // "could not read this file" blamed the file and sent
            // the user to re-save it in Files for no reason.
            resultMessage = "Could not check this file against your history (\(settingsErrorMessage(error))). Nothing was imported — try again."
            resultIsError = true
            return
        }
        var seen: Set<String> = []
        previewRows = parsed.rows.map { row in
            let key = row.dedupeKey
            let isDuplicate = existingKeys.contains(key) || seen.contains(key)
            if !isDuplicate { seen.insert(key) }
            return CSVPreviewRow(row: row, isDuplicate: isDuplicate)
        }
        parseErrors = parsed.errors
        resultMessage = nil
    }

    private func showPickerError(_ message: String) {
        previewRows = []
        parseErrors = []
        resultMessage = message
        resultIsError = true
    }

    // MARK: - Confirm import

    func confirmImport() async {
        guard context.isAdmin else {
            toast.showError("Only the admin can import transactions.")
            return
        }
        let rows = newRows
        guard !rows.isEmpty else {
            toast.show("Nothing new to import.")
            return
        }
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let inserts = rows.map { row in
            CSVTransactionInsert(
                householdId: context.householdId,
                date: row.date,
                merchant: row.merchant,
                amountCents: row.amountCents,
                cardSuffix: row.suffix,
                kind: CSVParsing.classifyKind(merchant: row.merchant, amountCents: row.amountCents)
            )
        }
        do {
            let insertedIds = try await context.client.postgrest.insertCSVTransactions(inserts)
            let added = insertedIds.count
            // A blocked audit insert must not fail the import it logs.
            try? await context.client.postgrest.appendAudit(AuditLogInsert(
                householdId: context.householdId,
                actor: context.currentUserId,
                actorName: context.email ?? (context.isAdmin ? "admin" : "member"),
                action: "CSV import",
                detail: "\(added) added, \(rows.count - added) not inserted."
            ))
            previewRows = []
            parseErrors = []
            fileName = "No file selected"
            resultMessage = nil
            toast.show("Imported \(added) transaction(s) as provisional.", kind: .success)
            await verifyCounts(expectedNew: rows.count, added: added)
        } catch {
            toast.showError("Could not import. Nothing was claimed as imported — try again.")
        }
    }

    /// Reload the history after import and confirm the insert
    /// landed: the shortfall check compares the inserted count
    /// against the new rows the file held (audit CF-6, Nov 12
    /// 2026 — the old check compared the WHOLE-history count to
    /// `added`, which can never be smaller, so the shortfall
    /// branch could never fire). A failed reload still reports
    /// that the import could not be verified.
    private func verifyCounts(expectedNew: Int, added: Int) async {
        do {
            _ = try await context.client.postgrest.transactionsForCSVDedupe(householdId: context.householdId)
            if added < expectedNew {
                resultMessage = "Imported \(added) of \(expectedNew) new transaction(s) — some rows were not inserted. Check the list."
                resultIsError = true
            }
        } catch {
            resultMessage = "Imported \(added) transaction(s), but the reload could not verify them — check the list."
            resultIsError = true
        }
    }
}

// MARK: - Document picker

/// UIDocumentPickerViewController for .csv files.
struct CSVDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.commaSeparatedText],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Cancelling the picker is not a failure: dismiss with
            // no message (previously this called onPick(nil), which
            // showed a misleading "No file reached the app" error).
        }
    }
}

// MARK: - View

struct CSVImportView: View {
    @StateObject private var viewModel: CSVImportViewModel

    init(context: SettingsContext, toast: ToastState) {
        _viewModel = StateObject(wrappedValue: CSVImportViewModel(context: context, toast: toast))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Transactions from a CSV File")
                .font(.title3)
                .fontWeight(.bold)
            Text("Expected columns: Date, Description, Amount, Card Ending.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))
            Text("Preview first — nothing is added until you confirm.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#6b7280"))

            HStack(spacing: 12) {
                Button("Choose File") {
                    viewModel.showPicker = true
                }
                .buttonStyle(PrimaryButtonStyle())
                Text(viewModel.fileName)
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                    .lineLimit(1)
            }

            if viewModel.isReading {
                ProgressView()
            }

            if viewModel.hasPreview {
                Text("\(viewModel.newRows.count) new, \(viewModel.duplicateCount) duplicate(s) skipped, \(viewModel.parseErrors.count) unparseable row(s).")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6b7280"))
                // Parse errors are errors: soft-red box, never the
                // grey muted line they used to render in (audit
                // CF-5, Nov 12 2026).
                if !viewModel.parseErrors.isEmpty {
                    ErrorBox(viewModel.parseErrors.joined(separator: "\n"))
                }
                ForEach(Array(viewModel.previewRows.enumerated()), id: \.offset) { index, preview in
                    Text("\(index + 1). \(preview.row.date) · \(preview.row.merchant) · \(OnBudgetKit.MoneyFormat.formatCents(preview.row.amountCents)) · ••\(preview.row.suffix) — \(preview.isDuplicate ? "Duplicate, will be skipped" : "New")")
                        .font(.subheadline)
                        .foregroundStyle(preview.isDuplicate ? Color(hex: "#6b7280") : DesignTokens.ink)
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

            HStack(spacing: 12) {
                Button(viewModel.isImporting ? "Importing…" : "Confirm Import") {
                    Task { await viewModel.confirmImport() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.newRows.isEmpty || viewModel.isImporting)
            }
        }
        .sheet(isPresented: $viewModel.showPicker) {
            CSVDocumentPicker { url in
                viewModel.showPicker = false
                viewModel.filePicked(url)
            }
        }
    }
}
