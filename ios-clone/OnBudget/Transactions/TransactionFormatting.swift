import Foundation
import SwiftUI
import OnBudgetKit

/// Pure display formatting for Transactions — no network.
///
/// Every label below is copied from the live web app v66
/// (`origin/main` live.js). Money is integer cents; dates are
/// `YYYY-MM-DD` strings in America/New_York; the data floor is
/// 2026-11-01 — no row dated before it is ever shown or accepted.
/// The amount-colour helper returns a SwiftUI Color, so this file
/// imports SwiftUI; the money text itself stays pure (MoneyFormat).
public enum TransactionFormatting {

    /// The app's data floor (live.js:231, 756).
    public static let dataFloorDate = "2026-11-01"

    // MARK: - Money

    /// `formatCents` (engine.mjs:350): plain `$1,234.56`, negative
    /// as `-$X` (never `($X)`).
    public static func formatCents(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let abs = abs(cents)
        let dollars = abs / 100
        let remainder = abs % 100
        let dollarsText = dollarsString(dollars)
        return "\(sign)$\(dollarsText).\(String(format: "%02d", remainder))"
    }

    private static func dollarsString(_ dollars: Int) -> String {
        let text = String(dollars)
        var grouped = ""
        for (index, char) in text.reversed().enumerated() {
            if index > 0, index % 3 == 0 { grouped.append(",") }
            grouped.append(char)
        }
        return String(grouped.reversed())
    }

    // MARK: - Amount display: the one shared kind→colour rule
    //
    // Owner, Nov 12, 2026 (voice note + refinement the same day):
    // the KIND, not the direction, decides how a transaction
    // amount renders — every screen routes its row amounts through
    // `amountDisplay(for:)`, never through its own colour logic.
    // - Money in (kind income / refund / cashback): GREEN
    //   (`DesignTokens.success`, #16a34a) with a "+" prefix
    //   ("+$75.00"). The stored Plaid negative is flipped to "+"
    //   here, at the display layer only.
    // - Charity gifts (kind charity): BLUE (`DesignTokens.primary`,
    //   #2f6bff). Charity rows are outflows, but the kind decides.
    // - Regular kinds (charge / payment / transfer / fund charge /
    //   other): BLACK ink, stored sign kept ("$X" / "-$X").
    // - RED is never a transaction amount: it stays reserved for
    //   the over-budget hero figure, negative balances, and errors.
    // - Zero is "$0.00" in ink for every kind.
    // Display only: the model cents, the week math, and the totals
    // are untouched — only the text and colour of a rendered row
    // change.

    /// Text + colour for one transaction row, under the shared
    /// kind rule above. The single helper every amount-rendering
    /// screen uses (Home Recent, Transactions list + detail,
    /// Trash, Review, action sheets, toasts that quote a row).
    public static func amountDisplay(for transaction: Transaction) -> (text: String, color: Color) {
        if transaction.amountCents == 0 { return (formatCents(0), DesignTokens.ink) }
        if transaction.isInflow {
            return (
                MoneyFormat.amountText(cents: transaction.amountCents, isMoneyIn: true),
                DesignTokens.success
            )
        }
        if transaction.kind == .charity {
            return (formatCents(transaction.amountCents), DesignTokens.primary)
        }
        return (formatCents(transaction.amountCents), DesignTokens.ink)
    }

    /// Display for an amount already known to be money in —
    /// charity income rows, fund top-ups, savings transfer-in /
    /// interest, a released surplus: "+$X" green. A zero or
    /// negative input falls back to the plain rendering: a known
    /// inflow is positive by construction, so this is only a guard.
    public static func inflowDisplay(cents: Int) -> (text: String, color: Color) {
        guard cents > 0 else { return (formatCents(cents), DesignTokens.ink) }
        return ("+" + formatCents(cents), DesignTokens.success)
    }

