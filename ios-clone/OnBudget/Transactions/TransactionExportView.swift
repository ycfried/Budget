import SwiftUI
import PDFKit
import OnBudgetKit

/// Transaction export (build 45, Nov 18, 2026): a full-screen popup
/// on the Transactions page. Scope (Filtered / All) + format (PDF /
/// CSV) → Generate. A PDF opens an in-app preview first (build 59,
/// Nov 22, 2026 — the finished statement, rendered by PDFKit from
/// the very file that gets shared, so preview and file can never
/// differ); Share inside the preview opens the iOS share sheet, so
/// the user can save, AirDrop, email, or print it. A CSV has no
/// preview and goes straight to the share sheet. Nothing is
/// auto-emailed or auto-saved anywhere — the sheet is the choice.
/// Read-only: it never changes transactions.
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
    /// The PDF to preview (build 59, Nov 22, 2026): the user
    /// sees the finished statement in-app and confirms before
    /// sharing — the preview IS the file, rendered by PDFKit,
    /// so it can never differ from what gets shared. CSV has no
    /// preview (a plain-text file) and goes straight to share.
    @State private var previewURL: URL? = nil
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
                        Button(format == .pdf ? "Preview PDF" : "Export as CSV") { generate() }
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
        // PDF preview (build 59): the finished statement,
        // in-app, before anything is shared. The preview sheet
        // owns the share step — Share opens the share sheet
        // from inside the preview.
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let previewURL {
                TransactionExportPreviewSheet(url: previewURL)
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
                 ? "A branded statement with charts — preview it before sharing."
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

    /// Generate the file. A PDF opens the in-app preview
    /// first — the user confirms the finished statement, then
    /// shares it from the preview. A CSV has no preview and
    /// goes straight to the share sheet. Duplicate taps while
    /// a file is being built are ignored (never a greyed-out
    /// button); a tap before the rows arrive is ignored the
    /// same way. A zero-match scope shows its message instead
    /// of an empty file.
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
                if chosenFormat == .pdf {
                    previewURL = url
                } else {
                    shareURL = url
                }
            }
        }
    }
}

// MARK: - PDF preview (build 59, Nov 22, 2026)

/// The pre-export preview: the finished PDF, in-app, rendered
/// by PDFKit from the very file that gets shared — so the preview
/// and the shared file are the same document by construction.
/// Share opens the iOS share sheet from inside the preview;
/// Close dismisses without sharing anything.
public struct TransactionExportPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL? = nil

    public init(url: URL) { self.url = url }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Preview", onClose: { dismiss() })
            PDFKitView(url: url)
            TwoButtonRow {
                Button("Share") { shareURL = url }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("export.preview.share")
            } secondary: {
                Button("Close") { dismiss() }
                    .buttonStyle(TertiaryButtonStyle())
                    .accessibilityIdentifier("export.preview.close")
            }
            .padding()
        }
        .accessibilityIdentifier("export.preview")
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                FileShareSheet(url: shareURL)
            }
        }
    }
}

/// PDFKit's PDFView, wrapped for SwiftUI: a scrollable,
/// pinch-to-zoom rendering of the finished statement.
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGray6
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - PDF renderer (UIGraphicsPDFRenderer)

/// Draws a `TransactionExportPDFStatement` as a branded STAGE
/// statement (build 59, Nov 22, 2026): wordmark header in
/// uniform stage blue, a Summary section with three donut charts
/// (Money In vs Out, Spending by Kind, Tzedaka Share) built from
/// the same transactions as the table, the table (date, merchant,
/// amount, kind) with amounts and kinds in the transaction
/// colour code, footer totals, and a page number on every page.
/// Letter pages. The content model is kit-tested; this is only
/// the drawing.
public enum TransactionExportPDFRenderer {
    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { pageRect.width - margin * 2 }

    private static let stageBlue = UIColor(red: 0x02 / 255, green: 0x88 / 255, blue: 0xdd / 255, alpha: 1)
    private static let deep = UIColor(red: 0x1d / 255, green: 0x4e / 255, blue: 0xd8 / 255, alpha: 1)
    private static let ink = UIColor(red: 0x0f / 255, green: 0x17 / 255, blue: 0x2a / 255, alpha: 1)
    private static let muted = UIColor(red: 0x6b / 255, green: 0x72 / 255, blue: 0x80 / 255, alpha: 1)
    private static let divider = UIColor(red: 0xe5 / 255, green: 0xe7 / 255, blue: 0xeb / 255, alpha: 1)

