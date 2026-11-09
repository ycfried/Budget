import Foundation

/// Money + date formatting for the Funds / Review / Trash screens.
/// Mirrors the web app's `formatCents` / `fmtLong` (`live.js`, `engine.mjs:350`):
/// plain `$1,234.56`, negative as `-$X`. Dates are `YYYY-MM-DD` in
/// America/New_York; weeks are Sunday–Saturday. The app's data floor is
/// 2026-11-01 — no date before it is ever accepted.
public enum MoneyFormat {
    // MARK: - Money

    /// `$1,234.56` for 123456 cents; `-$12.34` for -1234. A confirmed
    /// zero is `$0.00`, never `—` (spec §2.4).
    public static func formatCents(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let absCents = abs(cents)
        let dollars = absCents / 100
        let remainder = absCents % 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US")
        let dollarsText = formatter.string(from: NSNumber(value: dollars)) ?? "\(dollars)"
        return "\(sign)$\(dollarsText).\(String(format: "%02d", remainder))"
    }

    /// Strict dollars → cents, mirroring live.js `parseDollarsStrict`:
    /// optional leading `$`, commas allowed, digits with at most two
    /// decimal places, nothing else. Returns nil for empty, negative,
    /// or malformed input — an empty field is never 0.
    public static func parseDollarsStrict(_ text: String) -> Int? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("$") { cleaned.removeFirst() }
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        guard parts[0].allSatisfy({ $0.isNumber }), !parts[0].isEmpty else { return nil }
        var cents = Int(parts[0]) ?? 0
        cents *= 100
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard fraction.count <= 2, fraction.allSatisfy({ $0.isNumber }) else { return nil }
            var fractionCents = Int(fraction) ?? 0
            if fraction.count == 1 { fractionCents *= 10 }
            cents += fractionCents
        }
        return cents
    }

    /// Percent from basis points, no trailing zeros: 1000 → "10",
    /// 1050 → "10.5" (live.js rate formatting, spec §9.3).
    public static func formatRateBp(_ basisPoints: Int) -> String {
        let percent = Double(basisPoints) / 100.0
        if percent.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(percent))"
        }
        var text = String(format: "%.2f", percent)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Percent text → basis points: "10.5" → 1050. Nil when unparseable.
    public static func parseRatePercent(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let value = Double(cleaned), value >= 0, value <= 100 else { return nil }
        return Int((value * 100).rounded())
    }

    // MARK: - Dates

    /// Parse a `YYYY-MM-DD` date as UTC noon (no timezone shift).
    public static func date(from dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateString)
    }

    /// `YYYY-MM-DD` for a date (UTC calendar, no shift).
    public static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Long form: "Nov 8, 2026" (`fmtLong`, live.js).
    public static func fmtLong(_ dateString: String) -> String {
        guard let date = date(from: dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Short form for list rows: "Nov 8, 2026" (same as fmtLong; the web
    /// `displayDay` renders the same shape for resolved dates).
    public static func displayDay(_ dateString: String) -> String {
        fmtLong(String(dateString.prefix(10)))
    }

    /// "Mon D, YYYY, h:mm AM" for a created_at timestamp
    /// (live.js `fmtDateTime` shape).
    public static func fmtDateTime(_ isoString: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: isoString)
            ?? ISO8601DateFormatter().date(from: isoString)
        guard let date else { return displayDay(isoString) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.string(from: date)
    }

    /// Today's date in America/New_York, `YYYY-MM-DD`.
    public static func todayNY() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.string(from: Date())
    }

    /// The Sunday starting the current week, in America/New_York.
    public static func currentSundayNY() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        calendar.firstWeekday = 1
        let now = Date()
        let startOfWeek = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? now
        return dateString(from: startOfWeek)
    }

    /// The `count` consecutive Sundays starting at `firstSunday`
    /// (`YYYY-MM-DD`), for the Temporary Allowance preview + loop.
    public static func sundays(from firstSunday: String, count: Int) -> [String] {
        guard let start = date(from: firstSunday) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return (0..<max(1, min(4, count))).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index * 7, to: start) else { return nil }
            return dateString(from: day)
        }
    }

    /// Days between two `YYYY-MM-DD` dates (second minus first).
    public static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let start = date(from: from), let end = date(from: to) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// The app's data floor: no transaction dated before this is shown
    /// or accepted (live.js:231, 756).
    public static let dataFloor = "2026-11-01"
}
