// OnBudgetKit — Models.swift
//
// Codable models matching the live rows. Column lists were taken from
// the live schema (`supabase/schema.sql` + migrations) and from the
// exact `.select(…)` lists in live.js — the client asks for the same
// columns the web app asks for, never `*` on a table it does not own.
//
// TWO RULES, from the handoff (HANDOFF.md §3) and the compute-week
// contract (live.js:1-25):
//   1. The server is authoritative for week math. `WeekResult` is
//      displayed, never recomputed. The client sends ONLY
//      `household_id` (and an optional Sunday `week_start`) to
//      compute-week — never D, T, or any legacy credit field.
//   2. `FundSummary` / `CharitySummary` below are DISPLAY aggregations
//      (sums over rows the server already computed). They mirror the
//      web client's arithmetic line-for-line; they are not week math
//      and must never be used to derive a week's figures.
//
// Dates: the API stores dates as `YYYY-MM-DD` strings and timestamps
// as ISO-8601 strings. Models keep them as `String` on purpose —
// no timezone conversion is ever applied to a stored date.

import Foundation

// MARK: - Shared value types

/// A transaction's kind. The live CHECK constraint has been rewritten
/// twice (8 kinds in `refund-classification-income-kind.sql`; 6 in
/// `r13-charity.sql` — see the README's ambiguity list), so decoding
/// tolerates any string the server may send via `.other`.
public enum TransactionKind: Equatable, Codable, Sendable {
    case charge
    case refund
    case fundCharge
    case payment
    case cashback
    case transfer
    case income
    case charity
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "charge": self = .charge
        case "refund": self = .refund
        case "fund_charge": self = .fundCharge
        case "payment": self = .payment
        case "cashback": self = .cashback
        case "transfer": self = .transfer
        case "income": self = .income
        case "charity": self = .charity
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .charge: return "charge"
        case .refund: return "refund"
        case .fundCharge: return "fund_charge"
        case .payment: return "payment"
        case .cashback: return "cashback"
        case .transfer: return "transfer"
        case .income: return "income"
        case .charity: return "charity"
        case .other(let raw): return raw
        }
    }

    /// The kinds the web UI offers in Reclassify (live.js:3923-3930).
    /// 'charity' is listed there but is routed to the guarded
    /// mark-as-charity path, never sent to `reclassify_transaction`.
    public static let reclassifiable: [TransactionKind] = [
        .charge, .refund, .fundCharge, .transfer, .payment, .cashback, .income,
    ]
}

/// `provisional` (pending) / `verified` (posted) / `excluded` (trash) /
/// `reversed`. A row is in Trash when `excluded == true` OR
/// `state == .excluded` (live.js:819-820).
public enum TransactionState: String, Equatable, Codable {
    case provisional
    case verified
    case excluded
    case reversed
}

/// Where a row came from. `plaid` is authoritative; `amex_alert` rows
/// start provisional and are merged into the Plaid row on arrival.
public enum TransactionSource: String, Equatable, Codable {
    case csv
    case amexAlert = "amex_alert"
    case plaid
    case manual
}

/// Household role. Admin-only enforcement lives server-side (RPCs /
/// Edge Functions / RLS); hiding a button is presentation only.
public enum HouseholdRole: String, Equatable, Codable {
    case admin
    case member
}

// MARK: - Transactions

/// One row of `transactions` (live.js:751-756 selects `*` with
/// `date >= 2026-11-01`, ordered by date desc — the app never shows
/// pre-November rows; the server floors week math at Nov 1 too).
public struct Transaction: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    /// `YYYY-MM-DD`.
    public let date: String
    public let merchant: String
    /// Signed integer cents. A refund is negative.
    public let amountCents: Int
    /// Last 4 of the card, or "0000" for cash / no card.
    public let cardSuffix: String
    public let source: TransactionSource
    public let state: TransactionState
    public let kind: TransactionKind
    /// Cents of this charge covered by the Extra Fund (0 when none).
    public let fundAllocationCents: Int
    public let excluded: Bool
    public let excludeReason: String
    public let late: Bool
    public let externalId: String?
    public let dedupeHash: String
    /// The purchase this refund is linked to, if any.
    public let originalPurchaseId: UUID?
    /// State before the row was excluded (`pre_exclusion_state`,
    /// `n4-pre-exclusion-state.sql`) — what restore puts back.
    public let preExclusionState: String?
    public let plaidPendingTransactionId: String?
    public let plaidTransactionId: String?
    public let createdAt: String

    public var isInTrash: Bool { excluded || state == .excluded }
    /// A pending (provisional) refund restores nothing and is excluded
    /// from week math (compute-week contract).
    public var isPendingRefund: Bool { kind == .refund && state == .provisional }

    enum CodingKeys: String, CodingKey {
        case id, date, merchant, state, kind, excluded, late
        case householdId = "household_id"
        case amountCents = "amount_cents"
        case cardSuffix = "card_suffix"
        case source
        case fundAllocationCents = "fund_allocation_cents"
        case excludeReason = "exclude_reason"
        case externalId = "external_id"
        case dedupeHash = "dedupe_hash"
        case originalPurchaseId = "original_purchase_id"
        case preExclusionState = "pre_exclusion_state"
        case plaidPendingTransactionId = "plaid_pending_transaction_id"
        case plaidTransactionId = "plaid_transaction_id"
        case createdAt = "created_at"
    }
}

