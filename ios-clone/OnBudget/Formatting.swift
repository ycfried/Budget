// OnBudget — Formatting.swift
//
// Pure formatting + client-side validation for the Auth + Home screens.
// Foundation only (no SwiftUI) so the logic stays parseable and testable
// on any toolchain. All money is integer cents; display uses the web
// app's formatCents rule (engine.mjs:350): plain "$1,234.56", negative
// as "-$X". Dates are YYYY-MM-DD in America/New_York; weeks are
// Sunday–Saturday. Clone basis: live web v66.

import Foundation
import OnBudgetKit

/// Money + date formatting shared by the Auth and Home screens.
/// The single owner of `MoneyFormat` is `OnBudgetKit.MoneyFormat`
/// (integration, Nov 9, 2026 — the two app-target copies that used
/// to live here and in Funds/MoneyFormat.swift are deleted); this
/// typealias is the one app-target spelling, so existing call sites
/// (`MoneyFormat.string`, `.formatCents`, …) keep working.
/// NOTE: the kit's `parseDollarsStrict` and `fmtDateTime` are the
/// web-faithful shapes (live.js:44-53, fmtDateTime has no year);
/// the deleted Funds copy rejected negatives / $-prefixed input and
/// stamped a year — both diverged from the web and are gone with it.
public typealias MoneyFormat = OnBudgetKit.MoneyFormat

/// The single owner of `Transaction` is `OnBudgetKit.Transaction`
/// (compile-fixes, Nov 9, 2026): bare `Transaction` is ambiguous
/// in the app target because SwiftUI also declares a `Transaction`
/// type, and the app never uses SwiftUI's (no `withTransaction` /
/// `.transaction(` anywhere). This typealias is the one app-target
/// spelling, exactly like `MoneyFormat` above, so every existing
/// call site keeps working and the model stays canonical in the kit.
public typealias Transaction = OnBudgetKit.Transaction

/// Date helpers. The app's data floor is 2026-11-01; no transaction
/// dated before it is ever shown (live.js:756).
public enum AppDates {

    public static let newYork = TimeZone(identifier: "America/New_York")!

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = newYork
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = newYork
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        formatter.timeZone = newYork
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// "2026-11-08" -> Date, or nil when the string is malformed.
    public static func date(from yyyyMMdd: String) -> Date? {
        dayFormatter.date(from: yyyyMMdd)
    }

    /// "2026-11-08" -> "Nov 8, 2026".
    public static func long(_ yyyyMMdd: String) -> String {
        guard let date = date(from: yyyyMMdd) else { return yyyyMMdd }
        return longFormatter.string(from: date)
    }

    /// Hero kicker: "Nov 8, 2026 (Sun–Sat)" (live.js weekLabel).
    public static func weekLabel(weekStart: String) -> String {
        "\(long(weekStart)) (Sun–Sat)"
    }

    /// Today / Yesterday (New York date) or "Mon D, YYYY" short form.
    public static func relativeDay(_ yyyyMMdd: String) -> String {
        guard date(from: yyyyMMdd) != nil else { return yyyyMMdd }
        let today = dayFormatter.string(from: Date())
        if yyyyMMdd == today { return "Today" }
        if let yesterday = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date()) {
            if yyyyMMdd == dayFormatter.string(from: yesterday) { return "Yesterday" }
        }
        return long(yyyyMMdd)
    }

    /// "Last synced Nov 9, 4:32 PM" from an ISO-8601 timestamp, or nil
    /// when there is no sync on record.
    public static func lastSyncLabel(isoTimestamp: String?) -> String? {
        guard let raw = isoTimestamp, !raw.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }
        return "Last synced \(shortTimeFormatter.string(from: date))"
    }

    /// The Sunday (YYYY-MM-DD) of the week containing `date`, New York.
    public static func sunday(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        calendar.firstWeekday = 1 // Sunday
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard let sunday = calendar.date(from: components) else {
            return dayFormatter.string(from: date)
        }
        return dayFormatter.string(from: sunday)
    }

    /// True when `yyyyMMdd` falls in the week starting `weekStart`.
    public static func isInWeek(_ yyyyMMdd: String, weekStart: String) -> Bool {
        guard let day = date(from: yyyyMMdd), let start = date(from: weekStart) else { return false }
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: start) ?? start
        return day >= start && day < end
    }
}

/// Client-side validation that runs BEFORE any Supabase call, using
/// the web app's exact messages (live.js:2397-2620, reset.html).
public enum AuthValidation {

    public static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("@") else { return false }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].contains(".") else { return false }
        return true
    }

    /// Sign-in field checks. Sign-in failure itself is deliberately
    /// generic ("Username or password is incorrect.") and never names a field.
    public static func signInError(email: String, password: String) -> String? {
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an email address to sign in."
        }
        if password.isEmpty { return "Enter your password." }
        return nil
    }

    /// Create-account checks, in the web's order (live.js:2440-2460).
    public static func createAccountError(email: String, password: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter an email address to create an account." }
        if !isValidEmail(trimmed) { return "Enter a valid email address." }
        if password.isEmpty { return "Enter a password of at least 8 characters." }
        if password.count < 8 { return "Password must be at least 8 characters." }
        return nil
    }

    /// The name step: household name is REQUIRED at sign-up (owner,
    /// Nov 4) — empty fails before any Supabase call.
    public static func accountNameError(_ name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter a name for your new account." : nil
    }

    /// The household name step (live.js:2622-2720).
    public static func householdNameError(_ name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter a household name." : nil
    }

    /// Reset-password completion (reset.html, verified Nov 9, 2026).
    public static func newPasswordError(password: String, confirm: String) -> String? {
        if password.isEmpty || password.count < 8 {
            return "Enter a password of at least 8 characters."
        }
        if password != confirm { return "The two passwords do not match." }
        return nil
    }
}
