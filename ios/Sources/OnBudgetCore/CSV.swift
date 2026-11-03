import Foundation

public struct CSVRow: Equatable, Sendable, Identifiable {
    public let rowNumber: Int
    public var id: Int { rowNumber }
    public let date: PurchaseDate
    public let merchant: String
    public let amount: Money
    public let cardSuffix: String
}
public struct CSVPreview: Equatable, Sendable {
    public let rows: [CSVRow]
    public let errors: [String]
    /// Duplicate detection and reconciliation belong to the server matcher.
    public let reconciliationNote = "Preview only. Duplicate and match decisions require the server."
}
public enum CSVImport {
    public static let maximumBytes = 2_000_000
    public static func preview(_ text: String) -> CSVPreview {
        guard text.utf8.count <= maximumBytes else { return CSVPreview(rows: [], errors: ["File exceeds the 2 MB limit."]) }
        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let parsed: [[String]]
        do { parsed = try fields(clean) }
        catch { return CSVPreview(rows: [], errors: ["Unclosed quote or invalid CSV quoting."]) }
        guard let header = parsed.first else { return CSVPreview(rows: [], errors: ["The file is empty."]) }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count,
              let dateIndex = names.firstIndex(of: "date"), let nameIndex = names.firstIndex(of: "description"),
              let amountIndex = names.firstIndex(of: "amount"), let cardIndex = names.firstIndex(of: "card ending") else {
            return CSVPreview(rows: [], errors: ["Expected unique columns: Date, Description, Amount, Card Ending."])
        }
        var rows: [CSVRow] = []; var errors: [String] = []
        for (offset, row) in parsed.dropFirst().enumerated() {
            let number = offset + 2
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            do {
                guard row.count == header.count else { throw ServiceError.invalidRequest }
                let rawDate = row[dateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let date: PurchaseDate
                if rawDate.contains("/") {
                    let pieces = rawDate.split(separator: "/").compactMap { Int($0) }
                    guard rawDate.range(of: #"^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$"#, options: .regularExpression) != nil, pieces.count == 3 else { throw InputError.invalidDate }
                    date = try PurchaseDate(String(format: "%04d-%02d-%02d", pieces[2], pieces[0], pieces[1]))
                } else { date = try PurchaseDate(rawDate) }
                var amountText = row[amountIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if amountText.hasPrefix("("), amountText.hasSuffix(")") { amountText = "-" + amountText.dropFirst().dropLast() }
                amountText = amountText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
                let amount = try Money(dollars: amountText)
                guard amount.cents != 0 else { throw InputError.invalidAmount }
                let merchant = row[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !merchant.isEmpty, merchant.count <= 120 else { throw InputError.invalidMerchant }
                let suffix = row[cardIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                guard suffix.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else { throw InputError.invalidCard }
                rows.append(CSVRow(rowNumber: number, date: date, merchant: merchant, amount: amount, cardSuffix: suffix))
            } catch { errors.append("Row \(number): invalid date, amount, merchant, card digits, or column count.") }
        }
        return CSVPreview(rows: rows, errors: errors)
    }
    private enum ParseError: Error { case malformed }
    private static func fields(_ text: String) throws -> [[String]] {
        if text.isEmpty { return [] }
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var records: [[String]] = []; var row: [String] = []; var field = ""
        var quoted = false; var closed = false; var index = 0
        while index < chars.count {
            let ch = chars[index]
            if quoted {
                if ch == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(ch) }
            } else if ch == "," || ch == "\n" {
                row.append(field); field = ""; closed = false
                if ch == "\n" { records.append(row); row = [] }
            } else if ch == "\"" {
                guard field.isEmpty, !closed else { throw ParseError.malformed }
                quoted = true
            } else {
                guard !closed else { throw ParseError.malformed }
                field.append(ch)
            }
            index += 1
        }
        guard !quoted else { throw ParseError.malformed }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); records.append(row) }
        return records
    }
}