/// The narrow row used for CSV-dedupe whole-history reads
/// (live.js:2468-2470: merchant, amount_cents, date, card_suffix).
public struct TransactionDedupeRow: Equatable, Codable {
    public let merchant: String
    public let amountCents: Int
    public let date: String
    public let cardSuffix: String

    enum CodingKeys: String, CodingKey {
        case merchant, date
        case amountCents = "amount_cents"
        case cardSuffix = "card_suffix"
    }

    /// The dedupe hash for a manual/CSV row (live.js:2756):
    /// SHA-256 hex of "date|MERCHANT|amountCents|suffix".
    public var dedupeHash: String {
        SHA256.hex("\(date)|\(merchant.uppercased())|\(amountCents)|\(cardSuffix)")
    }
}

/// A hand-entered purchase (live.js:2744-2761). Inserts are
/// `source: manual`, `state: provisional`, `kind: charge`, and are
/// constrained to exactly that by RLS (`02-rls-hardening.sql`).
/// `date` must be on/after 2026-11-01 (live.js:2740-2742).
public struct ManualTransactionInsert: Equatable, Codable {
    public let householdId: UUID
    public let date: String
    public let merchant: String
    public let amountCents: Int
    public let cardSuffix: String
    public let source = "manual"
    public let state = "provisional"
    public let kind = "charge"
    public let dedupeHash: String

    public init(householdId: UUID, date: String, merchant: String, amountCents: Int, cardSuffix: String) {
        self.householdId = householdId
        self.date = date
        // The web client upper-cases the merchant before hashing and
        // storing (live.js:2747).
        self.merchant = merchant.trimmingCharacters(in: .whitespaces).uppercased()
        self.amountCents = amountCents
        self.cardSuffix = cardSuffix
        self.dedupeHash = SHA256.hex("\(date)|\(self.merchant)|\(amountCents)|\(cardSuffix)")
    }

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case date, merchant
        case amountCents = "amount_cents"
        case cardSuffix = "card_suffix"
        case source, state, kind
        case dedupeHash = "dedupe_hash"
    }
}

/// One CSV row to insert (live.js:2500-2518). `kind` comes from the
/// CSV classifier (charge vs refund by sign/merchant); the hash format
/// is the same as a manual row.
public struct CSVTransactionInsert: Equatable, Codable {
    public let householdId: UUID
    public let date: String
    public let merchant: String
    public let amountCents: Int
    public let cardSuffix: String
    public let source = "csv"
    public let state = "provisional"
    public let kind: String
    public let dedupeHash: String

    public init(householdId: UUID, date: String, merchant: String, amountCents: Int, cardSuffix: String, kind: String) {
        self.householdId = householdId
        self.date = date
        self.merchant = merchant
        self.amountCents = amountCents
        self.cardSuffix = cardSuffix
        self.kind = kind
        self.dedupeHash = SHA256.hex("\(date)|\(merchant.uppercased())|\(amountCents)|\(cardSuffix)")
    }

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case date, merchant
        case amountCents = "amount_cents"
        case cardSuffix = "card_suffix"
        case source, state, kind
        case dedupeHash = "dedupe_hash"
    }
}

// MARK: - Household & membership

/// One row of `households`. `baseAllowanceCents` defaults to 37500
/// ($375) in the schema — a null `allowanceSetAt` means no admin has
/// ever explicitly set an allowance (live.js:566-583), so the $375
/// figure must not be presented as a choice until it is set.
public struct Household: Equatable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let baseAllowanceCents: Int
    public let fundShortfallCents: Int
    public let autoSyncEnabled: Bool
    public let inviteCode: String?
    public let allowanceSetAt: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case baseAllowanceCents = "base_allowance_cents"
        case fundShortfallCents = "fund_shortfall_cents"
        case autoSyncEnabled = "auto_sync_enabled"
        case inviteCode = "invite_code"
        case allowanceSetAt = "allowance_set_at"
        case createdAt = "created_at"
    }
}

