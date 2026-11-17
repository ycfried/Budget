import Foundation

/// Customizable fund icons (build 41 — owner, Nov 16, 2026) and the
/// fund-reorder move (build 41 — long-press enters reorder mode,
/// drag moves). Both are pure logic, so they live in the kit where
/// the Linux test suite can pin them; the app owns the rendering
/// (the UIImage resolvability check) and the gestures.

/// The icon picker options. Twelve long-established SF Symbols (all
/// present since iOS 13/14, so they resolve on iOS 18.5 — see the
/// Nov 16 handshake lesson: only offer symbols proven to resolve;
/// a simulator smoke test pins every entry). The four theme
/// defaults are first, so a fund can always pick its own default
/// back.
public enum FundIconOptions {
    public static let all: [String] = [
        "dollarsign.circle.fill",
        "gift.fill",
        "banknote.fill",
        "minus.circle.fill",
        "cart.fill",
        "bag.fill",
        "basket.fill",
        "creditcard.fill",
        "house.fill",
        "car.fill",
        "heart.fill",
        "star.fill",
    ]
}

/// The icon-resolution rule: the household's custom SF Symbol for a
/// fund when one is stored AND it resolves, else the theme default.
/// `resolves` is injected because the check is `UIImage(systemName:)`
/// in the app — the kit tests run on Linux, where UIKit does not
/// exist — so the app passes `{ UIImage(systemName: $0) != nil }`
/// and the tests pass a stub. A blank stored value falls back to
/// the default, so a reset is just a missing/empty key; a stored
/// value that fails to resolve (e.g. a symbol removed in a later
/// iOS) falls back silently instead of rendering a blank circle.
public enum FundIconResolver {
    public static func resolved(
        custom: String?,
        default defaultIcon: String,
        resolves: (String) -> Bool
    ) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && resolves(trimmed) { return trimmed }
        return defaultIcon
    }
}

/// The fund-reorder move (build 41 — drag a card over another to
/// move it). The dragged fund takes the TARGET's slot: dragging
/// the top fund over the third lands it third, not last, and not
/// one slot early. `Array.move(fromOffsets:toOffset:)` counts the
/// destination in the array WITH the dragged element still in it,
/// so moving down needs `to + 1` (without it, from 0 to 2 lands
/// at 1 — the classic off-by-one, caught by run 3's two failing
/// tests); moving up takes `to` as-is. Out-of-range or same-spot
/// moves return the order unchanged.
public enum FundOrderMove {
    public static func moved<T>(_ order: [T], from: Int, to: Int) -> [T] {
        guard order.indices.contains(from), order.indices.contains(to), from != to else { return order }
        var copy = order
        copy.move(fromOffsets: IndexSet(integer: from), toOffset: from < to ? to + 1 : to)
        return copy
    }
}
