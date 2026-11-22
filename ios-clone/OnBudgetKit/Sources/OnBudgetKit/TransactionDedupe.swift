// TransactionDedupe.swift — build 58 (owner, Nov 22, 2026).
//
// Two rules, pinned here so the app and the server cannot drift
// apart again:
//
// 1. PENDING COUNTS TOWARD TOTALS (owner, Nov 22 ~12:20: "pending
//    transactions should count towards the totals.. people want the
//    total to be as accurate as possible to the minute.. most
//    pending transactions post after a day, two three.. people need
//    to know this minute what to expect.. if a pending transaction
//    ever disappears then it should be auto reversed.. I notice
//    charity doesn't count something pending").
//    The server already counts provisional charges in week math
//    (compute-week chargeContribution — provisional charges count;
//    only provisional REFUNDS are excluded, and only until they
//    post). The charity side was the gap: the ingest hook
//    (accrueCharityForIncomeTx) and the charity trigger
//    (reclassify-income-accrual.sql) were verified-only, so a
//    pending income row accrued nothing. Both are widened in build
//    58 to accrue for provisional income too, and the existing
//    reverse branches (exclude / reclassify-away) deduct it when
//    the pending income disappears — the auto-reverse.
//    `countsTowardSpending` and `accruesCharity` below are the
//    client-side mirror of those server rules, so the list and the
//    feed can be reasoned about (and tested) without a live DB.
//
// 2. SAME-SOURCE DUPLICATES NEVER SHOW TWICE (owner, Nov 22 ~12:21:
//    "The code/system should automatically pick this up and avoid
//    it from showing up to begin with"). Two Amazon pairs in the
//    live household were the same alert ingested twice — both rows
//    source amex_alert, identical dedupe_hash, no bank row. The
//    ingestion guard (canonical.ts findExistingSameHash) stops new
//    ones; `byHash` is the display safety net: even if two rows
//    with one dedupe_hash exist in the database, the list shows
//    one. The bank+email merge rule is untouched (same date +
//    amount + similar merchant, one EMAIL + one BANK = one
//    transaction, bank row kept) and so is the TOIREMORG
//    never-merge rule (different merchants, different hashes —
//    never one group).

import Foundation

public extension Transaction {
    /// Whether this row counts toward the week's spending total.
    /// Mirrors compute-week (engine.mjs isExcludedFromMath /
    /// chargeContribution): a charge / fund charge that is not
    /// excluded and not reversed counts — INCLUDING provisional
    /// (pending) charges. A provisional REFUND counts nothing
    /// (it restores nothing until it posts), and neither do
    /// payments, cashback, transfers, income, or charity rows.
    var countsTowardSpending: Bool {
        guard !excluded, !isInTrash, state != .reversed else { return false }
        return kind == .charge || kind == .fundCharge
    }

    /// Whether this row accrues charity at the household rate.
    /// Mirrors the charity trigger (reclassify-income-accrual.sql
    /// v4) and the ingest hook (accrueCharityForIncomeTx): kind
    /// income, not excluded, state verified OR provisional (v4 —
    /// pending income accrues immediately), dated on/after
    /// 2026-11-01, with a nonzero amount. A row that stops
    /// matching (excluded, reclassified away) has its accrual
    /// reversed by the trigger — the auto-reverse.
    var accruesCharity: Bool {
        guard kind == .income else { return false }
        guard !excluded, !isInTrash else { return false }
        guard state == .verified || state == .provisional else { return false }
        guard date >= "2026-11-01" else { return false }
        return amountCents != 0
    }
}

/// Display safety net for same-dedupe_hash duplicates: collapse
/// rows that share one dedupe_hash to a single row, so two rows for
/// one purchase never show as two rows in the list — even if both
/// still exist in the database (the server cleanup removes them;
/// this keeps the list correct meanwhile). The kept row is the
/// best one: a verified row over a provisional one, a bank (Plaid)
/// row over any other source, then the earliest created. Rows
/// without a hash (empty string) cannot be grouped, so they are
/// always kept. Input order is preserved — the kept row stays
/// where the first row of its group was.
public enum TransactionDedupe {
    public static func byHash(_ rows: [Transaction]) -> [Transaction] {
        var bestIndexByHash: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let hash = row.dedupeHash
            guard !hash.isEmpty else { continue }
            if let bestIndex = bestIndexByHash[hash] {
                if prefers(row, over: rows[bestIndex]) {
                    bestIndexByHash[hash] = index
                }
            } else {
                bestIndexByHash[hash] = index
            }
        }
        let keptIndices = Set(bestIndexByHash.values)
        return rows.enumerated().filter { index, row in
            row.dedupeHash.isEmpty || keptIndices.contains(index)
        }.map { $0.element }
    }

    /// True when `candidate` should replace `current` as the kept
    /// row for one dedupe_hash. Verified beats provisional;
    /// a bank row beats any other source; otherwise the earliest
    /// created wins (the original row, not the duplicate).
    static func prefers(_ candidate: Transaction, over current: Transaction) -> Bool {
        let candidateState = stateRank(candidate.state)
        let currentState = stateRank(current.state)
        if candidateState != currentState { return candidateState < currentState }
        let candidateSource = sourceRank(candidate.source)
        let currentSource = sourceRank(current.source)
        if candidateSource != currentSource { return candidateSource < currentSource }
        if candidate.createdAt != current.createdAt { return candidate.createdAt < current.createdAt }
        return candidate.id.uuidString < current.id.uuidString
    }

    private static func stateRank(_ state: TransactionState) -> Int {
        switch state {
        case .verified: return 0
        case .provisional: return 1
        case .excluded: return 2
        case .reversed: return 3
        }
    }

    private static func sourceRank(_ source: TransactionSource) -> Int {
        source == .plaid ? 0 : 1
    }
}