/// The signed-in user's own membership row (`household_members`,
/// live.js:374-376). Only `household_id` + `role` are read here.
public struct HouseholdMembership: Equatable, Codable {
    public let householdId: UUID
    public let role: HouseholdRole
    public let userId: UUID?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case role
        case userId = "user_id"
        case displayName = "display_name"
    }
}

/// One row returned by the `list_household_members()` RPC
/// (`signup-display-name.sql:207-216`): no full email ever — only
/// `emailPrefix` (the part before '@') as the name fallback.
public struct MemberListRow: Equatable, Codable, Identifiable {
    public let userId: UUID
    public let displayName: String?
    public let role: HouseholdRole
    public let createdAt: String
    public let emailPrefix: String?

    public var id: UUID { userId }

    /// Display-name resolution, in order (live.js:486-496): stored
    /// display name, the signed-in user's own auth-metadata name,
    /// email prefix, "Household member". Never the bare word "Member".
    public func displayName(fallbackOwnMetadataName: String? = nil, isOwnRow: Bool = false) -> String {
        if let stored = displayName?.trimmingCharacters(in: .whitespaces), !stored.isEmpty { return stored }
        if isOwnRow, let meta = fallbackOwnMetadataName?.trimmingCharacters(in: .whitespaces), !meta.isEmpty { return meta }
        if let prefix = emailPrefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty { return prefix }
        return "Household member"
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case role
        case createdAt = "created_at"
        case emailPrefix = "email_prefix"
    }
}

// MARK: - Week figures (server-authoritative)

/// The compute-week response — the FINAL-spec contract (live.js:15-25
/// and `supabase/functions/compute-week/index.ts:393-403`).
/// The client displays these figures and never recomputes them.
/// `week_start` is the Sunday of the week; `available_cents` may be
/// negative. `carried_debt_cents` is the incoming debt D itself, NOT
/// the engine's carriedDebt output (max(0, D − B)).
public struct WeekResult: Equatable, Codable {
    public let weekStart: String
    public let baseAvailableCents: Int
    public let tempCents: Int
    public let carriedDebtCents: Int
    public let chargesCents: Int
    public let availableCents: Int
    public let weekLocked: Bool
    public let pendingRefundExcludedCents: Int
    public let unlinkedExcessCents: Int

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case baseAvailableCents = "base_available_cents"
        case tempCents = "temp_cents"
        case carriedDebtCents = "carried_debt_cents"
        case chargesCents = "charges_cents"
        case availableCents = "available_cents"
        case weekLocked = "week_locked"
        case pendingRefundExcludedCents = "pending_refund_excluded_cents"
        case unlinkedExcessCents = "unlinked_excess_cents"
    }

    /// Envelope keys: the flat fields plus the optional `result` wrapper.
    enum EnvelopeKeys: String, CodingKey {
        case result
        case weekStart = "week_start"
        case baseAvailableCents = "base_available_cents"
        case tempCents = "temp_cents"
        case carriedDebtCents = "carried_debt_cents"
        case chargesCents = "charges_cents"
        case availableCents = "available_cents"
        case weekLocked = "week_locked"
        case pendingRefundExcludedCents = "pending_refund_excluded_cents"
        case unlinkedExcessCents = "unlinked_excess_cents"
    }

    public init(from decoder: Decoder) throws {
        // The function returns the fields flat, but live.js:605 reads
        // `week.result ?? week` — tolerate a wrapped shape too.
        // A single keyed container handles both: the flat fields and
        // an optional nested `result` object of the same shape.
        let container = try decoder.container(keyedBy: EnvelopeKeys.self)
        let flat: WeekResultFlat
        if let wrapped = try container.decodeIfPresent(WeekResultFlat.self, forKey: .result) {
            flat = wrapped
        } else {
            flat = try WeekResultFlat(fromEnvelope: container)
        }
        self.weekStart = flat.weekStart
        self.baseAvailableCents = flat.baseAvailableCents
        self.tempCents = flat.tempCents
        self.carriedDebtCents = flat.carriedDebtCents
        self.chargesCents = flat.chargesCents
        self.availableCents = flat.availableCents
        self.weekLocked = flat.weekLocked
        self.pendingRefundExcludedCents = flat.pendingRefundExcludedCents
        self.unlinkedExcessCents = flat.unlinkedExcessCents
    }

    public init(
        weekStart: String, baseAvailableCents: Int, tempCents: Int,
        carriedDebtCents: Int, chargesCents: Int, availableCents: Int,
        weekLocked: Bool, pendingRefundExcludedCents: Int, unlinkedExcessCents: Int
    ) {
        self.weekStart = weekStart
        self.baseAvailableCents = baseAvailableCents
        self.tempCents = tempCents
        self.carriedDebtCents = carriedDebtCents
        self.chargesCents = chargesCents
        self.availableCents = availableCents
        self.weekLocked = weekLocked
        self.pendingRefundExcludedCents = pendingRefundExcludedCents
        self.unlinkedExcessCents = unlinkedExcessCents
    }
}

