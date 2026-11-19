import SwiftUI
import OnBudgetKit

/// Transaction export (build 45, Nov 18, 2026): a full-screen popup
/// on the Transactions page. Scope (Filtered / All) + format (PDF /
/// CSV) → Generate → the iOS share sheet, so the user can save,
/// AirDrop, email, or print the file. Nothing is auto-emailed or
/// auto-saved anywhere — the sheet is the choice. Read-only: it
/// never changes transactions.
///
/// The full history is fetched once, in the background, when the
/// popup opens — the list page only ever holds the rows loaded so
/// far (25 at a time), so exporting the loaded page alone would
/// silently miss the rows the user never tapped Load More for.
/// Switching scope never refetches: the filtered scope applies the
/// active `TransactionFilters` to the fetched rows, Export all
/// passes them through untouched.
///
/// Design rules: Title Case headings and labels; two-button row
/// primary blue first + grey tertiary second; no greyed-out
/// buttons — Generate stays tappable and duplicate taps are
/// ignored (the `isSaving` guard pattern); loading is shimmer
/// skeletons, no spinner, no "Loading..." text; errors are the
/// soft-red box with dark red text.
public struct TransactionExportView: View {
    @Bindable var viewModel: TransactionsViewModel
    /// The household name the shell already loaded
    /// (`appState.householdName`); nil falls back to a fetch.
    let householdName: String?
    let onDismiss: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var scope: TransactionExportScope = .filtered
    @State private var format: TransactionExportFormat = .pdf
    /// The whole household history, fetched once on open (nil
    /// until it arrives). Scope switching re-slices this, never
    /// refetches.
    @State private var allRows: [Transaction]? = nil
    @State private var fetchError: String? = nil
    @State private var isGenerating: Bool = false
    @State private var shareURL: URL? = nil
    @State private var resolvedHouseholdName: String? = nil

    public init(viewModel: TransactionsViewModel, householdName: String?, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.householdName = householdName
        self.onDismiss = onDismiss
    }

    /// The rows this scope covers, in export order (filtered:
    /// the active filters + sort; all: date desc, as fetched).
    private var rowsForScope: [Transaction] {
        guard let allRows else { return [] }
        switch scope {
        case .all: return allRows
        case .filtered: return viewModel.filters.apply(to: allRows)
        }
    }

    /// The filter summary under the scope picker: the active
    /// filters as "This Week · Spending", or the no-filters line.
    private var filterSummary: String {
        let chips = viewModel.filters.activeChips(customNames: viewModel.fundNames)
        if chips.isEmpty { return "No filters active — this exports every transaction." }
        return chips.map(\.label).joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Export Transactions", onClose: onDismiss)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scopeSection
                    formatSection
                    statusSection
                    TwoButtonRow {
                        Button(format == .pdf ? "Export as PDF" : "Export as CSV") { generate() }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("export.generate")
                    } secondary: {
                        Button("Cancel") { onDismiss() }
                            .buttonStyle(TertiaryButtonStyle())
                    }
                    // Progress, inline: the Generate button is
                    // never greyed out — a duplicate tap while a
                    // file is being built is ignored instead.
                    if isGenerating {
                        Text("Preparing your file…")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#6b7280"))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding()
            }
        }
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        .accessibilityIdentifier("export.popup")
        .task {
            resolvedHouseholdName = householdName
            if resolvedHouseholdName == nil {
                resolvedHouseholdName = await viewModel.fetchHouseholdName()
            }
            await fetchAllRows()
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                FileShareSheet(url: shareURL)
            }
        }
    }

    // MARK: - Sections

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to Export")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            Picker("Scope", selection: $scope) {
                Text("Filtered").tag(TransactionExportScope.filtered)
                Text("All").tag(TransactionExportScope.all)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export.scope")
            Text(scope == .filtered ? filterSummary : "All transactions in the household, no date or kind restriction.")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            Picker("Format", selection: $format) {
                Text("PDF").tag(TransactionExportFormat.pdf)
                Text("CSV").tag(TransactionExportFormat.csv)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export.format")
            Text(format == .pdf
                 ? "A formatted statement: household, date range, and totals."
                 : "One row per transaction, opens in any spreadsheet.")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let fetchError {
            SoftErrorBox(fetchError)
            Button("Try Again") {
                Task { await fetchAllRows() }
            }
            .buttonStyle(OutlineButtonStyle())
        } else if allRows == nil {
            // Shimmer skeletons shaped like the count line, no
            // spinner, no "Loading..." text (owner loading language).
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 180, height: 14)
                SkeletonBlock(width: 260, height: 14)
            }
            .accessibilityLabel("Loading transactions")
        } else if rowsForScope.isEmpty {
            SoftErrorBox(scope == .filtered
                ? "No transactions match the current filters — change the filters or choose All."
                : "No transactions here yet — nothing to export.")
        } else {
            Text("\(rowsForScope.count) transactions")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("export.count")
        }
    }

    // MARK: - Fetch + generate

    /// The whole history, in the background: the fetch runs in a
    /// Task and the list never blanks — the popup shows skeletons
    /// until the rows arrive.
    private func fetchAllRows() async {
        fetchError = nil
        do {
            allRows = try await viewModel.fetchExportRows(scope: .all)
        } catch let error as OnBudgetError {
            fetchError = error.displayMessage
        } catch {
            fetchError = "Could not load transactions — check your connection and try again."
        }
    }

    /// Generate the file and open the share sheet. Duplicate taps
    /// while a file is being built are ignored (never a greyed-out
    /// button); a tap before the rows arrive is ignored the same
    /// way. A zero-match scope shows its message instead of an
    /// empty file.
    private func generate() {
        guard !isGenerating else { return }
        guard allRows != nil, !rowsForScope.isEmpty else { return }
        let scopeRows = rowsForScope
        let fundNames = viewModel.fundNames
        let household = resolvedHouseholdName ?? "Household"
        let chosenFormat = format
        isGenerating = true
        Task.detached {
            let fileName = chosenFormat.fileName()
            let data: Data
            switch chosenFormat {
            case .csv:
                data = Data(TransactionExport.csvString(transactions: scopeRows, fundNames: fundNames).utf8)
            case .pdf:
                let statement = TransactionExport.pdfStatement(
                    transactions: scopeRows,
                    householdName: household
                )
                data = TransactionExportPDFRenderer.data(statement: statement)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? data.write(to: url, options: .atomic)
            await MainActor.run {
                isGenerating = false
                shareURL = url
            }
        }
    }
}

