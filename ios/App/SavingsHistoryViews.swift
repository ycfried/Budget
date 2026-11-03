import SwiftUI
import OnBudgetCore
import UniformTypeIdentifiers

struct SavingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: EditorMode?
    var body: some View {
        List {
            Section { SnapshotNotice() }
            if let savings = model.snapshot?.savings {
                Section("Reconciliation") {
                    AmountRow(title: "Fund available", money: savings.fundAvailable)
                    AmountRow(title: "Earned, not transferred", money: savings.earnedNotTransferred)
                    if let balance = savings.actualBalance { AmountRow(title: "Actual savings balance", money: balance) }
                    else { Text("Actual balance not recorded") }
                    AmountRow(title: "Interest / outside movements", money: savings.interestAndMovements)
                    Text("Positive earned-not-transferred suggests a manual deposit. Negative means savings holds money for fund spending already on the card. Interest is not spendable.").font(.caption)
                    Text("This app never initiates transfers or payments.").font(.caption.bold())
                }
                if model.isAdmin {
                    Section("Record only") {
                        Button("Attest actual balance") { editor = .attest }
                        Button("Record posted movement") { editor = .savings }
                    }.disabled(!model.canWrite)
                }
                Section("Movement history") {
                    ForEach(savings.records) { record in
                        VStack(alignment: .leading) { AmountRow(title: record.title, money: record.amount); Text(record.detail).font(.caption) }
                    }
                }
            }
        }.navigationTitle("Savings").sheet(item: $editor) { ActionEditor(mode: $0) }
    }
}
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    var body: some View {
        List {
            Section { SnapshotNotice() }
            ForEach(model.snapshot?.history ?? []) { week in
                Section("Week of \(week.weekStart)") {
                    AmountRow(title: "Base allowance", money: week.allowance)
                    AmountRow(title: "Temporary increases", money: week.increment)
                    AmountRow(title: "Debt in", money: week.debtIn)
                    AmountRow(title: "Debt out", money: week.debtOut)
                    AmountRow(title: "Spent", money: week.spent)
                    AmountRow(title: "Surplus", money: week.surplus)
                    Text(week.releaseStatus).font(.caption)
                    if !week.revisionNote.isEmpty { Label(week.revisionNote, systemImage: "clock.arrow.circlepath").font(.caption) }
                }
            }
            if model.isAdmin {
                Section {
                    Button { exporting = true } label: {
                        Label("Export sample history CSV", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }.navigationTitle("Weekly history")
            .fileExporter(isPresented: $exporting, document: HistoryDocument(text: HistoryExport.csv(model.snapshot?.history ?? [])), contentType: .commaSeparatedText, defaultFilename: "OnBudget-sample-history.csv") { result in
                switch result {
                case .success: model.notify("Sample history exported.")
                case .failure: model.notify("Could not export sample history. Try again from Files.")
                }
            }
    }
}

struct HistoryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