private struct WeekResultFlat: Decodable {
    let weekStart: String
    let baseAvailableCents: Int
    let tempCents: Int
    let carriedDebtCents: Int
    let chargesCents: Int
    let availableCents: Int
    let weekLocked: Bool
    let pendingRefundExcludedCents: Int
    let unlinkedExcessCents: Int

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case baseAvailableCents = "base_available_cents"
        case tempCents = "temp_cents"
        case carriedDebtCents = "carried_debt_cents"
        case chargesCents = "charges_cents"
        case availableCents = "available_cents"
        case weekLocked = "week_locked"
        case pendingRefundExcludedCents = "pending_refund_excluded_cents"
        case unlinkedExcessCents = "unlinked_excess_cents"
    }

    /// Decode the flat fields out of an envelope container (same raw
    /// key strings as `CodingKeys`, plus the `result` key).
    init(fromEnvelope container: KeyedDecodingContainer<WeekResult.EnvelopeKeys>) throws {
        self.weekStart = try container.decode(String.self, forKey: .weekStart)
        self.baseAvailableCents = try container.decode(Int.self, forKey: .baseAvailableCents)
        self.tempCents = try container.decode(Int.self, forKey: .tempCents)
        self.carriedDebtCents = try container.decode(Int.self, forKey: .carriedDebtCents)
        self.chargesCents = try container.decode(Int.self, forKey: .chargesCents)
        self.availableCents = try container.decode(Int.self, forKey: .availableCents)
        self.weekLocked = try container.decodeIfPresent(Bool.self, forKey: .weekLocked) ?? false
        self.pendingRefundExcludedCents = try container.decodeIfPresent(Int.self, forKey: .pendingRefundExcludedCents) ?? 0
        self.unlinkedExcessCents = try container.decodeIfPresent(Int.self, forKey: .unlinkedExcessCents) ?? 0
    }
}

/// The week-close response (`supabase/functions/week-close/index.ts:993-1000`).
/// A no-op close (nothing due) returns `weeks_closed: 0` with the same shape.
public struct WeekCloseResult: Equatable, Codable {
    public let weeksClosed: Int
    public let releases: Int
    public let heldLegacy: Int
    public let restorations: Int
    public let heldRefundsCreated: Int
    public let fundAvailableCents: Int
    public let shortfallCents: Int
    public let pendingLateAdjustmentCents: Int
    public let unlinkedExcessByWeek: [String: Int]?
    public let restorationsSkipped: [String]

    enum CodingKeys: String, CodingKey {
        case weeksClosed = "weeks_closed"
        case releases
        case heldLegacy = "held_legacy"
        case restorations
        case heldRefundsCreated = "held_refunds_created"
        case fundAvailableCents = "fund_available_cents"
        case shortfallCents = "shortfall_cents"
        case pendingLateAdjustmentCents = "pending_late_adjustment_cents"
        case unlinkedExcessByWeek = "unlinked_excess_by_week"
        case restorationsSkipped = "restorations_skipped"
    }
}

/// One row of `week_closes` (live.js:2170-2172 selects week_start,
/// surplus_cents, outgoing_debt_cents).
public struct WeekClose: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let weekStart: String
    public let surplusCents: Int
    public let outgoingDebtCents: Int
    public let outgoingCreditCents: Int?
    public let baseAllowanceCents: Int?
    public let tempIncreaseCents: Int?
    public let lateAdjustmentCents: Int?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case weekStart = "week_start"
        case surplusCents = "surplus_cents"
        case outgoingDebtCents = "outgoing_debt_cents"
        case outgoingCreditCents = "outgoing_credit_cents"
        case baseAllowanceCents = "base_allowance_cents"
        case tempIncreaseCents = "temp_increase_cents"
        case lateAdjustmentCents = "late_adjustment_cents"
        case createdAt = "created_at"
    }
}

