import SwiftUI
import UniformTypeIdentifiers
import OnBudgetCore

struct TransactionsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = PurchaseQuery()
    @State private var pageSize = 20
    @State private var add = false
    @State private var importing = false
    @State private var preview: CSVPreview?
    var body: some View {
        List {
            Section { SampleNotice() }
            if model.readError != nil { Text("Last-known sample · updates unavailable").font(.caption) }
            Section {
                Picker("State", selection: $query.filter) {
                    ForEach(PurchaseFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Sort", selection: $query.sort) {
                    ForEach(PurchaseSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Card hint", selection: $query.card) {
                    Text("All").tag("All")
                    ForEach(Array(Set(model.snapshot?.purchases.map(\.cardSuffix) ?? [])).sorted(), id: \.self) { Text("••\($0)").tag($0) }
                }
                Picker("Month", selection: $query.month) {
                    Text("All").tag("All")
                    ForEach(Array(Set(model.snapshot?.purchases.map { String($0.date.rawValue.prefix(7)) } ?? [])).sorted().reversed(), id: \.self) { Text($0).tag($0) }
                }
            }
            let rows = query.apply(to: model.snapshot?.purchases ?? [])
            Section {
                if rows.isEmpty { ContentUnavailableView.search(text: query.search) }
                ForEach(Array(rows.prefix(pageSize))) { row in
                    NavigationLink { PurchaseDetailView(purchase: row) } label: { PurchaseRow(purchase: row) }
                }
                if pageSize < rows.count { Button("Load more") { pageSize += 20 } }
            } header: { Text("\(rows.count) purchases") }
            if model.isAdmin {
                Section("CSV import") {
                    Text("Date, Description, Amount, Card Ending. Preview before submitting.").font(.caption)
                    Button("Choose CSV from Files") { importing = true }.disabled(!model.canWrite)
                    if let preview {
                        Text(preview.reconciliationNote).font(.caption)
                        Text("\(preview.rows.count) readable rows · \(preview.errors.count) errors")
                        ForEach(Array(preview.errors.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                        ForEach(preview.rows) { row in
                            VStack(alignment: .leading) {
                                Text(row.merchant)
                                Text("\(row.date.rawValue) · \(row.amount.formatted) · ••\(row.cardSuffix)").font(.caption)
                            }
                        }
                        Button("Review sample import") { confirmImport = true }
                            .disabled(preview.rows.isEmpty || !preview.errors.isEmpty || !model.canWrite)
                        Button("Discard preview", role: .cancel) { self.preview = nil }
                    }
                }
            }
        }
        .navigationTitle("Purchases")
        .searchable(text: $query.search, prompt: "Merchant, amount, date")
        .toolbar { Button { add = true } label: { Label("Add purchase", systemImage: "plus") }.disabled(!model.canWrite) }
        .sheet(isPresented: $add) { ActionEditor(mode: .manual) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= CSVImport.maximumBytes else { throw ServiceError.invalidRequest }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= CSVImport.maximumBytes, let text = String(data: data, encoding: .utf8) else { throw ServiceError.invalidRequest }
                preview = CSVImport.preview(text)
            } catch { preview = nil; model.notify("Could not read CSV. Choose a UTF-8 file under 2 MB from Files.") }
        }
        .confirmationDialog("Record this sample import? No transactions or totals will change.", isPresented: $confirmImport) {
            Button("Record sample import") {
                guard let preview else { return }
                Task { await model.submit(.csv(preview.rows)); self.preview = nil }
            }
        }
        .refreshable { await model.refresh() }
    }
    @State private var confirmImport = false
}

struct PurchaseDetailView: View {
    @Environment(AppModel.self) private var model
    let purchase: Purchase
    @State private var editor: EditorMode?
    var body: some View {
        List {
            Section { SampleNotice(); PurchaseRow(purchase: purchase) }
            Section("Details") {
                LabeledContent("Source", value: purchase.source)
                LabeledContent("Classification", value: purchase.kind)
                AmountRow(title: "Fund allocation", money: purchase.allocation)
                Text(purchase.provenance)
                Text("Original amount, adjustments, refund linkage and full state history require the approved backend adapter.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Actions") {
                Button("Request Extra Fund") { editor = .request(purchase.id) }
                Button("Flag for review") { editor = .flag(purchase.id) }
                if model.isAdmin {
                    Button(purchase.excluded ? "Restore" : "Exclude") { editor = .transaction(purchase.id, purchase.excluded ? .restore : .exclude) }
                    Button("Reclassify") { editor = .transaction(purchase.id, .reclassify) }
                    if purchase.source == "manual" { Button("Delete manual purchase", role: .destructive) { editor = .transaction(purchase.id, .delete) } }
                }
            }.disabled(!model.canWrite)
        }.navigationTitle("Purchase").sheet(item: $editor) { ActionEditor(mode: $0) }
    }
}
