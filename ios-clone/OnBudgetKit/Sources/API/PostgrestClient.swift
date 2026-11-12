// OnBudgetKit — PostgrestClient.swift
//
// Typed reads (and the two member writes) over PostgREST
// (`<base>/rest/v1/<table>`), the same calls the web app makes with
// `supabase.from(…)` (live.js). Headers on every request:
//   apikey: <anon key>
//   Authorization: Bearer <user JWT>
//   Content-Type / Accept: application/json
//
// Paging (live.js:304-317, 413-426):
//   * Lists fetch `limit + 1` rows and render `limit` — the probe row
//     proves whether older rows exist ("Load More" shows only when
//     the probe row came back). `fetchPage` returns `(rows, hasMore)`.
//   * Whole-history reads (CSV dedupe, charity/savings aggregates)
//     page through in 1000-row pages ordered by `created_at` asc
//     (`fetchAllPages`) — a bare `.limit(1000)` silently truncates
//     any sum past 1000 rows (live.js:413-426).
//
// A failed page is an error, never a partial result presented as real
// numbers. An empty result is valid data, not an error.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Query model

/// A PostgREST filter. Values are rendered exactly as PostgREST
/// expects: `eq.2026-11-01`, `in.(charge,fund_charge)`,
/// `ilike.%stem%`, `is.null`.
public enum PostgrestFilter: Equatable {
    case equal(String, String)
    case notEqual(String, String)
    case greaterThan(String, String)
    case greaterThanOrEqual(String, String)
    case lessThan(String, String)
    case lessThanOrEqual(String, String)
    case `in`(String, [String])
    case like(String, String)
    case ilike(String, String)
    case isNull(String, Bool)

    var queryItem: URLQueryItem {
        switch self {
        case .equal(let column, let value):
            return URLQueryItem(name: column, value: "eq.\(value)")
        case .notEqual(let column, let value):
            return URLQueryItem(name: column, value: "neq.\(value)")
        case .greaterThan(let column, let value):
            return URLQueryItem(name: column, value: "gt.\(value)")
        case .greaterThanOrEqual(let column, let value):
            return URLQueryItem(name: column, value: "gte.\(value)")
        case .lessThan(let column, let value):
            return URLQueryItem(name: column, value: "lt.\(value)")
        case .lessThanOrEqual(let column, let value):
            return URLQueryItem(name: column, value: "lte.\(value)")
        case .in(let column, let values):
            return URLQueryItem(name: column, value: "in.(\(values.joined(separator: ",")))")
        case .like(let column, let value):
            return URLQueryItem(name: column, value: "like.\(value)")
        case .ilike(let column, let value):
            return URLQueryItem(name: column, value: "ilike.\(value)")
        case .isNull(let column, let isNull):
            return URLQueryItem(name: column, value: "is.\(isNull ? "null" : "not.null")")
        }
    }

    // Convenience constructors for the household-scoped reads.
    public static func householdId(_ id: UUID) -> PostgrestFilter {
        .equal("household_id", id.uuidString)
    }

    /// Filter for a row of the `households` table itself. Its primary
    /// key is `id` — there is NO `household_id` column on that table,
    /// so `.householdId` against `households` fails with "column
    /// households.household_id does not exist" (phone feedback, Nov
    /// 11, 2026: Budget card, invite code, auto-sync toggle, Extra
    /// Fund, and the Home allowance flag all broke on this one
    /// filter). Use `.householdId` only for tables that HAVE a
    /// `household_id` column (transactions, household_members, …).
    public static func householdRow(_ id: UUID) -> PostgrestFilter {
        .equal("id", id.uuidString)
    }

    public static func onOrAfterNov1() -> PostgrestFilter {
        // The app starts Nov 1, 2026 — the list never shows pre-Nov
        // rows (live.js:747-750).
        .greaterThanOrEqual("date", "2026-11-01")
    }
}

/// A PostgREST ordering term: `order=date.desc` / `order=created_at.asc`.
public struct PostgrestOrder: Equatable {
    public let column: String
    public let ascending: Bool

    public init(_ column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    var value: String { "\(column).\(ascending ? "asc" : "desc")" }
}

/// A complete read query. `buildRequest` is pure so tests can assert
/// on the URL it produces without touching the network.
public struct PostgrestQuery: Equatable {
    public let table: String
    public let columns: String
    public let filters: [PostgrestFilter]
    public let orders: [PostgrestOrder]
    /// Max rows to return (nil = server default).
    public let limit: Int?
    /// Rows to skip (used by `fetchAllPages`).
    public let offset: Int?
    /// When true, asks for an exact count (`Prefer: count=exact`) and
    /// the response's `Content-Range` header is parsed for the total.
    public let countExact: Bool

