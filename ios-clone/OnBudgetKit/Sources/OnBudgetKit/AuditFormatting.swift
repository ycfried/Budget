// OnBudgetKit — AuditFormatting.swift
//
// Activity display translation, ported from the live web app (v66).
// Display-side ONLY: stored `audit_log` rows are never edited.
// Pure Foundation — unit-tested in this package.
//
// Sources: `formatAuditDetail` / `formatAuditAction` /
// `formatAuditActor` (live.js:3662-3694), `householdActivityText` /
// `activityTitle` / `simplifyActivityDetail` /
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

    /// "Admin"/"Member" are role placeholders, not people — a
    /// system row (week closes) was written with the role instead
    /// of a name, and rendering "Admin" names a person who does
    /// not exist (owner, Nov 14, 2026). Those render as NO actor:
    /// the row shows the time only. A real name, or the part
    /// before '@', is kept as-is.
    public static func formatActor(_ name: String) -> String {
        if name == "admin" { return "" }
        if name == "member" { return "" }
        if name.contains("@") { return String(name.split(separator: "@").first ?? Substring(name)) }
        return name
    }

    /// Merchant names in normal case ("TOIREMORG CHARITY" →
    /// "Toiremorg Charity"), never ALL CAPS (owner, Nov 14, 2026).
    /// Tokens without letters ($ amounts, dates) pass through
    /// untouched; the first letter of each word is upper-cased,
    /// the rest lower-cased ("7-ELEVEN" → "7-Eleven",
    /// "MCDONALD'S" → "Mcdonald's").
    public static func normalCaseMerchant(_ text: String) -> String {
        text.split(separator: " ").map { word -> String in
            var result = ""
            var seenLetter = false
            for ch in word {
                if ch.isLetter {
                    result.append(seenLetter ? ch.lowercased() : ch.uppercased())
                    seenLetter = true
                } else {
                    result.append(ch)
                }
            }
            return result
        }.joined(separator: " ")
    }

    /// A no-op allowance row (stored Nov 11, 2026: $400 → $400)
    /// changed nothing — it never renders as a row at all (owner,
    /// Nov 14, 2026). The formatted detail for a no-op is the plain
    /// value ("$400.00"); a real change reads "$375.00 → $400.00",
    /// so only no-ops lack the arrow.
    public static func isNoOpAllowanceChange(action: String, detail: String) -> Bool {
        action == "Base allowance changed" && !detail.contains(" → ")
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

    /// Fact-first detail, display only — stored rows untouched.
    /// One short structured line: the essential fact, never a
    /// sentence. Merchants stay ALL CAPS as stored (owner, Nov 26,
    /// 2026: the approved examples read `CLOUDFLARE HQ →
    /// CLOUDFLARE`, `AMAZON $30.73`, `ROYAL FARMS $7.63` — the
    /// same ALL-CAPS as the transaction rows; the Nov 14
    /// normal-case rule does not apply to this line). Facts join
    /// with " · ", renames and money moves use " → ", and no line
    /// ends with a period. A detail that adds nothing the title
    /// does not say returns "" and the row hides the line.
    public static func simplifyDetail(_ detail: String) -> String {
        var text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Merged duplicate -> "AMAZON $30.73 · counted once".
        if let groups = firstMatch(
            text,
            pattern: "^Merged duplicate \\(([^)]+)\\) into (?:the original bank row|original) \\([^)]+\\)[^.]*\\.?"
        ), let merged = groups[1] {
            return "\(merged.trimmingCharacters(in: .whitespaces)) · counted once"
        }
        // Same-source duplicate excluded -> the same fact.
        if let groups = firstMatch(
            text,
            pattern: "^Same-source duplicate (.+?) (-?\\$[\\d,]+\\.\\d{2}) \\(kind \\w+\\) shares .+?; excluded as a duplicate\\.?$"
        ), let subject = groups[1], let amount = groups[2] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) \(amount) · counted once"
        }
        // Kept separate.
        if matches(text, pattern: "^Kept .*as separate purchases") {
            return "Kept as two separate purchases"
        }
        // Merchant renamed -> "CLOUDFLARE HQ → CLOUDFLARE · 2 rows
        // · applies to new rows".
        if let groups = firstMatch(
            text,
            pattern: "^Renamed \"(.+?)\" to \"(.+?)\"(?: \\(kind \\w+\\))?(?: \\(matches \".+?\"\\))?(?: — (\\d+) row\\(s\\) updated(, rule applies to new rows too)?)?\\.?$"
        ), let old = groups[1], let new = groups[2] {
            let rows = groups[3] ?? ""
            let hasRule = groups[4] != nil
            if rows.isEmpty { return "\(old) → \(new)" }
            let count = Int(rows) ?? 0
            let rowWord = count == 1 ? "row" : "rows"
            if hasRule { return "\(old) → \(new) · \(count) \(rowWord) · applies to new rows" }
            return "\(old) → \(new) · \(count) \(rowWord)"
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
            return parts.joined(separator: " · ")
        }
        // A bare "N weeks closed." on its own is the title restated.
        if matches(text, pattern: "^\\d+ weeks? closed\\.?$") { return "" }
        // Surplus paid toward debt -> "$179.99 → Carried Debt ·
        // Week of Nov 8, 2026" (owner, Nov 26, 2026). This is the
        // Build 68 shortenActivityDetail rule, moved into the kit
        // so the Activity view no longer needs its own copy.
        if let groups = firstMatch(
            text,
            pattern: "^Surplus (\\$[\\d,]+\\.\\d{2}) for week (.+?) paid toward the carried debt.*$"
        ), let amount = groups[1], let week = groups[2] {
            return "\(amount) → Carried Debt · Week of \(week.trimmingCharacters(in: .whitespaces))"
        }
        // Surplus released -> "$120.00 → Extra Fund · Week of
        // Nov 1, 2026".
        if let groups = firstMatch(
            text,
            pattern: "^Surplus (\\$[\\d,]+\\.\\d{2}) for week (.+?) released to the Extra Fund\\.?$"
        ), let amount = groups[1], let week = groups[2] {
            return "\(amount) → Extra Fund · Week of \(week.trimmingCharacters(in: .whitespaces))"
        }
        // Refund restoration: amounts first, week last; zero parts
        // dropped.
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
            let weekPart = "Week of \(week.trimmingCharacters(in: .whitespaces))"
            if kept.isEmpty {
                return "Refund · \(weekPart)"
            }
            return "\(kept.joined(separator: " · ")) · \(weekPart)"
        }
        // Excluded -> "AMAZON $62.99 · excluded · Order cancelled"
        // (reason only when present).
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) excluded(?: — reason: (.+?)| — no reason given)?\\.?$"
        ), let subject = groups[1] {
            let reason = (groups[2] ?? "")?.trimmingCharacters(in: .whitespaces) ?? ""
            let base = "\(subject.trimmingCharacters(in: .whitespaces)) · excluded"
            if !reason.isEmpty && !reason.lowercased().contains("no reason given") {
                return "\(base) · \(reason)"
            }
            return base
        }
        // Restored -> the subject only; the title says restored.
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) restored to the week as (?:posted|pending)\\.?$"
        ), let subject = groups[1] {
            return subject.trimmingCharacters(in: .whitespaces)
        }
        // Restored by the one-off repair -> the subject only.
        if let groups = firstMatch(
            text,
            pattern: "^Restored (.+?) (-?\\$[\\d,]+\\.\\d{2}) to verified.*$"
        ), let subject = groups[1], let amount = groups[2] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) \(amount)"
        }
        // Reclassified -> "ERIE INSURANCE $1,986.00 · counts as a
        // charge · Insurance" (reason only when present).
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) reclassified from (\\w+) to (\\w+)(?: — reason: (.+?)| — no reason given)?\\.?$"
        ), let subject = groups[1], let toKind = groups[3] {
            let to = kindWords[toKind.lowercased()] ?? toKind
            let reason = (groups[4] ?? "")?.trimmingCharacters(in: .whitespaces) ?? ""
            let base = "\(subject.trimmingCharacters(in: .whitespaces)) · counts as \(to)"
            if !reason.isEmpty && !reason.lowercased().contains("no reason given") {
                return "\(base) · \(reason)"
            }
            return base
        }
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) \\(manual entry\\) deleted by admin\\.?$"
        ), let subject = groups[1] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) · deleted for good"
        }
        // Moved to trash -> the subject (+ reason when present);
        // the title says trash.
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) moved to trash(?: — reason: (.+?))?\\.?$"
        ), let subject = groups[1] {
            let reason = (groups[2] ?? "")?.trimmingCharacters(in: .whitespaces) ?? ""
            let base = subject.trimmingCharacters(in: .whitespaces)
            if !reason.isEmpty { return "\(base) · \(reason)" }
            return base
        }
        // Member removed -> the name only; the title says removed.
        // The stored "They can no longer see the household." tail
        // is wordy and it pushed the line past the right edge
        // (owner, Nov 14, 2026).
        if let groups = firstMatch(
            text,
            pattern: "^Removed (.+?) from the household\\..*$"
        ), let name = groups[1] {
            return name.trimmingCharacters(in: .whitespaces)
        }
        // Member promoted -> "chayasf1 · admin".
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) was made an admin.*$"
        ), let name = groups[1] {
            return "\(name.trimmingCharacters(in: .whitespaces)) · admin"
        }
        // Marked as a charity gift -> "WALMART $56.34". The title
        // already says it was marked as a charity gift, so
        // restating it here repeats the title (owner, Nov 14,
        // 2026). No date: the actor/time line below already
        // carries it.
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) (-?\\$[\\d,]+\\.\\d{2}) on (.+?) marked as a charity gift.*$"
        ), let subject = groups[1], let amount = groups[2] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) \(amount)"
        }
        // Expense removed from recurring -> "ROYAL FARMS $7.63 ·
        // counts as a purchase again" (owner, Nov 26, 2026).
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) (-?\\$[\\d,]+\\.\\d{2}) removed from recurring expenses.*$"
        ), let subject = groups[1], let amount = groups[2] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) \(amount) · counts as a purchase again"
        }
        // Tagged as a recurring expense -> "ROYAL FARMS $7.63 ·
        // recurring · monthly".
        if let groups = firstMatch(
            text,
            pattern: "^(.+?) (-?\\$[\\d,]+\\.\\d{2}) tagged as a recurring expense \\((\\w+)\\).*$"
        ), let subject = groups[1], let amount = groups[2], let freq = groups[3] {
            return "\(subject.trimmingCharacters(in: .whitespaces)) \(amount) · recurring · \(freq)"
        }
        // Base allowance change -> "$375.00 → $400.00". A no-op
        // ("changed from $X to $X") renders as the plain value —
        // the entry is written server-side by set_base_allowance
        // with no old==new guard (supabase/04-admin-rpcs.sql), so
        // already-stored no-ops render as the plain value (see
        // isNoOpAllowanceChange).
        if let groups = firstMatch(
            text,
            pattern: "^Base allowance changed from (\\$[\\d,]+\\.\\d{2}) to (\\$[\\d,]+\\.\\d{2})\\.?$"
        ), let from = groups[1], let to = groups[2] {
            if from == to { return from }
            return "\(from) → \(to)"
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
            // The greedy capture swallows the sentence dot
            // ("20%."); strip it so the rate reads "20%", not
            // "20%." (owner, Nov 14, 2026 — plain language).
            let rate = (groups[1] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return "\(rate) · future income only"
        }
        // Income that commits to charity -> "YEHOSHUA FRIEDMAN
        // $3,000.00 · $300.00 to charity" (date dropped — the
        // actor/time line carries it).
        text = replace(text, pattern: "^Income (.+?) (-?\\$[\\d,]+\\.\\d{2}) on (.+?) at ([^ ]+) commits (-?\\$[\\d,]+\\.\\d{2}) to charity\\.?$") { groups in
            "\(groups[1] ?? "") \(groups[2] ?? "") · \(groups[5] ?? "") to charity"
        }
        // Income corrected (reversed and replaced) -> same fact.
        text = replace(text, pattern: "^Income (.+?) (-?\\$[\\d,]+\\.\\d{2}) reversed and replaced by (.+?) (-?\\$[\\d,]+\\.\\d{2}) at ([^ ]+), committing (-?\\$[\\d,]+\\.\\d{2})\\.?$") { groups in
            "\(groups[1] ?? "") \(groups[2] ?? "") · \(groups[6] ?? "") to charity"
        }
        // Income excluded / reversed -> "YEHOSHUA FRIEDMAN
        // $3,000.00 · $300.00 off charity owed".
        text = replace(text, pattern: "^Income (.+?) (-?\\$[\\d,]+\\.\\d{2}) on (.+?) at ([^ ]+) was excluded; (-?\\$[\\d,]+\\.\\d{2}) deducted from charity owed\\.?$") { groups in
            "\(groups[1] ?? "") \(groups[2] ?? "") · \(groups[5] ?? "") off charity owed"
        }
        // Gift -> "TEST ORG $5.00".
        text = replace(text, pattern: "^Gift (.+?) (-?\\$[\\d,]+\\.\\d{2}) on (.+?)\\.?$") { groups in
            "\(groups[1] ?? "") \(groups[2] ?? "")"
        }
        // Cash gift -> the amount only; the title says cash gift,
        // and the Tzedaka card already shows the Available after.
        text = replace(text, pattern: "^Cash gift (-?\\$[\\d,]+\\.\\d{2}) on (.+?) \\(Available .+? after\\)\\.?$") { groups in
            groups[1] ?? ""
        }
        // Fund spending -> the amount only; the title says it was
        // spent from the Extra Fund.
        text = replace(text, pattern: "^Fund spending (.+?)( \\(override: .+?\\))?\\.?$") { groups in
            groups[1] ?? ""
        }
        text = replace(text, pattern: "^Request.*approved for (.+?)( \\(split; remainder .+?\\))?( \\(override: .+?\\))?\\.?$") { groups in
            // Amount only — the title already says the request was
            // approved (owner, Nov 12 2026).
            groups[1] ?? ""
        }
        text = replace(text, pattern: "^Base allowance set to (.+?)\\.?$") { groups in
            groups[1] ?? ""
        }
        // Weekly allowance set -> "$375.00 · Week of Nov 8, 2026".
        text = replace(text, pattern: "^Weekly allowance set to (.+?) for week (.+?)\\.?$") { groups in
            "\(groups[1] ?? "") · Week of \(groups[2] ?? "")"
        }
        // Temporary increase -> "+$50.00 · Week of Nov 8, 2026".
        text = replace(text, pattern: "^Temporary increase (.+?) for week (.+?)\\.?$") { groups in
            "+\(groups[1] ?? "") · Week of \(groups[2] ?? "")"
        }
        text = replace(text, pattern: "^Fund shortfall changed from (.+?) to (.+?)\\.?$") { groups in
            "Shortfall \(groups[2] ?? "")"
        }
        // Carried debt cleared -> "$1,127.96 cleared · $0.00
        // remains".
        text = replace(text, pattern: "^Cleared (-?\\$[\\d,]+\\.\\d{2}) of carried debt by hand(?: \\(partial clear of .+?; .+? owed before, (-?\\$[\\d,]+\\.\\d{2}) remain\\))?\\.?$") { groups in
            let amount = groups[1] ?? ""
            let remain = groups[2] ?? ""
            if remain.isEmpty { return "\(amount) cleared" }
            return "\(amount) cleared · \(remain) remains"
        }
        // Debt paid from the Extra Fund -> "$50.00 → Carried Debt
        // · Extra Fund".
        text = replace(text, pattern: "^Paid (-?\\$[\\d,]+\\.\\d{2}) toward the carried debt from the Extra Fund\\.?$") { groups in
            "\(groups[1] ?? "") → Carried Debt · Extra Fund"
        }
        // Debt repayment rule -> "Off", or "25% of weekly
        // allowance" for a bare percent (the rule is a share of
        // the weekly allowance).
        text = replace(text, pattern: "^Debt repayment rule set to ([^\\(]+?)(?: \\(applies .+?\\))?\\.?$") { groups in
            let value = (groups[1] ?? "").trimmingCharacters(in: .whitespaces)
            if value.lowercased() == "off" { return "Off" }
            if value.range(of: "^\\d+%$", options: .regularExpression) != nil {
                return "\(value) of weekly allowance"
            }
            return value.prefix(1).uppercased() + String(value.dropFirst())
        }
        // Extra Fund request created -> "$10.15 · Proof11 Bulk 015".
        text = replace(text, pattern: "^Requested (-?\\$[\\d,]+\\.\\d{2}) for (.+?)\\.?$") { groups in
            "\(groups[1] ?? "") · \(groups[2] ?? "")"
        }
        // Manual top-up -> "$740.00" when the whole top-up went to
        // the fund; "$100.00 · $80.00 to fund" when part covered a
        // shortfall (legacy split form).
        text = replace(text, pattern: "^Manual top-up (-?\\$[\\d,]+\\.\\d{2}): (-?\\$[\\d,]+\\.\\d{2}) covered shortfall, (-?\\$[\\d,]+\\.\\d{2}) added to fund, (-?\\$[\\d,]+\\.\\d{2}) owed back after.*$") { groups in
            let topup = groups[1] ?? ""
            let shortfall = groups[2] ?? ""
            let added = groups[3] ?? ""
            let owedBack = groups[4] ?? ""
            if !isZeroAmount(shortfall) || added != topup {
                var fact = "\(topup) · \(added) to fund"
                if !isZeroAmount(owedBack) { fact += " · \(owedBack) owed back" }
                return fact
            }
            return topup
        }
        // Manual top-up saved as pending -> "$200.00 · pending".
        text = replace(text, pattern: "^Manual top-up (-?\\$[\\d,]+\\.\\d{2}) saved as pending.*$") { groups in
            "\(groups[1] ?? "") · pending"
        }
        // Fund hidden / shown -> the fund name only.
        text = replace(text, pattern: "^Fund (.+?) hidden from Home\\.?$") { groups in
            let name = (groups[1] ?? "").trimmingCharacters(in: .whitespaces)
            return name.prefix(1).uppercased() + String(name.dropFirst())
        }
        text = replace(text, pattern: "^Fund (.+?) shown on Home again\\.?$") { groups in
            let name = (groups[1] ?? "").trimmingCharacters(in: .whitespaces)
            return name.prefix(1).uppercased() + String(name.dropFirst())
        }
        // Fund renamed -> "debt → Debt".
        text = replace(text, pattern: "^Fund (.+?) renamed to \"(.+?)\"\\.?$") { groups in
            "\(groups[1] ?? "") → \(groups[2] ?? "")"
        }
        // Gmail disconnected -> the email only.
        text = replace(text, pattern: "^Disconnected (.+?) from email alerts\\.?$") { groups in
            groups[1] ?? ""
        }
        // A manual add -> "TEA $5.00" (date dropped — the
        // actor/time line carries it). Last: the income and gift
        // patterns above have already claimed their forms.
        text = replace(text, pattern: "^(.+?) (-?\\$[\\d,]+\\.\\d{2}) on (.+?)\\.?$") { groups in
            "\(groups[1] ?? "") \(groups[2] ?? "")"
        }
        // A join or a household creation says nothing the title
        // does not say — the detail stays empty and the row shows
        // title + actor/time only. (Was "Joined the household." /
        // "Household created.": the restatement check above runs
        // BEFORE these replaces, so the invite-code form slipped
        // through and rendered under its own title — owner,
        // Nov 14, 2026.)
        text = replace(text, pattern: "^Created via create_household RPC.*$") { _ in "" }
        text = replace(text, pattern: "^Joined via invite code\\.?$") { _ in "" }
        // Fallback: the shortest faithful version for a type with
        // no fact pattern yet — the text as-is, minus a trailing
        // period. (The Nov 26, 2026 redesign covers every action
        // in the live log; this only fires for a future action
        // whose stored wording has no pattern yet.)
        var result = collapseWhitespaceAndDots(text)
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    // MARK: - Activity titles, grouping

    // Per-type icons replaced the dot (owner, Nov 26, 2026): each
    // row carries a small SF Symbol for its type, coloured by
    // meaning from the app palette (red removals, green positive
    // money movements, blue neutral changes, grey housekeeping) —
    // the colour lives in the icon only. The icon + colour mapping
    // lives in the app (`ActivityView.activityIcon`), keyed on the
    // translated action; the kit stays UI-free. The Nov 14, 2026
    // rule it replaces (one muted dot for every row, no colour
    // coding — the dots meant nothing without a legend) no longer
    // applies: the icons ARE the legend now, one per type.

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

    /// A collapsed "Weeks processed" group reads as "Week closed"
    /// (one) or "Weeks closed" (more than one) — never with the
    /// internal "processed" wording, and never with a number:
    /// the stored rows do not name which weeks were closed, so a
    /// count ("8 Weeks Closed") is a number nobody can explain
    /// (owner, Nov 14, 2026). The count survives only as the
    /// singular/plural decision. The detail carries what actually
    /// resulted (surplus released, refunds restored, held).
    /// Titles are Title-Cased at DISPLAY time only (audit X-P2-3,
    /// Nov 12 2026): the stored/translated action stays sentence
    /// case in `formatAction`, so e.g. "Transaction added by hand"
    /// renders "Transaction Added by Hand" here and nowhere else.
    public static func activityTitle(action: String, count: Int) -> String {
        if action == "Weeks processed" {
            return TitleCase.apply(to: count == 1 ? "week closed" : "weeks closed")
        }
        return TitleCase.apply(to: action)
    }

    /// Collapse repeated weekly-processing events inside one day's
    /// activity. User actions never collapse. The collapsed count
    /// only decides the title's singular/plural — it is never
    /// rendered as a number (see activityTitle).
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
