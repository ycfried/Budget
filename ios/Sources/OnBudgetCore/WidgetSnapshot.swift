import Foundation

/// Minimal display cache. No session, household identifiers, merchant, or bank fields.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let available: Money
    public let fundAvailable: Money
    public let computedAt: Date
    public let isSample: Bool
    public init(available: Money, fundAvailable: Money, computedAt: Date, isSample: Bool) {
        self.available = available; self.fundAvailable = fundAvailable
        self.computedAt = computedAt; self.isSample = isSample
    }
    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(computedAt) > 3600 || computedAt > date
    }
}
public enum HistoryExport {
    /// Spreadsheet formula injection protection for exported text cells.
    private static func cell(_ value: String) -> String {
        let guarded = ["=", "+", "-", "@"].contains(value.first.map(String.init) ?? "") ? "'" + value : value
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func csv(_ weeks: [HistoryWeek]) -> String {
        let header = "Week,Allowance cents,Increment cents,Debt in cents,Debt out cents,Spent cents,Surplus cents,Release,Revision"
        return ([header] + weeks.map {
            [cell($0.weekStart), String($0.allowance.cents), String($0.increment.cents), String($0.debtIn.cents),
             String($0.debtOut.cents), String($0.spent.cents), String($0.surplus.cents), cell($0.releaseStatus), cell($0.revisionNote)].joined(separator: ",")
        }).joined(separator: "\n")
    }
}