    /// Strict money parsing (live.js:52-60 `parseDollarsStrict`):
    /// empty / blank / non-numeric is nil, never 0. Accepts `$`,
    /// commas, and `(…)` negatives. Returns integer cents.
    public static func parseDollarsStrict(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        guard let value = Decimal(string: text), value.isFinite else { return nil }
        var cents = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        let int = NSDecimalNumber(decimal: rounded).intValue
        // 0 is a real parse result (callers reject non-positive
        // amounts where the form requires one); only unparseable is nil.
        return negative || value < 0 ? -abs(int) : abs(int)
    }

    // MARK: - Dates (America/New_York)

    public static var newYorkTimeZone: TimeZone {
        TimeZone(identifier: "America/New_York") ?? .current
    }

    /// Today's date as `YYYY-MM-DD` in New York (live.js `nyTodayString`).
    public static func nyTodayString(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = newYorkTimeZone
        return formatter.string(from: date)
    }

    /// The current Sunday–Saturday week in New York, as `YYYY-MM-DD` bounds.
    public static func currentWeekBounds(date: Date = Date()) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYorkTimeZone
        calendar.firstWeekday = 1
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        guard let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: startOfDay),
              let saturday = calendar.date(byAdding: .day, value: 6, to: sunday) else {
            let today = nyTodayString(date: date)
            return (today, today)
        }
        return (string(from: sunday), string(from: saturday))
    }

    /// The current calendar month in New York, as `YYYY-MM-DD` bounds
    /// (first day – last day). Companion to `currentWeekBounds`, for
    /// the single "When" control's "This Month" quick pick.
    public static func currentMonthBounds(date: Date = Date()) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYorkTimeZone
        let startOfDay = calendar.startOfDay(for: date)
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: startOfDay)),
              let range = calendar.range(of: .day, in: .month, for: startOfDay),
              let last = calendar.date(byAdding: .day, value: range.count - 1, to: first) else {
            let today = nyTodayString(date: date)
            return (today, today)
        }
        return (string(from: first), string(from: last))
    }

    /// First – last day of a `YYYY-MM` month, as `YYYY-MM-DD` bounds.
    /// A past month stored in the filter normalizes to its span (the
    /// single "When" control has no month dropdown — a stored past
    /// month reads as its custom range, same effect).
    public static func monthBounds(_ yearMonth: String) -> (start: String, end: String) {
        guard let first = dateFromString("\(yearMonth)-01") else { return (yearMonth + "-01", yearMonth + "-01") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYorkTimeZone
        guard let range = calendar.range(of: .day, in: .month, for: first),
              let last = calendar.date(byAdding: .day, value: range.count - 1, to: first) else {
            return (string(from: first), string(from: first))
        }
        return (string(from: first), string(from: last))
    }

    /// The current month as `YYYY-MM` in New York.
    public static func currentMonthString(date: Date = Date()) -> String {
        String(nyTodayString(date: date).prefix(7))
    }

    /// `YYYY-MM-DD` for a Date, in New York.
    public static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = newYorkTimeZone
        return formatter.string(from: date)
    }

    /// Parse a `YYYY-MM-DD` string as a New York noon date (noon
    /// avoids DST midnight shifts — live.js uses `T12:00:00` too).
    public static func dateFromString(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = newYorkTimeZone
        return formatter.date(from: "\(string) 12:00:00")
    }

    /// `displayDay` (live.js:41): Today / Yesterday (NY date), else
    /// `Mon D` short form.
    public static func displayDay(_ dateString: String, today: String? = nil) -> String {
        let todayNY = today ?? nyTodayString()
        if dateString == todayNY { return "Today" }
        if let todayDate = dateFromString(todayNY),
           let yesterday = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: todayDate),
           dateString == string(from: yesterday) {
            return "Yesterday"
        }
        return fmtShort(dateString)
    }

    /// `fmtShort`: `Mon D` (live.js `fmtShort`).
    public static func fmtShort(_ dateString: String) -> String {
        guard let date = dateFromString(dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en-US")
        formatter.dateFormat = "MMM d"
        formatter.timeZone = newYorkTimeZone
        return formatter.string(from: date)
    }

    /// `fmtLong`: `Mon D, YYYY` (live.js `fmtLong`).
    public static func fmtLong(_ dateString: String) -> String {
        guard let date = dateFromString(dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en-US")
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = newYorkTimeZone
        return formatter.string(from: date)
    }

    /// `weekRangeOf` (live.js:4076): `Mon D – Mon D, YYYY` (Sun–Sat).
    public static func weekRangeOf(_ dateString: String) -> String {
        guard let date = dateFromString(dateString) else { return dateString }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYorkTimeZone
        let weekday = calendar.component(.weekday, from: date)
        guard let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: date),
              let saturday = calendar.date(byAdding: .day, value: 6, to: sunday) else {
            return dateString
        }
        return "\(fmtShort(string(from: sunday))) – \(fmtLong(string(from: saturday)))"
    }

    /// `Month YYYY` for a `YYYY-MM` value (filter month options).
    public static func monthLabel(_ yearMonth: String) -> String {
        guard let date = dateFromString("\(yearMonth)-02") else { return yearMonth }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en-US")
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = newYorkTimeZone
        return formatter.string(from: date)
    }

    // MARK: - Row labels

    /// Merchant names display Title-Cased; stored values stay upper-case.
    public static func displayMerchant(_ merchant: String) -> String {
        TitleCase.apply(to: merchant)
    }

    /// `stateWord` (live.js:205): Posted / Pending / Reversed / Excluded.
    /// "Reversed" renders as Reversed, never Posted.
    public static func stateWord(for transaction: Transaction) -> String {
        if transaction.isInTrash { return "Excluded" }
        switch transaction.state {
        case .reversed: return "Reversed"
        case .provisional: return "Pending"
        case .verified: return "Posted"
        case .excluded: return "Excluded"
        }
    }

    /// Kind label in detail (live.js:990): Refund / Charity gift /
    /// Transfer / Transaction.
    public static func kindLabel(for transaction: Transaction) -> String {
        switch transaction.kind {
        case .refund: return "Refund"
        case .charity: return "Charity gift"
        case .transfer: return "Transfer"
        default: return "Transaction"
        }
    }

    /// Source labels, display only (live.js:347): Bank / By hand /
    /// File / Email (renamed from "Email alert", owner Nov 11, 2026).
    public static func sourceLabel(for source: TransactionSource) -> String {
        switch source {
        case .plaid: return "Bank"
        case .manual: return "By hand"
        case .csv: return "File"
        case .amexAlert: return "Email"
        }
    }

    /// Card label (live.js:989, 1040): `••suffix`; charity cash gifts
    /// show "Cash / no card", never `••0000`.
    public static func cardLabel(for transaction: Transaction) -> String {
        if transaction.kind == .charity, transaction.cardSuffix == "0000" {
            return "Cash / no card"
        }
        return "••\(transaction.cardSuffix)"
    }

    /// One chip label for the From/To date range: "Nov 8 – Nov 14"
    /// for a range, just "Nov 8" when both bounds are the same date,
    /// "From Nov 8" / "To Nov 14" for a single bound; nil when no
    /// date filter is set.
    public static func dateRangeChipLabel(from fromDate: String, to toDate: String) -> String? {
        if fromDate.isEmpty, toDate.isEmpty { return nil }
        if !fromDate.isEmpty, !toDate.isEmpty {
            if fromDate == toDate { return fmtShort(fromDate) }
            return "\(fmtShort(fromDate)) – \(fmtShort(toDate))"
        }
        if !fromDate.isEmpty { return "From \(fmtShort(fromDate))" }
        return "To \(fmtShort(toDate))"
    }
}

