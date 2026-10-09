import Foundation
import XCTest
@testable import ClipShelfCore

final class PinboardOrderingTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-order-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func fixtures(_ store: HistoryStore, count: Int) throws -> (Pinboard, [ClipboardRecord]) {
        let board = try store.createPinboard(name: "Ordered")
        let items = try (0..<count).map { try store.create(ClipboardRecord(text: "item \($0)", pinboardID: board.id)) }
        return (board, items)
    }
    private func ids(_ store: HistoryStore, _ board: UUID, limit: Int = 1_000, offset: Int = 0) throws -> [UUID] {
        try store.searchMetadata(HistoryQuery(pinboardIDs: [board], limit: limit, sortOrder: .pinboard), offset: offset).map(\.id)
    }
    private func transfer(_ source: HistoryStore, _ destination: HistoryStore, account: String) throws {
        let pending = try source.pendingSyncOperations(accountID: account, limit: 1_000)
        try destination.applyRemoteChanges(accountID: account, changes: pending, nextCursor: nil)
        try source.acknowledgeSyncOperations(accountID: account, operationIDs: Set(pending.map(\.operationID)))
    }

    func testPartialPageMovePreservesHiddenItemsAndHistoryOrderAcrossRestart() throws {
        let store = try store()
        let (board, records) = try fixtures(store, count: 12)
        let original = records.map(\.id), history = try store.load().map(\.id)
        XCTAssertEqual(try ids(store, board.id, limit: 3), Array(original.prefix(3)))
        try store.move(recordIDs: [original[2], original[1]], to: board.id, before: original[0],
                       expectedRevisions: Dictionary(uniqueKeysWithValues: records.prefix(3).map { ($0.id, $0.revision) }))
        let expected = [original[2], original[1], original[0]] + Array(original.dropFirst(3))
        XCTAssertEqual(try ids(store, board.id), expected)
        XCTAssertEqual(try ids(store, board.id, limit: 3, offset: 3), Array(original[3..<6]))
        XCTAssertEqual(try store.load().map(\.id), history)
        XCTAssertEqual(try ids(self.store(), board.id), expected)
        XCTAssertThrowsError(try store.reorderPinboardItems(boardID: board.id, orderedIDs: Array(expected.prefix(3))))
        XCTAssertEqual(try ids(store, board.id), expected)
    }

    func testAnchorAndMovedItemRevisionChangesRejectWholeDrag() throws {
        let store = try store()
        let (board, records) = try fixtures(store, count: 4)
        let original = records.map(\.id)
        var edited = records[0]; edited.text = "anchor edited"
        _ = try store.update(record: edited)
        XCTAssertThrowsError(try store.move(recordIDs: [records[3].id], to: board.id, before: records[0].id,
                                           expectedRevisions: [records[0].id: records[0].revision, records[3].id: records[3].revision]))
        XCTAssertEqual(try ids(store, board.id), original)
        var moved = records[3]; moved.text = "dragged item edited"
        _ = try store.update(record: moved)
        XCTAssertThrowsError(try store.move(recordIDs: [moved.id], to: board.id, before: records[1].id,
                                           expectedRevisions: [moved.id: records[3].revision]))
        XCTAssertEqual(try ids(store, board.id), original)
        XCTAssertThrowsError(try store.move(recordIDs: [records[1].id], to: board.id, before: records[1].id))
    }

    func testCrossBoardBatchMoveAppendsAndUnpinClearsRankWithoutChangingHistoryOrder() throws {
        let store = try store()
        let (first, records) = try fixtures(store, count: 5)
        let second = try store.createPinboard(name: "Second")
        let existing = try store.create(ClipboardRecord(text: "existing", pinboardID: second.id))
        let history = try store.load().map(\.id)
        try store.move(recordIDs: [records[3].id, records[1].id], to: second.id)
        XCTAssertEqual(try ids(store, second.id), [existing.id, records[3].id, records[1].id])
        XCTAssertEqual(try ids(store, first.id), [records[0].id, records[2].id, records[4].id])
        try store.move(recordIDs: [records[3].id, records[1].id], to: nil)
        XCTAssertNil(try store.item(id: records[3].id)?.pinboardOrder)
        XCTAssertNil(try store.item(id: records[1].id)?.pinboardID)
        XCTAssertEqual(try store.load().map(\.id), history)
    }

    func testGapExhaustionRebalancesAndFailureRollsBackOrderAndOutbox() throws {
        let store = try store()
        try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Tight ranks")
        let items = try (0..<3).map { try store.create(ClipboardRecord(text: "\($0)", pinboardID: board.id, pinboardOrder: Int64($0))) }
        let pending = try store.pendingSyncOperations(accountID: "account")
        try store.execute("CREATE TRIGGER abort_order BEFORE UPDATE ON clipboard_records WHEN NEW.id = '\(items[2].id.uuidString)' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertThrowsError(try store.move(recordIDs: [items[2].id], to: board.id, before: items[1].id))
        XCTAssertEqual(try ids(store, board.id), items.map(\.id))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), pending)
        try store.execute("DROP TRIGGER abort_order")
        try store.move(recordIDs: [items[2].id], to: board.id, before: items[1].id)
        XCTAssertEqual(try ids(store, board.id), [items[0].id, items[2].id, items[1].id])
        let ranks = try store.searchMetadata(HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)).compactMap(\.pinboardOrder)
        XCTAssertEqual(Set(ranks).count, 3)
        XCTAssertEqual(ranks, ranks.sorted())
    }

    func testFilteredMetadataAndFullRecordQueriesSortBeforePagination() throws {
        let store = try store()
        let (board, records) = try fixtures(store, count: 6)
        try store.reorderPinboardItems(boardID: board.id, orderedIDs: Array(records.map(\.id).reversed()))
        let query = HistoryQuery(text: "item", pinboardIDs: [board.id], limit: 2, sortOrder: .pinboard)
        XCTAssertEqual(try store.search(query).map(\.id), [records[5].id, records[4].id])
        XCTAssertEqual(try store.searchMetadata(query, offset: 2).map(\.id), [records[3].id, records[2].id])
        XCTAssertEqual(try store.metadataOffset(of: records[0].id, query: query), 5)
        XCTAssertNil(try store.metadataOffset(of: records[0].id, query: HistoryQuery(text: "does not match", pinboardIDs: [board.id], sortOrder: .pinboard)))
        XCTAssertEqual(try store.metadataOffset(of: records[5].id, query: HistoryQuery(limit: 0)), 0)
        XCTAssertNil(try store.metadataOffset(of: UUID(), query: query))
        XCTAssertThrowsError(try store.searchMetadata(HistoryQuery(sortOrder: .pinboard)))
        XCTAssertThrowsError(try store.searchMetadata(HistoryQuery(pinboardIDs: [board.id, UUID()], sortOrder: .pinboard)))
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        XCTAssertEqual(try store.searchIntegrationMetadata(query, offset: 2, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing).map(\.id), [records[3].id, records[2].id])
    }

    func testRankSurvivesBackupRestoreAndSyncedBackupIdentityRemapping() throws {
        let store = try store()
        try store.configureSync(accountID: "account")
        let (board, records) = try fixtures(store, count: 4)
        try store.move(recordIDs: [records[3].id], to: board.id, before: records[1].id)
        let query = HistoryQuery(pinboardIDs: [board.id], sortOrder: .pinboard)
        let expected = try store.searchMetadata(query).map(\.text)
        let archive = directory.appendingPathComponent("ranked.clipshelfbackup")
        try store.exportBackup(to: archive)
        let restored = try self.store("restored")
        let summary = try restored.restoreBackup(from: archive, mode: .replace)
        XCTAssertTrue(summary.identitiesRemapped)
        let restoredBoard = try XCTUnwrap(restored.pinboards().first)
        XCTAssertNotEqual(restoredBoard.id, board.id)
        XCTAssertEqual(try restored.searchMetadata(HistoryQuery(pinboardIDs: [restoredBoard.id], sortOrder: .pinboard)).map(\.text), expected)
    }

    func testVersionSixMigrationPreservesPriorBoardDisplayWithoutUploadingMigration() throws {
        let old = try store()
        try old.configureSync(accountID: "account")
        let (board, records) = try fixtures(old, count: 4)
        let before = try old.pendingSyncOperations(accountID: "account")
        try old.execute("UPDATE clipboard_records SET pinboard_order = NULL; DELETE FROM sync_dirty; PRAGMA user_version = 6")
        let migrated = try store()
        XCTAssertEqual(try ids(migrated, board.id), Array(records.map(\.id).reversed()))
        XCTAssertEqual(try migrated.pendingSyncOperations(accountID: "account"), before)
        XCTAssertTrue(try migrated.searchMetadata(HistoryQuery(pinboardIDs: [board.id])).allSatisfy { $0.pinboardOrder != nil })
    }

    func testFirstPostMigrationReorderPublishesUntouchedRanksWithoutChangingOldOperations() throws {
        let old = try store("old")
        try old.configureSync(accountID: "account")
        let (board, records) = try fixtures(old, count: 5)
        // Emulate v6 payloads, which contain no rank field. These operation IDs may already exist remotely.
        try old.execute("UPDATE sync_outbox SET payload = CAST(json_remove(CAST(payload AS TEXT), '$.record.pinboardOrder') AS BLOB)")
        let originalOperations = try old.pendingSyncOperations(accountID: "account")
        try old.execute("UPDATE clipboard_records SET pinboard_order = NULL; DELETE FROM sync_dirty; PRAGMA user_version = 6")
        let migrated = try store("old")
        XCTAssertEqual(try migrated.pendingSyncOperations(accountID: "account"), originalOperations)
        try migrated.move(recordIDs: [records[0].id], to: board.id, before: records[3].id)
        let changes = try migrated.pendingSyncOperations(accountID: "account")
        XCTAssertEqual(Array(changes.prefix(originalOperations.count)), originalOperations)
        XCTAssertEqual(Set(changes.dropFirst(originalOperations.count).map(\.entityID)), Set(records.map(\.id)))
        let peer = try store("peer")
        try peer.configureSync(accountID: "account")
        try peer.applyRemoteChanges(accountID: "account", changes: changes, nextCursor: nil)
        XCTAssertEqual(try ids(migrated, board.id), try ids(peer, board.id))
    }

    func testPrivateSyncPersistsRanksAndConcurrentOrderingDoesNotDuplicateContent() throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: "account"); try b.configureSync(accountID: "account")
        let (board, records) = try fixtures(a, count: 5)
        try transfer(a, b, account: "account")
        XCTAssertEqual(try ids(a, board.id), try ids(b, board.id))
        try a.move(recordIDs: [records[4].id], to: board.id, before: records[0].id)
        try b.move(recordIDs: [records[4].id], to: board.id, before: records[2].id)
        let operationsA = try a.pendingSyncOperations(accountID: "account"), operationsB = try b.pendingSyncOperations(accountID: "account")
        try a.applyRemoteChanges(accountID: "account", changes: operationsB, nextCursor: nil)
        try b.applyRemoteChanges(accountID: "account", changes: operationsA, nextCursor: nil)
        XCTAssertEqual(try ids(a, board.id), try ids(b, board.id))
        XCTAssertEqual(try a.load().count, records.count)
        XCTAssertEqual(try b.load().count, records.count)
        XCTAssertEqual(try ids(self.store("a"), board.id), try ids(b, board.id))
    }

    func testOrderAndTextEditsMergeIndependentlyAcrossPeersAndReplay() throws {
        let a = try store("a"), b = try store("b"), c = try store("replay")
        for device in [a, b, c] { try device.configureSync(accountID: "account") }
        let (board, records) = try fixtures(a, count: 4)
        let initial = try a.pendingSyncOperations(accountID: "account")
        try transfer(a, b, account: "account")
        let target = records[3].id
        try a.move(recordIDs: [target], to: board.id, before: records[0].id)
        var edit = try XCTUnwrap(b.item(id: target)); edit.text = "edited while another device drags"
        _ = try b.update(record: edit)
        let moved = try a.pendingSyncOperations(accountID: "account")
        let edited = try b.pendingSyncOperations(accountID: "account")
        XCTAssertTrue(moved.allSatisfy { $0.orderingOnly == true })
        XCTAssertTrue(edited.allSatisfy { $0.orderingOnly != true })
        try a.applyRemoteChanges(accountID: "account", changes: edited, nextCursor: nil)
        try b.applyRemoteChanges(accountID: "account", changes: moved, nextCursor: nil)
        // Replay reversed arrival, including causal children before their parents.
        try c.applyRemoteChanges(accountID: "account", changes: edited + moved + initial.reversed(), nextCursor: nil)
        for device in [a, b, c] {
            XCTAssertEqual(try device.item(id: target)?.text, edit.text)
            XCTAssertEqual(try ids(device, board.id), [target] + records.prefix(3).map(\.id))
            XCTAssertEqual(try device.load().count, records.count)
        }
        // A later local edit must preserve the merged order after restart.
        let reopened = try store("a")
        var later = try XCTUnwrap(reopened.item(id: target)); later.text = "later edit"
        _ = try reopened.update(record: later)
        XCTAssertEqual(try reopened.pendingSyncOperations(accountID: "account").last?.baseOperationID, edited.first?.operationID)
        try b.applyRemoteChanges(accountID: "account", changes: reopened.pendingSyncOperations(accountID: "account"), nextCursor: nil)
        XCTAssertEqual(try b.item(id: target)?.text, "later edit")
        XCTAssertEqual(try ids(b, board.id), try ids(reopened, board.id))
        XCTAssertEqual(try b.load().count, records.count)
    }

    func testConcurrentDeleteAndOrderDoNotCreateConflictCopyOrReviveContent() throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: "account"); try b.configureSync(accountID: "account")
        let (board, records) = try fixtures(a, count: 3)
        try transfer(a, b, account: "account")
        try a.move(recordIDs: [records[2].id], to: board.id, before: records[0].id)
        try b.delete(id: records[2].id)
        let moved = try a.pendingSyncOperations(accountID: "account"), deleted = try b.pendingSyncOperations(accountID: "account")
        try a.applyRemoteChanges(accountID: "account", changes: deleted, nextCursor: nil)
        try b.applyRemoteChanges(accountID: "account", changes: moved, nextCursor: nil)
        for device in [a, b] {
            XCTAssertNil(try device.item(id: records[2].id))
            XCTAssertEqual(try ids(device, board.id), records.prefix(2).map(\.id))
            XCTAssertEqual(try device.load().count, 2)
        }
    }

    func testFirstPostMigrationCreateReturnsPersistedRevisionWithoutMutatingUntouchedItems() throws {
        let old = try store()
        try old.configureSync(accountID: "account")
        let (board, records) = try fixtures(old, count: 3)
        try old.execute("UPDATE clipboard_records SET pinboard_order = NULL; DELETE FROM sync_dirty; PRAGMA user_version = 6")
        let migrated = try store()
        let created = try migrated.create(ClipboardRecord(text: "new after migration", pinboardID: board.id))
        XCTAssertEqual(try migrated.item(id: created.id), created)
        for record in records { XCTAssertEqual(try migrated.item(id: record.id)?.revision, record.revision) }
        var edited = created; edited.text = "immediately editable"
        XCTAssertNoThrow(try migrated.update(record: edited))
    }

    func testSharedSyncCarriesOrderAndReadOnlyParticipantCannotReorder() throws {
        let owner = try store("owner"), reader = try store("reader")
        try owner.configureSharing(accountID: "owner"); try reader.configureSharing(accountID: "reader")
        let (source, _) = try fixtures(owner, count: 4)
        let id = UUID()
        func descriptor(_ account: String) -> SharedBoardDescriptor {
            SharedBoardDescriptor(boardID: id, accountID: account, containerIdentifier: "iCloud.test.synthetic", zoneName: "synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        }
        _ = try owner.createSharedCopy(from: source.id, descriptor: descriptor("owner"))
        try reader.registerSharedBoard(descriptor("reader"), access: .readOnly)
        let initial = try owner.pendingSharedOperations(boardID: id, accountID: "owner")
        try reader.applySharedChanges(boardID: id, accountID: "reader", changes: initial, nextCursor: nil)
        try owner.acknowledgeSharedOperations(boardID: id, accountID: "owner", operationIDs: Set(initial.map(\.operationID)))
        let originals = try ids(owner, id)
        XCTAssertEqual(try ids(reader, id), originals)
        XCTAssertThrowsError(try reader.move(recordIDs: [originals[3]], to: id, before: originals[0]))
        XCTAssertThrowsError(try reader.reorderPinboardItems(boardID: id, orderedIDs: Array(originals.reversed())))
        try owner.move(recordIDs: [originals[3], originals[2]], to: id, before: originals[0])
        let pending = try owner.pendingSharedOperations(boardID: id, accountID: "owner")
        try reader.applySharedChanges(boardID: id, accountID: "reader", changes: pending, nextCursor: nil)
        XCTAssertEqual(try ids(reader, id), try ids(owner, id))
        XCTAssertEqual(try ids(reader, id).count, 4)
    }
}
