import Foundation
import XCTest
@testable import ClipShelfCore

final class DeletionUndoIdentityTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-identity-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func ref(_ record: ClipboardRecord) -> ClipboardSelectionReference { .init(id: record.id, revision: record.revision) }
    private func part(_ value: String) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data(value.utf8))])
    }
    private func boardIDs(_ store: HistoryStore, _ board: UUID) throws -> [UUID] {
        try store.selectionSnapshot(.init(pinboardIDs: [board], sortOrder: .pinboard)).references.map(\.id)
    }

    func testSyncedEditMoveDeleteUndoChainRestoresOriginalFieldsThroughFreshIdentity() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B")
        _ = try store.create(ClipboardRecord(text: "A neighbour", pinboardID: a.id))
        let original = try store.create(ClipboardRecord(text: "original", sourceApp: "Synthetic", copiedAt: Date(timeIntervalSince1970: 1),
                                                       parts: [part("original"), part("second")], pinboardID: a.id,
                                                       isInHistory: false, originDeviceID: UUID(), originDeviceName: "Mac"))
        let originalPosition = try store.historyOrderWithoutLock(id: original.id)
        var changed = original; changed.text = "edited"; changed.parts[0] = part("edited")
        let edit = try store.editSelectionRecord(changed)
        let move = try store.moveSelection([edit.committedReference], to: b.id)
        let payload = try store.resolveSelection(move.references), deletion = try store.deleteSelection(move.references)
        let receipt = try store.restoreDeletedSelection(payload, undo: deletion)
        let newID = try XCTUnwrap(receipt.identityChanges[original.id])
        XCTAssertNotEqual(newID, original.id); XCTAssertEqual(receipt.references[0].revision, 1)
        XCTAssertNil(try store.item(id: original.id))
        let rebasedMove = try store.rebaseSelectionMoveUndo(move, after: receipt)
        var rebasedEdit = try store.rebaseSelectionEditUndo(edit, after: receipt)
        XCTAssertEqual(rebasedEdit.expectedContentFingerprint, edit.expectedContentFingerprint)
        XCTAssertEqual(rebasedEdit.original.id, newID)
        let moveReceipt = try store.undoSelectionMove(rebasedMove)
        rebasedEdit = try store.rebaseSelectionEditUndo(rebasedEdit, after: moveReceipt)
        let editReceipt = try store.undoSelectionEdit(rebasedEdit)
        var expected = original; expected.id = newID; expected.pinboardOrderIdentity = original.id
        expected.revision = editReceipt.references[0].revision
        XCTAssertEqual(try store.item(id: newID), expected)
        XCTAssertEqual(try store.historyOrderWithoutLock(id: newID), originalPosition)
        XCTAssertTrue(try store.syncIsDeleted(accountID: "account", kind: .clipboard, id: original.id))
        XCTAssertEqual(try boardIDs(store, b.id), [])
        XCTAssertEqual(try boardIDs(store, a.id).last, newID)
    }

    func testEarlierDeletionRebasesOnlyRestoredNeighboursAndRetainsOriginalPayload() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Board")
        let a = try store.create(ClipboardRecord(text: "A", pinboardID: board.id))
        let b = try store.create(ClipboardRecord(text: "B", pinboardID: board.id))
        let c = try store.create(ClipboardRecord(text: "C", pinboardID: board.id))
        let deletionA = try store.deleteSelection([ref(a)]), deletionB = try store.deleteSelection([ref(b)])
        let receiptB = try store.restoreDeletedSelection([b], undo: deletionB)
        XCTAssertThrowsError(try store.restoreDeletedSelection([a], undo: deletionA))
        let originalsA = try store.rebaseDeletedSelectionOriginals([a], undo: deletionA, after: receiptB)
        let rebasedA = try store.rebaseSelectionDeleteUndo(deletionA, after: receiptB)
        XCTAssertEqual(originalsA, [a])
        let receiptA = try store.restoreDeletedSelection(originalsA, undo: rebasedA)
        XCTAssertEqual(try boardIDs(store, board.id), [receiptA.references[0].id, receiptB.references[0].id, c.id])
        XCTAssertEqual(try store.selectionSnapshot(.init()).references.map(\.id), [c.id, receiptB.references[0].id, receiptA.references[0].id])
        XCTAssertThrowsError(try store.restoreDeletedSelection(originalsA, undo: rebasedA))
    }

    func testExternalBoardReorderingStillRejectsOlderMoveAfterIdentityRebase() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B")
        let original = try store.create(ClipboardRecord(text: "moving", pinboardID: a.id))
        let neighbour = try store.create(ClipboardRecord(text: "neighbour", pinboardID: b.id))
        let move = try store.moveSelection([ref(original)], to: b.id)
        let current = try XCTUnwrap(store.item(id: original.id))
        let deletion = try store.deleteSelection([ref(current)])
        let receipt = try store.restoreDeletedSelection([current], undo: deletion)
        let rebased = try store.rebaseSelectionMoveUndo(move, after: receipt)
        _ = try store.moveSelection([ref(neighbour)], to: b.id, before: nil)
        let before = try boardIDs(store, b.id)
        XCTAssertThrowsError(try store.undoSelectionMove(rebased))
        XCTAssertEqual(try boardIDs(store, b.id), before)
    }

    func testDeleteUndoRejectsPayloadChangesEvenWhenIdentityAndRevisionMatchAndCanRetry() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let original = try store.create(ClipboardRecord(text: "original", parts: [part("one"), part("two")]))
        let undo = try store.deleteSelection([ref(original)])
        var forged = original; forged.parts[1] = part("untrusted replacement")
        XCTAssertThrowsError(try store.restoreDeletedSelection([forged], undo: undo))
        let other = try self.store("other"), unrelated = try other.create(ClipboardRecord(text: "unrelated"))
        let otherDelete = try other.deleteSelection([ref(unrelated)])
        let otherReceipt = try other.restoreDeletedSelection([unrelated], undo: otherDelete)
        XCTAssertThrowsError(try store.rebaseSelectionDeleteUndo(undo, after: otherReceipt))
        XCTAssertThrowsError(try store.rebaseDeletedSelectionOriginals([original], undo: undo, after: otherReceipt))
        let restored = try store.restoreDeletedSelection([original], undo: undo)
        XCTAssertEqual(try store.item(id: restored.references[0].id)?.parts, original.parts)
    }

    func testDeleteUndoRejectsNewSurvivorPlacementBeforeWritingAnyRestoredRecord() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Board")
        let original = try store.create(ClipboardRecord(text: "deleted", pinboardID: board.id))
        _ = try store.create(ClipboardRecord(text: "survivor", pinboardID: board.id))
        let undo = try store.deleteSelection([ref(original)])
        let inserted = try store.create(ClipboardRecord(text: "new occupant", pinboardID: board.id))
        let outbox = try store.pendingSyncOperations(accountID: "account")
        XCTAssertThrowsError(try store.restoreDeletedSelection([original], undo: undo))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), outbox)
        _ = try store.deleteSelection([ref(inserted)])
        let receipt = try store.restoreDeletedSelection([original], undo: undo)
        XCTAssertEqual(try boardIDs(store, board.id).first, receipt.references[0].id)
    }

    func testCanonicalIdentityDoesNotAllowChangedContentToPassOlderEditUndo() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let original = try store.create(ClipboardRecord(text: "original"))
        var editRecord = original; editRecord.text = "first edit"
        let edit = try store.editSelectionRecord(editRecord)
        var external = try XCTUnwrap(store.item(id: original.id)); external.text = "outside mutation"
        let current = try store.update(record: external)
        let deleted = try store.deleteSelection([ref(current)])
        let receipt = try store.restoreDeletedSelection([current], undo: deleted)
        let rebased = try store.rebaseSelectionEditUndo(edit, after: receipt)
        XCTAssertThrowsError(try store.undoSelectionEdit(rebased))
        XCTAssertEqual(try store.item(id: receipt.references[0].id)?.text, "outside mutation")
    }
    func testHistoricalMoveCannotBecomeValidWhenReplacementRevisionCountsCatchUp() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B")
        let original = try store.create(ClipboardRecord(text: "before", pinboardID: a.id))
        let oldMove = try store.moveSelection([ref(original)], to: b.id)
        var changed = try XCTUnwrap(store.item(id: original.id)); changed.text = "external body edit"
        changed = try store.update(record: changed)
        let deletion = try store.deleteSelection([ref(changed)])
        let receipt = try store.restoreDeletedSelection([changed], undo: deletion)
        let rebased = try store.rebaseSelectionMoveUndo(oldMove, after: receipt)
        var fresh = try XCTUnwrap(store.item(id: receipt.references[0].id)); fresh.text = "new identity revision 2"
        fresh = try store.update(record: fresh)
        XCTAssertEqual(fresh.revision, oldMove.references[0].revision)
        XCTAssertNotNil(rebased.expected[0].historicalIdentity)
        XCTAssertThrowsError(try store.undoSelectionMove(rebased))
        XCTAssertEqual(try store.item(id: fresh.id), fresh)
    }

    func testRepeatedFreshIdentityRestoresKeepOlderEditLineageDistinct() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B")
        let original = try store.create(ClipboardRecord(text: "original", pinboardID: a.id))
        var changed = original; changed.text = "first edit"
        var edit = try store.editSelectionRecord(changed)
        var move = try store.moveSelection([edit.committedReference], to: b.id)
        var current = try XCTUnwrap(store.item(id: original.id))
        var freshIDs: [UUID] = []
        for _ in 0..<3 {
            let deletion = try store.deleteSelection([ref(current)])
            let receipt = try store.restoreDeletedSelection([current], undo: deletion)
            edit = try store.rebaseSelectionEditUndo(edit, after: receipt)
            move = try store.rebaseSelectionMoveUndo(move, after: receipt)
            current = try XCTUnwrap(store.item(id: receipt.references[0].id))
            freshIDs.append(current.id)
            XCTAssertEqual(edit.expected.historicalIdentity, original.id)
        }
        XCTAssertEqual(Set(freshIDs).count, 3)
        let receipt = try store.undoSelectionMove(move)
        edit = try store.rebaseSelectionEditUndo(edit, after: receipt)
        XCTAssertNil(edit.expected.historicalIdentity)
        let result = try store.undoSelectionEdit(edit)
        let restored = try XCTUnwrap(store.item(id: result.references[0].id))
        XCTAssertEqual(restored.text, original.text); XCTAssertEqual(restored.pinboardID, a.id)
        XCTAssertEqual(restored.id, freshIDs.last)
    }

    func testDeletionFingerprintPreflightsWholeBatchBeforeOpeningOversizedMissingAttachments() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "bounded deletion"))
        let part = StoredRepresentation(typeIdentifier: "public.data", digest: String(repeating: "a", count: 64),
                                        byteCount: RepresentationStorage.maximumRepresentationBytes)
        let metadata = try JSONEncoder().encode([Array(repeating: part, count: 9)])
        let hex = metadata.map { String(format: "%02x", $0) }.joined()
        try store.execute("UPDATE clipboard_records SET parts = X'\(hex)' WHERE id = '\(original.id.uuidString)'")
        XCTAssertThrowsError(try store.deleteSelection([ref(original)])) { error in
            guard case HistoryStoreError.selectionPayloadTooLarge = error else { return XCTFail("Expected preflight before missing blob read: \(error)") }
        }
        XCTAssertEqual(try store.syncScalar("SELECT id FROM clipboard_records WHERE id = ?", [original.id.uuidString]), original.id.uuidString)
    }

    func testUndoOfPreviouslyUnboundLocalContentDoesNotUploadUntilExplicitOptIn() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "before sync was enabled"))
        try store.configureSync(accountID: "account", includeLocalData: false)
        XCTAssertNil(try store.syncNamespace(kind: .clipboard, id: original.id))
        XCTAssertFalse(try store.isSyncLocalOnly(kind: .clipboard, id: original.id))
        let undo = try store.deleteSelection([ref(original)])
        let deletionOperations = try store.pendingSyncOperations(accountID: "account")
        XCTAssertEqual(deletionOperations.count, 1); XCTAssertEqual(deletionOperations.first?.action, .delete)
        let receipt = try store.restoreDeletedSelection([original], undo: undo)
        let restoredID = receipt.references[0].id
        XCTAssertNotEqual(restoredID, original.id)
        XCTAssertTrue(try store.isSyncLocalOnly(kind: .clipboard, id: restoredID))
        XCTAssertNil(try store.syncNamespace(kind: .clipboard, id: restoredID))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), deletionOperations)
        try store.configureSync(accountID: "account", includeLocalData: true)
        let published = try store.pendingSyncOperations(accountID: "account").filter { $0.entityID == restoredID }
        XCTAssertEqual(published.count, 1); XCTAssertEqual(published.first?.record?.text, original.text)
        XCTAssertFalse(try store.isSyncLocalOnly(kind: .clipboard, id: restoredID))
    }

}