/// One row of `surplus_releases` (live.js:2173-2175).
public struct SurplusRelease: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let weekStart: String
    public let surplusCents: Int
    public let releaseDate: String
    public let status: String
    public let releasedCents: Int
    public let createdAt: String?
    public let closedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case weekStart = "week_start"
        case surplusCents = "surplus_cents"
        case releaseDate = "release_date"
        case status
        case releasedCents = "released_cents"
        case createdAt = "created_at"
        case closedAt = "closed_at"
    }
}

// MARK: - Extra Fund

/// One row of `fund_requests`. `status` is pending / approved /
/// declined / split; a split approval keeps the unapproved remainder
/// in `remainderCents` (live.js:1234-1240).
public struct FundRequest: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let transactionId: UUID?
    public let requestedBy: UUID
    public let amountCents: Int
    public let note: String
    public let status: String
    public let remainderCents: Int
    public let decidedBy: UUID?
    public let decidedAt: String?
    public let createdAt: String

    /// Approved cents: full amount when approved; requested − remainder
    /// when split; nil otherwise (live.js:1234).
    public var approvedCents: Int? {
        if status == "approved" { return amountCents }
        if status == "split" { return amountCents - remainderCents }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case transactionId = "transaction_id"
        case requestedBy = "requested_by"
        case amountCents = "amount_cents"
        case note, status
        case remainderCents = "remainder_cents"
        case decidedBy = "decided_by"
        case decidedAt = "decided_at"
        case createdAt = "created_at"
    }
}

/// One row of `fund_ledger`. Kinds: release, allocation,
/// override_allocation, adjustment, reversal (`fund-ledger.sql`).
public struct FundLedgerEntry: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let kind: String
    public let amountCents: Int
    public let weekStart: String?
    public let requestId: UUID?
    public let note: String
    public let createdBy: UUID?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case kind
        case amountCents = "amount_cents"
        case weekStart = "week_start"
        case requestId = "request_id"
        case note
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

/// One row of `fund_topups` (`r12-add-money.sql:36-54`).
public struct FundTopup: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let clientKey: String
    public let amountCents: Int
    public let shortfallCoveredCents: Int
    public let fundAddedCents: Int
    public let shortfallAfterCents: Int
    public let note: String
    public let createdBy: UUID?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case clientKey = "client_key"
        case amountCents = "amount_cents"
        case shortfallCoveredCents = "shortfall_covered_cents"
        case fundAddedCents = "fund_added_cents"
        case shortfallAfterCents = "shortfall_after_cents"
        case note
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

/// The Extra Fund summary — a DISPLAY aggregation over the ledger,
/// releases, and household shortfall, mirroring live.js:1609-1631
/// exactly. It is sums, not week math: the server owns all figures
/// behind it, and this struct only re-presents them.
/// The expanded card shows only Available / Pending / Total.
public struct FundSummary: Equatable {
    public let availableCents: Int
    public let pendingCents: Int
    public let releasedTotalCents: Int
    public let spentCents: Int
    public let shortfallCents: Int
    public let heldTotalCents: Int
    public let heldWeeks: Int

    /// Pending as the sheet shows it: pending releases plus held weeks
    /// (live.js:1647-1650).
    public var pendingIncludingHeldCents: Int { pendingCents + heldTotalCents }
    /// Total as the sheet shows it: Available + Pending (incl. held).
    public var totalCents: Int { availableCents + pendingIncludingHeldCents }

    public static func compute(
        ledger: [FundLedgerEntry],
        releases: [SurplusRelease],
        shortfallCents: Int
    ) -> FundSummary {
        let sumKind = { (kind: String) in
            ledger.filter { $0.kind == kind }.reduce(0) { $0 + $1.amountCents }
        }
        let available = ledger.reduce(0) { $0 + $1.amountCents }
        let spent = abs(sumKind("allocation") + sumKind("override_allocation"))
        let pending = releases
            .filter { $0.status == "pending" }
            .reduce(0) { $0 + max(0, $1.surplusCents - $1.releasedCents) }
        // live.js uses `released_cents || surplus_cents`: a 0 released
        // figure falls back to the surplus figure.
        let releasedTotal = releases
            .filter { $0.status == "released" }
            .reduce(0) { $0 + ($1.releasedCents != 0 ? $1.releasedCents : $1.surplusCents) }
        let heldRows = releases.filter { $0.status == "held" }
        let heldTotal = heldRows.reduce(0) { $0 + $1.surplusCents }
        return FundSummary(
            availableCents: available,
            pendingCents: pending,
            releasedTotalCents: releasedTotal,
            spentCents: spent,
            shortfallCents: shortfallCents,
            heldTotalCents: heldTotal,
            heldWeeks: heldRows.count
        )
    }
}

