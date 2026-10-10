import Foundation
import XCTest
@testable import ClipShelfCore

final class PinboardReorderSnapshotTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite3") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-board-reorder-snapshot-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func store() throws -> HistoryStore { try HistoryStore(databaseURL: databaseURL) }

    private func boards(_ store: HistoryStore) throws -> [UUID] {
        try ["A", "B", "C"].map { try store.createPinboard(name: $0).id }
    }

    private func assertInvalidOrder(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            guard case HistoryStoreError.invalidPinboardOrder = error else {
                return XCTFail("Expected invalidPinboardOrder, got \(error)", file: file, line: line)
            }
        }
    }

    func testMatchingSnapshotPersistsPersonalOrderWithoutChangingBoardsOrSyncOperations() throws {
        let store = try store()
        try store.configureSync(accountID: "account")
        let original = try boards(store)
        let boardValues = try store.pinboardsWithoutLock()
        let operations = try store.pendingSyncOperations(accountID: "account")
        let changed = [original[2], original[0], original[1]]

        try store.reorderPinboards(ids: changed, expectedOrder: original)

        XCTAssertEqual(try store.pinboards().map(\.id), changed)
        XCTAssertEqual(try self.store().pinboards().map(\.id), changed)
        XCTAssertEqual(try store.pinboardsWithoutLock(), boardValues)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), operations)
    }

    func testConcurrentSameSetReorderRejectsStaleSnapshotWithoutOverwritingNewOrder() throws {
        let store = try store(), original = try boards(store)
        let otherConnection = try self.store()
        let concurrentOrder = [original[2], original[0], original[1]]
        try otherConnection.reorderPinboards(ids: concurrentOrder, expectedOrder: original)

        assertInvalidOrder {
            try store.reorderPinboards(ids: [original[1], original[2], original[0]], expectedOrder: original)
        }

        XCTAssertEqual(try store.pinboards().map(\.id), concurrentOrder)
        XCTAssertEqual(try self.store().pinboards().map(\.id), concurrentOrder)
    }

    func testNewBoardRejectsSnapshotEvenWhenProposedOrderContainsEveryCurrentBoard() throws {
        let store = try store(), original = try boards(store)
        try store.reorderPinboards(ids: original)
        let added = try self.store().createPinboard(name: "Received after drag started")
        let current = try store.pinboards()
        XCTAssertEqual(current.map(\.id), original + [added.id])

        assertInvalidOrder {
            try store.reorderPinboards(ids: Array(current.map(\.id).reversed()), expectedOrder: original)
        }

        XCTAssertEqual(try store.pinboards(), current)
        XCTAssertEqual(try self.store().pinboards(), current)
    }

    func testDeletedBoardRejectsSnapshotEvenWhenProposedOrderContainsOnlySurvivingBoards() throws {
        let store = try store(), original = try boards(store)
        try store.reorderPinboards(ids: original)
        try self.store().deletePinboard(id: original[1])
        let current = try store.pinboards()
        XCTAssertEqual(current.map(\.id), [original[0], original[2]])

        assertInvalidOrder {
            try store.reorderPinboards(ids: [original[2], original[0]], expectedOrder: original)
        }

        XCTAssertEqual(try store.pinboards(), current)
        XCTAssertEqual(try self.store().pinboards(), current)
    }

    func testMatchingSnapshotStillRequiresCompleteUniqueProposedOrder() throws {
        let store = try store(), original = try boards(store)
        try store.reorderPinboards(ids: original)
        let invalidOrders = [Array(original.dropLast()), [original[0], original[0], original[2]],
                             [original[0], original[1], UUID()]]

        for invalid in invalidOrders {
            assertInvalidOrder { try store.reorderPinboards(ids: invalid, expectedOrder: original) }
            XCTAssertEqual(try store.pinboards().map(\.id), original)
        }
        XCTAssertEqual(try self.store().pinboards().map(\.id), original)
    }

    func testWriteFailureRollsBackSnapshotReorderAndSameSnapshotCanBeRetried() throws {
        let store = try store()
        try store.configureSync(accountID: "account")
        let original = try boards(store)
        try store.reorderPinboards(ids: original)
        let boardValues = try store.pinboardsWithoutLock()
        let operations = try store.pendingSyncOperations(accountID: "account")
        let changed = Array(original.reversed())
        try store.execute("CREATE TRIGGER fail_snapshot_reorder BEFORE INSERT ON pinboard_local_order WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END")

        XCTAssertThrowsError(try store.reorderPinboards(ids: changed, expectedOrder: original)) { error in
            guard case HistoryStoreError.database = error else { return XCTFail("Expected injected database failure, got \(error)") }
        }
        XCTAssertEqual(try store.pinboards().map(\.id), original)
        XCTAssertEqual(try self.store().pinboards().map(\.id), original)
        XCTAssertEqual(try store.pinboardsWithoutLock(), boardValues)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), operations)

        try store.execute("DROP TRIGGER fail_snapshot_reorder")
        try store.reorderPinboards(ids: changed, expectedOrder: original)
        XCTAssertEqual(try self.store().pinboards().map(\.id), changed)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), operations)
    }

    func testMatchingSnapshotCanReorderReadOnlySharedBoardWithoutSharedWrites() throws {
        let store = try store()
        try store.configureSharing(accountID: "reader")
        let local = try store.createPinboard(name: "Local")
        let shared = Pinboard(name: "Read only")
        let descriptor = SharedBoardDescriptor(boardID: shared.id, accountID: "reader", containerIdentifier: "iCloud.test.synthetic",
                                               zoneName: "synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        try store.registerSharedBoard(descriptor, access: .readOnly)
        let operation = SyncOperation(accountID: descriptor.namespace, entityID: shared.id, entityKind: .pinboard,
                                      action: .upsert, baseRevision: 0, revision: 1, pinboard: shared)
        try store.applySharedChanges(boardID: shared.id, accountID: "reader", changes: [operation], nextCursor: nil)
        let original = try store.pinboards().map(\.id)
        let boardValues = try store.pinboardsWithoutLock()

        try store.reorderPinboards(ids: [shared.id, local.id], expectedOrder: original)

        XCTAssertEqual(try self.store().pinboards().map(\.id), [shared.id, local.id])
        XCTAssertEqual(try store.pinboardsWithoutLock(), boardValues)
        try store.updateSharedAccess(boardID: shared.id, accountID: "reader", access: .readWrite)
        XCTAssertTrue(try store.pendingSharedOperations(boardID: shared.id, accountID: "reader").isEmpty)
    }
}
