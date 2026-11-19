import XCTest
@testable import OnBudgetKit

/// Build 41 — customizable fund icons and the drag-to-reorder move.
final class FundIconsAndReorderTests: XCTestCase {
    func testIconOptionsAreTwelveWithDefaultsFirst() {
        XCTAssertEqual(FundIconOptions.all.count, 12)
        XCTAssertEqual(
            Array(FundIconOptions.all.prefix(4)),
            ["dollarsign.circle.fill", "gift.fill", "banknote.fill", "minus.circle.fill"]
        )
        // No duplicates in the picker.
        XCTAssertEqual(Set(FundIconOptions.all).count, FundIconOptions.all.count)
    }

    func testIconResolverCustomWinsWhenItResolves() {
        XCTAssertEqual(
            FundIconResolver.resolved(custom: "cart.fill", default: "dollarsign.circle.fill") { _ in true },
            "cart.fill"
        )
    }

    func testIconResolverFallsBackOnBlankOrMissingCustom() {
        XCTAssertEqual(
            FundIconResolver.resolved(custom: "", default: "dollarsign.circle.fill") { _ in true },
            "dollarsign.circle.fill"
        )
        XCTAssertEqual(
            FundIconResolver.resolved(custom: "   ", default: "dollarsign.circle.fill") { _ in true },
            "dollarsign.circle.fill"
        )
        XCTAssertEqual(
            FundIconResolver.resolved(custom: nil, default: "dollarsign.circle.fill") { _ in true },
            "dollarsign.circle.fill"
        )
    }

    func testIconResolverFallsBackWhenCustomDoesNotResolve() {
        // A stored symbol removed in a later iOS must never render
        // a blank circle — the theme default wins.
        XCTAssertEqual(
            FundIconResolver.resolved(custom: "not.a.symbol", default: "gift.fill") { _ in false },
            "gift.fill"
        )
    }

    func testReorderMoveDownTakesTargetSlot() {
        // Dragging the top fund over the third lands it third, not
        // last — the +1 overshoot is the classic bug here.
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 0, to: 2), ["B", "C", "A", "D"])
    }

    func testReorderMoveUpTakesTargetSlot() {
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 3, to: 0), ["D", "A", "B", "C"])
    }

    func testReorderMoveAdjacentBothDirections() {
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 1, to: 2), ["A", "C", "B", "D"])
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 2, to: 1), ["A", "C", "B", "D"])
    }

    func testReorderMoveSameSpotAndOutOfRangeAreNoOps() {
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 1, to: 1), ["A", "B", "C", "D"])
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 0, to: 9), ["A", "B", "C", "D"])
        XCTAssertEqual(FundOrderMove.moved(["A", "B", "C", "D"], from: 9, to: 0), ["A", "B", "C", "D"])
    }

    // MARK: Fund prominence (build 46 — the simpler Home)

    func testProminenceStoredValueWins() {
        XCTAssertEqual(FundProminence.resolved("hero", default: .quiet), .hero)
        XCTAssertEqual(FundProminence.resolved("card", default: .hero), .card)
        XCTAssertEqual(FundProminence.resolved("quiet", default: .card), .quiet)
    }

    func testProminenceMissingBlankOrUnknownFallsBackToDefault() {
        XCTAssertEqual(FundProminence.resolved(nil, default: .hero), .hero)
        XCTAssertEqual(FundProminence.resolved("", default: .card), .card)
        XCTAssertEqual(FundProminence.resolved("   ", default: .quiet), .quiet)
        XCTAssertEqual(FundProminence.resolved("big", default: .card), .card)
        XCTAssertEqual(FundProminence.resolved("HERO", default: .quiet), .quiet)
    }

    func testProminenceTrimsWhitespace() {
        XCTAssertEqual(FundProminence.resolved("  card  ", default: .hero), .card)
    }

    func testProminenceRawValuesAreTheStoredStrings() {
        XCTAssertEqual(FundProminence.hero.rawValue, "hero")
        XCTAssertEqual(FundProminence.card.rawValue, "card")
        XCTAssertEqual(FundProminence.quiet.rawValue, "quiet")
        XCTAssertEqual(FundProminence.allCases.count, 3)
    }

    // MARK: Fund Home visibility (build 47 — remove/add funds)

    func testOnlySavingsAndOverspentCanHide() {
        // Owner, Nov 19, 2026: "The only ones that stay and are
        // built in are spending & Charity."
        XCTAssertFalse(FundHomeVisibility.canHide(fundKey: "spending"))
        XCTAssertFalse(FundHomeVisibility.canHide(fundKey: "charity"))
        XCTAssertTrue(FundHomeVisibility.canHide(fundKey: "fund"))
        XCTAssertTrue(FundHomeVisibility.canHide(fundKey: "debt"))
        XCTAssertFalse(FundHomeVisibility.canHide(fundKey: "other"))
    }

    func testHiddenMapHidesOnlyHideableFunds() {
        let hidden: [String: Bool] = ["fund": true, "debt": true, "spending": true, "charity": true]
        XCTAssertTrue(FundHomeVisibility.isHidden(fundKey: "fund", hiddenMap: hidden))
        XCTAssertTrue(FundHomeVisibility.isHidden(fundKey: "debt", hiddenMap: hidden))
        // A stored value for a built-in fund never hides it — the
        // server refuses those keys too, so this is belt and braces.
        XCTAssertFalse(FundHomeVisibility.isHidden(fundKey: "spending", hiddenMap: hidden))
        XCTAssertFalse(FundHomeVisibility.isHidden(fundKey: "charity", hiddenMap: hidden))
    }

    func testMissingOrFalseMapEntryShowsTheFund() {
        XCTAssertFalse(FundHomeVisibility.isHidden(fundKey: "fund", hiddenMap: [:]))
        XCTAssertFalse(FundHomeVisibility.isHidden(fundKey: "fund", hiddenMap: ["fund": false]))
        XCTAssertFalse(FundHomeVisibility.isHidden(fundKey: "debt", hiddenMap: ["fund": true]))
    }
}
