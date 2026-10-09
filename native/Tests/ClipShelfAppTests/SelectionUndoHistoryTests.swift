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
}