    public init(
        table: String,
        columns: String = "*",
        filters: [PostgrestFilter] = [],
        orders: [PostgrestOrder] = [],
        limit: Int? = nil,
        offset: Int? = nil,
        countExact: Bool = false
    ) {
        self.table = table
        self.columns = columns
        self.filters = filters
        self.orders = orders
        self.limit = limit
        self.offset = offset
        self.countExact = countExact
    }

    /// The `limit + 1` probe query for a list page (live.js:751-756).
    public static func page(
        table: String,
        columns: String = "*",
        filters: [PostgrestFilter] = [],
        orders: [PostgrestOrder] = [],
        limit: Int,
        offset: Int = 0
    ) -> PostgrestQuery {
        PostgrestQuery(
            table: table, columns: columns, filters: filters, orders: orders,
            limit: limit + 1, offset: offset
        )
    }

    func buildRequest(configuration: SupabaseConfiguration, accessToken: String) -> URLRequest {
        var components = URLComponents(
            url: configuration.restBaseURL.appendingPathComponent(table),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [URLQueryItem(name: "select", value: columns)]
        items += filters.map(\.queryItem)
        if !orders.isEmpty {
            items.append(URLQueryItem(name: "order", value: orders.map(\.value).joined(separator: ",")))
        }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if countExact {
            request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        }
        return request
    }
}

// MARK: - Client

/// Typed PostgREST access. Constructed by `SupabaseClient` (which
/// supplies the token provider); screens never build one directly.
public struct PostgrestClient {
    public let configuration: SupabaseConfiguration
    public let tokenProvider: () async throws -> String
    private let transport: HTTPTransport

    public init(
        configuration: SupabaseConfiguration,
        tokenProvider: @escaping () async throws -> String,
        transport: HTTPTransport
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    // MARK: Generic operations

    /// Run a read query and decode the rows. A non-2xx status throws
    /// `OnBudgetError` (a 401 becomes `.sessionExpired`).
    public func fetch<T: Decodable>(_ query: PostgrestQuery) async throws -> [T] {
        let token = try await tokenProvider()
        let request = query.buildRequest(configuration: configuration, accessToken: token)
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read \(query.table).")
        }
    }

    /// Run a read query and also return the exact total when the
    /// query asked for `countExact` (parsed from `Content-Range`:
    /// `0-49/123`). Used for the Activity count line (live.js:2247).
    public func fetchWithCount<T: Decodable>(_ query: PostgrestQuery) async throws -> ([T], Int?) {
        let token = try await tokenProvider()
        let request = query.buildRequest(configuration: configuration, accessToken: token)
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        let rows: [T]
        do {
            rows = try JSONDecoder().decode([T].self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read \(query.table).")
        }
        var total: Int?
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            total = Int(contentRange[contentRange.index(after: slash)...])
        }
        return (rows, total)
    }

    /// Fetch one row (`maybeSingle` semantics, live.js:375): limit 1
    /// and take the first row, or nil when there is none. Implemented
    /// as limit-1 rather than the `Accept: object+json` form so a
    /// missing row is nil instead of a 406.
    public func fetchOne<T: Decodable>(_ query: PostgrestQuery) async throws -> T? {
        let single = PostgrestQuery(
            table: query.table, columns: query.columns, filters: query.filters,
            orders: query.orders, limit: 1, offset: query.offset, countExact: false
        )
        let rows: [T] = try await fetch(single)
        return rows.first
    }

    /// One list page with the `limit + 1` probe (live.js:751-756,
    /// 888-900). Returns the page rows plus whether an older row
    /// exists (`hasMore` is true exactly when the probe row came back).
    public func fetchPage<T: Decodable>(_ query: PostgrestQuery, pageSize: Int) async throws -> (rows: [T], hasMore: Bool) {
        let probe = PostgrestQuery(
            table: query.table, columns: query.columns, filters: query.filters,
            orders: query.orders, limit: pageSize + 1, offset: query.offset, countExact: false
        )
        let rows: [T] = try await fetch(probe)
        if rows.count > pageSize {
            return (Array(rows.prefix(pageSize)), true)
        }
        return (rows, false)
    }

    /// Whole-history read in 1000-row pages, ordered so pages are
    /// stable (live.js:413-426 `fetchAllPages`). Used for CSV dedupe
    /// and for the charity/savings sums. A failed page throws — the
    /// caller must never present a partial sum as real numbers.
    public func fetchAllPages<T: Decodable>(_ query: PostgrestQuery) async throws -> [T] {
        var all: [T] = []
        var offset = 0
        let pageSize = 1000
        while true {
            let page = PostgrestQuery(
                table: query.table, columns: query.columns, filters: query.filters,
                orders: query.orders, limit: pageSize, offset: offset, countExact: false
            )
            let rows: [T] = try await fetch(page)
            all += rows
            if rows.count < pageSize { return all }
            offset += pageSize
        }
    }