// MARK: - Client-side list filtering (live.js:786-830)

/// The Transactions status filter values (live.js §7.3).
public enum TransactionStatusFilter: String, Equatable, CaseIterable {
    case all
    case charity
    case pending
    case posted
    case refunds

    public var label: String {
        switch self {
        case .all: return "All transactions"
        case .charity: return "Charity gifts"
        case .pending: return "Pending"
        case .posted: return "Posted"
        case .refunds: return "Refunds"
        }
    }
}

/// Sort field + direction (live.js:823-833). Amount sort is by
/// absolute value; the direction button shows arrow AND words.
public enum TransactionSort: String, Equatable, CaseIterable {
    case dateDesc = "date-desc"
    case dateAsc = "date-asc"
    case amountDesc = "amount-desc"
    case amountAsc = "amount-asc"

    /// Menu label for the single Sort picker (one control, all four
    /// options): "Newest first" / "Oldest first" / "Amount: high to
    /// low" / "Amount: low to high".
    public var label: String {
        switch self {
        case .dateDesc: return "Newest first"
        case .dateAsc: return "Oldest first"
        case .amountDesc: return "Amount: high to low"
        case .amountAsc: return "Amount: low to high"
        }
    }

    public var field: String { rawValue.hasPrefix("amount") ? "amount" : "date" }
    public var isAscending: Bool { rawValue.hasSuffix("asc") }

