import Foundation
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor final class DeletionUndoLedgerTests: XCTestCase {
    private func withStore(_ body: (HistoryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-deletion-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3")))
    }

    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        .init(id: record.id, revision: record.revision)
    }

    private func undo(_ action: SelectionUndoAction, in store: HistoryStore) throws -> HistorySelectionUndoReceipt {
        switch action {
        case .deletion(let originals, let token): return try store.restoreDeletedSelection(originals, undo: token)
        case .edit(let token): return try store.undoSelectionEdit(token)
        case .move(let token): return try store.undoSelectionMove(token)
        }
    }

    func testSyncedEditMoveAndDeleteUndoContinueAcrossRepeatedReplacementIdentities() throws {
        try withStore { store in
            try store.configureSync(accountID: "account")
            let firstBoard = try store.createPinboard(name: "First"), secondBoard = try store.createPinboard(name: "Second")
            let original = try store.create(ClipboardRecord(text: "original text", pinboardID: firstBoard.id))
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            var failures: [Error] = [], receipts: [HistorySelectionUndoReceipt] = []
            @MainActor func remember(_ action: SelectionUndoAction) {
                XCTAssertTrue(ledger.register(action) { ticket in
                    do {
                        let receipt = try self.undo(ticket.action, in: store)
                        ledger.remove(ticket)
                        XCTAssertEqual(ledger.rebaseActions(using: store, receipt: receipt), 0)
                        receipts.append(receipt)
                    } catch { failures.append(error) }
                })
            }
            var edited = original; edited.text = "edited text"
            let edit = try store.editSelectionRecord(edited)
            remember(.edit(edit))
            let move = try store.moveSelection([edit.committedReference], to: secondBoard.id)
            remember(.move(move))
            var current = try XCTUnwrap(store.resolveSelection(move.references).first)
            var retiredIDs: Set<UUID> = []
            let olderPayload = ledger.retainedPayloadBytes

            for _ in 0..<4 {
                let retiredID = current.id
                retiredIDs.insert(retiredID)
                weak var deletionTicket: SelectionUndoTicket?
                try autoreleasepool {
                    remember(.deletion([current], try store.deleteSelection([reference(current)])))
                    deletionTicket = ledger.tickets.last
                    XCTAssertEqual(ledger.tickets.count, 3)
                    XCTAssertEqual(ledger.retainedPayloadBytes, olderPayload + SelectionUndoTicket.payloadSize([current]))
                    manager.undo()
                    XCTAssertTrue(failures.isEmpty, "\(failures)")
                    let receipt = try XCTUnwrap(receipts.last)
                    current = try XCTUnwrap(store.resolveSelection(receipt.references).first)
                    XCTAssertEqual(receipt.identityChanges[retiredID], current.id)
                    XCTAssertNotEqual(current.id, retiredID)
                    XCTAssertEqual(current.text, edited.text)
                    XCTAssertEqual(current.pinboardID, secondBoard.id)
                    XCTAssertEqual(ledger.tickets.count, 2)
                    XCTAssertEqual(ledger.retainedPayloadBytes, olderPayload)
                }
                // Cocoa releases executed undo groups at the event's autorelease boundary.
                XCTAssertNil(deletionTicket, "Executed deletion payload must leave the UndoManager, including after ID rebasing")
            }

            manager.undo()
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            XCTAssertEqual(try store.item(id: current.id)?.pinboardID, firstBoard.id)
            XCTAssertEqual(try store.item(id: current.id)?.text, edited.text)
            manager.undo()
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            XCTAssertEqual(try store.item(id: current.id)?.text, original.text)
            XCTAssertEqual(try store.item(id: current.id)?.pinboardID, firstBoard.id)
            XCTAssertEqual(try store.load().map(\.id), [current.id])
            for id in retiredIDs {
                XCTAssertNil(try store.item(id: id))
                XCTAssertTrue(try store.hasSyncTombstone(accountID: "account", kind: .clipboard, entityID: id))
            }
            XCTAssertFalse(manager.canUndo)
            XCTAssertTrue(ledger.tickets.isEmpty)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
        }
    }

    func testEarlierDeletionTracksRestoredBoardNeighbourThroughUndoManager() throws {
        try withStore { store in
            try store.configureSync(accountID: "account")
            let board = try store.createPinboard(name: "Ordered")
            let records = try ["first", "second", "third"].map {
                try store.create(ClipboardRecord(text: $0, pinboardID: board.id))
            }
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            var failures: [Error] = [], restoredIDs: [String: UUID] = [:]
            @MainActor func deleteAndRemember(_ record: ClipboardRecord) throws {
                let deletion = try store.deleteSelection([reference(record)])
                XCTAssertTrue(ledger.register(.deletion([record], deletion)) { ticket in
                    do {
                        let receipt = try self.undo(ticket.action, in: store)
                        let restored = try XCTUnwrap(store.resolveSelection(receipt.references).first)
                        restoredIDs[restored.text] = restored.id
                        ledger.remove(ticket)
                        XCTAssertEqual(ledger.rebaseActions(using: store, receipt: receipt), 0)
                    } catch { failures.append(error) }
                })
            }
            try deleteAndRemember(records[0])
            try deleteAndRemember(records[1])
            manager.undo()
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            XCTAssertTrue(manager.canUndo)
            XCTAssertEqual(try store.search(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.text), ["second", "third"])
            manager.undo()
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            let result = try store.search(.init(pinboardIDs: [board.id], sortOrder: .pinboard))
            XCTAssertEqual(result.map(\.text), records.map(\.text))
            XCTAssertEqual(result.map(\.pinboardOrder), records.map(\.pinboardOrder))
            XCTAssertEqual(result.map(\.id), [try XCTUnwrap(restoredIDs["first"]), try XCTUnwrap(restoredIDs["second"]), records[2].id])
            XCTAssertNotEqual(restoredIDs["first"], records[0].id)
            XCTAssertNotEqual(restoredIDs["second"], records[1].id)
            XCTAssertFalse(manager.canUndo)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
        }
    }

    func testAsyncQuotaFailureRequeuesSameActionAboveOlderEditWithoutGrowingPayload() throws {
        try withStore { store in
            try store.configureSync(accountID: "account")
            let older = try store.create(ClipboardRecord(text: "older original"))
            var changed = older; changed.text = "older edited"
            let edit = try store.editSelectionRecord(changed)
            let deleted = try store.create(ClipboardRecord(text: "retry deletion content"))
            let deletion = try store.deleteSelection([reference(deleted)])
            let bytes = SelectionUndoTicket.payloadSize([older, deleted])
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager, maximumActions: 2, maximumPayloadBytes: bytes)
            var pending: SelectionUndoTicket?
            @MainActor func beginUndo(_ ticket: SelectionUndoTicket) {
                XCTAssertNil(pending)
                pending = ticket
            }
            autoreleasepool { XCTAssertTrue(ledger.register(.edit(edit), handler: beginUndo)) }
            let olderTicketID = try XCTUnwrap(ledger.tickets.first?.id)
            autoreleasepool { XCTAssertTrue(ledger.register(.deletion([deleted], deletion), handler: beginUndo)) }
            let status = try store.contentQuotaStatus()
            let limited = try store.setContentQuotaLimit(status.usedBytes, expectedRevision: status.policyRevision)
            let outbox = try store.pendingSyncOperations(accountID: "account")

            for _ in 0..<4 {
                weak var consumed: SelectionUndoTicket?
                try autoreleasepool {
                    manager.undo()
                    XCTAssertFalse(manager.isUndoing, "Complete only after the callback returns, as the detached save does")
                    let failed = try XCTUnwrap(pending)
                    pending = nil
                    consumed = failed
                    guard case .deletion = failed.action else { return XCTFail("Retry must remain above the older edit") }
                    XCTAssertThrowsError(try self.undo(failed.action, in: store)) {
                        XCTAssertTrue(SelectionUndoHistory.isRetryableFailure($0))
                        guard case .exceeded = $0 as? ContentQuotaError else { return XCTFail("Expected actual quota failure, got \($0)") }
                    }
                    XCTAssertTrue(ledger.retainForRetry(failed, handler: beginUndo))
                }
                XCTAssertNil(consumed, "Each failed ticket is released rather than accumulated")
                XCTAssertEqual(ledger.tickets.count, 2)
                XCTAssertEqual(ledger.retainedPayloadBytes, bytes)
                XCTAssertEqual(ledger.tickets.first?.id, olderTicketID)
                XCTAssertEqual(try store.item(id: older.id)?.text, changed.text)
                XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), outbox)
                XCTAssertEqual(try store.contentQuotaStatus(), limited)
                XCTAssertTrue(manager.canUndo)
            }

            _ = try store.setContentQuotaLimit(nil, expectedRevision: limited.policyRevision)
            manager.undo()
            let retried = try XCTUnwrap(pending)
            pending = nil
            let restored = try self.undo(retried.action, in: store)
            ledger.remove(retried)
            XCTAssertEqual(ledger.rebaseActions(using: store, receipt: restored), 0)
            XCTAssertEqual(try store.resolveSelection(restored.references).map(\.text), [deleted.text])
            XCTAssertEqual(ledger.tickets.map(\.id), [olderTicketID])
            XCTAssertEqual(ledger.retainedPayloadBytes, SelectionUndoTicket.payloadSize([older]))
            manager.undo()
            let olderTicket = try XCTUnwrap(pending)
            pending = nil
            guard case .edit = olderTicket.action else { return XCTFail("Original older edit must remain next") }
            _ = try self.undo(olderTicket.action, in: store)
            ledger.remove(olderTicket)
            XCTAssertEqual(try store.item(id: older.id)?.text, older.text)
            XCTAssertFalse(manager.canUndo)
            XCTAssertTrue(ledger.tickets.isEmpty)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
        }
    }

    func testRetryFailureClassificationDoesNotKeepStaleOrUnauthorizedActions() {
        let terminal: [Error] = [HistoryStoreError.staleRevision, HistoryStoreError.invalidSelection,
                                 HistoryStoreError.recordNotFound, HistoryStoreError.pinboardNotFound,
                                 HistoryStoreError.corruptAttachment, HistoryStoreError.corruptOwnedFile,
                                 SyncError.accountChanged, SyncError.namespaceConflict,
                                 SharedBoardError.accountChanged, SharedBoardError.readOnly, SharedBoardError.revoked,
                                 StorageWriteFailure.invalidRequirement, StorageWriteFailure.releasedLease,
                                 ContentQuotaError.invalidLimit,
                                 HistoryStoreError.database(code: 19, message: "constraint failure")]
        for error in terminal { XCTAssertFalse(SelectionUndoHistory.isRetryableFailure(error), "\(error)") }
        let retryable: [Error] = [ContentQuotaError.exceeded(usedBytes: 2, limitBytes: 1),
                                  ContentQuotaError.measurementUnavailable, ContentQuotaError.stalePolicy,
                                  StorageWriteFailure.capacityUnavailable, StorageWriteFailure.diskFull,
                                  StorageWriteFailure.insufficientSpace(requiredBytes: 2, availableBytes: 1),
                                  StorageWriteFailure.destinationChanged, StorageWriteFailure.coordinationUnavailable,
                                  HistoryStoreError.database(code: 5, message: "busy"),
                                  HistoryStoreError.database(code: 266, message: "extended IO error")]
        for error in retryable { XCTAssertTrue(SelectionUndoHistory.isRetryableFailure(error), "\(error)") }
    }

    func testAccountChangeDuringAsyncUndoDropsOnlyThatActionAndReleasesItsPayload() throws {
        try withStore { store in
            try store.configureSync(accountID: "A")
            let record = try store.create(ClipboardRecord(text: "private A"))
            let deletion = try store.deleteSelection([reference(record)])
            let manager = UndoManager(), ledger = SelectionUndoHistory(manager: manager)
            var pending: SelectionUndoTicket?
            let other = NSObject()
            var otherHandled = false
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: other) { _ in otherHandled = true }
            manager.endUndoGrouping()
            weak var originalTicket: SelectionUndoTicket?
            autoreleasepool {
                XCTAssertTrue(ledger.register(.deletion([record], deletion)) { pending = $0 })
                originalTicket = ledger.tickets.first
            }
            try autoreleasepool {
                manager.undo()
                XCTAssertFalse(manager.isUndoing)
                try store.configureSync(accountID: "B")
                XCTAssertThrowsError(try self.undo(XCTUnwrap(pending).action, in: store)) {
                    XCTAssertFalse(SelectionUndoHistory.isRetryableFailure($0))
                }
                ledger.remove(try XCTUnwrap(pending))
                pending = nil
            }
            XCTAssertNil(originalTicket)
            XCTAssertEqual(ledger.retainedPayloadBytes, 0)
            XCTAssertTrue(manager.canUndo)
            manager.undo()
            XCTAssertTrue(otherHandled)
            XCTAssertFalse(manager.canUndo)
            XCTAssertTrue(try store.load().isEmpty)
            XCTAssertTrue(try store.pendingSyncOperations(accountID: "B").isEmpty)
        }
    }
}
