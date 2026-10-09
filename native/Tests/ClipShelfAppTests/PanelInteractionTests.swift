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

    func testDeepWindowRemainsBoundedAndNavigatesBothDirections() {
        var page = PanelPageWindow()
        let start = PanelPageWindow.centeredOffset(for: 99_999)
        XCTAssertEqual(start, 99_849)
        page.update(offset: start, count: 300, hasMore: true)
        XCTAssertEqual(page.count, 300)
        XCTAssertTrue(page.hasPrevious)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.previousOffset, 99_549)
        XCTAssertEqual(page.nextOffset, 100_149)
        XCTAssertEqual(page.rangeDescription, "第 99850–100149 条")
        page.update(offset: page.previousOffset, count: 300, hasMore: true)
        XCTAssertEqual(page.nextOffset, start)
    }

    func testFirstAndShortLastWindowHaveAccurateBoundaries() {
        var page = PanelPageWindow()
        page.update(offset: 0, count: 300, hasMore: true)
        XCTAssertFalse(page.hasPrevious)
        XCTAssertEqual(page.previousOffset, 0)
        XCTAssertEqual(PanelPageWindow.centeredOffset(for: 5), 0)
        page.update(offset: 600, count: 17, hasMore: false)
        XCTAssertEqual(page.nextOffset, 617)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.rangeDescription, "第 601–617 条")
        page.update(offset: 600, count: 0, hasMore: false)
        XCTAssertEqual(page.rangeDescription, "0 条")
        XCTAssertTrue(page.hasPrevious)
    }

    func testWindowHeadCannotBeUsedAsBeginningOfWholeBoard() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertThrowsError(try PanelReorderPlan.insertion(movingIDs: [ids[3]], visibleIDs: ids,
                                                          at: 0, hasMore: true, hasPrevious: true)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .unloadedBoundary)
        }
        XCTAssertThrowsError(try PanelReorderPlan.step(movingIDs: [ids[0]], visibleIDs: ids,
                                                     forward: false, hasMore: true, hasPrevious: true)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .unloadedBoundary)
        }
        XCTAssertThrowsError(try PanelReorderPlan.step(movingIDs: [ids[1]], visibleIDs: ids,
                                                     forward: false, hasMore: true, hasPrevious: true)) {
            XCTAssertEqual($0 as? PanelReorderPlan.PlanningError, .unloadedBoundary)
        }
    }

    func testMiddleOfDeepWindowStillSupportsStableMultiSelection() throws {
        let ids = (0..<7).map { _ in UUID() }
        let plan = try PanelReorderPlan.insertion(movingIDs: [ids[1], ids[3]], visibleIDs: ids,
                                                  at: 6, hasMore: true, hasPrevious: true)
        XCTAssertEqual(plan.movingIDs, [ids[1], ids[3]])
        XCTAssertEqual(plan.beforeID, ids[6])
        let previous = try PanelReorderPlan.step(movingIDs: [ids[3], ids[5]], visibleIDs: ids,
                                                forward: false, hasMore: true, hasPrevious: true)
        XCTAssertEqual(previous.beforeID, ids[2])
    }
}