    /// Insert rows and return the inserted rows (`Prefer:
    /// return=representation`). The member insert policy allows only
    /// `source` manual/csv with `state` provisional for transactions
    /// (`02-rls-hardening.sql`) — anything else fails server-side.
    public func insert<T: Encodable, R: Decodable>(
        table: String,
        rows: [T],
        returningColumns: String = "id"
    ) async throws -> [R] {
        let token = try await tokenProvider()
        var components = URLComponents(
            url: configuration.restBaseURL.appendingPathComponent(table),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "select", value: returningColumns)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        do {
            request.httpBody = try JSONEncoder().encode(rows)
        } catch {
            throw OnBudgetError.unknown("Could not encode the rows to save.")
        }
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode([R].self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the saved rows.")
        }
    }

    // MARK: - Typed reads (columns match live.js exactly)

    /// The signed-in user's own membership row (live.js:374-376).
    /// A read failure here is surfaced, never silently treated as
    /// "no household" (the Nov 1 stuck-screen bug).
    public func loadMembership(userId: UUID) async throws -> HouseholdMembership? {
        try await fetchOne(PostgrestQuery(
            table: "household_members",
            columns: "household_id,role",
            filters: [.equal("user_id", userId.uuidString)],
            limit: 1
        ))
    }

    /// The household row's name (live.js:458).
    public func householdName(householdId: UUID) async throws -> String? {
        // All non-optional Household fields: decoding a full
        // Household from a "name"-only select fails (missing keys
        // are decoding errors, not nils) — fixed Nov 9, 2026.
        let row: Household? = try await fetchOne(PostgrestQuery(
            table: "households",
            columns: "id,name,base_allowance_cents,fund_shortfall_cents,auto_sync_enabled,created_at",
            filters: [.householdRow(householdId)]
        ))
        return row?.name
    }

    /// Base allowance + whether it was ever explicitly set
    /// (live.js:566-583). `allowanceSetAt == nil` means the $375 is
    /// the schema default, not a choice.
    public func householdAllowance(householdId: UUID) async throws -> (baseAllowanceCents: Int?, allowanceExplicitlySet: Bool) {
        struct AllowanceRow: Decodable {
            let baseAllowanceCents: Int?
            let allowanceSetAt: String?
            enum CodingKeys: String, CodingKey {
                case baseAllowanceCents = "base_allowance_cents"
                case allowanceSetAt = "allowance_set_at"
            }
        }
        let row: AllowanceRow? = try await fetchOne(PostgrestQuery(
            table: "households",
            columns: "base_allowance_cents,allowance_set_at",
            filters: [.householdRow(householdId)]
        ))
        return (row?.baseAllowanceCents, row?.allowanceSetAt != nil)
    }

    /// Whether automatic sync is on, the server truth
    /// (`households.auto_sync_enabled`, live.js:1354).
    public func autoSyncEnabled(householdId: UUID) async throws -> Bool {
        struct Row: Decodable {
            let autoSyncEnabled: Bool?
            enum CodingKeys: String, CodingKey { case autoSyncEnabled = "auto_sync_enabled" }
        }
        let row: Row? = try await fetchOne(PostgrestQuery(
            table: "households",
            columns: "auto_sync_enabled",
            filters: [.householdRow(householdId)]
        ))
        return row?.autoSyncEnabled == true
    }

    /// The household's invite code (admin only in the UI; live.js:3261).
    public func inviteCode(householdId: UUID) async throws -> String? {
        struct Row: Decodable { let inviteCode: String?; enum CodingKeys: String, CodingKey { case inviteCode = "invite_code" } }
        let row: Row? = try await fetchOne(PostgrestQuery(
            table: "households",
            columns: "invite_code",
            filters: [.householdRow(householdId)]
        ))
        return row?.inviteCode
    }

    /// The household's fund shortfall (live.js:1611).
    public func fundShortfallCents(householdId: UUID) async throws -> Int {
        struct Row: Decodable { let fundShortfallCents: Int?; enum CodingKeys: String, CodingKey { case fundShortfallCents = "fund_shortfall_cents" } }
        let row: Row? = try await fetchOne(PostgrestQuery(
            table: "households",
            columns: "fund_shortfall_cents",
            filters: [.householdRow(householdId)]
        ))
        return row?.fundShortfallCents ?? 0
    }

    /// The household's names for a set of ids (admin-household picker,
    /// live.js:2948).
    public func householdNames(ids: [UUID]) async throws -> [Household] {
        guard !ids.isEmpty else { return [] }
        // All non-optional Household fields (same latent bug as
        // householdName: "id,name" cannot decode a full Household).
        return try await fetch(PostgrestQuery(
            table: "households",
            columns: "id,name,base_allowance_cents,fund_shortfall_cents,auto_sync_enabled,created_at",
            filters: [.in("id", ids.map(\.uuidString))]
        ))
    }

