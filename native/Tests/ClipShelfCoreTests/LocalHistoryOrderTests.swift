import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class LocalHistoryOrderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-order-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite"))
    }
    private func insertRestored(_ record: ClipboardRecord, order: Int64, into store: HistoryStore) throws {
        try store.transaction { try store.insert(record, historyOrder: order) }
    }
    private func counter(_ store: HistoryStore) throws -> Int64 {
        try XCTUnwrap(store.syncScalar("SELECT last_position FROM history_order_state WHERE singleton = 1", []).flatMap(Int64.init))
    }
    private func downgradeToActualThirteen(_ store: HistoryStore) throws {
        try store.execute("""
            DROP TRIGGER history_order_insert; DROP TRIGGER history_order_update;
            DROP INDEX clipboard_local_history_order; DROP TABLE history_order_state;
            ALTER TABLE clipboard_records DROP COLUMN local_history_order;
            ALTER TABLE clipboard_records DROP COLUMN pinboard_order_identity;
            PRAGMA user_version = 13;
            """)
    }
    private func assertInvalid<T>(_ block: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try block(), file: file, line: line) { error in
            guard case HistoryStoreError.invalidStoredRecord = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    func testRestoredSlotSurvivesNewCapturesAndEveryHistoryProjection() throws {
        let value = try store()
        let originals = try (0..<5).map { index in
            try value.create(ClipboardRecord(text: "searchable item \(index)", copiedAt: Date(timeIntervalSince1970: Double(100 - index))))
        }
        let oldOrder = try value.historyOrderWithoutLock(id: originals[2].id)
        try value.delete(id: originals[2].id)
        let newest = try value.create(ClipboardRecord(text: "searchable newest"))
        try insertRestored(originals[2], order: oldOrder, into: value)
        let expected = [newest.id] + originals.reversed().map(\.id)
        let query = HistoryQuery(text: "searchable")
        XCTAssertEqual(try value.load().map(\.id), expected)
        XCTAssertEqual(try value.search(query).map(\.id), expected)
        XCTAssertEqual(try value.searchMetadata(query).map(\.id), expected)
        XCTAssertEqual(try value.selectionSnapshot(query).references.map(\.id), expected)
        XCTAssertEqual(try value.metadataOffset(of: originals[2].id, query: query), 3)
        XCTAssertEqual(try value.metadataPage(query, anchorID: originals[2].id).focusID, originals[2].id)
        XCTAssertEqual(try value.searchIntegrationMetadata(query, expectedSyncConfiguration: value.syncConfiguration(),
                                                         expectedSharingConfiguration: value.sharingConfiguration()).map(\.id), expected)
        XCTAssertEqual(try store().load().map(\.id), expected)
    }

    func testCounterNeverReusesDeletedTailOrClearedLibraryPositions() throws {
        let value = try store()
        let old = try value.create(ClipboardRecord(text: "old"))
        let oldOrder = try value.historyOrderWithoutLock(id: old.id)
        try value.clear()
        let reopened = try store()
        let fresh = try reopened.create(ClipboardRecord(text: "fresh"))
        XCTAssertGreaterThan(try reopened.historyOrderWithoutLock(id: fresh.id), oldOrder)
        try insertRestored(old, order: oldOrder, into: reopened)
        XCTAssertEqual(try reopened.load().map(\.id), [fresh.id, old.id])
        let highWater = try counter(reopened)
        try reopened.clear()
        XCTAssertEqual(try counter(store()), highWater)
    }

    func testRestoringAnOlderCaptureDoesNotChangeAdjacentDuplicateSemantics() throws {
        let value = try store()
        let first = try value.record(ClipboardRecord(text: "first"))
        let position = try value.historyOrderWithoutLock(id: first.id)
        let second = try value.record(ClipboardRecord(text: "second"))
        try value.delete(id: first.id)
        try insertRestored(first, order: position, into: value)
        let highWater = try counter(value)
        let repeated = try value.record(ClipboardRecord(text: "second", copiedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(repeated.id, second.id)
        XCTAssertEqual(try counter(value), highWater)
        XCTAssertEqual(try value.load().map(\.id), [second.id, first.id])
    }

    func testRawInsertAllocatesOrderAndKeepsFTSOnActualRowID() throws {
        let value = try store(), id = UUID()
        try value.transaction {
            try value.syncExecute("INSERT INTO clipboard_records(id,text,copied_at) VALUES (?, ?, 1)", [id.uuidString, "searchable raw row"])
        }
        XCTAssertGreaterThan(try value.historyOrderWithoutLock(id: id), 0)
        XCTAssertEqual(try value.search(.init(text: "searchable raw")).map(\.id), [id])
    }

    func testDuplicateOrUnallocatedRestorationSlotRollsBackWholeInsertAndCounter() throws {
        let value = try store(), existing = try value.create(ClipboardRecord(text: "existing"))
        let highWater = try counter(value), proposed = ClipboardRecord(text: "must not survive")
        XCTAssertThrowsError(try insertRestored(proposed, order: value.historyOrderWithoutLock(id: existing.id), into: value))
        XCTAssertNil(try value.item(id: proposed.id))
        XCTAssertEqual(try counter(value), highWater)
        assertInvalid { try insertRestored(proposed, order: highWater + 1, into: value) }
        assertInvalid { try insertRestored(proposed, order: 0, into: value) }
        XCTAssertEqual(try value.load().map(\.id), [existing.id])
    }

    func testCorruptOrExhaustedCounterCannotCommitNewCapture() throws {
        let value = try store(), existing = try value.create(ClipboardRecord(text: "existing"))
        try value.execute("UPDATE history_order_state SET last_position = 0")
        XCTAssertThrowsError(try value.create(ClipboardRecord(text: "counter moved backwards")))
        XCTAssertEqual(try value.load().map(\.id), [existing.id])
        assertInvalid { try store() }
        try value.execute("UPDATE history_order_state SET last_position = 9223372036854775807")
        XCTAssertThrowsError(try value.create(ClipboardRecord(text: "overflow")))
        XCTAssertEqual(try counter(value), Int64.max)
        try value.execute("DELETE FROM history_order_state")
        XCTAssertThrowsError(try value.create(ClipboardRecord(text: "missing counter")))
        assertInvalid { try store() }
        XCTAssertEqual(try value.load().map(\.id), [existing.id])
    }

    func testActualSchemaThirteenMigrationPreservesRowOrderTokensAndPendingOperations() throws {
        let value = try store()
        try value.configureSync(accountID: "account")
        let records = try (0..<4).map { try value.create(ClipboardRecord(text: "legacy \($0)")) }
        try value.delete(id: records[1].id)
        let expected = try value.load().map(\.id)
        let tokens = try expected.map { try value.syncScalar("SELECT hex(token) FROM history_cleanup_tokens WHERE record_id = ?", [$0.uuidString]) }
        let pending = try value.pendingSyncOperations(accountID: "account")
        try downgradeToActualThirteen(value)
        let migrated = try store()
        XCTAssertEqual(try migrated.load().map(\.id), expected)
        XCTAssertEqual(try migrated.pendingSyncOperations(accountID: "account"), pending)
        XCTAssertEqual(try expected.map { try migrated.syncScalar("SELECT hex(token) FROM history_cleanup_tokens WHERE record_id = ?", [$0.uuidString]) }, tokens)
        XCTAssertEqual(try counter(migrated), 3)
        XCTAssertEqual(try migrated.syncScalar("PRAGMA user_version", []), "14")
        let fresh = try migrated.create(ClipboardRecord(text: "after migration"))
        XCTAssertEqual(try migrated.historyOrderWithoutLock(id: fresh.id), 4)
    }

    func testFailedMigrationRollsBackColumnAndRestoresOriginalTriggers() throws {
        let value = try store(), old = try value.create(ClipboardRecord(text: "original"))
        try downgradeToActualThirteen(value)
        try value.execute("CREATE TABLE history_order_state(blocked TEXT)")
        XCTAssertThrowsError(try store())
        XCTAssertEqual(try value.syncScalar("PRAGMA user_version", []), "13")
        XCTAssertEqual(try value.syncScalar("SELECT name FROM sqlite_master WHERE name = 'history_cleanup_update'", []), "history_cleanup_update")
        XCTAssertEqual(try value.syncScalar("SELECT id FROM clipboard_records", []), old.id.uuidString)
        XCTAssertThrowsError(try value.prepare("SELECT local_history_order FROM clipboard_records"))
    }

    func testCurrentSchemaRejectsMissingIndexOrSubstitutedTriggerWithoutRepair() throws {
        let value = try store()
        try value.execute("DROP INDEX clipboard_local_history_order")
        assertInvalid { try store() }
        XCTAssertNil(try value.syncScalar("SELECT name FROM sqlite_master WHERE name = 'clipboard_local_history_order'", []))
        try value.execute("CREATE UNIQUE INDEX clipboard_local_history_order ON clipboard_records(local_history_order)")
        try value.execute("DROP TRIGGER history_order_insert; CREATE TRIGGER history_order_insert AFTER INSERT ON clipboard_records BEGIN SELECT 1; END")
        assertInvalid { try store() }
    }

    func testOrderColumnCannotBeClearedAndCorruptProjectionFailsExplicitly() throws {
        let value = try store(), item = try value.create(ClipboardRecord(text: "original"))
        XCTAssertThrowsError(try value.syncExecute("UPDATE clipboard_records SET local_history_order = NULL WHERE id = ?", [item.id.uuidString]))
        try value.execute("DROP TRIGGER history_order_update")
        try value.syncExecute("UPDATE clipboard_records SET local_history_order = NULL WHERE id = ?", [item.id.uuidString])
        assertInvalid { try value.load() }
        assertInvalid { try value.searchMetadata(.init()) }
        assertInvalid { try value.item(id: item.id) }
        assertInvalid { try value.selectionSnapshot(.init()) }
        assertInvalid { try value.metadataOffset(of: item.id, query: .init()) }
    }

    func testBackupExportRestorePreservesVisibleOrderAndNeverImportsCounter() throws {
        let source = try store("source")
        let records = try (0..<3).map { try source.create(ClipboardRecord(text: "archive \($0)")) }
        let oldOrder = try source.historyOrderWithoutLock(id: records[1].id)
        try source.delete(id: records[1].id)
        try insertRestored(records[1], order: oldOrder, into: source)
        let archive = directory.appendingPathComponent("library.clipshelfbackup")
        try source.exportBackup(to: archive)
        let target = try store("target")
        for index in 0..<8 { _ = try target.create(ClipboardRecord(text: "existing \(index)")) }
        let previous = try counter(target)
        _ = try target.restoreBackup(from: archive, mode: .replace)
        XCTAssertEqual(try target.load().map(\.id), records.reversed().map(\.id))
        XCTAssertGreaterThan(try target.historyOrderWithoutLock(id: records[0].id), previous)
        XCTAssertEqual(try counter(target), previous + 3)
    }

    func testHistoryFirstPageUsesOrderIndexWithoutTemporarySort() throws {
        let value = try store()
        let plan = try value.prepare("EXPLAIN QUERY PLAN SELECT \(HistoryStore.columns) FROM clipboard_records WHERE is_in_history = 1 ORDER BY local_history_order DESC LIMIT 300")
        defer { sqlite3_finalize(plan) }
        var details = ""
        while sqlite3_step(plan) == SQLITE_ROW { details += (value.textColumn(plan, 3) ?? "") + "\n" }
        XCTAssertTrue(details.contains("clipboard_local_history_order"), details)
        XCTAssertFalse(details.contains("TEMP B-TREE"), details)
    }
}
