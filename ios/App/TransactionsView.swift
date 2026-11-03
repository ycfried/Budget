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
            Section { SnapshotNotice() }
            if model.readError != nil { Text("Last-known sample · updates unavailable").font(.caption) }
            Section {
                Picker("State", selection: $query.filter) {
                    ForEach(PurchaseFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Classification", selection: $query.kind) {
                    ForEach(["All", "charge", "refund", "fund_charge", "payment", "cashback"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                Picker("Week", selection: $query.weekStart) {
                    Text("All").tag("All")
                    ForEach(knownWeeks, id: \.self) { Text("Week of \($0)").tag($0) }
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
                if model.loading && model.snapshot == nil { ProgressView("Loading sample purchases…") }
                else if rows.isEmpty { ContentUnavailableView("No matching purchases", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try different filters or add a sample purchase.")) }
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
        .confirmationDialog("Import these rows into the sample household? Financial totals remain fixed.", isPresented: $confirmImport) {
            Button("Record sample import") {
                guard let preview else { return }
                Task { if await model.submit(.csv(preview.rows)) { self.preview = nil } }
            }
        }
        .refreshable { await model.refresh() }
    }
    private var knownWeeks: [String] {
        var weeks = model.snapshot?.history.map(\.weekStart) ?? []
        if let current = model.snapshot?.dashboard.week.weekStart { weeks.append(current) }
        return Array(Set(weeks)).sorted().reversed()
    }
    @State private var confirmImport = false
}

struct PurchaseDetailView: View {
    @Environment(AppModel.self) private var model
    let purchase: Purchase
    @State private var editor: EditorMode?
    private var current: Purchase {
        model.snapshot?.purchases.first(where: { $0.id == purchase.id }) ?? purchase
    }
    var body: some View {
        List {
            Section { SampleNotice(); PurchaseRow(purchase: current) }
            Section("Details") {
                LabeledContent("Source", value: current.source)
                LabeledContent("Classification", value: current.kind.wireValue)
                AmountRow(title: "Original amount", money: current.originalAmount)
                AmountRow(title: "Fund allocation", money: current.allocation)
                Text(current.provenance)
                Text("Sample workflow history only. Matching, refunds and financial totals require server authority.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sample state history") {
                if current.history.isEmpty { Text("No state changes recorded in this sample session.") }
                ForEach(Array(current.history.reversed())) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.action).font(.headline)
                        Text("\(event.from.label) → \(event.to.label)")
                        Text("\(event.actor) · \(event.date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                        if !event.note.isEmpty { Text(event.note).font(.caption) }
                    }.accessibilityElement(children: .combine)
                }
            }
            Section("Actions") {
                if [.provisional, .pending, .posted, .review].contains(current.state) && (current.kind == .charge || current.kind == .fundCharge) {
                    Button("Request Extra Fund") { editor = .request(current.id) }
                }
                if [.provisional, .pending, .posted].contains(current.state) {
                    Button("Flag for review") { editor = .flag(current.id) }
                }
                if model.isAdmin {
                    if current.state == .review && (current.kind == .charge || current.kind == .fundCharge) {
                        Button("Confirm reviewed sample") { editor = .transaction(current.id, .confirmReview) }
                    }
                    if current.state == .quarantined {
                        Button("Approve quarantined sample") { editor = .transaction(current.id, .approveQuarantine) }
                    }
                    if current.state == .review || current.state == .quarantined {
                        Button("Void sample", role: .destructive) { editor = .transaction(current.id, .void) }
                    }
                    if [.provisional, .pending, .posted, .review, .excluded].contains(current.state) {
                        Button(current.excluded ? "Restore" : "Exclude") { editor = .transaction(current.id, current.excluded ? .restore : .exclude) }
                        Button("Reclassify") { editor = .transaction(current.id, .reclassify) }
                        if current.source == "manual" { Button("Void manual sample", role: .destructive) { editor = .transaction(current.id, .delete) } }
                    }
                }
            }.disabled(!model.canWrite)
        }.navigationTitle("Purchase").sheet(item: $editor) { ActionEditor(mode: $0) }
    }
}