/// The `add_fund_money` jsonb return (`r12-add-money.sql:92,132`):
/// the shortfall-first split. The server split is authoritative;
/// the client preview (same rule) is informational only.
public struct AddFundMoneyResult: Equatable, Codable {
    public let amountCents: Int
    public let shortfallCoveredCents: Int
    public let fundAddedCents: Int
    public let shortfallAfterCents: Int
    public let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case amountCents = "amount_cents"
        case shortfallCoveredCents = "shortfall_covered_cents"
        case fundAddedCents = "fund_added_cents"
        case shortfallAfterCents = "shortfall_after_cents"
        case replayed
    }
}

// MARK: - Savings (read-only in the live app)

/// One row of `savings_ledger`. The live app READS these rows only
/// (live.js:1282-1306); there is no live write path — `attest_savings`
/// and `record_savings_entry` have no call sites and their EXECUTE
/// grants were revoked live (see RPCs.swift). Balance is the latest
/// attested `actualBalanceCents`, never a sum of movements.
public struct SavingsLedgerEntry: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let kind: String
    public let amountCents: Int
    public let actualBalanceCents: Int?
    public let attestedBy: UUID?
    public let note: String
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case kind
        case amountCents = "amount_cents"
        case actualBalanceCents = "actual_balance_cents"
        case attestedBy = "attested_by"
        case note
        case createdAt = "created_at"
    }
}

// MARK: - Charity

/// One row of `charity_settings` (`r13-charity.sql:91-95`).
/// Default 1000 bp = 10%.
public struct CharitySettings: Equatable, Codable {
    public let householdId: UUID
    public let defaultRateBp: Int
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case defaultRateBp = "default_rate_bp"
        case updatedAt = "updated_at"
    }
}

/// One row of `charity_income` (`r13-charity.sql:96-111`).
/// `status` is active / reversed; a correction reverses the old row
/// and inserts a new one linked by `replacesId`.
public struct CharityIncome: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let sourceLabel: String
    public let amountCents: Int
    /// `YYYY-MM-DD`.
    public let incomeDate: String
    public let rateBp: Int
    public let status: String
    public let replacesId: UUID?
    public let note: String
    public let createdBy: UUID?
    public let createdAt: String?

    /// Committed cents for this income row, as the server computes it
    /// in `record_charity_income` (amount × rate / 10000, integer
    /// division). The RPC return carries the server's exact figure;
    /// this is the same arithmetic for display sums.
    public var committedCents: Int { amountCents * rateBp / 10_000 }

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case sourceLabel = "source_label"
        case amountCents = "amount_cents"
        case incomeDate = "income_date"
        case rateBp = "rate_bp"
        case status
        case replacesId = "replaces_id"
        case note
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

/// The `record_charity_income` / `correct_charity_income` jsonb return
/// (`r13-charity.sql:190,239`).
public struct CharityIncomeResult: Equatable, Codable {
    public let incomeId: UUID
    public let rateBp: Int
    public let committedCents: Int

    enum CodingKeys: String, CodingKey {
        case incomeId = "income_id"
        case rateBp = "rate_bp"
        case committedCents = "committed_cents"
    }
}

/// The `record_charity_gift` jsonb return (`r13-charity.sql:290-317`).
/// `replayed: true` means the idempotency key was already used and
/// the stored gift was returned with no money moved.
public struct CharityGiftResult: Equatable, Codable {
    public let transactionId: UUID
    public let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case replayed
    }
}

/// Charity aggregates — DISPLAY ONLY, mirroring live.js:1696-1720.
/// Committed = Σ amount × rate over ACTIVE income rows; Given = Σ
/// verified charity transactions dated ≥ 2026-11-01. Pending (provisional)
/// gifts count toward Given only once they post (live.js:3814-3820).
public struct CharitySummary: Equatable {
    public let committedCents: Int
    public let givenCents: Int
    public let pendingGiftCents: Int
    public let defaultRateBp: Int

    public var remainingCents: Int { committedCents - givenCents }

    public static func compute(
        activeIncome: [CharityIncome],
        charityTransactions: [Transaction],
        defaultRateBp: Int
    ) -> CharitySummary {
        let committed = activeIncome
            .filter { $0.status == "active" }
            .reduce(0) { $0 + $1.committedCents }
        let verified = charityTransactions.filter {
            $0.kind == .charity && $0.state == .verified && !$0.excluded && $0.date >= "2026-11-01"
        }
        let pending = charityTransactions.filter {
            $0.kind == .charity && $0.state == .provisional && !$0.excluded && $0.date >= "2026-11-01"
        }
        return CharitySummary(
            committedCents: committed,
            givenCents: verified.reduce(0) { $0 + $1.amountCents },
            pendingGiftCents: pending.reduce(0) { $0 + $1.amountCents },
            defaultRateBp: defaultRateBp
        )
    }
}

