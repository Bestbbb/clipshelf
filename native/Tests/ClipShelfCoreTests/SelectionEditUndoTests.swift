import Foundation
import XCTest
@testable import ClipShelfCore

final class SelectionEditUndoTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-edit-undo-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        ClipboardSelectionReference(id: record.id, revision: record.revision)
    }
    private func edit(_ store: HistoryStore, id: UUID, text: String) throws -> HistorySelectionEditUndo {
        var current = try XCTUnwrap(store.item(id: id)); current.text = text
        return try store.editSelectionRecord(current)
    }

    func testConsecutiveEditsCaptureOriginalInsideTransactionAndUndoWithTrustedRebase() throws {
        let store = try store()
        let original = try store.create(ClipboardRecord(text: "original", rtf: Data([0, 1, 2]), originDeviceID: UUID(), originDeviceName: "Mac"))
        let first = try edit(store, id: original.id, text: "first")
        XCTAssertEqual(first.original, original)
        let second = try edit(store, id: original.id, text: "second")
        XCTAssertEqual(second.original.text, "first"); XCTAssertEqual(second.original.revision, 2)
        let receipt = try store.undoSelectionEdit(second)
        XCTAssertEqual(try store.item(id: original.id)?.text, "first")
        XCTAssertThrowsError(try store.undoSelectionEdit(first))
        let rebased = try store.rebaseSelectionEditUndo(first, after: receipt)
        try store.undoSelectionEdit(rebased)
        var expected = original; expected.revision = 5
        XCTAssertEqual(try store.item(id: original.id), expected)
    }

    func testMoveThenEditUndoCanRebaseMoveWithoutChangingOriginalPlacement() throws {
        let store = try store()
        let original = try store.create(ClipboardRecord(text: "original"))
        let board = try store.createPinboard(name: "Destination")
        let move = try store.moveSelection([reference(original)], to: board.id)
        let edit = try edit(store, id: original.id, text: "edited in board")
        let receipt = try store.undoSelectionEdit(edit)
        let rebased = try store.rebaseSelectionMoveUndo(move, after: receipt)
        try store.undoSelectionMove(rebased)
        let restored = try XCTUnwrap(store.item(id: original.id))
        XCTAssertNil(restored.pinboardID); XCTAssertEqual(restored.text, original.text)
        XCTAssertNil(restored.originDeviceID); XCTAssertEqual(restored.revision, 5)
    }

    func testExternalBodyEditCannotBeOverwrittenOrWashedByAnotherUndoReceipt() throws {
        let store = try store(), external = try self.store()
        let original = try store.create(ClipboardRecord(text: "original"))
        let first = try edit(store, id: original.id, text: "first")
        var other = try XCTUnwrap(external.item(id: original.id)); other.text = "outside edit"
        _ = try external.update(record: other)
        XCTAssertThrowsError(try store.editSelectionRecord(original))
        XCTAssertThrowsError(try store.undoSelectionEdit(first))
        let later = try edit(store, id: original.id, text: "later")
        let receipt = try store.undoSelectionEdit(later)
        let rebased = try store.rebaseSelectionEditUndo(first, after: receipt)
        XCTAssertThrowsError(try store.undoSelectionEdit(rebased))
        XCTAssertEqual(try store.item(id: original.id)?.text, "outside edit")
    }

    func testUndoRejectsAccountGenerationRoundTripsAndCrossStoreTokens() throws {
        for shared in [false, true] {
            let store = try store(shared ? "shared" : "private"), other = try self.store("other")
            let original = try store.create(ClipboardRecord(text: "local"))
            let undo = try edit(store, id: original.id, text: "local edit")
            XCTAssertThrowsError(try other.undoSelectionEdit(undo))
            if shared { try store.configureSharing(accountID: "A"); try store.configureSharing(accountID: nil) }
            else { try store.configureSync(accountID: "A"); try store.configureSync(accountID: nil) }
            XCTAssertThrowsError(try store.undoSelectionEdit(undo))
            XCTAssertEqual(try store.item(id: original.id)?.text, "local edit")
            XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM sync_outbox", []), "0")
        }
    }

    func testEditFailureRollsBackAndDeletedRecordIsNeverRecreatedByEditUndo() throws {
        let store = try store()
        let original = try store.create(ClipboardRecord(text: "original"))
        try store.execute("CREATE TRIGGER reject_edit BEFORE UPDATE ON clipboard_records BEGIN SELECT RAISE(ABORT, 'synthetic edit failure'); END")
        XCTAssertThrowsError(try edit(store, id: original.id, text: "rejected"))
        XCTAssertEqual(try store.item(id: original.id), original)
        try store.execute("DROP TRIGGER reject_edit")
        let undo = try edit(store, id: original.id, text: "saved")
        try store.deleteSelection(try store.selectionSnapshot(HistoryQuery()).references)
        XCTAssertThrowsError(try store.undoSelectionEdit(undo))
        XCTAssertNil(try store.item(id: original.id))
    }

    func testDeletionRestoreReceiptAlsoRebasesOlderEditUndo() throws {
        let store = try store(), other = try self.store("other")
        let original = try store.create(ClipboardRecord(text: "original"))
        let edit = try edit(store, id: original.id, text: "edited")
        let selection = try store.selectionSnapshot(HistoryQuery()).references
        let originals = try store.resolveSelection(selection)
        let deletion = try store.deleteSelection(selection)
        let receipt = try store.restoreDeletedSelection(originals, undo: deletion)
        XCTAssertThrowsError(try other.rebaseSelectionEditUndo(edit, after: receipt))
        try store.undoSelectionEdit(try store.rebaseSelectionEditUndo(edit, after: receipt))
        XCTAssertEqual(try store.item(id: original.id)?.text, "original")
        XCTAssertEqual(try store.item(id: original.id)?.revision, 4)
    }
}
