// OnBudgetKit — CSVParsing.swift
//
// CSV import parsing + classification, ported from the live web app
// (v66). Pure Foundation — unit-tested in this package.
//
// Sources: `parseCsvLive` / `parseAmountLive` / `normalizeMerchant` /
// `csvRowKey` / `isPreNovDate` (live.js:215-298),
// `classifyCsvKind` (filterState.mjs:501-519, mirroring
// canonical.ts classifyKind).

import Foundation

/// One parsed CSV row, before dedupe marking.
public struct ParsedCSVRow: Equatable {
    public let date: String
    public let merchant: String
    public let amountCents: Int
    public let suffix: String

    public init(date: String, merchant: String, amountCents: Int, suffix: String) {
        self.date = date
        self.merchant = merchant
        self.amountCents = amountCents
        self.suffix = suffix
    }

    /// The preview dedupe key: normalized merchant / date / amount /
    /// suffix (live.js `csvRowKey`).
    public var dedupeKey: String { CSVParsing.csvRowKey(self) }
}

/// The result of parsing a CSV file's text: parsed rows plus the
/// error lines for rows that were skipped.
public struct ParsedCSV: Equatable {
    public let rows: [ParsedCSVRow]
    public let errors: [String]

    public init(rows: [ParsedCSVRow], errors: [String]) {
        self.rows = rows
        self.errors = errors
    }
}

public enum CSVParsing {
    /// The app's data floor: no transaction dated before 2026-11-01
    /// is ever shown or accepted (live.js:231).
    public static let dataFloorDate = "2026-11-01"

    /// Quote-aware comma split of one CSV line (live.js:244-252).
    public static func splitCSVLine(_ line: String) -> [String] {
        var output: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                output.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        output.append(current)
        return output.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Amounts accept `$`, commas, and `(…)` negatives
    /// (live.js `parseAmountLive`).
    public static func parseAmountLive(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        guard let number = Double(text), number.isFinite else { return nil }
        let cents = Int((abs(number) * 100).rounded())
        return (negative || number < 0) ? -cents : cents
    }

    /// Upper-cased, whitespace-collapsed merchant (live.js
    /// `normalizeMerchant`).
    public static func normalizeMerchant(_ merchant: String) -> String {
        merchant.uppercased().trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Canonical preview dedupe key: normalized merchant with
    /// punctuation dropped / date / amount / suffix.
    public static func csvRowKey(_ row: ParsedCSVRow) -> String {
        let merchant = normalizeMerchant(row.merchant)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
        return "\(merchant)|\(row.date)|\(row.amountCents)|\(row.suffix)"
    }

    /// Same key shape for an already-stored transaction row.
    public static func csvRowKey(merchant: String, date: String, amountCents: Int, suffix: String) -> String {
        csvRowKey(ParsedCSVRow(date: date, merchant: merchant, amountCents: amountCents, suffix: suffix))
    }

    public static func isPreNovDate(_ date: String) -> Bool {
        date.count == 10 && date < dataFloorDate
    }

    /// Parse CSV text (`parseCsvLive`): header must include Date,
    /// Description, Amount (Card Ending optional); dates `YYYY-MM-DD`
    /// or `MM/DD/YYYY`; suffix = last 4 digits of the Card Ending
    /// column else `0000`. Rows before 2026-11-01 and unparseable rows
    /// are skipped with an error line each.
    public static func parseCSV(_ text: String) -> ParsedCSV {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            return ParsedCSV(rows: [], errors: ["CSV needs a header row and at least one data row."])
        }
        let header = splitCSVLine(lines[0]).map { $0.lowercased() }
        let dateIndex = header.firstIndex { $0.contains("date") } ?? -1
        let merchantIndex = header.firstIndex { $0.contains("description") || $0.contains("merchant") } ?? -1
        let amountIndex = header.firstIndex { $0.contains("amount") } ?? -1
        let suffixIndex = header.firstIndex { $0.contains("ending") || $0.contains("card") } ?? -1
        guard dateIndex >= 0, merchantIndex >= 0, amountIndex >= 0 else {
            return ParsedCSV(rows: [], errors: ["Header must include Date, Description, and Amount columns."])
        }
        var rows: [ParsedCSVRow] = []
        var errors: [String] = []
        for line in lines.dropFirst() {
            let columns = splitCSVLine(line)
            func column(_ index: Int) -> String {
                index >= 0 && index < columns.count ? columns[index] : ""
            }
            let dateRaw = column(dateIndex)
            let merchant = normalizeMerchant(column(merchantIndex))
            let cents = parseAmountLive(column(amountIndex))
            let suffixText = suffixIndex >= 0 ? column(suffixIndex) : ""
            let suffix: String = {
                // live.js: last 4 digits at the END of the column,
                // else `0000`.
                let trimmed = suffixText.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 4 else { return "0000" }
                let tail = String(trimmed.suffix(4))
                return tail.allSatisfy { $0.isNumber } ? tail : "0000"
            }()
            var date = dateRaw
            let mdy = dateRaw.split(separator: "/").map(String.init)
            if mdy.count == 3, let month = Int(mdy[0]), let day = Int(mdy[1]), let year = Int(mdy[2]) {
                date = String(format: "%04d-%02d-%02d", year, month, day)
            }
            let validDate = date.count == 10
                && date[date.index(date.startIndex, offsetBy: 4)] == "-"
                && date[date.index(date.startIndex, offsetBy: 7)] == "-"
                && date.filter({ $0.isNumber || $0 == "-" }).count == 10
            guard validDate, !merchant.isEmpty, let amountCents = cents else {
                errors.append("Skipped unparseable row: \(line)")
                continue
            }
            guard !isPreNovDate(date) else {
                errors.append("Skipped row before Nov 1, 2026: \(line)")
                continue
            }
            rows.append(ParsedCSVRow(date: date, merchant: merchant, amountCents: amountCents, suffix: suffix))
        }
        return ParsedCSV(rows: rows, errors: errors)
    }

    /// Classify a CSV row's kind (filterState.mjs `classifyCsvKind`):
    /// transfer-first, then deposit/payment/cashback/charity name
    /// patterns, else refund by sign, else charge.
    public static func classifyKind(merchant: String, amountCents: Int) -> String {
        let name = merchant
        func matches(_ pattern: String) -> Bool {
            name.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
        }
        if matches("INTERNAL TRANSFER") { return "transfer" }
        if amountCents < 0 && matches("CHECK DEPOSIT|MOBILE DEPOSIT|\\bDEPOSIT\\b") { return "income" }
        if matches("MOBILE PAYMENT|PAYMENT - THANK YOU|CARD PAYMENT|PAYMENT\\s*:\\s*CREDIT|PAYMENT CREDIT|/ ?PAYMENT|EPAYMENT|E-PAYMENT|ACH PAYMENT") {
            return "payment"
        }
        if matches("CASH BACK|CASHBACK|REWARD") { return "cashback" }
        if amountCents > 0 && matches("\\b(CHARITY|DONATION|DONATE|TZEDAKA|TZEDAKAH|KEREN|CHABAD|TOIREMORG|COLEL)\\b") {
            return "charity"
        }
        return amountCents < 0 ? "refund" : "charge"
    }
}