// MARK: - PDF renderer (UIGraphicsPDFRenderer)

/// Draws a `TransactionExportPDFStatement` as a clean formatted
/// statement: header (household, date range, generated date),
/// table (date, merchant, amount, kind), footer totals (total in,
/// total out, net). Letter pages, ink text, one divider under the
/// header row — no IDs, no raw enum names, no internal machinery.
/// The content model is kit-tested; this is only the drawing.
public enum TransactionExportPDFRenderer {
    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { pageRect.width - margin * 2 }

    private static let ink = UIColor(red: 0x0f / 255, green: 0x17 / 255, blue: 0x2a / 255, alpha: 1)
    private static let muted = UIColor(red: 0x6b / 255, green: 0x72 / 255, blue: 0x80 / 255, alpha: 1)
    private static let divider = UIColor(red: 0xe5 / 255, green: 0xe7 / 255, blue: 0xeb / 255, alpha: 1)

    public static func data(statement: TransactionExportPDFStatement) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "STAG Transactions"]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return renderer.pdfData { context in
            var y = margin
            context.beginPage()
            // Header.
            y = draw(statement.householdName, at: y, font: .boldSystemFont(ofSize: 18), color: ink)
            y = draw(statement.dateRange, at: y + 4, font: .systemFont(ofSize: 13), color: muted)
            y = draw(statement.generatedLine, at: y + 2, font: .systemFont(ofSize: 12), color: muted)
            y += 12
            drawDivider(at: y)
            y += 12
            // Table.
            y = drawTableHeader(at: y)
            for row in statement.rows {
                if y + 20 > pageRect.height - margin - 80 {
                    context.beginPage()
                    y = margin
                    y = drawTableHeader(at: y)
                }
                y = drawTableRow(row, at: y)
            }
            // Footer totals: a new page when they would not fit.
            if y + 76 > pageRect.height - margin {
                context.beginPage()
                y = margin
            }
            y += 8
            drawDivider(at: y)
            y += 12
            y = drawTotal(label: "Total In", value: statement.totalInText, at: y, bold: false)
            y = drawTotal(label: "Total Out", value: statement.totalOutText, at: y, bold: false)
            y = drawTotal(label: "Net", value: statement.netText, at: y, bold: true)
            _ = y
        }
    }

    @discardableResult
    private static func draw(_ text: String, at y: CGFloat, font: UIFont, color: UIColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        return y + size.height
    }

    private static func drawDivider(at y: CGFloat) {
        divider.setFill()
        UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 1))
    }

    private static func drawTableHeader(at y: CGFloat) -> CGFloat {
        let font = UIFont.boldSystemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: muted]
        ("Date" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        ("Merchant" as NSString).draw(at: CGPoint(x: margin + 100, y: y), withAttributes: attributes)
        drawRightAligned("Amount", at: CGPoint(x: margin + 348, y: y), width: 92, font: font, color: muted)
        ("Kind" as NSString).draw(at: CGPoint(x: margin + 448, y: y), withAttributes: attributes)
        let nextY = y + 16
        drawDivider(at: nextY + 4)
        return nextY + 12
    }

    private static func drawTableRow(_ row: TransactionExportPDFRow, at y: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 12)
        let merchantAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: truncatingParagraphStyle(),
        ]
        (row.date as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [.font: font, .foregroundColor: ink]
        )
        (row.merchant as NSString).draw(
            in: CGRect(x: margin + 100, y: y, width: 240, height: 16),
            withAttributes: merchantAttributes
        )
        drawRightAligned(row.amount, at: CGPoint(x: margin + 348, y: y), width: 92, font: font, color: ink)
        (row.kind as NSString).draw(
            at: CGPoint(x: margin + 448, y: y),
            withAttributes: [.font: font, .foregroundColor: ink]
        )
        return y + 20
    }

    @discardableResult
    private static func drawTotal(label: String, value: String, at y: CGFloat, bold: Bool) -> CGFloat {
        let font = bold ? UIFont.boldSystemFont(ofSize: 13) : UIFont.systemFont(ofSize: 13)
        (label as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [.font: font, .foregroundColor: ink]
        )
        drawRightAligned(value, at: CGPoint(x: margin + 340, y: y), width: 192, font: font, color: ink)
        return y + 20
    }

    private static func drawRightAligned(_ text: String, at origin: CGPoint, width: CGFloat, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        (text as NSString).draw(
            in: CGRect(x: origin.x, y: origin.y, width: width, height: 16),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    private static func truncatingParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }
}
