import XCTest
@testable import ClipShelf

final class PanelInteractionTests: XCTestCase {
    func testTextSearchLeavesNavigationButPreservesExplicitMultiBoardFilter() {
        let a = UUID(), b = UUID()
        var scope = PanelBoardScope()
        scope.navigate(to: a)
        XCTAssertEqual(scope.queryIDs, [a])
        scope.beginTextSearch()
        XCTAssertTrue(scope.queryIDs.isEmpty)
        scope.filter([a, b])
        scope.beginTextSearch()
        XCTAssertEqual(scope.queryIDs, [a, b])
        XCTAssertNil(scope.singleBoardID)
    }

    func testLocateClearsMultiBoardFilterAndDeletedBoardIsRemoved() {
        let a = UUID(), b = UUID(), c = UUID()
        var scope = PanelBoardScope()
        scope.filter([a, b])
        scope.navigate(to: c)
        XCTAssertEqual(scope.queryIDs, [c])
        XCTAssertTrue(scope.filteredIDs.isEmpty)
        scope.retain([a, b])
        XCTAssertTrue(scope.queryIDs.isEmpty)
        scope.filter([a, b])
        scope.retain([b])
        XCTAssertEqual(scope.singleBoardID, b)
    }

    func testDragPreservesVisibleOrderOfDiscontiguousSelectionAndUsesAnchor() throws {
        let ids = (0..<6).map { _ in UUID() }
        let plan = try PanelReorderPlan.insertion(movingIDs: [ids[1], ids[3]], visibleIDs: ids, at: 5, hasMore: true)
        XCTAssertEqual(plan.movingIDs, [ids[1], ids[3]])
        XCTAssertEqual(plan.beforeID, ids[5])
    }

    func testPartialPageCannotBeMistakenForEndOfBoard() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertThrowsError(try PanelReorderPlan.insertion(movingIDs: [ids[0]], visibleIDs: ids, at: ids.count, hasMore: true)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .unloadedBoundary)
        }
        XCTAssertThrowsError(try PanelReorderPlan.step(movingIDs: [ids[2]], visibleIDs: ids, forward: true, hasMore: true)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .unloadedBoundary)
        }
    }

    func testCompletePageCanAppendAndPreviousStepIsStable() throws {
        let ids = (0..<5).map { _ in UUID() }
        let appended = try PanelReorderPlan.insertion(movingIDs: [ids[1], ids[2]], visibleIDs: ids, at: ids.count, hasMore: false)
        XCTAssertEqual(appended.movingIDs, [ids[1], ids[2]])
        XCTAssertNil(appended.beforeID)
        let previous = try PanelReorderPlan.step(movingIDs: [ids[2], ids[4]], visibleIDs: ids, forward: false, hasMore: false)
        XCTAssertEqual(previous.movingIDs, [ids[2], ids[4]])
        XCTAssertEqual(previous.beforeID, ids[1])
    }

    func testVanishedSelectionAndNoOpAreRejected() {
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertThrowsError(try PanelReorderPlan.insertion(movingIDs: [UUID()], visibleIDs: ids, at: 1, hasMore: false)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .staleSelection)
        }
        XCTAssertThrowsError(try PanelReorderPlan.insertion(movingIDs: [ids[1]], visibleIDs: ids, at: 1, hasMore: false)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .noMovement)
        }
    }
}
