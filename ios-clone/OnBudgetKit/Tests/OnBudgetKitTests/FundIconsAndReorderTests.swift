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
}
