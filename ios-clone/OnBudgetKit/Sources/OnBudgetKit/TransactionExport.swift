// OnBudgetKit — TransactionExport.swift
//
// Transaction export (build 45, Nov 18, 2026): the pure, testable
// half of the Transactions-page export. The app target owns the
// popup, the full-history fetch, and the UIGraphicsPDFRenderer
// drawing (UIKit is unavailable to this package's tests, which run
// on macOS/Linux — see FundIcons.swift); everything that decides
// WHAT goes in the file lives here, in plain Foundation, so the
// kit tests pin it exactly.
//
// The export is read-only: it never changes transactions. It takes
// the rows it is given and nothing else — the app applies the
// active `TransactionFilters` (filtered scope) or passes the whole
// household history (Export all) before calling in. A generator
// given a filtered list can never re-expand it.
//
// Amounts: the sign is DERIVED from the same kind rule as
// `TransactionFormatting.amountDisplay` (app target), never copied
// from the stored value — income rows store NEGATIVE cents in the
// DB and read as positive money in. Transfers flip too (Plaid
// stores money-out positive, money-in negative). Every other kind
// keeps its stored sign. Zero is "0.00" / "$0.00" for every kind.
//
// Labels are human-readable Title Case, never raw enum values:
// kind "Fund Charge" (not `fund_charge`), source "Bank" (not
// `plaid`), fund from the household's CURRENT display names
// (`fundNames`, same map as `appState.fundNames` — a renamed fund
// reads under its new name, never a hardcoded default). The
// fund-name resolution mirrors `FundSectionID.displayName(
// customNames:)` (app target) keyed by the same raw strings
// ("spending" / "fund" / "charity"); the kit cannot import the app
// target, so the rule is restated here, not re-derived.

import Foundation

/// Export scope: the filtered list, or the whole household history.
public enum TransactionExportScope: String, Equatable, CaseIterable {
    case filtered
    case all

    public var label: String {
        switch self {
        case .filtered: return "Filtered"
        case .all: return "All"
        }
    }
}

/// Export format, picked at export time.
public enum TransactionExportFormat: String, Equatable, CaseIterable {
    case pdf
    case csv

    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .csv: return "CSV"
        }
    }

    /// "transactions-2026-11-18.pdf" — the share-sheet filename.
    public func fileName(generatedDate: String = TransactionExport.todayString()) -> String {
        "transactions-\(generatedDate).\(rawValue)"
    }
}

/// Totals for one exported set, in cents. "In" is the money-in
/// kinds (income / refund / cashback) plus incoming transfers;
/// "Out" is every other kind (charges, fund charges, charity,
/// payments) plus outgoing transfers; "Net" is In − Out. The
/// direction is kind-based, not sign-based — see `totals`.
public struct TransactionExportTotals: Equatable {
    public let totalInCents: Int
    public let totalOutCents: Int
    public var netCents: Int { totalInCents - totalOutCents }

    public init(totalInCents: Int, totalOutCents: Int) {
        self.totalInCents = totalInCents
        self.totalOutCents = totalOutCents
    }
}

/// One PDF statement row (what the renderer draws, in order).
/// `colorHex` is the transaction's colour from the app's colour
/// code (Income deep blue, Spending ink, Charity primary blue,
/// Excluded grey) — the renderer colours the amount and kind by
/// it, so the PDF reads like the app's transaction list.
public struct TransactionExportPDFRow: Equatable {
    public let date: String
    public let merchant: String
    public let amount: String
    public let kind: String
    public let colorHex: String

    public init(date: String, merchant: String, amount: String, kind: String, colorHex: String) {
        self.date = date
        self.merchant = merchant
        self.amount = amount
        self.kind = kind
        self.colorHex = colorHex
    }
}

/// One slice of a statement chart: a labeled share of a total,
/// in cents, with its brand colour as a hex string. The renderer
/// draws slices as donut wedges and the legend from these.
public struct TransactionExportChartSlice: Equatable {
    public let label: String
    public let cents: Int
    public let colorHex: String
    public let amountText: String

    public init(label: String, cents: Int, colorHex: String, amountText: String) {
        self.label = label
        self.cents = cents
        self.colorHex = colorHex
        self.amountText = amountText
    }
}