    /// A UIColor from a "#rrggbb" hex string (the kit's colour
    /// code). Falls back to ink for malformed input.
    private static func color(hex: String) -> UIColor {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else { return ink }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    public static func data(statement: TransactionExportPDFStatement) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "STAGE Transactions"]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return renderer.pdfData { context in
            var pageNumber = 1
            func drawPageFooter() {
                let text = "Page \(pageNumber)"
                let font = UIFont.systemFont(ofSize: 10)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: muted]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: CGPoint(x: (pageRect.width - size.width) / 2, y: pageRect.height - 28),
                    withAttributes: attributes
                )
            }
            func beginNewPage() {
                drawPageFooter()
                pageNumber += 1
                context.beginPage()
            }

            var y = margin
            context.beginPage()
            // Branded header: the STAGE wordmark in one uniform
            // stage blue (no S logo in a PDF — the full wordmark
            // reads as one word), then household, range, generated.
            y = draw("S · T · A · G · E", at: y, font: .boldSystemFont(ofSize: 20), color: stageBlue)
            y = draw(statement.householdName, at: y + 4, font: .boldSystemFont(ofSize: 18), color: ink)
            y = draw(statement.dateRange, at: y + 4, font: .systemFont(ofSize: 13), color: muted)
            y = draw(statement.generatedLine, at: y + 2, font: .systemFont(ofSize: 12), color: muted)
            y += 12
            drawThickDivider(at: y, color: stageBlue)
            y += 14
            // Summary charts (donuts) — the same transactions as
            // the table, so the visuals and the rows agree.
            if !statement.charts.isEmpty {
                let height = chartsSectionHeight(statement.charts)
                if y + height > pageRect.height - margin {
                    beginNewPage()
                    y = margin
                }
                y = drawCharts(statement.charts, at: y)
                y += 12
                drawDivider(at: y)
                y += 12
            }
            // Table.
            y = drawTableHeader(at: y)
            for row in statement.rows {
                if y + 20 > pageRect.height - margin - 80 {
                    beginNewPage()
                    y = margin
                    y = drawTableHeader(at: y)
                }
                y = drawTableRow(row, at: y)
            }
            // Footer totals: a new page when they would not fit.
            if y + 76 > pageRect.height - margin {
                beginNewPage()
                y = margin
            }
            y += 8
            drawDivider(at: y)
            y += 12
            y = drawTotal(label: "Total In", value: statement.totalInText, at: y, bold: false, valueColor: deep)
            y = drawTotal(label: "Total Out", value: statement.totalOutText, at: y, bold: false, valueColor: ink)
            y = drawTotal(label: "Net", value: statement.netText, at: y, bold: true, valueColor: stageBlue)
            drawPageFooter()
            _ = y
        }
    }

    // MARK: - Charts

    /// The height of the whole Summary section, so the caller
    /// can page-break before it: Summary title + chart titles
    /// + donuts + the tallest legend (two lines per slice).
    private static func chartsSectionHeight(_ charts: [TransactionExportChart]) -> CGFloat {
        let maxSlices = charts.map(\.slices.count).max() ?? 0
        return 18 + 10 + 14 + 8 + 96 + 8 + CGFloat(maxSlices * 26)
    }

    /// The Summary section: one column per chart, each with a
    /// title, a donut, and a two-line-per-slice legend (dot +
    /// label, then amount and share). Returns the y below it.
    private static func drawCharts(_ charts: [TransactionExportChart], at y: CGFloat) -> CGFloat {
        var y = y
        y = draw("Summary", at: y, font: .boldSystemFont(ofSize: 14), color: ink)
        y += 10
        let columnWidth = contentWidth / CGFloat(charts.count)
        let maxSlices = charts.map(\.slices.count).max() ?? 0
        let donutRadius: CGFloat = 48
        let holeRadius: CGFloat = 24
        let sectionTop = y
        for (index, chart) in charts.enumerated() {
            let columnX = margin + CGFloat(index) * columnWidth
            let centerX = columnX + columnWidth / 2
            // Title, centered over the donut.
            _ = drawCentered(chart.title, at: centerX, y: sectionTop, font: .boldSystemFont(ofSize: 11), color: ink)
            // Donut, centered in the column.
            let donutCenter = CGPoint(x: centerX, y: sectionTop + 14 + 8 + donutRadius)
            drawDonut(chart: chart, center: donutCenter, outerRadius: donutRadius, holeRadius: holeRadius)
            // Legend, left-aligned in the column.
            let legendX = columnX + 8
            let legendY = sectionTop + 14 + 8 + donutRadius * 2 + 8
            _ = drawLegend(slices: chart.slices, total: chart.totalCents, at: legendX, y: legendY, width: columnWidth - 16)
        }
        return sectionTop + 14 + 8 + donutRadius * 2 + 8 + CGFloat(maxSlices * 26)
    }

    /// One donut: a filled wedge per slice from the top, going
    /// clockwise, then a white hole punched in the middle.
    private static func drawDonut(chart: TransactionExportChart, center: CGPoint, outerRadius: CGFloat, holeRadius: CGFloat) {
        let total = chart.totalCents
        guard total > 0 else { return }
        var startAngle = -CGFloat.pi / 2
        for slice in chart.slices {
            let fraction = CGFloat(slice.cents) / CGFloat(total)
            let endAngle = startAngle + fraction * 2 * CGFloat.pi
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            path.close()
            color(hex: slice.colorHex).setFill()
            path.fill()
            startAngle = endAngle
        }
        let hole = UIBezierPath(ovalIn: CGRect(
            x: center.x - holeRadius, y: center.y - holeRadius,
            width: holeRadius * 2, height: holeRadius * 2
        ))
        UIColor.white.setFill()
        hole.fill()
    }

    /// The legend under one donut: per slice, a colour dot +
    /// label, then the amount and share on the line below. The
    /// shares are whole percents that sum to 100 (the last slice
    /// takes the remainder, so rounding never leaves 99 or 101).
    /// Returns the y below the legend.
    private static func drawLegend(slices: [TransactionExportChartSlice], total: Int, at x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        var lineY = y
        let dotRadius: CGFloat = 4
        let labelFont = UIFont.boldSystemFont(ofSize: 10)
        let valueFont = UIFont.systemFont(ofSize: 10)
        var pctSoFar = 0
        for (index, slice) in slices.enumerated() {
            let dotCenter = CGPoint(x: x + dotRadius, y: lineY + 5)
            let dot = UIBezierPath(ovalIn: CGRect(
                x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            ))
            color(hex: slice.colorHex).setFill()
            dot.fill()
            let labelX = x + dotRadius * 2 + 4
            (slice.label as NSString).draw(
                in: CGRect(x: labelX, y: lineY, width: width - dotRadius * 2 - 4, height: 13),
                withAttributes: [.font: labelFont, .foregroundColor: ink, .paragraphStyle: truncatingParagraphStyle()]
            )
            let pct: Int
            if index == slices.count - 1 {
                pct = max(0, 100 - pctSoFar)
            } else {
                pct = Int((Double(slice.cents) / Double(total) * 100).rounded())
                pctSoFar += pct
            }
            let valueText = "\(slice.amountText) · \(pct)%"
            (valueText as NSString).draw(
                at: CGPoint(x: labelX, y: lineY + 13),
                withAttributes: [.font: valueFont, .foregroundColor: muted]
            )
            lineY += 26
        }
        return lineY
    }

    // MARK: - Text helpers

    @discardableResult
    private static func draw(_ text: String, at y: CGFloat, font: UIFont, color: UIColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        return y + size.height
    }

    @discardableResult
    private static func drawCentered(_ text: String, at centerX: CGFloat, y: CGFloat, font: UIFont, color: UIColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: centerX - size.width / 2, y: y), withAttributes: attributes)
        return y + size.height
    }

    private static func drawDivider(at y: CGFloat) {
        divider.setFill()
        UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 1))
    }

    private static func drawThickDivider(at y: CGFloat, color: UIColor) {
        color.setFill()
        UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 2))
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
        let rowColor = color(hex: row.colorHex)
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
        drawRightAligned(row.amount, at: CGPoint(x: margin + 348, y: y), width: 92, font: font, color: rowColor)
        (row.kind as NSString).draw(
            at: CGPoint(x: margin + 448, y: y),
            withAttributes: [.font: font, .foregroundColor: rowColor]
        )
        return y + 20
    }

    @discardableResult
    private static func drawTotal(label: String, value: String, at y: CGFloat, bold: Bool, valueColor: UIColor) -> CGFloat {
        let font = bold ? UIFont.boldSystemFont(ofSize: 13) : UIFont.systemFont(ofSize: 13)
        (label as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [.font: font, .foregroundColor: ink]
        )
        drawRightAligned(value, at: CGPoint(x: margin + 340, y: y), width: 192, font: font, color: valueColor)
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
