import Foundation

/// The per-user, per-type notification toggles (Settings Notifications
/// card, Nov 16, 2026). One row per (user_id, household_id) in
/// `notification_preferences`; all fourteen flags default true.
/// A missing row means all on, and a missing column decodes as true —
/// so the client keeps working if the migration lags behind the app.
public struct NotificationPreferences: Codable, Equatable {
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
    public var largePurchase: Bool
    public var bankBroken: Bool
    public var budgetIncreased: Bool

    public init(
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
        largePurchase: Bool = true,
        bankBroken: Bool = true,
        budgetIncreased: Bool = true
    ) {
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
        self.largePurchase = largePurchase
        self.bankBroken = bankBroken
        self.budgetIncreased = budgetIncreased
    }

    public static let allOn = NotificationPreferences()

    enum CodingKeys: String, CodingKey {
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
        case largePurchase = "large_purchase"
        case bankBroken = "bank_broken"
        case budgetIncreased = "budget_increased"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        largePurchase = try container.decodeIfPresent(Bool.self, forKey: .largePurchase) ?? true
        bankBroken = try container.decodeIfPresent(Bool.self, forKey: .bankBroken) ?? true
        budgetIncreased = try container.decodeIfPresent(Bool.self, forKey: .budgetIncreased) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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
        try container.encode(largePurchase, forKey: .largePurchase)
        try container.encode(bankBroken, forKey: .bankBroken)
        try container.encode(budgetIncreased, forKey: .budgetIncreased)
    }

    /// The fourteen toggles in Settings order, each with its Title
    /// Case label (matching the notification title it controls) and
    /// a key path for reading/writing the flag.
    public static let toggles: [(label: String, keyPath: WritableKeyPath<NotificationPreferences, Bool>)] = [
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
        ("Large Purchase", \.largePurchase),
        ("Bank Connection Broken", \.bankBroken),
        ("Budget Increased", \.budgetIncreased),
    ]
}