/// One chart in the statement: a titled set of slices that sum
/// to a total. Built from the same transactions as the table, so
/// the charts and the rows can never disagree.
public struct TransactionExportChart: Equatable {
    public let title: String
    public let slices: [TransactionExportChartSlice]
    public var totalCents: Int { slices.reduce(0) { $0 + $1.cents } }

    public init(title: String, slices: [TransactionExportChartSlice]) {
        self.title = title
        self.slices = slices
    }
}

/// The PDF statement's content, as data — the app renderer draws
/// exactly these lines, in this order, and nothing else. No IDs,
/// no raw enum names, no internal machinery.
public struct TransactionExportPDFStatement: Equatable {
    /// Household name, as stored.
    public let householdName: String
    /// "Nov 1, 2026 – Nov 18, 2026", one date, or "All Transactions".
    public let dateRange: String
    /// "Generated Nov 18, 2026".
    public let generatedLine: String
    public let rows: [TransactionExportPDFRow]
    public let totals: TransactionExportTotals
    /// "$1,234.56" forms of the totals, for the footer.
    public let totalInText: String
    public let totalOutText: String
    public let netText: String
    /// The summary charts (donuts), built from the same
    /// transactions as `rows` — In vs Out, Out by kind, Charity
    /// share. Empty when the set has nothing to chart.
    public let charts: [TransactionExportChart]

    public init(
        householdName: String, dateRange: String, generatedLine: String,
        rows: [TransactionExportPDFRow], totals: TransactionExportTotals,
        totalInText: String, totalOutText: String, netText: String,
        charts: [TransactionExportChart]
    ) {
        self.householdName = householdName
        self.dateRange = dateRange
        self.generatedLine = generatedLine
        self.rows = rows
        self.totals = totals
        self.totalInText = totalInText
        self.totalOutText = totalOutText
        self.netText = netText
        self.charts = charts
    }
}

public enum TransactionExport {

    // MARK: - Display-signed amounts (the amountDisplay rule, pure)

    /// The cents as the file shows them: money-in kinds (income /
    /// refund / cashback) flip to positive, transfers flip (Plaid
    /// stores money-out positive, money-in negative), payments and
    /// trashed rows keep their stored sign, everything else keeps
    /// its stored sign. Zero stays zero.
    public static func displaySignedCents(for transaction: Transaction) -> Int {
        if transaction.amountCents == 0 { return 0 }
        if transaction.kind == .transfer {
            return -transaction.amountCents
        }
        if transaction.isInflow {
            return abs(transaction.amountCents)
        }
        return transaction.amountCents
    }

    /// "$12.34" / "-$10.00" / "+$75.00" — the app's display text
    /// for the row (money-in kinds get the "+" prefix).
    public static func amountText(for transaction: Transaction) -> String {
        let signed = displaySignedCents(for: transaction)
        if signed == 0 { return MoneyFormat.formatCents(0) }
        if signed > 0, transaction.isInflow || transaction.kind == .transfer {
            return "+" + MoneyFormat.formatCents(signed)
        }
        return MoneyFormat.formatCents(signed)
    }

    /// Plain number for the CSV amount column: "75.00", "-100.00",
    /// "12.34" — two decimals, no "$", no commas (so the amount
    /// never needs quoting), sign per the display rule above.
    public static func amountDecimalText(for transaction: Transaction) -> String {
        let signed = displaySignedCents(for: transaction)
        let sign = signed < 0 ? "-" : ""
        let absolute = abs(signed)
        return "\(sign)\(absolute / 100).\(String(format: "%02d", absolute % 100))"
    }

    // MARK: - Human-readable labels (never raw enum values)

    /// "Charge" / "Refund" / "Fund Charge" / "Payment" /
    /// "Cashback" / "Transfer" / "Income" / "Charity". An unknown
    /// kind reads Title-Cased from its raw value ("fund_charge"
    /// would read "Fund Charge" the same way).
    public static func kindName(for transaction: Transaction) -> String {
        kindName(forKind: transaction.kind)
    }

