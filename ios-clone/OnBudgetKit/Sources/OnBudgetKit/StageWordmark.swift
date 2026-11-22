#if canImport(SwiftUI)
import SwiftUI
#endif
import Foundation

/// The STAGE wordmark text (owner, Nov 18, 2026 — build 47:
/// STAG → STAGE). The S logo IS the S of STAGE, so this renders
/// only "T · A · G · E" — the whole lockup in one uniform blue
/// (#0288dd, owner Nov 19, 2026): letters AND the centered-dot
/// separators, so it reads as one word S · T · A · G · E. The old
/// spec colours (dark green letters #20392f, gold dots #b08d57)
/// are retired. At the font the caller passes — the same size and
/// weight as the logo beside it. Call sites compose it with their
/// own S-logo image (OnBudgetKit has no asset access), on ONE
/// horizontal line with the logo — never stacked above/below it
/// (owner, Nov 20, 2026 — build 50: the loading screen read
/// "S" then "TAGE"), never with the full word "STAGE" (no second
/// S). Build 54 (owner, Nov 21, 2026): the letters are bolder
/// (black weight) and slightly larger (+2pt at every call site) —
/// they were a drop too thin and small next to the S logo.
///
/// Call sites: AuthViews AuthBrandHeader, SharedViews
/// LoadingView, OnBudgetWidget wordmark().
#if canImport(SwiftUI)
public struct StageWordmarkText: View {
    public let font: Font

    public init(font: Font) {
        self.font = font
    }

    public var body: some View {
        (
            Text("T").foregroundStyle(DesignTokens.stageBlue)
            + Text(" · ").foregroundStyle(DesignTokens.stageBlue)
            + Text("A").foregroundStyle(DesignTokens.stageBlue)
            + Text(" · ").foregroundStyle(DesignTokens.stageBlue)
            + Text("G").foregroundStyle(DesignTokens.stageBlue)
            + Text(" · ").foregroundStyle(DesignTokens.stageBlue)
            + Text("E").foregroundStyle(DesignTokens.stageBlue)
        )
        .font(font)
    }
}
#endif
