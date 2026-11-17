import Foundation

/// The per-user notification settings (Settings Notifications card,
/// Nov 16, 2026). One row per (user_id, household_id) in
/// `notification_preferences`.
/// - `notificationsEnabled` is the master on/off (Nov 16, ~11:56 PM):
///   off means the server sends this user nothing, whatever the
///   per-type flags say. Default true.
/// - The fifteen per-type flags default true. A missing row means
///   all on, and a missing column decodes as true — so the client
///   keeps working if the migration lags behind the app.
/// `Sendable` because the kit compiles in Swift 6 mode and the
/// static `allOn` / `toggles` must be concurrency-safe.
public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var weekClosed: Bool
    public var newWeek: Bool
    public var overBudget: Bool
    public var newPurchase: Bool
    public var newIncome: Bool
    public var newCharity: Bool
    public var monthlyStatement: Bool
    public var memberJoined: Bool
    public var memberLeft: Bool
    public var gmailExpiring: Bool
    public var fundRequest: Bool
    public var needsReview: Bool
    public var largePurchase: Bool
    public var bankBroken: Bool
    public var budgetIncreased: Bool

    public init(
        notificationsEnabled: Bool = true,
        weekClosed: Bool = true,
        newWeek: Bool = true,
        overBudget: Bool = true,
        newPurchase: Bool = true,
        newIncome: Bool = true,
        newCharity: Bool = true,
        monthlyStatement: Bool = true,
        memberJoined: Bool = true,
        memberLeft: Bool = true,
        gmailExpiring: Bool = true,
        fundRequest: Bool = true,
        needsReview: Bool = true,
        largePurchase: Bool = true,
        bankBroken: Bool = true,
        budgetIncreased: Bool = true
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.weekClosed = weekClosed
        self.newWeek = newWeek
        self.overBudget = overBudget
        self.newPurchase = newPurchase
        self.newIncome = newIncome
        self.newCharity = newCharity
        self.monthlyStatement = monthlyStatement
        self.memberJoined = memberJoined
        self.memberLeft = memberLeft
        self.gmailExpiring = gmailExpiring
        self.fundRequest = fundRequest
        self.needsReview = needsReview
        self.largePurchase = largePurchase
        self.bankBroken = bankBroken
        self.budgetIncreased = budgetIncreased
    }

    public static let allOn = NotificationPreferences()

    enum CodingKeys: String, CodingKey {
        case notificationsEnabled = "notifications_enabled"
        case weekClosed = "week_closed"
        case newWeek = "new_week"
        case overBudget = "over_budget"
        case newPurchase = "new_purchase"
        case newIncome = "new_income"
        case newCharity = "new_charity"
        case monthlyStatement = "monthly_statement"
        case memberJoined = "member_joined"
        case memberLeft = "member_left"
        case gmailExpiring = "gmail_expiring"
        case fundRequest = "fund_request"
        case needsReview = "needs_review"
        case largePurchase = "large_purchase"
        case bankBroken = "bank_broken"
        case budgetIncreased = "budget_increased"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        weekClosed = try container.decodeIfPresent(Bool.self, forKey: .weekClosed) ?? true
        newWeek = try container.decodeIfPresent(Bool.self, forKey: .newWeek) ?? true
        overBudget = try container.decodeIfPresent(Bool.self, forKey: .overBudget) ?? true
        newPurchase = try container.decodeIfPresent(Bool.self, forKey: .newPurchase) ?? true
        newIncome = try container.decodeIfPresent(Bool.self, forKey: .newIncome) ?? true
        newCharity = try container.decodeIfPresent(Bool.self, forKey: .newCharity) ?? true
        monthlyStatement = try container.decodeIfPresent(Bool.self, forKey: .monthlyStatement) ?? true
        memberJoined = try container.decodeIfPresent(Bool.self, forKey: .memberJoined) ?? true
        memberLeft = try container.decodeIfPresent(Bool.self, forKey: .memberLeft) ?? true
        gmailExpiring = try container.decodeIfPresent(Bool.self, forKey: .gmailExpiring) ?? true
        fundRequest = try container.decodeIfPresent(Bool.self, forKey: .fundRequest) ?? true
        needsReview = try container.decodeIfPresent(Bool.self, forKey: .needsReview) ?? true
        largePurchase = try container.decodeIfPresent(Bool.self, forKey: .largePurchase) ?? true
        bankBroken = try container.decodeIfPresent(Bool.self, forKey: .bankBroken) ?? true
        budgetIncreased = try container.decodeIfPresent(Bool.self, forKey: .budgetIncreased) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(weekClosed, forKey: .weekClosed)
        try container.encode(newWeek, forKey: .newWeek)
        try container.encode(overBudget, forKey: .overBudget)
        try container.encode(newPurchase, forKey: .newPurchase)
        try container.encode(newIncome, forKey: .newIncome)
        try container.encode(newCharity, forKey: .newCharity)
        try container.encode(monthlyStatement, forKey: .monthlyStatement)
        try container.encode(memberJoined, forKey: .memberJoined)
        try container.encode(memberLeft, forKey: .memberLeft)
        try container.encode(gmailExpiring, forKey: .gmailExpiring)
        try container.encode(fundRequest, forKey: .fundRequest)
        try container.encode(needsReview, forKey: .needsReview)
        try container.encode(largePurchase, forKey: .largePurchase)
        try container.encode(bankBroken, forKey: .bankBroken)
        try container.encode(budgetIncreased, forKey: .budgetIncreased)
    }

    /// The fifteen per-type toggles in Settings order, each with its
    /// Title Case label (matching the notification title it controls)
    /// and a key path for reading/writing the flag. The master
    /// on/off is NOT in this list — it is a separate control at the
    /// top of the card. Computed (not a stored `let`): a stored array
    /// of key paths is not `Sendable` in Swift 6, and a computed
    /// property creates a fresh array on each access, so there is no
    /// shared mutable state.
    public static var toggles: [(label: String, keyPath: WritableKeyPath<NotificationPreferences, Bool>)] {
        [
            ("Week Closed", \.weekClosed),
            ("New Week", \.newWeek),
            ("Over Budget", \.overBudget),
            ("New Purchase", \.newPurchase),
            ("New Income", \.newIncome),
            ("Charity Gift", \.newCharity),
            ("Monthly Statement", \.monthlyStatement),
            ("Member Joined", \.memberJoined),
            ("Member Left", \.memberLeft),
            ("Gmail Connection Expiring", \.gmailExpiring),
            ("Fund Request Waiting", \.fundRequest),
            ("Needs Review", \.needsReview),
            ("Large Purchase", \.largePurchase),
            ("Bank Connection Broken", \.bankBroken),
            ("Budget Increased", \.budgetIncreased),
        ]
    }
}