    /// The admin households the caller belongs to (Gmail picker,
    /// live.js:2940-2942).
    public func adminMemberships(userId: UUID) async throws -> [HouseholdMembership] {
        try await fetch(PostgrestQuery(
            table: "household_members",
            columns: "household_id",
            filters: [.equal("user_id", userId.uuidString), .equal("role", "admin")]
        ))
    }

    // MARK: Transactions

    /// One page of the Transactions list (live.js:751-756): `*`,
    /// household-scoped, `date >= 2026-11-01`, date desc, with the
    /// probe row. Callers filter client-side by state/kind/search —
    /// the server list is the whole household history page.
    public func transactionsPage(householdId: UUID, pageSize: Int = 100, offset: Int = 0) async throws -> (rows: [Transaction], hasMore: Bool) {
        try await fetchPage(
            PostgrestQuery(
                table: "transactions",
                columns: "*",
                filters: [.householdId(householdId), .onOrAfterNov1()],
                orders: [PostgrestOrder("date", ascending: false)],
                offset: offset
            ),
            pageSize: pageSize
        )
    }

    /// Whole-history dedupe rows for CSV import (live.js:2468-2470):
    /// merchant, amount, date, suffix, ordered by created_at asc.
    public func transactionsForCSVDedupe(householdId: UUID) async throws -> [TransactionDedupeRow] {
        try await fetchAllPages(PostgrestQuery(
            table: "transactions",
            columns: "merchant,amount_cents,date,card_suffix",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: true)]
        ))
    }

    /// The possible-duplicate check before a manual add (live.js:2744-2746):
    /// same merchant + amount + date, limit 1. Returns true when such
    /// a row exists — the caller asks the user before adding anyway.
    public func hasPossibleDuplicate(householdId: UUID, merchant: String, amountCents: Int, date: String) async throws -> Bool {
        struct Row: Decodable {
            let merchant: String
            let amountCents: Int
            let date: String
            enum CodingKeys: String, CodingKey {
                case merchant, date
                case amountCents = "amount_cents"
            }
        }
        let rows: [Row] = try await fetch(PostgrestQuery(
            table: "transactions",
            columns: "merchant,amount_cents,date",
            filters: [
                .householdId(householdId),
                .equal("merchant", merchant),
                .equal("amount_cents", String(amountCents)),
                .equal("date", date),
            ],
            limit: 1
        ))
        return !rows.isEmpty
    }

    /// The linked purchase's merchant / amount / date for the unlink
    /// sheet (live.js:3867).
    public func linkedPurchaseSummary(purchaseId: UUID) async throws -> (merchant: String, amountCents: Int, date: String)? {
        struct Row: Decodable {
            let merchant: String
            let amountCents: Int
            let date: String
            enum CodingKeys: String, CodingKey {
                case merchant, date
                case amountCents = "amount_cents"
            }
        }
        let row: Row? = try await fetchOne(PostgrestQuery(
            table: "transactions",
            columns: "merchant,amount_cents,date",
            filters: [.equal("id", purchaseId.uuidString)]
        ))
        guard let row else { return nil }
        return (row.merchant, row.amountCents, row.date)
    }

    /// Candidate purchases for linking a refund by hand (live.js:3890-3901):
    /// same card, charges in the 90 days before the refund, not
    /// excluded/reversed, newest first, max 20. The caller adds the
    /// merchant-stem `ilike` when a stem exists, and falls back to the
    /// unfiltered list when no name matches.
    public func refundLinkCandidates(
        householdId: UUID,
        cardSuffix: String,
        refundDate: String,
        sinceDate: String,
        merchantStem: String?
    ) async throws -> [Transaction] {
        var filters: [PostgrestFilter] = [
            .householdId(householdId),
            .in("kind", ["charge", "fund_charge"]),
            .equal("card_suffix", cardSuffix),
            .lessThanOrEqual("date", refundDate),
            .greaterThanOrEqual("date", sinceDate),
            .notEqual("excluded", "true"),
            .notEqual("state", "excluded"),
            .notEqual("state", "reversed"),
        ]
        if let stem = merchantStem, !stem.isEmpty {
            filters.append(.ilike("merchant", "%\(stem)%"))
        }
        return try await fetch(PostgrestQuery(
            table: "transactions",
            // All non-optional Transaction fields: the previous
            // "id,merchant,amount_cents,date" select could not decode
            // full Transaction rows (fixed Nov 9, 2026; the
            // Transactions view model no longer works around it).
            columns: "id,household_id,date,merchant,amount_cents,card_suffix,source,state,kind,fund_allocation_cents,excluded,exclude_reason,late,dedupe_hash,created_at",
            filters: filters,
            orders: [PostgrestOrder("date", ascending: false)],
            limit: 20
        ))
    }