// MARK: - Duplicates, refunds, restoration

/// One row of `duplicate_candidates` (`dedupe-review-queue.sql:44-60`).
/// `status` is pending / merged / separate.
public struct DuplicateCandidate: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let canonicalTransactionId: UUID
    public let duplicateTransactionId: UUID
    public let reason: String
    public let merchantA: String
    public let merchantB: String
    public let status: String
    public let resolutionNote: String?
    public let resolvedBy: UUID?
    public let createdAt: String
    public let resolvedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case canonicalTransactionId = "canonical_transaction_id"
        case duplicateTransactionId = "duplicate_transaction_id"
        case reason
        case merchantA = "merchant_a"
        case merchantB = "merchant_b"
        case status
        case resolutionNote = "resolution_note"
        case resolvedBy = "resolved_by"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}

/// One row of `merchant_aliases` — admin-confirmed evidence that two
/// merchant spellings are the same place (live.js:2068).
public struct MerchantAlias: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let nameA: String
    public let nameB: String
    public let confirmedBy: UUID?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case nameA = "name_a"
        case nameB = "name_b"
        case confirmedBy = "confirmed_by"
        case createdAt = "created_at"
    }
}

/// One row of `refund_link_dismissals` (`refund-link-dismissals.sql:20-30`).
public struct RefundLinkDismissal: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let refundId: UUID
    public let purchaseId: UUID
    public let dismissedBy: UUID?
    public let dismissedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case refundId = "refund_id"
        case purchaseId = "purchase_id"
        case dismissedBy = "dismissed_by"
        case dismissedAt = "dismissed_at"
    }
}

/// One row of `restoration_entries` (`restoration-snapshots.sql:76-90`):
/// one per refund event that restored a locked week.
public struct RestorationEntry: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let weekStart: String
    public let purchaseTransactionId: UUID?
    public let refundTransactionId: UUID
    public let restoredSurplusCents: Int
    public let debtReductionCents: Int
    public let fundCreditCents: Int
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case weekStart = "week_start"
        case purchaseTransactionId = "purchase_transaction_id"
        case refundTransactionId = "refund_transaction_id"
        case restoredSurplusCents = "restored_surplus_cents"
        case debtReductionCents = "debt_reduction_cents"
        case fundCreditCents = "fund_credit_cents"
        case createdAt = "created_at"
    }
}

/// One row of `held_refunds` (`restoration-snapshots.sql:92-107`):
/// the excess of a refund over its purchase, held until an admin
/// resolves it. `status` is pending / resolved.
public struct HeldRefund: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let refundTransactionId: UUID
    public let purchaseTransactionId: UUID?
    public let heldCents: Int
    public let status: String
    public let resolutionNote: String?
    public let createdAt: String?
    public let resolvedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case refundTransactionId = "refund_transaction_id"
        case purchaseTransactionId = "purchase_transaction_id"
        case heldCents = "held_cents"
        case status
        case resolutionNote = "resolution_note"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}

/// The action for `resolve_held_refund` (`merged-audit-held-release-atomic.sql`).
public enum HeldRefundAction: String, Equatable, Codable {
    /// Release the held amount (the live UI's only path, live.js:1855).
    case release
    case resolve
    case writeOff = "write_off"
}

/// The action for `resolve_duplicate_candidate`
/// (`dedupe-review-queue.sql:93-96`).
public enum DuplicateResolutionAction: String, Equatable, Codable {
    case merge
    case separate
}

// MARK: - Bank & email connections

/// One row of the `plaid_items_public` view (`03-plaid-vault.sql`).
/// The view exposes exactly these columns — no token, no cursor.
/// `status` is active / disconnected.
public struct PlaidItemPublic: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let plaidItemId: String
    public let institutionName: String?
    public let institutionId: String?
    public let status: String
    public let lastSyncAt: String?
    public let createdAt: String

    public var isActive: Bool { status == "active" }

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case plaidItemId = "plaid_item_id"
        case institutionName = "institution_name"
        case institutionId = "institution_id"
        case status
        case lastSyncAt = "last_sync_at"
        case createdAt = "created_at"
    }
}