    /// "↓ Newest First" / "↑ Oldest First" / "↓ Largest first" /
    /// "↑ Smallest first" (live.js:829-833).
    public var directionLabel: String {
        switch self {
        case .dateAsc: return "↑ Oldest First"
        case .amountDesc: return "↓ Largest first"
        case .amountAsc: return "↑ Smallest first"
        case .dateDesc: return "↓ Newest First"
        }
    }

    public func toggledDirection() -> TransactionSort {
        switch self {
        case .dateDesc: return .dateAsc
        case .dateAsc: return .dateDesc
        case .amountDesc: return .amountAsc
        case .amountAsc: return .amountDesc
        }
    }

    public func withField(_ field: String) -> TransactionSort {
        if field == "amount" { return isAscending ? .amountAsc : .amountDesc }
        return isAscending ? .dateAsc : .dateDesc
    }
}

/// The single "When" choice (Filters rethink, Nov 11, 2026 — owner:
/// one button + one calendar, tap a start date then an end date).
/// It replaces the three overlapping date controls (month dropdown,
/// "This week" toggle, From/To fields): the sheet offers This Week /
/// This Month / a custom range, and Clear returns to unfiltered
/// (no All Time pick). The stored filter keeps its old fields
/// (`month` / `weekOnly` / `fromDate` / `toDate`); this enum is the
/// one presentation of them, mapped both ways below.
public enum WhenSelection: Equatable {
    case allTime
    case thisWeek
    case thisMonth
    case custom(from: String, to: String)

    /// Plain label for the When button: "Choose Dates" when no
    /// range is set (T-P2-15 — the quick picks no longer offer All
    /// Time) / "This Week" / "This Month" / "Nov 8 – Nov 14"
    /// (one-sided range: "From Nov 8" / "To Nov 14").
    public var label: String {
        switch self {
        case .allTime: return "Choose Dates"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .custom(let from, let to):
            return TransactionFormatting.dateRangeChipLabel(from: from, to: to) ?? "Custom Range"
        }
    }
}

/// The full filter set for the Transactions list. Filters combine
/// (AND): status + month + card + week + From/To + min/max + search.
/// Applied client-side to the loaded page — the server list is the
/// whole household history page (live.js:751-756).
public struct TransactionFilters: Equatable {
    public var status: TransactionStatusFilter = .all
    /// `YYYY-MM`, or "all".
    public var month: String = "all"
    /// Card suffix, or "all".
    public var card: String = "all"
    public var weekOnly: Bool = false
    /// `YYYY-MM-DD`, empty = no bound.
    public var fromDate: String = ""
    /// `YYYY-MM-DD`, empty = no bound.
    public var toDate: String = ""
    /// Signed cents; nil = no limit.
    public var minCents: Int? = nil
    /// Signed cents; nil = no limit.
    public var maxCents: Int? = nil
    public var search: String = ""
    public var sort: TransactionSort = .dateDesc

    public init() {}

    /// min > max is a validation state, not an empty result (live.js:813).
    public var amountRangeInvalid: Bool {
        guard let minCents, let maxCents else { return false }
        return minCents > maxCents
    }