    /// Refund rows for the Refund Links review (live.js:2053-2055):
    /// refunds on/after Nov 1. Selects `*`: `Transaction` has
    /// non-optional fields (state, kind, excluded, dedupe_hash, …)
    /// that a narrow column list cannot decode — see the funds
    /// workstream note, Nov 9, 2026. The caller pairs them with
    /// purchases and filters client-side.
    public func refundRows(householdId: UUID) async throws -> [Transaction] {
        try await fetch(PostgrestQuery(
            table: "transactions",
            columns: "*",
            filters: [.householdId(householdId), .equal("kind", "refund"), .onOrAfterNov1()],
            orders: [PostgrestOrder("date", ascending: false)]
        ))
    }

    /// Purchase rows for the Refund Links review (live.js:2077-2079).
    /// Selects `*` for the same decode reason as `refundRows` above.
    public func purchaseRowsForRefundReview(householdId: UUID) async throws -> [Transaction] {
        try await fetch(PostgrestQuery(
            table: "transactions",
            columns: "*",
            filters: [.householdId(householdId), .in("kind", ["charge", "fund_charge"]), .onOrAfterNov1()],
            orders: [PostgrestOrder("date", ascending: false)]
        ))
    }

    /// Linked-refund amounts for the review (live.js:2087-2088):
    /// original_purchase_id + amount for linked refunds.
    public func linkedRefundAmounts(householdId: UUID) async throws -> [(purchaseId: UUID, amountCents: Int)] {
        struct Row: Decodable {
            let originalPurchaseId: UUID?
            let amountCents: Int
            enum CodingKeys: String, CodingKey {
                case originalPurchaseId = "original_purchase_id"
                case amountCents = "amount_cents"
            }
        }
        let rows: [Row] = try await fetch(PostgrestQuery(
            table: "transactions",
            columns: "original_purchase_id,amount_cents",
            filters: [.householdId(householdId), .equal("kind", "refund")]
        ))
        return rows.compactMap { row in
            guard let purchaseId = row.originalPurchaseId else { return nil }
            return (purchaseId, row.amountCents)
        }
    }

    // MARK: Fund requests & ledger

