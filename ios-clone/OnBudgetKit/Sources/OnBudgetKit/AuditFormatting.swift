// OnBudgetKit — AuditFormatting.swift
//
// Activity display translation, ported from the live web app (v66).
// Display-side ONLY: stored `audit_log` rows are never edited.
// Pure Foundation — unit-tested in this package.
//
// Sources: `formatAuditDetail` / `formatAuditAction` /
// `formatAuditActor` (live.js:3662-3694), `householdActivityText` /
// `activityDotClass` / `activityTitle` / `simplifyActivityDetail` /
// `groupDayActivity` / `historyPeriodLabel` / `filterRowsByDate`
// (filterState.mjs).

import Foundation

/// One Activity entry after display translation, ready to render.
/// `count` is > 1 only for collapsed repeated weekly-processing rows.
public struct AuditDisplayEntry: Equatable {
    public let action: String
    public let detail: String
    public let actor: String
    public let time: String
    public let count: Int

    public init(action: String, detail: String, actor: String, time: String, count: Int = 1) {
        self.action = action
        self.detail = detail
        self.actor = actor
        self.time = time
        self.count = count
    }

    /// Type-filter bucket, derived from the translated
    /// action/detail (owner, Nov 12 2026).
    public var type: AuditFormatting.ActivityType {
        AuditFormatting.ActivityType.classify(action: action, detail: detail)
    }
}

public enum AuditFormatting {
    // MARK: - Small regex helper