    /// True when any search or filter is active (drives the
    /// no-match empty copy).
    public var isSearchOrFilterActive: Bool {
        status != .all || month != "all" || card != "all" || weekOnly
            || !fromDate.isEmpty || !toDate.isEmpty
            || minCents != nil || maxCents != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Active-filter chips: (key, label) pairs; tapping a chip clears
    /// only that filter (live.js §7.1). The From/To date range is ONE
    /// chip ("Nov 8 – Nov 14"), never two — tapping it clears both
    /// dates.
    public var activeChips: [(key: String, label: String)] {
        var chips: [(String, String)] = []
        if status != .all { chips.append(("status", status.label)) }
        if card != "all" { chips.append(("card", "••\(card)")) }
        // ONE date chip at most, from the single "When" choice —
        // never a "From" chip and a "To" chip, never a week chip
        // beside a month chip.
        switch whenSelection {
        case .allTime: break
        case .thisWeek: chips.append(("when", "This Week"))
        case .thisMonth: chips.append(("when", "This Month"))
        case .custom(let from, let to):
            if let rangeLabel = TransactionFormatting.dateRangeChipLabel(from: from, to: to) {
                chips.append(("when", rangeLabel))
            }
        }
        if let minCents { chips.append(("min", "Min \(TransactionFormatting.formatCents(minCents))")) }
        if let maxCents { chips.append(("max", "Max \(TransactionFormatting.formatCents(maxCents))")) }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            chips.append(("search", "“\(search.trimmingCharacters(in: .whitespaces))”"))
        }
        return chips
    }

    public mutating func clearChip(_ key: String) {
        switch key {
        case "status": status = .all
        case "month": month = "all"
        case "card": card = "all"
        case "week": weekOnly = false
        case "when": setWhenSelection(.allTime)
        case "range": fromDate = ""; toDate = ""
        case "from": fromDate = ""
        case "to": toDate = ""
        case "min": minCents = nil
        case "max": maxCents = nil
        case "search": search = ""
        default: break
        }
    }

    /// "This week" and a custom From/To range are one choice, never
    /// both: turning This week on clears the dates; setting a date
    /// turns This week off. The filter sheet keeps its draft in
    /// agreement the same way; these helpers keep the applied
    /// filter in agreement too.
    public mutating func setWeekOnly(_ on: Bool) {
        weekOnly = on
        if on { fromDate = ""; toDate = "" }
    }

    public mutating func setFromDate(_ date: String) {
        fromDate = date
        if !date.isEmpty { weekOnly = false }
    }

    public mutating func setToDate(_ date: String) {
        toDate = date
        if !date.isEmpty { weekOnly = false }
    }

    /// The stored date fields as the single "When" choice. A stored
    /// past month has no place in the single control, so it reads as
    /// its custom range (same dates, same effect — only the
    /// presentation changes).
    public var whenSelection: WhenSelection {
        if weekOnly { return .thisWeek }
        if !fromDate.isEmpty || !toDate.isEmpty { return .custom(from: fromDate, to: toDate) }
        if month != "all" {
            if month == TransactionFormatting.currentMonthString() { return .thisMonth }
            let bounds = TransactionFormatting.monthBounds(month)
            return .custom(from: bounds.start, to: bounds.end)
        }
        return .allTime
    }

    /// Write a "When" choice into the stored date fields. One choice
    /// only: a new choice clears the other three, so the filter can
    /// never hold This week ON with dates set (the old contradiction).
    public mutating func setWhenSelection(_ selection: WhenSelection) {
        switch selection {
        case .allTime:
            weekOnly = false
            month = "all"
            fromDate = ""
            toDate = ""
        case .thisWeek:
            month = "all"
            setWeekOnly(true)
        case .thisMonth:
            weekOnly = false
            fromDate = ""
            toDate = ""
            month = TransactionFormatting.currentMonthString()
        case .custom(let from, let to):
            month = "all"
            setFromDate(from)
            setToDate(to)
        }
    }