/// One row of `plaid_accounts` (`plaid-accounts.sql:9-21`).
/// Accounts with `disconnectedAt` set are not rendered (live.js:1426-1428).
public struct PlaidAccount: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let plaidItemId: String
    public let plaidAccountId: String
    public let name: String?
    public let mask: String?
    public let type: String?
    public let subtype: String?
    public let disconnectedAt: String?
    public let createdAt: String?
    public let updatedAt: String?

    public var isDisconnected: Bool { disconnectedAt != nil }

    /// Plain-language type, DISPLAY ONLY (live.js:199-213): Plaid's
    /// raw type/subtype strings are never rendered verbatim.
    public var plainType: String {
        switch (type?.lowercased() ?? "", subtype?.lowercased() ?? "") {
        case ("credit", _): return "Credit card"
        case ("depository", "checking"): return "Checking"
        case ("depository", "savings"): return "Savings"
        case ("depository", _): return "Bank account"
        case ("loan", _): return "Loan"
        case ("investment", _): return "Investment"
        default: return ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case plaidItemId = "plaid_item_id"
        case plaidAccountId = "plaid_account_id"
        case name, mask, type, subtype
        case disconnectedAt = "disconnected_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One row of `account_nicknames` (`r3-account-nicknames.sql:14-21`).
public struct AccountNickname: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let plaidItemId: String
    public let plaidAccountId: String
    public let cardSuffix: String?
    public let nickname: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case plaidItemId = "plaid_item_id"
        case plaidAccountId = "plaid_account_id"
        case cardSuffix = "card_suffix"
        case nickname
    }
}

/// One row of the `email_connections_public` view
/// (`gmail-oauth.sql` + `gmail-connected-at.sql`): status only, no
/// token. `connectedAt` is the grant clock — Testing-mode Google
/// refresh tokens expire ~7 days after the grant.
public struct EmailConnectionPublic: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let provider: String
    public let emailAddress: String
    public let status: String
    public let lastPollAt: String?
    public let lastError: String?
    public let createdAt: String
    public let connectedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case provider
        case emailAddress = "email_address"
        case status
        case lastPollAt = "last_poll_at"
        case lastError = "last_error"
        case createdAt = "created_at"
        case connectedAt = "connected_at"
    }
}

// MARK: - Audit & webhooks

/// One row of `audit_log` (append-only; live.js:2241-2247).
public struct AuditLogEntry: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let actor: UUID?
    public let actorName: String
    public let action: String
    public let detail: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case actor
        case actorName = "actor_name"
        case action, detail
        case createdAt = "created_at"
    }
}

/// A new audit row to append (live.js:396-401). The insert goes
/// through RLS; a blocked insert must not fail the action it logs.
public struct AuditLogInsert: Equatable, Codable {
    public let householdId: UUID
    public let actor: UUID?
    public let actorName: String
    public let action: String
    public let detail: String

    enum CodingKeys: String, CodingKey {
        case householdId = "household_id"
        case actor
        case actorName = "actor_name"
        case action, detail
    }
}

/// One row of `webhook_events` (`webhook-events.sql`). The client
/// only READS unprocessed rows to decide whether an auto-sync is due
/// (live.js:3010-3013); only the plaid-webhook function writes.
public struct WebhookEvent: Equatable, Codable, Identifiable {
    public let id: UUID
    public let plaidItemId: String?
    public let webhookCode: String
    public let dedupeHash: String?
    public let processed: Bool
    public let householdId: UUID?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case plaidItemId = "plaid_item_id"
        case webhookCode = "webhook_code"
        case dedupeHash = "dedupe_hash"
        case processed
        case householdId = "household_id"
        case createdAt = "created_at"
    }
}

// MARK: - Allowance overrides & temp increases

/// One row of `weekly_allowance_overrides`
/// (`weekly-allowance-override.sql:51-60`). The Temporary Increase box
/// writes one row per week (1–4 weeks) via
/// `set_weekly_allowance_override` — never `add_temp_increase`
/// (live.js:4555-4560). A row replaces base + temp with B = override,
/// T = 0 for that week; a stored close snapshot still wins.
public struct WeeklyAllowanceOverride: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let weekStart: String
    public let allowanceCents: Int
    public let createdBy: UUID?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case weekStart = "week_start"
        case allowanceCents = "allowance_cents"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

/// One row of `temp_increases` (`live-temp-increases.sql:12-21`).
/// Read by compute-week server-side. The client never writes this
/// table directly (`add_temp_increase` is revoked live — see RPCs.swift).
public struct TempIncrease: Equatable, Codable {
    public let id: UUID?
    public let householdId: UUID
    public let weekStart: String
    public let amountCents: Int
    public let note: String
    public let createdBy: UUID?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case weekStart = "week_start"
        case amountCents = "amount_cents"
        case note
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}
