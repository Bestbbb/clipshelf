import XCTest
import ClipShelfCore
@testable import ClipShelf

final class PanelSelectionStateTests: XCTestCase {
    private func refs(_ count: Int) -> [ClipboardSelectionReference] {
        (0..<count).map { _ in ClipboardSelectionReference(id: UUID(), revision: 1) }
    }

    func testFrozenUniverseRangesCrossPagesAndShrinkInEitherDirection() throws {
        let all = refs(1_200)
        var state = PanelSelectionState()
        state.selectSingle(all[299])
        try state.installUniverse(all)
        try state.select(ref: all[1_050], toggle: false, extend: true)
        XCTAssertEqual(state.references, Array(all[299...1_050]))
        try state.select(ref: all[600], toggle: false, extend: true)
        XCTAssertEqual(state.references, Array(all[299...600]))
        try state.select(ref: all[10], toggle: false, extend: true)
        XCTAssertEqual(state.references, Array(all[10...299]))
        XCTAssertEqual(state.anchorID, all[299].id)
        XCTAssertEqual(state.rangeTarget(delta: -1), all[9].id)
    }

    func testSelectAllFreezesMembershipAndToggleUsesQueryOrder() throws {
        let all = refs(1_200), added = refs(1)[0]
        var state = PanelSelectionState()
        try state.selectAll(all)
        XCTAssertThrowsError(try state.select(ref: added, toggle: true, extend: false))
        XCTAssertEqual(state.references, all)
        try state.select(ref: all[400], toggle: true, extend: false)
        try state.select(ref: all[400], toggle: true, extend: false)
        XCTAssertEqual(state.references, all)
        try state.installUniverse([added] + all)
        XCTAssertEqual(state.references, all, "Refreshing the universe never silently selects a new capture")
        try state.select(ref: added, toggle: true, extend: false)
        XCTAssertEqual(state.references, [added] + all)
    }

    func testUniverseRebuildRejectsChangedOrMissingSelectedMemberAtomically() throws {
        let all = refs(1_000)
        var state = PanelSelectionState()
        try state.selectAll(all)
        let generation = state.generation
        var changed = all
        changed[700] = .init(id: all[700].id, revision: 2)
        XCTAssertThrowsError(try state.installUniverse(changed))
        XCTAssertThrowsError(try state.installUniverse(Array(all.dropLast())))
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.references, all)
    }

    func testCommitUpdatesExactSetAndInvalidatesOldRangeOrder() throws {
        let all = refs(1_000)
        var state = PanelSelectionState()
        try state.selectAll(all)
        let updated = all.map { ClipboardSelectionReference(id: $0.id, revision: 2) }
        XCTAssertThrowsError(try state.adoptCommitted(Array(updated.dropLast())))
        try state.adoptCommitted(updated.reversed())
        XCTAssertEqual(state.references, updated)
        XCTAssertNil(state.universe)
        XCTAssertNil(state.rangeTarget(delta: 1))
        try state.installUniverse(updated.reversed())
        XCTAssertEqual(state.references, updated.reversed())
    }

    func testDuplicateSnapshotsAndInvalidSelectionCannotBeExtended() throws {
        let all = refs(2)
        var state = PanelSelectionState()
        XCTAssertThrowsError(try state.selectAll(all + [all[0]]))
        state.selectSingle(all[0]); try state.installUniverse(all)
        state.invalidate()
        XCTAssertThrowsError(try state.select(ref: all[1], toggle: false, extend: true))
        XCTAssertEqual(state.references, [all[0]])
        state.selectSingle(all[1])
        XCTAssertFalse(state.isInvalid)
        XCTAssertEqual(state.references, [all[1]])
    }
}