    /// Apply all filters to the loaded page (live.js:798-830).
    /// Excluded rows never appear here — they live only in Trash.
    public func apply(to transactions: [Transaction]) -> [Transaction] {
        if amountRangeInvalid { return [] }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let week = TransactionFormatting.currentWeekBounds()
        let filtered = transactions.filter { tx in
            guard !tx.isInTrash else { return false }
            switch status {
            case .pending: guard tx.state == .provisional else { return false }
            case .posted: guard tx.state == .verified else { return false }
            case .refunds: guard tx.kind == .refund else { return false }
            case .charity: guard tx.kind == .charity else { return false }
            case .all: break
            }
            if month != "all", !tx.date.hasPrefix(month) { return false }
            if card != "all", tx.cardSuffix != card { return false }
            if weekOnly, !(tx.date >= week.start && tx.date <= week.end) { return false }
            if !fromDate.isEmpty, tx.date < fromDate { return false }
            if !toDate.isEmpty, tx.date > toDate { return false }
            if let minCents, tx.amountCents < minCents { return false }
            if let maxCents, tx.amountCents > maxCents { return false }
            if !query.isEmpty {
                let merchantMatch = tx.merchant.lowercased().contains(query)
                let dateMatch = tx.date.contains(query)
                let amountMatch = TransactionFormatting.formatCents(tx.amountCents).lowercased().contains(query)
                guard merchantMatch || dateMatch || amountMatch else { return false }
            }
            return true
        }
        return sortTransactions(filtered)
    }

    public func sortTransactions(_ transactions: [Transaction]) -> [Transaction] {
        switch sort {
        case .dateDesc:
            return transactions.sorted { $0.date > $1.date }
        case .dateAsc:
            return transactions.sorted { $0.date < $1.date }
        case .amountDesc:
            return transactions.sorted {
                abs($0.amountCents) != abs($1.amountCents)
                    ? abs($0.amountCents) > abs($1.amountCents)
                    : $0.date > $1.date
            }
        case .amountAsc:
            return transactions.sorted {
                abs($0.amountCents) != abs($1.amountCents)
                    ? abs($0.amountCents) < abs($1.amountCents)
                    : $0.date > $1.date
            }
        }
    }

    /// The list total (live.js:863-872): net spending only — charges
    /// + fund charges − refunds (refunds as −|amount|); payments,
    /// cashback, transfers, income, charity never count. On the
    /// Charity filter the total is the gifts total.
    public static func shownTotal(for shown: [Transaction], status: TransactionStatusFilter) -> Int {
        if status == .charity {
            return shown.filter { !$0.isInTrash && $0.kind == .charity }
                .reduce(0) { $0 + $1.amountCents }
        }
        return shown.filter {
            !$0.isInTrash && $0.state != .reversed
                && ($0.kind == .charge || $0.kind == .fundCharge || $0.kind == .refund)
        }.reduce(0) { sum, tx in
            sum + (tx.kind == .refund ? -abs(tx.amountCents) : tx.amountCents)
        }
    }

    /// Months present in the loaded page, newest first.
    public static func months(in transactions: [Transaction]) -> [String] {
        Array(Set(transactions.map { String($0.date.prefix(7)) })).sorted().reversed()
    }

    /// Card suffixes present in the loaded page, sorted.
    public static func cards(in transactions: [Transaction]) -> [String] {
        Array(Set(transactions.map(\.cardSuffix))).sorted()
    }
}

/// Merchant stem for refund-link candidate search (live.js:3890-3901):
/// the first word of the merchant, used as an `ilike %stem%` match,
/// falling back to every same-card charge in the window when no name
/// matches.
public enum RefundLinkCandidates {
    public static func merchantStem(for merchant: String) -> String? {
        let cleaned = merchant.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let first = cleaned.split(separator: " ").first.map(String.init) ?? cleaned
        return first.isEmpty ? nil : first
    }

    /// 90 days before the refund date, as `YYYY-MM-DD`.
    public static func windowStart(for refundDate: String) -> String {
        guard let date = TransactionFormatting.dateFromString(refundDate),
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -90, to: date) else {
            return TransactionFormatting.dataFloorDate
        }
        return TransactionFormatting.string(from: start)
    }
}
