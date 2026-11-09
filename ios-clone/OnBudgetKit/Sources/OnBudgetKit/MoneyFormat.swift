// OnBudgetKit — MoneyFormat.swift
//
// Display formatting ported from the live web app (v66), so screens
// render exactly what the web renders. Pure Foundation — no SwiftUI,
// no network — so it is unit-tested in this package.
//
// Sources: `formatCents` / `fmtLong` / `fmtDateTime` (live.js),
// `parseDollarsStrict` (live.js:52-60), `formatCentsHtml` cents span
// (live.js:3651-3659 — the app renders dollars + a smaller cents span;
// this helper returns the plain string; screens split it if needed).

import Foundation

/// Money + date display formatting for the live web v66 clone.
public enum MoneyFormat {
    private static let monthShort = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Plain `$1,234.56`; negative renders as `-$X` (engine.mjs:350).
    /// A confirmed zero is `$0.00`, never a dash.
    public static func formatCents(_ cents: Int) -> String {
        let negative = cents < 0
        let absolute = abs(cents)
        let dollars = absolute / 100
        let remainder = absolute % 100
        var grouped = ""
        var remaining = dollars
        repeat {
            let chunk = remaining % 1000
            remaining /= 1000
            let chunkText = remaining > 0
                ? String(format: "%03d", chunk)
                : String(chunk)
            grouped = grouped.isEmpty ? chunkText : chunkText + "," + grouped
        } while remaining > 0
        let centsText = String(format: "%02d", remainder)
        return (negative ? "-" : "") + "$" + grouped + "." + centsText
    }

    /// `YYYY-MM-DD` -> `Mon D, YYYY` (e.g. "Nov 8, 2026").
    /// Unparseable input is returned unchanged, never crashed on.
    public static func fmtLong(_ dateString: String) -> String {
        guard let parts = parseDateParts(dateString) else { return dateString }
        return "\(monthShort[parts.month - 1]) \(parts.day), \(parts.year)"
    }

    /// `YYYY-MM-DD` -> `Mon D` (e.g. "Nov 8").
    public static func fmtShort(_ dateString: String) -> String {
        guard let parts = parseDateParts(dateString) else { return dateString }
        return "\(monthShort[parts.month - 1]) \(parts.day)"
    }

    /// ISO timestamp -> `Mon D, h:mm AM` in America/New_York
    /// (live.js `fmtDateTime`). Unparseable input is returned unchanged.
    public static func fmtDateTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: isoString)
            ?? ISO8601DateFormatter().date(from: isoString)
        guard let date else { return isoString }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US")
        output.timeZone = TimeZone(identifier: "America/New_York")
        output.dateFormat = "MMM d, h:mm a"
        return output.string(from: date)
    }

    /// The `YYYY-MM-DD` of the day part of an ISO timestamp, in
    /// America/New_York (used to group Activity entries by day).
    public static func newYorkDayString(_ isoString: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString)
            ?? ISO8601DateFormatter().date(from: isoString) else { return nil }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(identifier: "America/New_York")
        output.dateFormat = "yyyy-MM-dd"
        return output.string(from: date)
    }

    /// Sunday `weekStart` (`YYYY-MM-DD`) + 6 days, as `YYYY-MM-DD`.
    /// Returns nil for an unparseable start.
    public static func weekEndString(weekStart: String) -> String? {
        guard let parts = parseDateParts(weekStart) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(identifier: "UTC") ?? .current
        output.dateFormat = "yyyy-MM-dd"
        return output.string(from: end)
    }

    /// Strict money-input parsing (live.js `parseDollarsStrict`):
    /// empty, blank, or non-numeric input is nil — never 0.
    /// An explicitly typed "0" parses to 0.
    public static func parseDollarsStrict(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"^-?\d+(\.\d{1,2})?$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil,
              let number = Double(trimmed), number.isFinite else { return nil }
        return Int((number * 100).rounded())
    }

    /// A valid email address per the web's profile check
    /// (live.js:3383): `^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$`.
    public static func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseDateParts(_ dateString: String) -> (year: Int, month: Int, day: Int)? {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        return (year, month, day)
    }
}
