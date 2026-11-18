import Foundation

/// One row of `weekly_budget_topups`
/// (`supabase/weekly-budget-topups.sql`, build 43 item 21, Nov 17,
/// 2026): one row per one-time "Top Up Budget" grant to a week's
/// budget, written by the `add_to_weekly_budget` RPC alongside the
/// override upsert. Append-only — never edited.
///
/// WHY this table exists: the override IS the week's total, so it
/// folds together the temporary allowance AND all top-ups. Without
/// a separate record the Spending breakdown could only show
/// Base and Total — the same number twice when a top-up was the
/// only thing above the base. The breakdown's "Top Ups" line sums
/// this table's rows for the current week; the Temporary
/// Increase/Decrease delta is then the override's delta against
/// the stored base MINUS that sum (see `temporaryDeltaCents`).
public struct WeeklyBudgetTopup: Equatable, Codable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    /// `YYYY-MM-DD` — the Sunday of the week the grant applies to.
    public let weekStart: String
    public let amountCents: Int
    public let createdBy: UUID?
    public let createdAt: String?

    public init(
        id: UUID, householdId: UUID, weekStart: String,
        amountCents: Int, createdBy: UUID? = nil, createdAt: String? = nil
    ) {
        self.id = id
        self.householdId = householdId
        self.weekStart = weekStart
        self.amountCents = amountCents
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case weekStart = "week_start"
        case amountCents = "amount_cents"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    /// The Spending breakdown's Temporary Increase/Decrease delta
    /// (build 43, item 21): the override's delta against the stored
    /// base, EXCLUDING one-time top-ups — those get their own "Top
    /// Ups" line, so counting them here too would double-count.
    /// Nil when there is no override driving the week (no temporary
    /// adjustment to show — the plain-base week) or when the delta
    /// is 0 (the override equals base + top-ups, so there is no
    /// temporary adjustment left to explain). The caller shows the
    /// row only when this is non-nil, keeping the existing +/−
    /// formatting ("Temporary Increase" for a positive delta,
    /// "Temporary Decrease" for a negative one).
    ///
    /// Row arithmetic (see `WeeklyBudgetTopupsTests`): for an
    /// override week, Base + Top Ups + delta − Debt Payment equals
    /// the week's Total (`baseAvailableCents + tempCents`, which is
    /// override − debt payment when the server reports `temp_cents`
    /// 0 for override weeks).
    public static func temporaryDeltaCents(
        overrideCents: Int?, baseAllowanceCents: Int?, topUpsCents: Int
    ) -> Int? {
        guard let override = overrideCents, let base = baseAllowanceCents else { return nil }
        let delta = override - base - topUpsCents
        return delta == 0 ? nil : delta
    }
}
