import Foundation

/// The walkthrough's "seen" flag (build 50, Nov 20, 2026 —
/// tutorial one-time fix).
///
/// The tour must show ONCE per household per device, then never
/// auto-show again (re-playable from Settings, "Take the Tour").
/// The build-48 key folded in the session's user UUID
/// ("tour.seen.<user>-<household>"), but that half can be nil or
/// change while the session store is swapped — the flag written
/// at Skip/Done time was then read back under a different key, so
/// the tour showed on EVERY app open (owner report, Nov 20,
/// 2026).
///
/// The stable key is per household, per device — it does NOT
/// depend on the session at all. The household id is set once at
/// boot and is the same on every launch; and UserDefaults is per
/// device, so a new family member on their own device still gets
/// the tour once, and a new household gets it once too (the
/// build-48 scoping, preserved). The legacy composite key is
/// still honoured on read and still written on mark, so a flag
/// already stored under it is not lost.
public enum TourSeen {
    /// The stable key: per household, per device.
    public static func key(householdId: UUID?) -> String {
        "tour.seen.household.\(householdId?.uuidString ?? "no-household")"
    }

    /// The legacy key (build 48): per user per household, folding
    /// in the session user UUID. Read- and write-compatible only;
    /// never the sole key any more.
    public static func legacyKey(userId: UUID?, householdId: UUID?) -> String {
        "tour.seen.\(userId?.uuidString ?? "signed-out")-\(householdId?.uuidString ?? "no-household")"
    }

    /// Whether the tour has been seen for this household on this
    /// device — true when the stable key is set, or when the
    /// legacy composite key is set (a flag written before build
    /// 50). The `userId` is the current session's user id, if
    /// any; nil is fine — the stable key is the one that matters.
    public static func hasSeen(
        householdId: UUID?,
        userId: UUID? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(householdId: householdId))
            || defaults.bool(forKey: legacyKey(userId: userId, householdId: householdId))
    }

    /// Mark the tour seen for this household on this device, under
    /// both the stable key and the legacy key.
    public static func markSeen(
        householdId: UUID?,
        userId: UUID? = nil,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: key(householdId: householdId))
        defaults.set(true, forKey: legacyKey(userId: userId, householdId: householdId))
    }
}
