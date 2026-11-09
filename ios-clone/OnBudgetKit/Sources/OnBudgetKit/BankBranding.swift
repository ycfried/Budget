// OnBudgetKit — BankBranding.swift
//
// Bank logo domains + brand colours for the Connected Accounts list,
// ported from the live web app (v66). Pure Foundation — unit-tested
// in this package.
//
// Sources: `BANK_LOGO_DOMAINS` / `BANK_BRAND_COLORS` /
// `bankDomainFor` / `bankBrandColorFor` (live.js:60-99). Logos come
// from Google's favicon service (`www.google.com/s2/favicons`,
// `sz=128`); Clearbit is dead since Nov 4, 2026 and is never used.
// An unmapped bank falls back to a brand-coloured monogram tile on
// slate `#475569` — never a flat grey box alone.

import Foundation

/// Bank branding for Connected Accounts rows.
public enum BankBranding {
    private static let logoDomains: [(key: String, domain: String)] = [
        ("american express", "americanexpress.com"),
        ("bank of america", "bankofamerica.com"),
        ("capital one", "capitalone.com"),
        ("chase", "chase.com"),
        ("citi", "citibank.com"),
        ("discover", "discover.com"),
        ("pnc", "pnc.com"),
        ("td", "td.com"),
        ("us bank", "usbank.com"),
        ("wells fargo", "wellsfargo.com"),
    ]

    private static let brandColors: [(key: String, hex: String)] = [
        ("american express", "#2e77bc"),
        ("bank of america", "#e31837"),
        ("capital one", "#004977"),
        ("chase", "#117aca"),
        ("citi", "#003b70"),
        ("discover", "#f48120"),
        ("pnc", "#f58025"),
        ("td", "#00a651"),
        ("us bank", "#0c2074"),
        ("wells fargo", "#d71e28"),
    ]

    public static let fallbackBrandHex = "#475569"

    /// The Google favicon domain for an institution name, or nil
    /// when unmapped (caller falls back to the monogram tile).
    public static func domain(for institutionName: String?) -> String? {
        let name = (institutionName ?? "").lowercased()
        return logoDomains.first { name.contains($0.key) }?.domain
    }

    /// The brand colour hex for an institution name, or slate
    /// `#475569` when unmapped.
    public static func brandHex(for institutionName: String?) -> String {
        let name = (institutionName ?? "").lowercased()
        return brandColors.first { name.contains($0.key) }?.hex ?? fallbackBrandHex
    }

    /// The Google favicon URL for an institution name, or nil when
    /// unmapped.
    public static func faviconURL(for institutionName: String?) -> URL? {
        guard let domain = domain(for: institutionName) else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128")
    }

    /// The one-letter monogram initial for an institution name.
    public static func initial(for institutionName: String?) -> String {
        let name = (institutionName ?? "").trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }
}

/// Email-connection warnings (filterState.mjs
/// `emailConnectionWarnings`): 'expiring' when the grant
/// (`connected_at`, falling back to `created_at`) is more than 5 days
/// old, 'stale' when `last_poll_at` is more than 24h old. A
/// `status == "error"` connection returns nothing — the card already
/// shows "Needs reconnect" for that case.
public enum EmailConnectionWarnings {
    public static func warnings(
        status: String,
        connectedAt: String?,
        createdAt: String?,
        lastPollAt: String?,
        now: Date = Date()
    ) -> [String] {
        guard status != "error" else { return [] }
        var output: [String] = []
        let grantRaw = connectedAt ?? createdAt
        if let grantRaw, let grantDate = parseISODate(grantRaw),
           now.timeIntervalSince(grantDate) > 5 * 24 * 3600 {
            output.append("expiring")
        }
        if let lastPollAt, let lastDate = parseISODate(lastPollAt),
           now.timeIntervalSince(lastDate) > 24 * 3600 {
            output.append("stale")
        }
        return output
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Bank-sync toast text from a `plaid-sync` response
/// (filterState.mjs `bankSyncToast`). The caller passes the decoded
/// counts; a stale flag adds one honest sentence and a non-empty
/// `skipped_by_reason` adds the per-reason breakdown.
public enum BankSyncToast {
    public static func text(
        error: String?,
        added: Int,
        updated: Int,
        skipped: Int,
        items: Int,
        duplicateRemoved: [String],
        stale: Bool?,
        minutesSincePreviousSync: Int?,
        skippedByReason: [String: Int]?,
        failedInstitutions: [String]
    ) -> (text: String, isError: Bool) {
        let failedNames = failedInstitutions.filter { !$0.isEmpty }
        if let error {
            return ("Sync failed: \(error)\(failedNames.isEmpty ? "" : " — \(failedNames.joined(separator: ", "))")", true)
        }
        var text = "Sync done: \(added) added, \(updated) updated, \(skipped) skipped across \(items) connected account(s)."
        if !duplicateRemoved.isEmpty {
            text += " A duplicate bank connection was removed because those accounts are already connected on another connection. Past transactions stay."
        }
        if stale == true {
            let minutes = minutesSincePreviousSync.map { " (\($0) minutes since the last one)" } ?? ""
            text += " Scheduled sync hadn't run in a while before this sync\(minutes)."
        }
        let reasons = (skippedByReason ?? [:])
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.replacingOccurrences(of: "-", with: " ")) ×\($0.value)" }
            .joined(separator: ", ")
        if !reasons.isEmpty { text += " Skipped: \(reasons)." }
        return (text, false)
    }
}

/// Email-check result message from a `gmail-poll` response
/// (filterState.mjs `emailCheckMessage`). Per-connection failures in
/// `errors[]` are surfaced — a top-level-only read used to report
/// false success after a token died.
public enum EmailCheckMessage {
    public static func text(
        topLevelError: String?,
        firstConnectionError: String?,
        stored: Int,
        duplicates: Int,
        quarantined: Int,
        unparseable: Int,
        stale: Bool?,
        minutesSincePreviousPoll: Int?
    ) -> (text: String, isError: Bool) {
        if let failed = firstConnectionError ?? topLevelError {
            let failText: String
            if let firstConnectionError, firstConnectionError.lowercased().contains("reauthorization") {
                failText = "access expired — reconnect your email."
            } else {
                failText = failed
            }
            return ("Email check failed: \(failText)", true)
        }
        var text = "Email checked: \(stored) added, \(duplicates) already known, \(quarantined) quarantined, \(unparseable) could not be read."
        if stale == true {
            let minutes = minutesSincePreviousPoll.map { " (\($0) minutes since the last one)" } ?? ""
            text += " Email hadn't been checked in a while before this check\(minutes)."
        }
        return (text, false)
    }
}
