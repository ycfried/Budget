#if canImport(SwiftUI)
import SwiftUI
#endif
import Foundation

/// The STAGE wordmark text (owner, Nov 18, 2026 — build 47:
/// STAG → STAGE). The S logo IS the S of STAGE, so this renders
/// only "T · A · G · E": the letters in brand dark green
/// (#20392f), the centered-dot separators in brand gold
/// (#b08d57), at the font the caller passes — the same size and
/// weight as the logo beside it. Call sites compose it with their
/// own S-logo image (OnBudgetKit has no asset access), never with
/// the full word "STAGE" (no second S).
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
            Text("T").foregroundStyle(DesignTokens.brandGreen)
            + Text(" · ").foregroundStyle(DesignTokens.brandGold)
            + Text("A").foregroundStyle(DesignTokens.brandGreen)
            + Text(" · ").foregroundStyle(DesignTokens.brandGold)
            + Text("G").foregroundStyle(DesignTokens.brandGreen)
            + Text(" · ").foregroundStyle(DesignTokens.brandGold)
            + Text("E").foregroundStyle(DesignTokens.brandGreen)
        )
        .font(font)
    }
}
#endif
