import Foundation
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor final class SelectionUndoHistoryTests: XCTestCase {
    private func withStore(_ body: (HistoryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-undo-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3")))
    }

    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        ClipboardSelectionReference(id: record.id, revision: record.revision)
    }

    func testConsecutiveMovesCreateSeparateUndoGroupsAndRebaseOnlyOwnChanges() throws {
        try withStore { store in
            let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B"), c = try store.createPinboard(name: "C")
            let record = try store.create(ClipboardRecord(text: "item", pinboardID: a.id))
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            var errors: [Error] = []
            var completed = 0
            @MainActor func remember(_ undo: HistorySelectionMoveUndo) {
                ledger.register(.move(undo)) { ticket in
                    do {
                        guard case .move(let token) = ticket.action else { return XCTFail("Unexpected action") }
                        let receipt = try store.undoSelectionMove(token)
                        ledger.remove(ticket)
                        XCTAssertEqual(ledger.rebaseActions(using: store, receipt: receipt), 0)
                        completed += 1
                    } catch { errors.append(error) }
                }
                XCTAssertEqual(manager.groupingLevel, 0)
            }
            let first = try store.moveSelection([reference(record)], to: b.id)
            remember(first)
            remember(try store.moveSelection(first.references, to: c.id))
            manager.undo()
            XCTAssertEqual(completed, 1)
            XCTAssertEqual(try store.item(id: record.id)?.pinboardID, b.id)
            XCTAssertTrue(manager.canUndo)
            manager.undo()
            XCTAssertEqual(completed, 2)
            XCTAssertEqual(try store.item(id: record.id)?.pinboardID, a.id)
            XCTAssertFalse(manager.canUndo)
            XCTAssertTrue(errors.isEmpty, "\(errors)")
            XCTAssertTrue(ledger.tickets.isEmpty)
        }
    }

    func testPayloadEvictionRemovesActualUndoActionAndOversizeKeepsExistingHistory() throws {
        try withStore { store in
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager, maximumPayloadBytes: 8)
            var handled: [UUID] = []
            @MainActor func register(_ text: String) throws -> (UUID, Bool) {
                let record = try store.create(ClipboardRecord(text: text))
                let token = try store.deleteSelection([reference(record)])
                let accepted = ledger.register(.deletion([record], token)) { ticket in
                    guard case .deletion(let originals, _) = ticket.action else { return }
                    handled.append(contentsOf: originals.map(\.id))
                    ledger.remove(ticket)
                }
                return (record.id, accepted)
            }
            let first = try register("aaaa"), second = try register("bbbb"), third = try register("cccc")
            XCTAssertTrue(first.1 && second.1 && third.1)
            XCTAssertEqual(ledger.retainedPayloadBytes, 8)
            XCTAssertEqual(ledger.tickets.count, 2)
            XCTAssertFalse(try register("too large").1)
            XCTAssertEqual(ledger.retainedPayloadBytes, 8)
            while manager.canUndo { manager.undo() }
            XCTAssertEqual(handled, [third.0, second.0])
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
        }
    }

    func testActionCapacityEvictsMetadataActionsFromUndoManager() throws {
        try withStore { store in
            let board = try store.createPinboard(name: "target")
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager, maximumActions: 2)
            var handled: [UUID] = []
            var expected: [UUID] = []
            for index in 0..<3 {
                let record = try store.create(ClipboardRecord(text: "item \(index)"))
                expected.append(record.id)
                let token = try store.moveSelection([reference(record)], to: board.id)
                ledger.register(.move(token)) { ticket in
                    guard case .move(let action) = ticket.action else { return }
                    handled.append(contentsOf: action.references.map(\.id)); ledger.remove(ticket)
                }
            }
            XCTAssertEqual(ledger.tickets.count, 2)
            while manager.canUndo { manager.undo() }
            XCTAssertEqual(handled, Array(expected.suffix(2).reversed()))
        }
    }

    func testInvalidEarlierTicketDoesNotTurnCommittedUndoIntoFailure() throws {
        try withStore { store in
            try withStore { other in
                let record = try store.create(ClipboardRecord(text: "own"))
                let board = try store.createPinboard(name: "own board")
                let token = try store.moveSelection([reference(record)], to: board.id)
                let otherRecord = try other.create(ClipboardRecord(text: "other"))
                let otherBoard = try other.createPinboard(name: "other board")
                let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
                ledger.register(.move(try other.moveSelection([reference(otherRecord)], to: otherBoard.id))) { _ in XCTFail("Invalid ticket survived") }
                let receipt = try store.undoSelectionMove(token)
                XCTAssertEqual(ledger.rebaseActions(using: store, receipt: receipt), 1)
                XCTAssertNil(try store.item(id: record.id)?.pinboardID)
                XCTAssertFalse(manager.canUndo)
                XCTAssertTrue(ledger.tickets.isEmpty)
            }
        }
    }

    func testOtherUndoActionsAutomaticallyEvictAndReleaseSelectionPayload() throws {
        try withStore { store in
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager, maximumActions: 2)
            let record = try store.create(ClipboardRecord(text: "retained payload"))
            let token = try store.deleteSelection([reference(record)])
            ledger.register(.deletion([record], token)) { _ in XCTFail("Evicted selection must not run") }
            weak var ticket = ledger.tickets.first
            XCTAssertNotNil(ticket)
            let target = NSObject()
            for _ in 0..<2 {
                manager.beginUndoGrouping()
                manager.registerUndo(withTarget: target) { _ in }
                manager.endUndoGrouping()
            }
            XCTAssertNil(ticket)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
            XCTAssertTrue(ledger.tickets.isEmpty)
            while manager.canUndo { manager.undo() }
        }
    }

    func testDatabaseReplacementBoundaryClearsBothUndoKindsAndReleasesPayload() throws {
        try withStore { store in
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            let record = try store.create(ClipboardRecord(text: "old library"))
            ledger.register(.deletion([record], try store.deleteSelection([reference(record)]))) { _ in
                XCTFail("Old library deletion survived the boundary")
            }
            weak var ticket = ledger.tickets.first
            let target = NSObject()
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: target) { _ in XCTFail("Old edit survived the boundary") }
            manager.endUndoGrouping()
            ledger.removeAll()
            XCTAssertNil(ticket)
            XCTAssertFalse(manager.canUndo)
            XCTAssertFalse(manager.canRedo)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
        }
    }

    func testEditingAndMovingShareOneContinuousUndoHistory() throws {
        try withStore { store in
            let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B")
            let record = try store.create(ClipboardRecord(text: "original", pinboardID: a.id))
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            var errors: [Error] = []
            @MainActor func register(_ action: SelectionUndoAction) {
                ledger.register(action) { ticket in
                    do {
                        let receipt: HistorySelectionUndoReceipt
                        switch ticket.action {
                        case .move(let token): receipt = try store.undoSelectionMove(token)
                        case .edit(let token): receipt = try store.undoSelectionEdit(token)
                        case .deletion(let records, let token): receipt = try store.restoreDeletedSelection(records, undo: token)
                        }
                        ledger.remove(ticket)
                        XCTAssertEqual(ledger.rebaseActions(using: store, receipt: receipt), 0)
                    } catch { errors.append(error) }
                }
            }
            register(.move(try store.moveSelection([reference(record)], to: b.id)))
            var edited = try XCTUnwrap(store.item(id: record.id)); edited.text = "edit one"
            register(.edit(try store.editSelectionRecord(edited)))
            edited = try XCTUnwrap(store.item(id: record.id)); edited.text = "edit two"
            register(.edit(try store.editSelectionRecord(edited)))
            manager.undo()
            XCTAssertEqual(try store.item(id: record.id)?.text, "edit one")
            manager.undo()
            XCTAssertEqual(try store.item(id: record.id)?.text, "original")
            manager.undo()
            XCTAssertEqual(try store.item(id: record.id)?.pinboardID, a.id)
            XCTAssertTrue(errors.isEmpty, "\(errors)")
            XCTAssertFalse(manager.canUndo)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
        }
    }

    func testCleanupInvalidatesWholeOverlappingEditMoveAndDeletionTicketsButKeepsOtherActionsUsable() throws {
        try withStore { store in
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            let removedBoard = try store.createPinboard(name: "removed move"), keptBoard = try store.createPinboard(name: "kept move")
            let removedEdit = try store.create(ClipboardRecord(text: "removed edit"))
            let keptEdit = try store.create(ClipboardRecord(text: "kept edit"))
            let moved = try ["moved a", "moved b"].map { try store.create(ClipboardRecord(text: $0)) }
            let keptMove = try store.create(ClipboardRecord(text: "kept move"))
            let deleted = try ["deleted a", "deleted b"].map { try store.create(ClipboardRecord(text: $0)) }
            let keptDelete = try store.create(ClipboardRecord(text: "kept delete"))
            var handled: [String] = [], errors: [Error] = []
            @MainActor func remember(_ action: SelectionUndoAction, name: String, kept: Bool) {
                XCTAssertTrue(ledger.register(action) { ticket in
                    guard kept else { return XCTFail("Invalidated action executed: \(name)") }
                    do {
                        switch ticket.action {
                        case .edit(let undo): _ = try store.undoSelectionEdit(undo)
                        case .move(let undo): _ = try store.undoSelectionMove(undo)
                        case .deletion(let records, let undo): _ = try store.restoreDeletedSelection(records, undo: undo)
                        }
                        handled.append(name); ledger.remove(ticket)
                    } catch { errors.append(error) }
                })
            }
            var edit = removedEdit; edit.renamedTitle = "changed"
            remember(.edit(try store.editSelectionRecord(edit)), name: "removed edit", kept: false)
            edit = keptEdit; edit.renamedTitle = "changed"
            remember(.edit(try store.editSelectionRecord(edit)), name: "kept edit", kept: true)
            remember(.move(try store.moveSelection(moved.map(reference), to: removedBoard.id)), name: "removed move", kept: false)
            remember(.move(try store.moveSelection([reference(keptMove)], to: keptBoard.id)), name: "kept move", kept: true)
            remember(.deletion(deleted, try store.deleteSelection(deleted.map(reference))), name: "removed deletion", kept: false)
            remember(.deletion([keptDelete], try store.deleteSelection([reference(keptDelete)])), name: "kept deletion", kept: true)
            let otherTarget = NSObject()
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: otherTarget) { _ in handled.append("ordinary action") }
            manager.endUndoGrouping()

            let affected: Set<UUID> = [removedEdit.id, moved[1].id, deleted[0].id]
            XCTAssertEqual(ledger.invalidate(recordIDs: affected), 3)
            XCTAssertEqual(ledger.invalidate(recordIDs: affected), 0)
            XCTAssertEqual(ledger.tickets.count, 3)
            XCTAssertEqual(ledger.retainedPayloadBytes, SelectionUndoTicket.payloadSize([keptEdit, keptDelete]))
            XCTAssertEqual(manager.groupingLevel, 0)
            while manager.canUndo { manager.undo() }
            XCTAssertEqual(handled, ["ordinary action", "kept deletion", "kept move", "kept edit"])
            XCTAssertTrue(errors.isEmpty, "\(errors)")
            XCTAssertEqual(try store.item(id: removedEdit.id)?.renamedTitle, "changed")
            XCTAssertEqual(try store.item(id: keptEdit.id)?.renamedTitle, keptEdit.renamedTitle)
            XCTAssertEqual(try moved.map { try store.item(id: $0.id)?.pinboardID }, [removedBoard.id, removedBoard.id])
            XCTAssertNil(try store.item(id: keptMove.id)?.pinboardID)
            XCTAssertTrue(try deleted.allSatisfy { try store.item(id: $0.id) == nil })
            XCTAssertNotNil(try store.item(id: keptDelete.id))
            XCTAssertTrue(ledger.tickets.isEmpty); XCTAssertEqual(ledger.retainedPayloadBytes, 0)

            let fresh = try store.create(ClipboardRecord(text: "after invalidation"))
            var changed = fresh; changed.renamedTitle = "new edit"
            remember(.edit(try store.editSelectionRecord(changed)), name: "fresh edit", kept: true)
            XCTAssertTrue(manager.canUndo); manager.undo()
            XCTAssertEqual(handled.last, "fresh edit")
            XCTAssertNil(try store.item(id: fresh.id)?.renamedTitle)
            XCTAssertFalse(manager.canUndo); XCTAssertEqual(manager.groupingLevel, 0)
        }
    }

    func testCleanupOfUnselectedBoardBaselineRetiresDependentMoveOnly() throws {
        try withStore { store in
            let board = try store.createPinboard(name: "destination"), unrelatedBoard = try store.createPinboard(name: "unrelated")
            let neighbour = try store.create(ClipboardRecord(text: "not selected", pinboardID: board.id))
            let selected = try store.create(ClipboardRecord(text: "selected"))
            let unrelated = try store.create(ClipboardRecord(text: "unrelated"))
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            let dependent = try store.moveSelection([reference(selected)], to: board.id)
            XCTAssertFalse(dependent.references.contains { $0.id == neighbour.id })
            XCTAssertTrue(dependent.affectedRecordIDs.contains(neighbour.id))
            ledger.register(.move(dependent)) { _ in XCTFail("Move with a cleaned-up board baseline survived") }
            var handled = 0
            ledger.register(.move(try store.moveSelection([reference(unrelated)], to: unrelatedBoard.id))) { ticket in
                handled += 1; ledger.remove(ticket)
            }
            XCTAssertEqual(ledger.invalidate(recordIDs: [neighbour.id]), 1)
            XCTAssertEqual(ledger.tickets.count, 1)
            manager.undo()
            XCTAssertEqual(handled, 1); XCTAssertFalse(manager.canUndo)
        }
    }

    func testEmptyOrDisjointCleanupKeepsEveryTicketAndOriginalUndoOrder() throws {
        try withStore { store in
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            let board = try store.createPinboard(name: "board")
            let edited = try store.create(ClipboardRecord(text: "edit"))
            let moved = try store.create(ClipboardRecord(text: "move"))
            let deleted = try store.create(ClipboardRecord(text: "delete"))
            var change = edited; change.renamedTitle = "new title"
            let actions: [SelectionUndoAction] = [.edit(try store.editSelectionRecord(change)),
                .move(try store.moveSelection([reference(moved)], to: board.id)),
                .deletion([deleted], try store.deleteSelection([reference(deleted)]))]
            var order: [Int] = []
            for (index, action) in actions.enumerated() {
                ledger.register(action) { ticket in order.append(index); ledger.remove(ticket) }
            }
            let ids = ledger.tickets.map(\.id), bytes = ledger.retainedPayloadBytes
            XCTAssertEqual(ledger.invalidate(recordIDs: []), 0)
            XCTAssertEqual(ledger.invalidate(recordIDs: [UUID()]), 0)
            XCTAssertEqual(ledger.tickets.map(\.id), ids)
            XCTAssertEqual(ledger.retainedPayloadBytes, bytes)
            while manager.canUndo { manager.undo() }
            XCTAssertEqual(order, [2, 1, 0]); XCTAssertEqual(manager.groupingLevel, 0)
        }
    }
}