    /// Fund requests, newest first, max 50 (live.js:1206-1208).
    public func fundRequests(householdId: UUID) async throws -> [FundRequest] {
        try await fetch(PostgrestQuery(
            table: "fund_requests",
            columns: "*",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: false)],
            limit: 50
        ))
    }

    /// Create a fund request (live.js:3845-3848, 4703-4706).
    /// Members may create them; `requested_by` must be the caller.
    public func createFundRequest(
        householdId: UUID,
        requestedBy: UUID,
        amountCents: Int,
        note: String,
        transactionId: UUID?
    ) async throws -> UUID {
        struct Insert: Encodable {
            let householdId: UUID
            let requestedBy: UUID
            let amountCents: Int
            let note: String
            let status = "pending"
            let transactionId: UUID?
            enum CodingKeys: String, CodingKey {
                case householdId = "household_id"
                case requestedBy = "requested_by"
                case amountCents = "amount_cents"
                case note, status
                case transactionId = "transaction_id"
            }
        }
        struct InsertedId: Decodable { let id: UUID }
        let inserted: [InsertedId] = try await insert(
            table: "fund_requests",
            rows: [Insert(
                householdId: householdId, requestedBy: requestedBy,
                amountCents: amountCents, note: note, transactionId: transactionId
            )],
            returningColumns: "id"
        )
        guard let id = inserted.first?.id else {
            throw OnBudgetError.decodingError("Could not read the saved fund request.")
        }
        return id
    }

    /// Fund ledger kinds + amounts (live.js:1609). The select must
    /// include every non-optional `FundLedgerEntry` field
    /// (household_id, note) — a narrower select fails decoding
    /// (found by the Auth+Home builder, Nov 9, 2026).
    public func fundLedger(householdId: UUID) async throws -> [FundLedgerEntry] {
        try await fetch(PostgrestQuery(
            table: "fund_ledger",
            columns: "id,household_id,kind,amount_cents,week_start,request_id,note,created_by,created_at",
            filters: [.householdId(householdId)]
        ))
    }

    /// Surplus releases (live.js:1610, 2173-2175). Same rule as
    /// fundLedger: all non-optional `SurplusRelease` fields are
    /// selected (household_id, week_start, release_date).
    public func surplusReleases(householdId: UUID) async throws -> [SurplusRelease] {
        try await fetch(PostgrestQuery(
            table: "surplus_releases",
            columns: "id,household_id,week_start,surplus_cents,release_date,status,released_cents,created_at,closed_at",
            filters: [.householdId(householdId)]
        ))
    }

    /// Fund top-ups for the history view (live.js:1668-1670). The
    /// select must include every non-optional `FundTopup` field
    /// (household_id, client_key) — a narrower select fails decoding
    /// (same class as the five reads fixed Nov 9, 2026).
    public func fundTopups(householdId: UUID) async throws -> [FundTopup] {
        try await fetch(PostgrestQuery(
            table: "fund_topups",
            columns: "id,household_id,client_key,amount_cents,shortfall_covered_cents,fund_added_cents,shortfall_after_cents,note,created_by,created_at",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: false)]
        ))
    }

    // MARK: Savings (read-only)

    /// Whole-history savings ledger, newest first (live.js:1282-1285).
    public func savingsLedger(householdId: UUID) async throws -> [SavingsLedgerEntry] {
        try await fetchAllPages(PostgrestQuery(
            table: "savings_ledger",
            columns: "*",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: false)]
        ))
    }

    // MARK: Bank & email connections

    /// Plaid items via the public view (live.js:1315-1317).
    /// Selects every non-optional `PlaidItemPublic` field
    /// (household_id was missing and broke decoding — found by the
    /// Auth+Home builder, Nov 9, 2026).
    public func plaidItems(householdId: UUID) async throws -> [PlaidItemPublic] {
        try await fetch(PostgrestQuery(
            table: "plaid_items_public",
            columns: "id,household_id,plaid_item_id,institution_name,institution_id,status,last_sync_at,created_at",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: false)]
        ))
    }

    /// Active Plaid items only (duplicate-warning check, live.js:2798-2799).
    /// Same rule as plaidItems: every non-optional `PlaidItemPublic`
    /// field is selected (id, household_id, status, created_at) — the
    /// previous two-column select failed decoding (same class as the
    /// five reads fixed Nov 9, 2026).
    public func activePlaidItems(householdId: UUID) async throws -> [PlaidItemPublic] {
        try await fetch(PostgrestQuery(
            table: "plaid_items_public",
            columns: "id,household_id,plaid_item_id,institution_name,institution_id,status,last_sync_at,created_at",
            filters: [.householdId(householdId), .equal("status", "active")]
        ))
    }

    /// Plaid accounts for a set of items (live.js:1322-1324). The
    /// select must include every non-optional `PlaidAccount` field
    /// (id, household_id) — the previous select failed decoding
    /// (same class as the five reads fixed Nov 9, 2026).
    public func plaidAccounts(itemIds: [String]) async throws -> [PlaidAccount] {
        guard !itemIds.isEmpty else { return [] }
        return try await fetch(PostgrestQuery(
            table: "plaid_accounts",
            columns: "id,household_id,plaid_item_id,plaid_account_id,name,mask,type,subtype,disconnected_at,created_at,updated_at",
            filters: [.in("plaid_item_id", itemIds)]
        ))
    }

    /// Account nicknames (live.js:1332-1333). A missing table/grant
    /// fails soft in the web app (nicknames just don't show); callers
    /// that want that behaviour should catch and continue.
    public func accountNicknames(householdId: UUID) async throws -> [AccountNickname] {
        try await fetch(PostgrestQuery(
            table: "account_nicknames",
            columns: "plaid_item_id,plaid_account_id,card_suffix,nickname",
            filters: [.householdId(householdId)]
        ))
    }

    /// Institution names for the mask → institution map
    /// (live.js:146-151).
    public func plaidItemInstitutions(householdId: UUID) async throws -> [(itemId: String, institutionName: String?)] {
        struct Row: Decodable {
            let plaidItemId: String
            let institutionName: String?
            enum CodingKeys: String, CodingKey {
                case plaidItemId = "plaid_item_id"
                case institutionName = "institution_name"
            }
        }
        let rows: [Row] = try await fetch(PostgrestQuery(
            table: "plaid_items_public",
            columns: "plaid_item_id,institution_name",
            filters: [.householdId(householdId)]
        ))
        return rows.map { ($0.plaidItemId, $0.institutionName) }
    }

    /// Account masks for the same map (live.js:149-150).
    public func plaidAccountMasks(itemIds: [String]) async throws -> [(itemId: String, mask: String?)] {
        struct Row: Decodable {
            let plaidItemId: String
            let mask: String?
            enum CodingKeys: String, CodingKey {
                case plaidItemId = "plaid_item_id"
                case mask
            }
        }
        guard !itemIds.isEmpty else { return [] }
        let rows: [Row] = try await fetch(PostgrestQuery(
            table: "plaid_accounts",
            columns: "plaid_item_id,mask",
            filters: [.in("plaid_item_id", itemIds)]
        ))
        return rows.map { ($0.plaidItemId, $0.mask) }
    }

    /// Email connections via the public view (live.js:1551-1552).
    /// The select must include `household_id`: the model declares it
    /// non-optional, and a missing key is a decoding error, not a
    /// nil — the list failed to load entirely ("Could not load email
    /// connections.", phone feedback, Nov 11, 2026) even though the
    /// view returns the column and the manual Check Email flow works.
    public func emailConnections(householdId: UUID) async throws -> [EmailConnectionPublic] {
        try await fetch(PostgrestQuery(
            table: "email_connections_public",
            columns: "id,household_id,provider,email_address,status,last_poll_at,last_error,created_at,connected_at",
            filters: [.householdId(householdId)]
        ))
    }

    /// Unprocessed webhook events for auto-sync (live.js:3007-3013).
    /// Returns true when at least one verified event is waiting.
    public func hasPendingWebhookEvent(itemIds: [String]) async throws -> Bool {
        guard !itemIds.isEmpty else { return false }
        let rows: [WebhookEvent] = try await fetch(PostgrestQuery(
            table: "webhook_events",
            // All non-optional WebhookEvent fields: an "id"-only
            // select cannot decode (missing webhook_code/processed).
            columns: "id,webhook_code,processed",
            filters: [.in("plaid_item_id", itemIds), .equal("processed", "false")],
            limit: 1
        ))
        return !rows.isEmpty
    }

    // MARK: Charity

    /// Active charity income rows, whole history (live.js:1700-1702).
    public func activeCharityIncome(householdId: UUID) async throws -> [CharityIncome] {
        try await fetchAllPages(PostgrestQuery(
            table: "charity_income",
            // All non-optional CharityIncome fields: the previous
            // "amount_cents,rate_bp" select failed decoding (found
            // by the Auth+Home builder, Nov 9, 2026).
            columns: "id,household_id,source_label,amount_cents,income_date,rate_bp,status,replaces_id,note,created_by,created_at",
            filters: [.householdId(householdId), .equal("status", "active")],
            orders: [PostgrestOrder("created_at", ascending: true)]
        ))
    }

    /// All charity income rows for the history view, newest first,
    /// max 50 (live.js:1764-1766). Same rule as activeCharityIncome:
    /// every non-optional `CharityIncome` field is selected
    /// (household_id) — the previous select failed decoding (same
    /// class as the five reads fixed Nov 9, 2026).
    public func charityIncomeHistory(householdId: UUID) async throws -> [CharityIncome] {
        try await fetch(PostgrestQuery(
            table: "charity_income",
            columns: "id,household_id,source_label,amount_cents,income_date,rate_bp,status,replaces_id,note,created_by,created_at",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("income_date", ascending: false)],
            limit: 50
        ))
    }

    /// The household's charity default rate (live.js:1703-1704).
    /// Selects household_id too: `CharitySettings.householdId` is
    /// non-optional, so the previous select failed decoding (found
    /// by the Auth+Home builder, Nov 9, 2026).
    public func charitySettings(householdId: UUID) async throws -> CharitySettings? {
        try await fetchOne(PostgrestQuery(
            table: "charity_settings",
            columns: "household_id,default_rate_bp,updated_at",
            filters: [.householdId(householdId)]
        ))
    }

    /// Verified charity gift amounts, whole history (live.js:1705-1707).
    /// The caller sums these for Given; pending gifts are read via
    /// `transactionsPage` and filtered client-side.
    public func verifiedCharityGiftAmounts(householdId: UUID) async throws -> [Int] {
        struct Row: Decodable { let amountCents: Int; enum CodingKeys: String, CodingKey { case amountCents = "amount_cents" } }
        let rows: [Row] = try await fetchAllPages(PostgrestQuery(
            table: "transactions",
            columns: "amount_cents",
            filters: [
                .householdId(householdId),
                .equal("kind", "charity"),
                .equal("state", "verified"),
                .equal("excluded", "false"),
                .onOrAfterNov1(),
            ],
            orders: [PostgrestOrder("created_at", ascending: true)]
        ))
        return rows.map(\.amountCents)
    }

    // MARK: Duplicates, restoration, history

    /// Pending duplicate candidates (live.js:1877-1878).
    public func pendingDuplicateCandidates(householdId: UUID) async throws -> [DuplicateCandidate] {
        try await fetch(PostgrestQuery(
            table: "duplicate_candidates",
            columns: "id,household_id,canonical_transaction_id,duplicate_transaction_id,reason,merchant_a,merchant_b,status,created_at",
            filters: [.householdId(householdId), .equal("status", "pending")]
        ))
    }

    /// Resolved duplicate candidates (live.js:2001-2002).
    public func resolvedDuplicateCandidates(householdId: UUID) async throws -> [DuplicateCandidate] {
        try await fetch(PostgrestQuery(
            table: "duplicate_candidates",
            columns: "id,household_id,canonical_transaction_id,duplicate_transaction_id,reason,merchant_a,merchant_b,status,created_at,resolved_at",
            filters: [.householdId(householdId), .notEqual("status", "pending")]
        ))
    }

    /// Merchant aliases (live.js:2068).
    public func merchantAliases(householdId: UUID) async throws -> [MerchantAlias] {
        try await fetch(PostgrestQuery(
            table: "merchant_aliases",
            columns: "household_id,name_a,name_b",
            filters: [.householdId(householdId)]
        ))
    }

    /// Refund-link dismissals (live.js:2074).
    public func refundLinkDismissals(householdId: UUID) async throws -> [RefundLinkDismissal] {
        try await fetch(PostgrestQuery(
            table: "refund_link_dismissals",
            columns: "household_id,refund_id,purchase_id",
            filters: [.householdId(householdId)]
        ))
    }

    /// Restoration entries, newest first, max 100 (live.js:1817-1819).
    public func restorationEntries(householdId: UUID) async throws -> [RestorationEntry] {
        try await fetch(PostgrestQuery(
            table: "restoration_entries",
            columns: "household_id,week_start,refund_transaction_id,restored_surplus_cents,debt_reduction_cents,fund_credit_cents,created_at",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: false)],
            limit: 100
        ))
    }

    /// Held refunds, newest first, max 100 (live.js:1820-1822).
    public func heldRefunds(householdId: UUID) async throws -> [HeldRefund] {
        try await fetch(PostgrestQuery(
            table: "held_refunds",
            columns: "id,household_id,refund_transaction_id,held_cents,status,resolution_note,created_at",
            filters: [.householdId(householdId)],
            orders: [PostgrestOrder("created_at", ascending: false)],
            limit: 100
        ))
    }

    /// Week closes for Past Weeks (live.js:2170-2172).
    public func weekCloses(householdId: UUID) async throws -> [WeekClose] {
        try await fetch(PostgrestQuery(
            table: "week_closes",
            // All non-optional WeekClose fields: the previous select
            // omitted household_id and could not decode.
            columns: "household_id,week_start,surplus_cents,outgoing_debt_cents",
            filters: [.householdId(householdId)]
        ))
    }

    /// Surplus releases for Past Weeks (live.js:2173-2175).
    public func surplusReleasesForHistory(householdId: UUID) async throws -> [SurplusRelease] {
        try await fetch(PostgrestQuery(
            table: "surplus_releases",
            // All non-optional SurplusRelease fields: the previous
            // select omitted household_id and release_date and could
            // not decode.
            columns: "household_id,week_start,surplus_cents,release_date,status,released_cents",
            filters: [.householdId(householdId)]
        ))
    }

    /// Audit log page (live.js:2241-2243). With a date filter the
    /// web app fetches 1000; without one it pages `auditLimit` (50)
    /// with Load More. Returns rows + exact total when countable.
    public func auditLogPage(
        householdId: UUID,
        limit: Int,
        from fromDate: String? = nil,
        to toDate: String? = nil
    ) async throws -> (rows: [AuditLogEntry], total: Int?) {
        var filters: [PostgrestFilter] = [.householdId(householdId)]
        if let fromDate { filters.append(.greaterThanOrEqual("created_at", fromDate)) }
        if let toDate { filters.append(.lessThanOrEqual("created_at", toDate)) }
        return try await fetchWithCount(PostgrestQuery(
            table: "audit_log",
            columns: "*",
            filters: filters,
            orders: [PostgrestOrder("created_at", ascending: false)],
            limit: limit,
            countExact: true
        ))
    }

    /// Append an audit row (live.js:396-401). A blocked insert is
    /// logged, never fatal to the action it describes — callers
    /// should catch and continue.
    public func appendAudit(_ entry: AuditLogInsert) async throws {
        struct InsertedId: Decodable { let id: UUID }
        let _: [InsertedId] = try await insert(table: "audit_log", rows: [entry], returningColumns: "id")
    }

    // MARK: Writes (member inserts)

    /// Insert manual purchases (live.js:2750-2756) and CSV rows
    /// (live.js:2512-2518). Returns the inserted ids.
    public func insertTransactions(_ rows: [ManualTransactionInsert]) async throws -> [UUID] {
        struct InsertedId: Decodable { let id: UUID }
        let inserted: [InsertedId] = try await insert(table: "transactions", rows: rows, returningColumns: "id")
        return inserted.map(\.id)
    }

    public func insertCSVTransactions(_ rows: [CSVTransactionInsert]) async throws -> [UUID] {
        struct InsertedId: Decodable { let id: UUID }
        let inserted: [InsertedId] = try await insert(table: "transactions", rows: rows, returningColumns: "id")
        return inserted.map(\.id)
    }
}