    private static func replace(
        _ input: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive],
        using replacement: ([String?]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let nsInput = input as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length)) {
            let range = match.range
            result += nsInput.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            var groups: [String?] = []
            for index in 0..<match.numberOfRanges {
                let groupRange = match.range(at: index)
                groups.append(groupRange.location == NSNotFound ? nil : nsInput.substring(with: groupRange))
            }
            if let replacementText = replacement(groups) {
                result += replacementText
            } else {
                result += nsInput.substring(with: range)
            }
            lastEnd = range.location + range.length
        }
        result += nsInput.substring(from: lastEnd)
        return result
    }

    private static func firstMatch(
        _ input: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let nsInput = input as NSString
        guard let match = regex.firstMatch(in: input, range: NSRange(location: 0, length: nsInput.length)) else {
            return nil
        }
        var groups: [String?] = []
        for index in 0..<match.numberOfRanges {
            let groupRange = match.range(at: index)
            groups.append(groupRange.location == NSNotFound ? nil : nsInput.substring(with: groupRange))
        }
        return groups
    }

    private static func matches(_ input: String, pattern: String) -> Bool {
        firstMatch(input, pattern: pattern) != nil
    }

    private static func collapseWhitespaceAndDots(_ input: String) -> String {
        var result = replace(input, pattern: "\\s{2,}", options: []) { _ in " " }
        result = replace(result, pattern: "\\.{2,}", options: []) { _ in "." }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - formatAuditDetail (live.js:3662-3682)

    /// Translate a stored audit detail into display text:
    /// UUIDs stripped, ISO dates -> long dates, "N cents" -> $X,
    /// "N basis points" -> N%, "as provisional" -> "as pending",
    /// "create_household RPC" -> "Household created."
    public static func formatDetail(_ detail: String?) -> String {
        var text = detail ?? ""
        text = replace(text, pattern: "Request [0-9a-f-]{36} approved") { _ in "Request approved" }
        text = replace(text, pattern: "Request [0-9a-f-]{36} declined") { _ in "Request declined" }
        text = replace(text, pattern: "^Created via create_household RPC.*$") { _ in "Household created." }
        text = replace(text, pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") { _ in "" }
        text = replace(text, pattern: "\\b(\\d{4})-(\\d{2})-(\\d{2})\\b", options: []) { groups in
            guard let year = groups[1], let month = groups[2], let day = groups[3] else { return nil }
            return MoneyFormat.fmtLong("\(year)-\(month)-\(day)")
        }
        text = replace(text, pattern: "\\b(\\d+) cents\\b", options: []) { groups in
            guard let number = groups[1], let cents = Int(number) else { return nil }
            return MoneyFormat.formatCents(cents)
        }
        text = replace(text, pattern: "(\\d+) basis points") { groups in
            guard let number = groups[1], let basisPoints = Double(number) else { return nil }
            let percent = basisPoints / 100
            var text = String(format: "%.2f", percent)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return "\(text)%"
        }
        text = replace(text, pattern: "as provisional", options: []) { _ in "as pending" }
        text = householdActivityText(text)
        text = collapseWhitespaceAndDots(text)
        return simplifyDetail(text)
    }

    /// Old rows carry the pre-rename wording; display them under the
    /// new name too (live.js:3683-3687).
    public static func formatAction(_ action: String) -> String {
        if action == "Manual provisional transaction added" || action == "Purchase added by hand" {
            return "Transaction added by hand"
        }
        return action
    }

    /// "Admin"/"Member", or the name before '@' — never a raw
    /// username or UUID (live.js:3688-3694).
    public static func formatActor(_ name: String) -> String {
        if name == "admin" { return "Admin" }
        if name == "member" { return "Member" }
        if name.contains("@") { return String(name.split(separator: "@").first ?? Substring(name)) }
        return name
    }

    // MARK: - householdActivityText (filterState.mjs:172-186)

    public static func householdActivityText(_ detail: String) -> String {
        var text = detail
        text = replace(text, pattern: "(\\d+) week\\(s\\) closed", options: []) { groups in
            guard let number = groups[1], let count = Int(number) else { return nil }
            return "\(count) \(count == 1 ? "week" : "weeks") closed"
        }
        text = replace(text, pattern: "(\\d+) release\\(s\\)", options: []) { groups in
            guard let number = groups[1], let count = Int(number) else { return nil }
            return "\(count) \(count == 1 ? "surplus" : "surpluses") released"
        }
        text = replace(text, pattern: "(\\d+) restoration\\(s\\)", options: []) { groups in
            guard let number = groups[1], let count = Int(number) else { return nil }
            return "\(count) \(count == 1 ? "refund" : "refunds") restored"
        }
        text = replace(text, pattern: "(\\d+) held refund\\(s\\)", options: []) { groups in
            guard let number = groups[1], let count = Int(number) else { return nil }
            return "\(count) \(count == 1 ? "refund" : "refunds") held for review"
        }
        text = replace(text, pattern: "week\\(s\\)", options: []) { _ in "weeks" }
        text = replace(text, pattern: "canonical Plaid row") { _ in "bank row" }
        text = replace(text, pattern: "into canonical") { _ in "into the original bank row" }
        text = replace(text, pattern: "\\bcanonical\\b") { _ in "original" }
        return text
    }

    // MARK: - simplifyActivityDetail (filterState.mjs:219-300)

    private static let kindWords: [String: String] = [
        "charge": "a charge",
        "refund": "a refund",
        "fund_charge": "Extra Fund spending",
        "transfer": "a transfer",
        "payment": "a card payment",
        "cashback": "cash back",
    ]

    private static func isZeroAmount(_ amount: String?) -> Bool {
        guard let amount = amount?.trimmingCharacters(in: .whitespaces) else { return false }
        return amount == "$0.00" || amount == "-$0.00"
    }

    /// Plain-language detail, display only — stored rows untouched.
    /// One short line: the merchant/amount appears once, never twice.
    public static func simplifyDetail(_ detail: String) -> String {
        var text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Merged duplicate -> "Counted once: <merchant $X>."
        if let groups = firstMatch(
            text,
            pattern: "^Merged duplicate \\(([^)]+)\\) into (?:the original bank row|original) \\([^)]+\\)[^.]*\\.?"
        ), let merged = groups[1] {
            return "Counted once: \(merged.trimmingCharacters(in: .whitespaces))."
        }
        // Kept separate.
        if matches(text, pattern: "^Kept .*as separate purchases") {
            return "Kept as two separate purchases."
        }
        // Weeks-processed summary: the TITLE carries the week
        // count ("N weeks closed"), so the detail never restates
        // it — only the releases / restorations / held parts stay.
        // Drop zero parts too; when nothing new remains the detail
        // is empty and the row shows title + actor/time only
        // (owner, Nov 12 2026: count and text must agree, and the
        // title says the thing once).
        if matches(text, pattern: "week(s)? closed") && matches(text, pattern: "release") {
            let stripped = text.hasSuffix(".") ? String(text.dropLast()) : text
            let parts = stripped.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                // "week closed" and "weeks closed" both contain
                // "closed"; no other clause does.
                .filter { !$0.hasPrefix("0") && !$0.hasPrefix("0 ") && !$0.contains("closed") }
            if parts.isEmpty { return "" }
            return "\(parts.joined(separator: " · "))."
        }
        // A bare "N weeks closed." on its own is the title restated.
        if matches(text, pattern: "^\\d+ weeks? closed\\.?$") { return "" }
        // Surplus released.
        if let groups = firstMatch(
            text,
            pattern: "^Surplus (\\$[\\d,]+\\.\\d{2}) for week (.+?) released to the Extra Fund\\.?$"
        ), let amount = groups[1], let week = groups[2] {
            return "\(amount) to the Extra Fund · Week of \(week.trimmingCharacters(in: .whitespaces))."
        }
        // Refund restoration: plain parts, zero parts dropped.
        if let groups = firstMatch(
            text,
            pattern: "^Refund .*for purchase week (.+?): surplus (\\$[\\d,]+\\.\\d{2}), debt reduction (\\$[\\d,]+\\.\\d{2}), fund (\\$[\\d,]+\\.\\d{2}), held (\\$[\\d,]+\\.\\d{2})\\.?$"
        ), let week = groups[1] {
            let plain: [(String?, String)] = [
                (groups[2], "left to spend"),
                (groups[3], "paid off debt"),
                (groups[4], "to the Extra Fund"),
                (groups[5], "held for review"),
            ]
            let kept = plain.filter { !isZeroAmount($0.0) }
                .map { "\($0.0!.trimmingCharacters(in: .whitespaces)) \($0.1)" }
            if kept.isEmpty {
                return "Refund for the week of \(week.trimmingCharacters(in: .whitespaces))."
            }
            return "Refund for the week of \(week.trimmingCharacters(in: .whitespaces)): \(kept.joined(separator: " · "))."
        }
        // Excluded / restored / reclassified / deleted / trash.
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) excluded(?: — reason: (.+?)| — no reason given)?\\.?$"
        ), let subject = groups[1] {
            let reason = (groups[2] ?? "")?.trimmingCharacters(in: .whitespaces) ?? ""
            if !reason.isEmpty && !reason.lowercased().contains("no reason given") {
                return "Removed from the week: \(subject.trimmingCharacters(in: .whitespaces)) (\(reason))."
            }
            return "Removed from the week: \(subject.trimmingCharacters(in: .whitespaces))."
        }
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) restored to the week as (?:posted|pending)\\.?$"
        ), let subject = groups[1] {
            return "Back in the week: \(subject.trimmingCharacters(in: .whitespaces))."
        }
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) reclassified from (\\w+) to (\\w+)(?: — reason: (.+?)| — no reason given)?\\.?$"
        ), let subject = groups[1], let toKind = groups[3] {
            let to = kindWords[toKind.lowercased()] ?? toKind
            let reason = (groups[4] ?? "")?.trimmingCharacters(in: .whitespaces) ?? ""
            if !reason.isEmpty && !reason.lowercased().contains("no reason given") {
                return "Now counts as \(to): \(subject.trimmingCharacters(in: .whitespaces)) (\(reason))."
            }
            return "Now counts as \(to): \(subject.trimmingCharacters(in: .whitespaces))."
        }
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) \\(manual entry\\) deleted by admin\\.?$"
        ), let subject = groups[1] {
            return "Deleted for good: \(subject.trimmingCharacters(in: .whitespaces))."
        }
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) moved to trash(?: — reason: (.+?))?\\.?$"
        ), let subject = groups[1] {
            return "Moved to the Trash: \(subject.trimmingCharacters(in: .whitespaces))."
        }
        // Marked as a charity gift: one short line, no
        // parenthetical restatement, no date (the actor/time line
        // below already carries it) — "Walmart $56.34 — marked as
        // a charity gift" (owner, Nov 12 2026).
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) (\\$[\\d,]+\\.\\d{2}) on (.+?) marked as a charity gift.*$"
        ), let subject = groups[1], let amount = groups[2] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) \(amount) — marked as a charity gift."
        }
        // Base allowance change: a no-op ("changed from $X to
        // $X") never renders as a change — the entry is written
        // server-side by set_base_allowance with no old==new guard
        // (supabase/04-admin-rpcs.sql), so already-stored no-ops
        // render as the plain value. A real change keeps only the
        // values; the title already says it changed.
        if let groups = firstMatch(
            text,
            pattern: "^Base allowance changed from (\\$[\\d,]+\\.\\d{2}) to (\\$[\\d,]+\\.\\d{2})\\.?$"
        ), let from = groups[1], let to = groups[2] {
            if from == to { return "Base allowance: \(from)." }
            return "From \(from) to \(to)."
        }
        // Pure restatements of the title: the detail adds nothing,
        // so the row shows title + actor/time only (owner, Nov 12
        // 2026: the title says the thing once). The Request forms
        // are the pre-rewrite text — the replace block below turns
        // them into "Extra Fund request approved/declined.", which
        // is the same restatement.
        if matches(text, pattern: "^Joined the household\\.?$") { return "" }
        if matches(text, pattern: "^Household created\\.?$") { return "" }
        if matches(text, pattern: "^Extra Fund request approved\\.?$") { return "" }
        if matches(text, pattern: "^Extra Fund request declined\\.?$") { return "" }
        if matches(text, pattern: "^Request.*approved\\.?$") { return "" }
        if matches(text, pattern: "^Request.*declined\\.?$") { return "" }
        // Charity / fund / household / allowance: strip internal wording.
        text = replace(text, pattern: "^Default charity rate set to ([^ ]+)( \\(applies to future incomes only\\))?\\.?$") { groups in
            "Charity rate: \(groups[1] ?? "") for future income."
        }
        text = replace(text, pattern: "^Income (.+?) at ([^ ]+) commits (.+?) to charity\\.?$") { groups in
            "Income \(groups[1] ?? "") — \(groups[3] ?? "") to charity."
        }
        text = replace(text, pattern: "^Gift (.+?) on (.+?)\\.?$") { groups in
            "Gift given: \(groups[1] ?? "") on \(groups[2] ?? "")."
        }
        text = replace(text, pattern: "^Fund spending (.+?)( \\(override: .+?\\))?\\.?$") { groups in
            "Spent from the Extra Fund: \(groups[1] ?? "")."
        }
        text = replace(text, pattern: "^Request.*approved for (.+?)( \\(split; remainder .+?\\))?( \\(override: .+?\\))?\\.?$") { groups in
            // Amount only — the title already says the request was
            // approved (owner, Nov 12 2026).
            "\(groups[1] ?? "")."
        }
        text = replace(text, pattern: "^Request.*approved\\.?$") { _ in "Extra Fund request approved." }
        text = replace(text, pattern: "^Request.*declined\\.?$") { _ in "Extra Fund request declined." }
        text = replace(text, pattern: "^Base allowance set to (.+?)\\.?$") { groups in
            "Weekly allowance: \(groups[1] ?? "")."
        }
        text = replace(text, pattern: "^Weekly allowance set to (.+?) for week (.+?)\\.?$") { groups in
            "Weekly allowance: \(groups[1] ?? "") for the week of \(groups[2] ?? "")."
        }
        text = replace(text, pattern: "^Temporary increase (.+?) for week (.+?)\\.?$") { groups in
            "Weekly allowance raised by \(groups[1] ?? "") for the week of \(groups[2] ?? "")."
        }
        text = replace(text, pattern: "^Fund shortfall changed from (.+?) to (.+?)\\.?$") { groups in
            "Extra Fund shortfall: \(groups[2] ?? "")."
        }
        text = replace(text, pattern: "^Created via create_household RPC.*$") { _ in "Household created." }
        text = replace(text, pattern: "^Joined via invite code\\.?$") { _ in "Joined the household." }
        return collapseWhitespaceAndDots(text)
    }

    // MARK: - Activity dots, titles, grouping

    /// Dot colour key: charity -> green, system rows (week closes,
    /// household creation) -> grey, everything else -> brand blue.
    public static func dotClass(action: String, detail: String) -> String {
        let text = "\(action) \(detail)"
        if text.range(of: "charity", options: .caseInsensitive) != nil { return "charity" }
        if text.range(of: "weeks processed|week.*closed|household created", options: [.caseInsensitive, .regularExpression]) != nil {
            return "system"
        }
        return "money"
    }

    // MARK: - Activity types (type filter, owner Nov 12 2026)

    /// The type filter's buckets. Chips show only the types
    /// actually present in the household's log, in this order;
    /// anything that fits no bucket lands in `other` so "All"
    /// stays the union of the chips.
    public enum ActivityType: String, CaseIterable {
        case weekCloses
        case members
        case allowance
        case charity
        case duplicates
        case trash
        case other

        public var label: String {
            switch self {
            case .weekCloses: return "Week closes"
            case .members: return "Members"
            case .allowance: return "Allowance"
            case .charity: return "Charity"
            case .duplicates: return "Duplicates"
            case .trash: return "Trash"
            case .other: return "Other"
            }
        }

        /// Classify a translated action/detail pair. Action-first:
        /// a duplicate merge of a charity gift is Duplicates, not
        /// Charity; an income row that commits money to charity is
        /// Charity. Refund-link suggestions sit with Duplicates
        /// (they are reviewed next to Possible Duplicates).
        public static func classify(action: String, detail: String) -> ActivityType {
            if action == "Weeks processed" { return .weekCloses }
            let text = "\(action) \(detail)".lowercased()
            if text.contains("duplicate") || text.contains("suggested link") || text.contains("link suggestion") {
                return .duplicates
            }
            if text.contains("household joined") || text.contains("household created")
                || text.contains("member") || text.contains("join failed") {
                return .members
            }
            if text.contains("allowance") || text.contains("temporary increase") { return .allowance }
            if text.contains("charity") || text.contains("gift") { return .charity }
            let lowerAction = action.lowercased()
            if lowerAction.contains("trash") || lowerAction == "transaction deleted"
                || lowerAction == "transaction excluded" || lowerAction == "transaction restored" {
                return .trash
            }
            return .other
        }
    }

    /// A collapsed "Weeks processed ×N" group reads as "N weeks
    /// closed", never with the internal "processed" wording.
    /// Titles are Title-Cased at DISPLAY time only (audit X-P2-3,
    /// Nov 12 2026): the stored/translated action stays sentence
    /// case in `formatAction`, so e.g. "Transaction added by hand"
    /// renders "Transaction Added by Hand" here and nowhere else.
    public static func activityTitle(action: String, count: Int) -> String {
        if action == "Weeks processed" {
            return TitleCase.apply(to: "\(count) \(count == 1 ? "week" : "weeks") closed")
        }
        return TitleCase.apply(to: action)
    }

    /// Collapse repeated weekly-processing events inside one day's
    /// activity. User actions never collapse.
    public static func groupDayActivity(_ entries: [AuditDisplayEntry]) -> [AuditDisplayEntry] {
        var output: [AuditDisplayEntry] = []
        var seen: [String: Int] = [:]
        for entry in entries {
            if entry.action == "Weeks processed" {
                let key = "\(entry.action)\n\(entry.detail)"
                if let index = seen[key] {
                    let existing = output[index]
                    output[index] = AuditDisplayEntry(
                        action: existing.action, detail: existing.detail,
                        actor: existing.actor, time: existing.time,
                        count: existing.count + 1
                    )
                    continue
                }
                seen[key] = output.count
                output.append(entry)
            } else {
                output.append(entry)
            }
        }
        return output
    }

    // MARK: - History period + date filter (filterState.mjs:95-115)

    /// States the active period so a filter can never silently make
    /// records disappear; with no filter the line stays empty.
    /// Dates render long ("Nov 1, 2026"), never raw ISO (audit
    /// X-P1-2, Nov 12 2026) — the same `fmtLong` every other line
    /// on these screens uses.
    public static func historyPeriodLabel(from: String?, to: String?) -> String {
        let from = (from ?? "").isEmpty ? nil : from
        let to = (to ?? "").isEmpty ? nil : to
        if from == nil && to == nil { return "" }
        if let from, let to { return "Showing \(MoneyFormat.fmtLong(from)) to \(MoneyFormat.fmtLong(to))." }
        if let from { return "Showing from \(MoneyFormat.fmtLong(from)) onward." }
        return "Showing up to \(MoneyFormat.fmtLong(to!))."
    }

    /// Filter rows by a `YYYY-MM-DD` date string. A blank bound means
    /// no limit on that side; rows without a parseable date are kept,
    /// never silently dropped by the filter.
    public static func filterRowsByDate<T>(
        _ rows: [T],
        getDate: (T) -> String?,
        from: String?,
        to: String?
    ) -> [T] {
        let from = (from ?? "").isEmpty ? nil : from
        let to = (to ?? "").isEmpty ? nil : to
        guard from != nil || to != nil else { return rows }
        return rows.filter { row in
            guard let date = getDate(row), !date.isEmpty else { return true }
            guard date.count >= 10,
                  date.prefix(4).allSatisfy({ $0.isNumber }),
                  date[date.index(date.startIndex, offsetBy: 4)] == "-" else { return true }
            let day = String(date.prefix(10))
            if let from, day < from { return false }
            if let to, day > to { return false }
            return true
        }
    }
}