    /// The same human-readable name from the kind alone (the
    /// charts group by kind, with no single transaction to name).
    public static func kindName(forKind kind: TransactionKind) -> String {
        switch kind {
        case .charge: return "Charge"
        case .refund: return "Refund"
        case .fundCharge: return "Fund Charge"
        case .payment: return "Payment"
        case .cashback: return "Cashback"
        case .transfer: return "Transfer"
        case .income: return "Income"
        case .charity: return "Charity"
        case .other(let raw):
            return TitleCase.apply(to: raw.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// "Bank" (plaid) / "Email" (amex_alert) / "CSV" (csv) /
    /// "Manual" (manual) / "Restored" (restored).
    public static func sourceName(for transaction: Transaction) -> String {
        switch transaction.source {
        case .plaid: return "Bank"
        case .amexAlert: return "Email"
        case .csv: return "CSV"
        case .manual: return "Manual"
        case .restored: return "Restored"
        }
    }

    /// The fund the row belongs to, under its CURRENT display name
    /// (a renamed fund reads under its new name): charge →
    /// Spending, fund_charge → the fund's name, charity → Tzedaka.
    /// Income, refunds, cashback, payments and transfers belong to
    /// no fund: "—", never a guessed fund.
    public static func fundName(for transaction: Transaction, fundNames: [String: String] = [:]) -> String {
        switch transaction.kind {
        case .charge: return displayFundName(key: "spending", fallback: "Spending", fundNames: fundNames)
        case .fundCharge: return displayFundName(key: "fund", fallback: "Extra Fund", fundNames: fundNames)
        case .charity: return displayFundName(key: "charity", fallback: "Charity", fundNames: fundNames)
        default: return "—"
        }
    }

    /// Same resolution as `FundSectionID.displayName(customNames:)`
    /// (app target): the stored custom name when present and
    /// non-blank, else the default. The custom name is shown
    /// exactly as typed.
    public static func displayFundName(key: String, fallback: String, fundNames: [String: String]) -> String {
        if let custom = fundNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return fallback
    }

    /// The row's merchant as shown: Title-Cased, except transfers,
    /// which read "Transfer from ••5939" / "Transfer to ••5939"
    /// (direction from the signed amount, other account from the
    /// bank description — mirrors `TransactionFormatting.
    /// transferTitle`, app target; the parsing is restated here so
    /// the kit stays self-contained).
    public static func merchantDisplay(for transaction: Transaction) -> String {
        guard transaction.kind == .transfer else {
            return TitleCase.apply(to: transaction.merchant)
        }
        let direction: String?
        if transaction.amountCents < 0 {
            direction = "from"
        } else if transaction.amountCents > 0 {
            direction = "to"
        } else {
            direction = nil
        }
        guard let direction else { return "Transfer" }
        if let last4 = otherAccountLast4(for: transaction) {
            return TitleCase.apply(to: "Transfer \(direction) ••\(last4)")
        }
        return TitleCase.apply(to: "Transfer \(direction)")
    }

    /// The OTHER account's last 4 digits from the bank's merchant
    /// string: the last run of exactly 4 digits, skipping a run
    /// equal to this row's own `cardSuffix` (that names this
    /// account, not the other one). Longer runs are not last-4s.
    public static func otherAccountLast4(for transaction: Transaction) -> String? {
        var found: String? = nil
        var run = ""
        func flushRun() {
            if run.count == 4, run != transaction.cardSuffix {
                found = run
            }
            run = ""
        }
        for character in transaction.merchant {
            if character.isNumber {
                run.append(character)
            } else {
                flushRun()
            }
        }
        flushRun()
        return found
    }

    /// "••1005"; cash / no card ("0000") reads "Cash", never
    /// "••0000".
    public static func cardDisplay(for transaction: Transaction) -> String {
        if transaction.cardSuffix == "0000" { return "Cash" }
        return "••\(transaction.cardSuffix)"
    }

    // MARK: - CSV

    public static let csvHeader = "Date,Merchant,Amount,Kind,Source,Fund,Card"

    /// One CSV field, quoted exactly when it must be: a field
    /// containing a comma, quote, or newline is wrapped in quotes
    /// and its internal quotes are doubled. Anything else is
    /// written bare.
    public static func csvField(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The whole CSV file: header row + one row per transaction, in
    /// the order given (the app sorts before calling — the
    /// generator never re-sorts, so a filtered list stays filtered
    /// and ordered). Dates stay `YYYY-MM-DD` (sortable,
    /// unambiguous); amounts are plain display-signed numbers.
    public static func csvString(transactions: [Transaction], fundNames: [String: String] = [:]) -> String {
        var lines = [csvHeader]
        for transaction in transactions {
            let fields = [
                transaction.date,
                merchantDisplay(for: transaction),
                amountDecimalText(for: transaction),
                kindName(for: transaction),
                sourceName(for: transaction),
                fundName(for: transaction, fundNames: fundNames),
                cardDisplay(for: transaction),
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Totals

    /// Total in / total out / net over the exported set. The
    /// direction is decided by KIND, not by the display sign: a
    /// charge displays as a bare "$12.34" (no minus), but it is
    /// still money out — a sign-based split would count every
    /// charge as money in. Money-in kinds (income / refund /
    /// cashback) count toward In at their display magnitude;
    /// transfers split by their flipped display sign (money in
    /// vs money out); every other kind (charge, fund charge,
    /// charity, payment) counts toward Out at its display
    /// magnitude. Zero rows count toward neither.
    public static func totals(transactions: [Transaction]) -> TransactionExportTotals {
        var totalIn = 0
        var totalOut = 0
        for transaction in transactions {
            let signed = displaySignedCents(for: transaction)
            if transaction.isInflow {
                totalIn += abs(signed)
            } else if transaction.kind == .transfer {
                if signed > 0 {
                    totalIn += signed
                } else if signed < 0 {
                    totalOut += -signed
                }
            } else if signed != 0 {
                totalOut += abs(signed)
            }
        }
        return TransactionExportTotals(totalInCents: totalIn, totalOutCents: totalOut)
    }

    // MARK: - Row colour + charts (build 59, Nov 22, 2026)

    /// The row's colour from the app's transaction colour code
    /// (owner, Nov 22, 2026 — the branded PDF reads like the
    /// app's list): money-in kinds deep blue #1d4ed8, Charity
    /// primary blue #2f6bff, transfers muted grey #6b7280,
    /// excluded rows muted grey, a zero amount ink, everything
    /// else Spending ink #0f172a. Mirrors the app's
    /// `amountDisplay` colour rule (kit-pinned here so the PDF
    /// and the list can never drift apart).
    public static func rowColorHex(for transaction: Transaction) -> String {
        if transaction.excluded || transaction.state == .excluded {
            return DesignTokens.mutedHex
        }
        if transaction.amountCents == 0 { return DesignTokens.inkHex }
        if let fixed = transaction.kind.fixedAmountColorHex { return fixed }
        if transaction.isInflow { return DesignTokens.deepHex }
        return DesignTokens.inkHex
    }

    /// The donut-slice colour for one money-out kind: Charge is
    /// Spending ink, Charity primary blue, Payment muted grey,
    /// Fund Charge fund amber, Transfer mid blue, anything else
    /// light blue. All brand tokens — never a guessed hex.
    public static func chartColorHex(for kind: TransactionKind) -> String {
        switch kind {
        case .charge: return DesignTokens.inkHex
        case .charity: return DesignTokens.primaryHex
        case .payment: return DesignTokens.mutedHex
        case .fundCharge: return DesignTokens.fundHex
        case .transfer: return DesignTokens.midHex
        default: return DesignTokens.lightHex
        }
    }

    /// The statement's summary charts, built from the same
    /// transactions as the table — so the charts and the rows
    /// always agree. Three donuts, in order: Money In vs Money
    /// Out; Money Out by kind; Tzedaka's share of Money Out.
    /// A chart is left out when it has nothing to show (no money
    /// in or out at all; no charity yet), and a slice is left out
    /// when its amount is zero — a donut never carries an empty
    /// wedge. Slices are biggest first, so the legend reads in
    /// size order.
    public static func charts(transactions: [Transaction]) -> [TransactionExportChart] {
        let totals = totals(transactions: transactions)
        var result: [TransactionExportChart] = []

        // 1. Money In vs Money Out.
        var inOutSlices: [TransactionExportChartSlice] = []
        if totals.totalInCents > 0 {
            inOutSlices.append(TransactionExportChartSlice(
                label: "Money In", cents: totals.totalInCents,
                colorHex: DesignTokens.deepHex,
                amountText: MoneyFormat.formatCents(totals.totalInCents)
            ))
        }
        if totals.totalOutCents > 0 {
            inOutSlices.append(TransactionExportChartSlice(
                label: "Money Out", cents: totals.totalOutCents,
                colorHex: DesignTokens.inkHex,
                amountText: MoneyFormat.formatCents(totals.totalOutCents)
            ))
        }
        if !inOutSlices.isEmpty {
            result.append(TransactionExportChart(title: "Money In vs Out", slices: inOutSlices))
        }

        // 2. Money Out by kind (the spending breakdown).
        var byKind: [TransactionKind: Int] = [:]
        for transaction in transactions {
            let signed = displaySignedCents(for: transaction)
            let outCents: Int
            if transaction.isInflow {
                continue
            } else if transaction.kind == .transfer {
                guard signed < 0 else { continue }
                outCents = -signed
            } else {
                guard signed != 0 else { continue }
                outCents = abs(signed)
            }
            byKind[transaction.kind, default: 0] += outCents
        }
        let kindSlices = byKind
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { kind, cents in
                TransactionExportChartSlice(
                    label: kindName(forKind: kind),
                    cents: cents,
                    colorHex: chartColorHex(for: kind),
                    amountText: MoneyFormat.formatCents(cents)
                )
            }
        if !kindSlices.isEmpty {
            result.append(TransactionExportChart(title: "Spending by Kind", slices: kindSlices))
        }

        // 3. Tzedaka's share of Money Out.
        let charityCents = byKind[.charity] ?? 0
        if totals.totalOutCents > 0, charityCents > 0 {
            var charitySlices: [TransactionExportChartSlice] = [
                TransactionExportChartSlice(
                    label: "Tzedaka", cents: charityCents,
                    colorHex: DesignTokens.primaryHex,
                    amountText: MoneyFormat.formatCents(charityCents)
                ),
            ]
            let rest = totals.totalOutCents - charityCents
            if rest > 0 {
                charitySlices.append(TransactionExportChartSlice(
                    label: "Everything Else", cents: rest,
                    colorHex: DesignTokens.tertiaryHex,
                    amountText: MoneyFormat.formatCents(rest)
                ))
            }
            result.append(TransactionExportChart(title: "Tzedaka Share", slices: charitySlices))
        }

        return result
    }

    // MARK: - Date range + PDF statement model

    /// Today's date as `YYYY-MM-DD` in New York.
    public static func todayString(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return formatter.string(from: date)
    }

    /// The range the exported set covers, from its own dates:
    /// "Nov 1, 2026 – Nov 18, 2026", one date alone, or "All
    /// Transactions" when the set is empty (nothing to range over).
    public static func dateRangeLabel(transactions: [Transaction]) -> String {
        let dates = transactions.map(\.date).sorted()
        guard let first = dates.first, let last = dates.last else {
            return "All Transactions"
        }
        if first == last { return MoneyFormat.fmtLong(first) }
        return "\(MoneyFormat.fmtLong(first)) – \(MoneyFormat.fmtLong(last))"
    }

    /// The statement content the PDF renderer draws: header
    /// (household, range, generated date), one row per transaction
    /// (date, merchant, amount, kind), footer totals. Rows keep
    /// the order given.
    public static func pdfStatement(
        transactions: [Transaction],
        householdName: String,
        generatedDate: String = todayString()
    ) -> TransactionExportPDFStatement {
        let totals = totals(transactions: transactions)
        let rows = transactions.map { transaction in
            TransactionExportPDFRow(
                date: MoneyFormat.fmtLong(transaction.date),
                merchant: merchantDisplay(for: transaction),
                amount: amountText(for: transaction),
                kind: kindName(for: transaction),
                colorHex: rowColorHex(for: transaction)
            )
        }
        return TransactionExportPDFStatement(
            householdName: householdName,
            dateRange: dateRangeLabel(transactions: transactions),
            generatedLine: "Generated \(MoneyFormat.fmtLong(generatedDate))",
            rows: rows,
            totals: totals,
            totalInText: MoneyFormat.formatCents(totals.totalInCents),
            totalOutText: MoneyFormat.formatCents(totals.totalOutCents),
            netText: MoneyFormat.netTotalText(cents: totals.netCents),
            charts: charts(transactions: transactions)
        )
    }
}
