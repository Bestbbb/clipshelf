import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

private final class SelectionReadTrace {
    var action: (() throws -> Void)?
    var failure: Error?
}

final class HistorySelectionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-selection-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func ref(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        ClipboardSelectionReference(id: record.id, revision: record.revision)
    }
    private func ids(_ store: HistoryStore, board: UUID) throws -> [UUID] {
        try store.selectionSnapshot(HistoryQuery(pinboardIDs: [board], sortOrder: .pinboard)).references.map(\.id)
    }
    private func rich(_ text: String, board: UUID? = nil, inHistory: Bool = true) -> ClipboardRecord {
        ClipboardRecord(text: text, rtf: Data([1, 2]), html: Data([3, 4, 5]),
                        parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: Data([6, 7, 8, 9]))])],
                        pinboardID: board, isInHistory: inHistory, originDeviceID: UUID(), originDeviceName: "Mac")
    }
    private func removeAttachments(_ store: HistoryStore) throws {
        for file in try FileManager.default.contentsOfDirectory(at: store.representations.directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }
    private func readOnlyShare(_ store: HistoryStore) throws -> ClipboardRecord {
        try store.configureSharing(accountID: "owner")
        let source = try store.createPinboard(name: "source")
        _ = try store.create(ClipboardRecord(text: "shared", pinboardID: source.id))
        let id = UUID()
        let descriptor = SharedBoardDescriptor(boardID: id, accountID: "owner", containerIdentifier: "iCloud.synthetic",
                                               zoneName: "ClipShelfShared_" + id.uuidString, zoneOwnerName: "owner", shareRecordName: "share")
        _ = try store.createSharedCopy(from: source.id, descriptor: descriptor)
        let record = try XCTUnwrap(store.search(HistoryQuery(pinboardIDs: [id])).first)
        try store.updateSharedAccess(boardID: id, accountID: "owner", access: .readOnly)
        return record
    }

    func testSnapshotIgnoresPaginationAndFreezesOrderedIDsBeyondSQLiteVariableLimit() throws {
        let store = try store()
        let board = try store.createPinboard(name: "Large")
        let records = try (0..<1_105).map { try store.create(ClipboardRecord(text: "literal 中文 \($0)", pinboardID: board.id)) }
        let query = HistoryQuery(text: "中文", pinboardIDs: [board.id], limit: 0, sortOrder: .pinboard)
        let snapshot = try store.selectionSnapshot(query)
        XCTAssertEqual(snapshot.references, records.map(ref))
        _ = try store.create(ClipboardRecord(text: "literal 中文 new", pinboardID: board.id))
        try store.validateSelection(snapshot.references)
        XCTAssertEqual(try store.resolveSelection(snapshot.references).map(\.id), records.map(\.id))
        XCTAssertEqual(snapshot.references.count, 1_105)
        let range = try store.selectionSnapshot(query, scope: .between(ref(records[902]), ref(records[197])))
        XCTAssertEqual(range.references, Array(records[197...902]).map(ref))
        XCTAssertEqual(try store.selectionSnapshot(HistoryQuery(text: "absent", limit: 1)).references, [])
    }

    func testRangeRejectsChangedDeletedOrFilteredAnchorsAndDuplicateActions() throws {
        let store = try store()
        let first = try store.create(ClipboardRecord(text: "needle first")), second = try store.create(ClipboardRecord(text: "needle second"))
        var changed = first; changed.text = "needle changed"; _ = try store.update(record: changed)
        XCTAssertThrowsError(try store.selectionSnapshot(HistoryQuery(text: "needle"), scope: .between(ref(first), ref(second))))
        XCTAssertThrowsError(try store.selectionSnapshot(HistoryQuery(text: "second"), scope: .between(ref(first), ref(second))))
        XCTAssertThrowsError(try store.validateSelection([ref(first), ref(second)]))
        XCTAssertThrowsError(try store.resolveSelection([ref(second), ref(first)]))
        XCTAssertThrowsError(try store.deleteSelection([ref(second), ref(first)]))
        XCTAssertNotNil(try store.itemMetadata(id: second.id))
        XCTAssertThrowsError(try store.deleteSelection([ref(second), ref(second)]))
        try store.deleteSelection([ref(second)])
        XCTAssertThrowsError(try store.selectionSnapshot(HistoryQuery(), scope: .between(ref(first), ref(second))))
    }

    func testResolutionBudgetCountsUnicodeAndEveryRichRepresentationBeforeOpeningFiles() throws {
        let store = try store()
        let one = try store.create(rich("中")), two = try store.create(rich("中"))
        // 3 UTF-8 text bytes + 2 RTF + 3 HTML + 4 PNG, repeated for each selected item.
        XCTAssertEqual(try store.resolveSelection([ref(two), ref(one)], maximumPayloadBytes: 24), [two, one])
        try removeAttachments(store)
        XCTAssertThrowsError(try store.resolveSelection([ref(two), ref(one)], maximumPayloadBytes: 23)) { error in
            guard case HistoryStoreError.selectionPayloadTooLarge = error else { return XCTFail("Budget must fail before opening a missing attachment: \(error)") }
        }
        XCTAssertThrowsError(try store.resolveSelection([ref(two), ref(one)], maximumPayloadBytes: 24))
        XCTAssertEqual(try store.resolveSelection([], maximumPayloadBytes: 0), [])
        XCTAssertThrowsError(try store.resolveSelection([], maximumPayloadBytes: -1))
    }

    func testResolutionUsesOneSQLiteReadSnapshotWhenAnotherConnectionEditsMidRead() throws {
        let reader = try store(), writer = try store()
        let first = try reader.create(ClipboardRecord(text: "before first")), second = try reader.create(ClipboardRecord(text: "before second"))
        let probe = SelectionReadTrace()
        probe.action = {
            var changed = first; changed.text = "after first"; _ = try writer.update(record: changed)
            try writer.delete(id: second.id)
        }
        sqlite3_trace_v2(reader.database, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)),
                  String(cString: sql).hasPrefix("SELECT length(CAST(text AS BLOB))") else { return 0 }
            let probe = Unmanaged<SelectionReadTrace>.fromOpaque(context).takeUnretainedValue()
            if let action = probe.action {
                probe.action = nil
                do { try action() } catch { probe.failure = error }
            }
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())
        defer { sqlite3_trace_v2(reader.database, 0, nil, nil) }
        XCTAssertEqual(try reader.resolveSelection([ref(first), ref(second)]), [first, second])
        XCTAssertNil(probe.failure); XCTAssertNil(probe.action)
        XCTAssertThrowsError(try reader.validateSelection([ref(first), ref(second)]))
    }

    func testLocalMoveStepUndoAndDeleteNeedNoAttachments() throws {
        let store = try store()
        let board = try store.createPinboard(name: "One"), other = try store.createPinboard(name: "Two")
        let records = try (0..<305).map { try store.create(rich("\($0)", board: board.id, inHistory: false)) }
        try removeAttachments(store)
        let step = try store.stepSelection([ref(records[299])], boardID: board.id, forward: true)
        var expected = records.map(\.id); expected.swapAt(299, 300)
        XCTAssertEqual(try ids(store, board: board.id), expected)
        try store.undoSelectionMove(step)
        XCTAssertEqual(try ids(store, board: board.id), records.map(\.id))
        let fresh = try store.selectionSnapshot(HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)).references
        let move = try store.moveSelection(fresh, to: other.id)
        XCTAssertEqual(try ids(store, board: other.id), records.map(\.id))
        try store.undoSelectionMove(move)
        XCTAssertEqual(try ids(store, board: board.id), records.map(\.id))
        XCTAssertEqual(try store.itemMetadata(id: records[0].id)?.isInHistory, false)
        let unpin = try store.moveSelection([try XCTUnwrap(store.selectionSnapshot(HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)).references.first)], to: nil)
        XCTAssertEqual(try store.itemMetadata(id: records[0].id)?.isInHistory, true)
        try store.undoSelectionMove(unpin)
        XCTAssertEqual(try store.itemMetadata(id: records[0].id)?.isInHistory, false)
        try store.deleteSelection(try store.selectionSnapshot(HistoryQuery(pinboardIDs: [board.id])).references)
        XCTAssertEqual(try ids(store, board: board.id), [])
    }

    func testMoveAndUndoValidateSelectionAnchorAndRebalancedNeighboursAtomically() throws {
        let store = try store(), otherStore = try self.store("other")
        let board = try store.createPinboard(name: "Dense")
        let records = try (0..<4).map { try store.create(ClipboardRecord(text: "\($0)", pinboardID: board.id, pinboardOrder: Int64($0))) }
        var staleAnchor = records[1]; staleAnchor.text = "changed"; let anchor = try store.update(record: staleAnchor)
        XCTAssertThrowsError(try store.moveSelection([ref(records[3])], to: board.id, before: ref(records[1])))
        XCTAssertEqual(try ids(store, board: board.id), records.map(\.id))
        let undo = try store.moveSelection([ref(records[3])], to: board.id, before: ref(anchor))
        XCTAssertEqual(try ids(store, board: board.id), [records[0].id, records[3].id, records[1].id, records[2].id])
        XCTAssertThrowsError(try otherStore.undoSelectionMove(undo))
        try store.undoSelectionMove(undo)
        XCTAssertEqual(try ids(store, board: board.id), records.map(\.id))
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.pinboardOrder), [0, 1, 2, 3])
        XCTAssertThrowsError(try store.undoSelectionMove(undo))
        let refs = try store.selectionSnapshot(HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)).references
        let second = try store.moveSelection([refs[3]], to: board.id, before: refs[1])
        var neighbour = try XCTUnwrap(store.item(id: records[2].id)); neighbour.text = "edited after rebalance"
        _ = try store.update(record: neighbour)
        let before = try ids(store, board: board.id)
        XCTAssertThrowsError(try store.undoSelectionMove(second))
        XCTAssertEqual(try ids(store, board: board.id), before)
    }

    func testWholeBoardStepKeepsNonSelectedOrderAndHandlesActualEndpoints() throws {
        let store = try store(), board = try store.createPinboard(name: "Board")
        let records = try (0..<8).map { try store.create(ClipboardRecord(text: "\($0)", pinboardID: board.id)) }
        let undo = try store.stepSelection([ref(records[4]), ref(records[2])], boardID: board.id, forward: true)
        XCTAssertEqual(try ids(store, board: board.id), [0, 1, 3, 5, 2, 4, 6, 7].map { records[$0].id })
        XCTAssertEqual(undo.references.map(\.id), [records[4].id, records[2].id])
        try store.undoSelectionMove(undo)
        let first = try XCTUnwrap(store.selectionSnapshot(HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)).references.first)
        let noOp = try store.stepSelection([first], boardID: board.id, forward: false)
        XCTAssertEqual(noOp.references, [first])
        XCTAssertEqual(try ids(store, board: board.id), records.map(\.id))
    }

    func testReadOnlyItemRejectsEntireDeleteMoveAndRestoreBatch() throws {
        let store = try store(), shared = try readOnlyShare(store)
        let local = try store.create(ClipboardRecord(text: "local"))
        let before = try store.syncScalar("SELECT count(*) FROM sync_outbox", [])
        XCTAssertThrowsError(try store.deleteSelection([ref(local), ref(shared)]))
        XCTAssertNotNil(try store.itemMetadata(id: local.id))
        XCTAssertThrowsError(try store.moveSelection([ref(local), ref(shared)], to: nil))
        XCTAssertThrowsError(try store.stepSelection([ref(shared)], boardID: shared.pinboardID!, forward: true))
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM sync_outbox", []), before)
        try store.updateSharedAccess(boardID: shared.pinboardID!, accountID: "owner", access: .owner)
        let forbidden = try store.create(ClipboardRecord(text: "restored shared", pinboardID: shared.pinboardID))
        let allowed = try store.create(ClipboardRecord(text: "restored local"))
        let deletion = try store.deleteSelection([ref(allowed), ref(forbidden)])
        try store.updateSharedAccess(boardID: shared.pinboardID!, accountID: "owner", access: .readOnly)
        XCTAssertThrowsError(try store.restoreDeletedSelection([allowed, forbidden], undo: deletion))
        XCTAssertNil(try store.itemMetadata(id: allowed.id))
    }

    func testDeleteAndRestoreFailuresRollBackEntireBatchAndKeepIndexConsistent() throws {
        let store = try store()
        let first = try store.create(ClipboardRecord(text: "search first")), second = try store.create(ClipboardRecord(text: "search second"))
        try store.execute("CREATE TRIGGER synthetic_delete_failure BEFORE DELETE ON clipboard_records WHEN OLD.id = '\(second.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'failure'); END")
        XCTAssertThrowsError(try store.deleteSelection([ref(first), ref(second)]))
        XCTAssertEqual(try store.selectionSnapshot(HistoryQuery(text: "search")).references.count, 2)
        try store.execute("DROP TRIGGER synthetic_delete_failure")
        let deletion = try store.deleteSelection([ref(second), ref(first)])
        try store.execute("CREATE TRIGGER synthetic_insert_failure BEFORE INSERT ON clipboard_records WHEN NEW.id = '\(second.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'failure'); END")
        XCTAssertThrowsError(try store.restoreDeletedSelection([second, first], undo: deletion))
        XCTAssertEqual(try store.selectionSnapshot(HistoryQuery(text: "search")).references, [])
        try store.execute("DROP TRIGGER synthetic_insert_failure")
        let restored = try store.restoreDeletedSelection([second, first], undo: deletion)
        XCTAssertEqual(restored.references.map(\.revision), [2, 2])
        XCTAssertEqual(try store.selectionSnapshot(HistoryQuery(text: "search")).references, restored.references)
        XCTAssertThrowsError(try store.validateSelection([ref(first), ref(second)]))
        XCTAssertThrowsError(try store.restoreDeletedSelection([ClipboardRecord(text: "new"), first], undo: deletion))
        XCTAssertEqual(try store.selectionSnapshot(HistoryQuery()).references.count, 2)
    }

    func testRestoreRetainsOriginPinRankAndMissingBoardRejectsWholeBatch() throws {
        let store = try store(), board = try store.createPinboard(name: "Restore")
        let record = try store.create(rich("origin", board: board.id, inHistory: false))
        let deletion = try store.deleteSelection([ref(record)])
        let restored = try store.restoreDeletedSelection([record], undo: deletion)
        let value = try XCTUnwrap(store.item(id: record.id))
        XCTAssertEqual(value.originDeviceID, record.originDeviceID)
        XCTAssertEqual(value.pinboardOrder, record.pinboardOrder)
        XCTAssertFalse(value.isInHistory)
        XCTAssertEqual(value.parts, record.parts)
        let secondDeletion = try store.deleteSelection(restored.references)
        try store.deletePinboard(id: board.id)
        XCTAssertThrowsError(try store.restoreDeletedSelection([value], undo: secondDeletion))
        XCTAssertNil(try store.itemMetadata(id: record.id))
    }

    func testSyncedDeleteTombstoneCannotBeResurrectedByBatchUndo() throws {
        let store = try store()
        try store.configureSync(accountID: "account")
        let record = try store.create(ClipboardRecord(text: "synced"))
        let deletion = try store.deleteSelection([ref(record)])
        let before = try store.pendingSyncOperations(accountID: "account")
        XCTAssertThrowsError(try store.restoreDeletedSelection([record], undo: deletion))
        XCTAssertNil(try store.itemMetadata(id: record.id))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), before)
    }

    func testUndoRejectsNewBoardPlacementOrRevokedPermissionAndPreservesAllRows() throws {
        let store = try store(), board = try store.createPinboard(name: "Board")
        let rows = try (0..<3).map { try store.create(ClipboardRecord(text: "\($0)", pinboardID: board.id, pinboardOrder: Int64($0))) }
        let undo = try store.moveSelection([ref(rows[2])], to: board.id, before: ref(rows[1]))
        _ = try store.create(ClipboardRecord(text: "inserted later", pinboardID: board.id))
        let afterInsert = try ids(store, board: board.id)
        XCTAssertThrowsError(try store.undoSelectionMove(undo))
        XCTAssertEqual(try ids(store, board: board.id), afterInsert)

        let shared = try readOnlyShare(store)
        try store.updateSharedAccess(boardID: shared.pinboardID!, accountID: "owner", access: .owner)
        let extra = try store.create(ClipboardRecord(text: "second shared", pinboardID: shared.pinboardID))
        let sharedUndo = try store.moveSelection([ref(extra)], to: shared.pinboardID, before: ref(shared))
        try store.updateSharedAccess(boardID: shared.pinboardID!, accountID: "owner", access: .readOnly)
        let before = try ids(store, board: shared.pinboardID!)
        XCTAssertThrowsError(try store.undoSelectionMove(sharedUndo))
        XCTAssertEqual(try ids(store, board: shared.pinboardID!), before)
    }

    func testSyncPayloadFailureRollsBackBulkMoveAndUndoDoesNotTouchBody() throws {
        let store = try store()
        try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Synced"), destination = try store.createPinboard(name: "Other")
        let first = try store.create(rich("first", board: board.id)), second = try store.create(rich("second", board: board.id))
        let before = try store.pendingSyncOperations(accountID: "account")
        try removeAttachments(store)
        XCTAssertThrowsError(try store.moveSelection([ref(first), ref(second)], to: destination.id))
        XCTAssertEqual(try ids(store, board: board.id), [first.id, second.id])
        XCTAssertEqual(try ids(store, board: destination.id), [])
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), before)
    }

    func testTrustedReceiptsAllowConsecutiveMoveUndosWithoutWeakeningRevisions() throws {
        let store = try store()
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B"), c = try store.createPinboard(name: "C")
        let record = try store.create(ClipboardRecord(text: "body", pinboardID: a.id))
        let first = try store.moveSelection([ref(record)], to: b.id)
        let second = try store.moveSelection(first.references, to: c.id)
        let receipt = try store.undoSelectionMove(second)
        XCTAssertThrowsError(try store.undoSelectionMove(first))
        let rebased = try store.rebaseSelectionMoveUndo(first, after: receipt)
        let finalReceipt = try store.undoSelectionMove(rebased)
        let restored = try XCTUnwrap(store.item(id: record.id))
        XCTAssertEqual(restored.pinboardID, a.id); XCTAssertEqual(restored.text, record.text)
        XCTAssertEqual(restored.revision, 5)
        XCTAssertEqual(finalReceipt.references, [ref(restored)])
        XCTAssertThrowsError(try store.rebaseSelectionMoveUndo(first, after: try self.store("other").undoSelectionMove(second)))
    }

    func testReceiptNeverWashesInterveningBodyOrBoardChanges() throws {
        let store = try store()
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B"), c = try store.createPinboard(name: "C")
        let record = try store.create(ClipboardRecord(text: "before", pinboardID: a.id))
        let first = try store.moveSelection([ref(record)], to: b.id)
        var edited = try XCTUnwrap(store.item(id: record.id)); edited.text = "external body edit"
        edited = try store.update(record: edited)
        let second = try store.moveSelection([ref(edited)], to: c.id)
        let receipt = try store.undoSelectionMove(second)
        let rebased = try store.rebaseSelectionMoveUndo(first, after: receipt)
        XCTAssertThrowsError(try store.undoSelectionMove(rebased))
        XCTAssertEqual(try store.item(id: record.id)?.text, "external body edit")

        let fresh = try XCTUnwrap(store.item(id: record.id))
        let earlier = try store.moveSelection([ref(fresh)], to: a.id)
        _ = try store.create(ClipboardRecord(text: "external board insertion", pinboardID: a.id))
        let later = try store.moveSelection(earlier.references, to: c.id)
        let laterReceipt = try store.undoSelectionMove(later)
        let earlierRebased = try store.rebaseSelectionMoveUndo(earlier, after: laterReceipt)
        XCTAssertThrowsError(try store.undoSelectionMove(earlierRebased))
        XCTAssertEqual(try store.itemMetadata(id: record.id)?.pinboardID, a.id)
    }

    func testDeletionReceiptRebasesOlderMoveUndoAndRejectsWrongStoreOrOriginalVersions() throws {
        let store = try store(), other = try self.store("other")
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B")
        let record = try store.create(ClipboardRecord(text: "kept", pinboardID: a.id))
        let move = try store.moveSelection([ref(record)], to: b.id)
        let selected = try store.resolveSelection(move.references)
        let deletion = try store.deleteSelection(move.references)
        XCTAssertThrowsError(try other.restoreDeletedSelection(selected, undo: deletion))
        XCTAssertThrowsError(try store.restoreDeletedSelection([record], undo: deletion))
        let receipt = try store.restoreDeletedSelection(selected, undo: deletion)
        XCTAssertThrowsError(try other.rebaseSelectionMoveUndo(move, after: receipt))
        let rebased = try store.rebaseSelectionMoveUndo(move, after: receipt)
        try store.undoSelectionMove(rebased)
        XCTAssertEqual(try store.itemMetadata(id: record.id)?.pinboardID, a.id)
        XCTAssertThrowsError(try store.restoreDeletedSelection(selected, undo: deletion))
    }

    func testDeleteUndoBindsPrivateAndSharedConfigurationGenerationsIncludingABA() throws {
        for mode in 0..<3 {
            let store = try store("account-\(mode)")
            let record = try store.create(ClipboardRecord(text: "must stay local"))
            let undo = try store.deleteSelection([ref(record)])
            if mode == 0 { try store.configureSync(accountID: "new-account", includeLocalData: false) }
            if mode == 1 { try store.configureSync(accountID: "new-account"); try store.configureSync(accountID: nil) }
            if mode == 2 { try store.configureSharing(accountID: "new-account"); try store.configureSharing(accountID: nil) }
            let before = try store.syncScalar("SELECT count(*) FROM sync_outbox", [])
            XCTAssertThrowsError(try store.restoreDeletedSelection([record], undo: undo))
            XCTAssertNil(try store.itemMetadata(id: record.id))
            XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM sync_outbox", []), before)
        }
    }

    func testMoveUndoCannotAdoptLocalContentAfterSyncConfigurationChanges() throws {
        let store = try store()
        let board = try store.createPinboard(name: "Local")
        let record = try store.create(ClipboardRecord(text: "local"))
        let undo = try store.moveSelection([ref(record)], to: board.id)
        try store.configureSync(accountID: "new-account", includeLocalData: false)
        XCTAssertThrowsError(try store.undoSelectionMove(undo))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "new-account"), [])
        XCTAssertEqual(try store.itemMetadata(id: record.id)?.pinboardID, board.id)
    }

    func testSuccessfulDeleteUndoCapabilityCannotBeReplayedAfterAnotherDeletion() throws {
        let store = try store()
        let record = try store.create(ClipboardRecord(text: "one-use"))
        let undo = try store.deleteSelection([ref(record)])
        let copiedToken = undo
        let receipt = try store.restoreDeletedSelection([record], undo: undo)
        let restored = try store.resolveSelection(receipt.references)
        let secondUndo = try store.deleteSelection(receipt.references)
        XCTAssertThrowsError(try store.restoreDeletedSelection([record], undo: copiedToken))
        XCTAssertNil(try store.itemMetadata(id: record.id))
        let secondReceipt = try store.restoreDeletedSelection(restored, undo: secondUndo)
        XCTAssertEqual(secondReceipt.references.first?.revision, 3)
    }
}
