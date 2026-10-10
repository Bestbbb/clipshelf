import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

private final class StartupSQLTrace {
    var statements: [String] = []
    var beforeBeginNumber: Int?
    var beforeBegin: (() throws -> Void)?
    var beginCount = 0
    var interceptedBegins = 0
    var callbackError: Error?

    var backfills: [String] {
        statements.filter { sql in
            sql.contains("select") && [
                "insert or ignore into history_cleanup_tokens",
                "insert or ignore into sync_content_heads",
                "insert or ignore into sync_order_heads"
            ].contains { sql.hasPrefix($0) }
        }
    }

    func install(on connection: OpaquePointer) throws {
        let status = sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            let probe = Unmanaged<StartupSQLTrace>.fromOpaque(context).takeUnretainedValue()
            let normalized = String(cString: sql).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            probe.statements.append(normalized)
            if normalized == "begin immediate" {
                probe.beginCount += 1
                if probe.beginCount == probe.beforeBeginNumber, let action = probe.beforeBegin {
                    // TRACE_STMT runs before BEGIN acquires the writer lock. The other connection
                    // finishes synchronously, avoiding timing-dependent sleeps or background work.
                    probe.beforeBegin = nil
                    probe.interceptedBegins += 1
                    do { try action() } catch { probe.callbackError = error }
                }
            }
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
        guard status == SQLITE_OK else { throw HistoryStoreError.database(code: status, message: "Unable to attach fixture trace") }
    }
}

final class StartupBackfillTests: XCTestCase {
    private enum FixtureFailure: Error { case connectionSetup }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-backfill-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func store(_ name: String = "local", trace: StartupSQLTrace? = nil) throws -> HistoryStore {
        let url = directory.appendingPathComponent(name + "/history.sqlite")
        guard let trace else { return try HistoryStore(databaseURL: url) }
        let value = try HistoryStore(databaseURL: url, configureConnection: { try trace.install(on: $0) })
        sqlite3_trace_v2(value.database, 0, nil, nil)
        return value
    }

    private func rows(_ store: HistoryStore, _ sql: String) throws -> [[String?]] {
        let statement = try store.prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            try store.check(status, allowingRow: true)
            result.append((0..<sqlite3_column_count(statement)).map { store.textColumn(statement, $0) })
        }
    }

    private func token(_ store: HistoryStore, _ id: UUID) throws -> String? {
        try store.syncScalar("SELECT hex(token) FROM history_cleanup_tokens WHERE record_id = ?", [id.uuidString])
    }

    private func fixture(_ store: HistoryStore) throws -> (Pinboard, [ClipboardRecord]) {
        try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Fixture")
        let records = try (0..<4).map { try store.create(ClipboardRecord(text: "item \($0)", pinboardID: board.id)) }
        return (board, records)
    }

    private func dropCleanupSchema(_ store: HistoryStore) throws {
        try store.execute("DROP TRIGGER history_cleanup_insert; DROP TRIGGER history_cleanup_update; DROP TRIGGER history_cleanup_delete; DROP TABLE history_cleanup_tokens")
    }

    private func assertCorrupt<T>(_ operation: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case HistoryStoreError.invalidStoredRecord = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    func testCurrentSchemaReopenExecutesNoBackfillsAndPreservesLiveConfirmation() throws {
        let original = try store()
        let (_, records) = try fixture(original)
        let tokens = try rows(original, "SELECT record_id, hex(token) FROM history_cleanup_tokens ORDER BY record_id")
        let content = try rows(original, "SELECT * FROM sync_content_heads ORDER BY entity_id")
        let order = try rows(original, "SELECT * FROM sync_order_heads ORDER BY entity_id")
        let outbox = try rows(original, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid")
        let plan = try original.prepareHistoryCleanup()
        let trace = StartupSQLTrace(), reopened = try store(trace: trace)
        XCTAssertTrue(trace.statements.contains { $0 == "pragma user_version" }, "Trace must include the actual connection migration")
        XCTAssertTrue(trace.statements.contains { $0.contains("pragma table_info(history_cleanup_tokens)") })
        XCTAssertEqual(trace.backfills, [])
        XCTAssertEqual(try rows(reopened, "SELECT record_id, hex(token) FROM history_cleanup_tokens ORDER BY record_id"), tokens)
        XCTAssertEqual(try rows(reopened, "SELECT * FROM sync_content_heads ORDER BY entity_id"), content)
        XCTAssertEqual(try rows(reopened, "SELECT * FROM sync_order_heads ORDER BY entity_id"), order)
        XCTAssertEqual(try rows(reopened, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid"), outbox)
        XCTAssertEqual(try original.commitHistoryCleanup(plan).summary.preservedPinnedCount, records.count)
    }

    func testThrowingConnectionInstrumentationReleasesItsWriterLock() throws {
        let original = try store(), record = try original.create(ClipboardRecord(text: "survives setup failure"))
        XCTAssertThrowsError(try HistoryStore(databaseURL: original.databaseURL, configureConnection: { connection in
            guard sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw HistoryStoreError.invalidStoredRecord
            }
            throw FixtureFailure.connectionSetup
        })) { error in
            guard case FixtureFailure.connectionSetup = error else { return XCTFail("Unexpected error: \(error)") }
        }
        // A leaked connection would retain the writer lock and make migration on reopen fail.
        let reopened = try store()
        XCTAssertEqual(try reopened.item(id: record.id), record)
        _ = try reopened.create(ClipboardRecord(text: "writable after setup failure"))
    }

    func testNewDatabaseRechecksVersionAfterAnotherConnectionInitializesBeforeWriterLock() throws {
        let trace = StartupSQLTrace(), peerTrace = StartupSQLTrace()
        var created: ClipboardRecord?, createdToken: String?
        trace.beforeBeginNumber = 1
        trace.beforeBegin = {
            let peer = try self.store("new-race", trace: peerTrace)
            let record = try peer.create(ClipboardRecord(text: "created by the first writer"))
            created = record
            createdToken = try self.token(peer, record.id)
        }
        let opened = try store("new-race", trace: trace)
        XCTAssertNil(trace.callbackError)
        XCTAssertEqual(trace.interceptedBegins, 1)
        XCTAssertEqual(peerTrace.backfills.count, 3, "The first writer installs all three empty baselines")
        XCTAssertTrue(trace.backfills.isEmpty, "The waiting opener must use the version committed by the first writer")
        let record = try XCTUnwrap(created)
        XCTAssertEqual(try opened.item(id: record.id), record)
        XCTAssertEqual(try token(opened, record.id), createdToken)
        XCTAssertEqual(try opened.syncScalar("PRAGMA user_version", []), "14")
    }

    func testVersionSixRechecksVersionAfterBackupAndConcurrentMigration() throws {
        let original = try store("upgrade-race")
        let (_, records) = try fixture(original)
        let outbox = try rows(original, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid")
        try dropCleanupSchema(original)
        try original.execute("DROP TABLE sync_content_heads; DROP TABLE sync_order_heads; PRAGMA user_version = 6")
        let trace = StartupSQLTrace(), peerTrace = StartupSQLTrace()
        var peerTokens: [[String?]] = [], peerHeads: [[String?]] = []
        trace.beforeBeginNumber = 2 // Recovery backup owns the first BEGIN; migration owns the second.
        trace.beforeBegin = {
            let peer = try self.store("upgrade-race", trace: peerTrace)
            peerTokens = try self.rows(peer, "SELECT record_id, hex(token) FROM history_cleanup_tokens ORDER BY record_id")
            peerHeads = try self.rows(peer, "SELECT * FROM sync_content_heads ORDER BY entity_id")
        }
        let opened = try store("upgrade-race", trace: trace)
        XCTAssertNil(trace.callbackError)
        XCTAssertEqual(trace.interceptedBegins, 1)
        XCTAssertEqual(trace.beginCount, 2)
        XCTAssertTrue(trace.statements.contains("rollback"), "The recovery snapshot completes before the competing upgrade")
        XCTAssertEqual(peerTrace.backfills.count, 3)
        XCTAssertTrue(trace.backfills.isEmpty, "The second migration must not repeat the first connection's backfills")
        XCTAssertEqual(try rows(opened, "SELECT record_id, hex(token) FROM history_cleanup_tokens ORDER BY record_id"), peerTokens)
        XCTAssertEqual(try rows(opened, "SELECT * FROM sync_content_heads ORDER BY entity_id"), peerHeads)
        XCTAssertEqual(try rows(opened, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid"), outbox)
        XCTAssertEqual(try opened.load().count, records.count)
        XCTAssertEqual(try opened.syncScalar("PRAGMA user_version", []), "14")
    }

    func testVersionSixActuallyBackfillsBothHeadsAndTokensWithoutChangingOutbox() throws {
        let original = try store()
        let (board, records) = try fixture(original)
        let heads = try rows(original, "SELECT * FROM sync_heads ORDER BY entity_id")
        let outbox = try rows(original, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid")
        try dropCleanupSchema(original)
        try original.execute("DROP TABLE sync_content_heads; DROP TABLE sync_order_heads; UPDATE clipboard_records SET pinboard_order = NULL; DELETE FROM sync_dirty; PRAGMA user_version = 6")
        let trace = StartupSQLTrace(), migrated = try store(trace: trace)
        XCTAssertEqual(trace.backfills.count, 3)
        XCTAssertEqual(try migrated.syncScalar("PRAGMA user_version", []), "14")
        XCTAssertEqual(try rows(migrated, "SELECT * FROM sync_content_heads ORDER BY entity_id"), heads)
        XCTAssertEqual(try rows(migrated, "SELECT entity_id, operation_id FROM sync_order_heads ORDER BY entity_id"),
                       try rows(migrated, "SELECT entity_id, operation_id FROM sync_heads WHERE entity_kind='clipboard' ORDER BY entity_id"))
        XCTAssertEqual(try rows(migrated, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid"), outbox)
        XCTAssertEqual(try migrated.syncScalar("SELECT COUNT(*) FROM history_cleanup_tokens WHERE length(token)=16", []), String(records.count))
        XCTAssertEqual(try migrated.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id), records.reversed().map(\.id))
        try migrated.move(recordIDs: [records[0].id], to: board.id, before: records[3].id)
        let peer = try store("peer")
        try peer.configureSync(accountID: "account")
        try peer.applyRemoteChanges(accountID: "account", changes: migrated.pendingSyncOperations(accountID: "account"), nextCursor: nil)
        XCTAssertEqual(try peer.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id),
                       try migrated.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id))
        let secondTrace = StartupSQLTrace()
        _ = try store(trace: secondTrace)
        XCTAssertTrue(secondTrace.backfills.isEmpty)
    }

    func testVersionNineOnlyBackfillsTokensAndFutureMutationsKeepThemCurrent() throws {
        let original = try store(), first = try original.create(ClipboardRecord(text: "first", rtf: Data([1])))
        try dropCleanupSchema(original)
        try original.execute("PRAGMA user_version = 9")
        let trace = StartupSQLTrace(), migrated = try store(trace: trace)
        XCTAssertEqual(trace.backfills.count, 1)
        XCTAssertTrue(trace.backfills[0].hasPrefix("insert or ignore into history_cleanup_tokens"))
        let initialToken = try XCTUnwrap(token(migrated, first.id)), plan = try migrated.prepareHistoryCleanup()
        let peer = try store()
        XCTAssertEqual(try token(peer, first.id), initialToken)
        try peer.syncExecute("UPDATE clipboard_records SET rtf = X'02' WHERE id = ?", [first.id.uuidString])
        XCTAssertNotEqual(try token(peer, first.id), initialToken)
        XCTAssertThrowsError(try migrated.commitHistoryCleanup(plan))
        try peer.delete(id: first.id)
        XCTAssertNil(try token(peer, first.id))
        try peer.synchronized { try peer.transaction { try peer.insert(first) } }
        XCTAssertNotEqual(try token(peer, first.id), initialToken)
        XCTAssertEqual(try migrated.commitHistoryCleanup(migrated.prepareHistoryCleanup()).summary.deletedCount, 1)
    }

    func testCurrentSchemaMissingHeadOrTokenTableIsRejectedWithoutReconstruction() throws {
        for table in ["sync_heads", "sync_content_heads", "sync_order_heads", "history_cleanup_tokens"] {
            let name = "missing-" + table, original = try store(name)
            let (_, records) = try fixture(original)
            try original.execute("DROP TABLE \(table)")
            assertCorrupt { try self.store(name) }
            XCTAssertNil(try original.syncScalar("SELECT type FROM sqlite_master WHERE name = ?", [table]))
            XCTAssertEqual(try original.item(id: records[0].id), records[0])
            XCTAssertEqual(try original.syncScalar("PRAGMA user_version", []), "14")
        }
    }

    func testCurrentSchemaViewWrongColumnsAndMissingKeyAreRejected() throws {
        let replacements = [
            "CREATE VIEW sync_content_heads AS SELECT account_id, entity_kind, entity_id, operation_id, revision FROM sync_heads",
            "CREATE TABLE sync_content_heads(account_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, operation_id TEXT NOT NULL, revision INTEGER NOT NULL)",
            "CREATE TABLE sync_content_heads(account_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, operation_id TEXT NOT NULL, revision BLOB NOT NULL, PRIMARY KEY(account_id, entity_kind, entity_id))"
        ]
        for (index, replacement) in replacements.enumerated() {
            let name = "malformed-\(index)", original = try store(name)
            _ = try fixture(original)
            try original.execute("DROP TABLE sync_content_heads; " + replacement)
            assertCorrupt { try self.store(name) }
        }
        let missingCascade = try store("cascade")
        try dropCleanupSchema(missingCascade)
        try missingCascade.execute("CREATE TABLE history_cleanup_tokens(record_id TEXT PRIMARY KEY, token BLOB NOT NULL CHECK(length(token)=16))")
        assertCorrupt { try self.store("cascade") }
    }

    func testCurrentSchemaRejectsNonNullableOrderingBoard() throws {
        let original = try store()
        _ = try fixture(original)
        try original.execute("""
            DROP TABLE sync_order_heads;
            CREATE TABLE sync_order_heads(account_id TEXT NOT NULL, entity_id TEXT NOT NULL,
                operation_id TEXT NOT NULL, board_id TEXT NOT NULL, PRIMARY KEY(account_id, entity_id));
            """)
        assertCorrupt { try self.store() }
        XCTAssertEqual(try original.syncScalar("PRAGMA user_version", []), "14")
    }

    func testExplicitNotNullCleanupPrimaryKeyRemainsCompatible() throws {
        let original = try store()
        // Explicit NOT NULL on a TEXT primary key is equivalent for our UUID-backed tokens.
        try dropCleanupSchema(original)
        try original.execute("""
            CREATE TABLE history_cleanup_tokens(record_id TEXT PRIMARY KEY NOT NULL REFERENCES clipboard_records(id) ON DELETE CASCADE,
                token BLOB NOT NULL CHECK(length(token)=16));
            PRAGMA user_version = 9;
            """)
        let migrated = try store(), record = try migrated.create(ClipboardRecord(text: "explicit primary key"))
        let trace = StartupSQLTrace(), reopened = try store(trace: trace)
        XCTAssertTrue(trace.backfills.isEmpty)
        XCTAssertEqual(try token(reopened, record.id), try token(migrated, record.id))
        XCTAssertEqual(try reopened.commitHistoryCleanup(reopened.prepareHistoryCleanup()).summary.deletedCount, 1)
    }

    func testCurrentSchemaMissingOrIncorrectTokenTriggersAreRejectedWithoutRepair() throws {
        let bodies: [String?] = [
            nil,
            "CREATE TRIGGER history_cleanup_update AFTER UPDATE ON clipboard_records BEGIN SELECT 1; END",
            "CREATE TRIGGER history_cleanup_update AFTER UPDATE OF text ON clipboard_records BEGIN INSERT OR REPLACE INTO history_cleanup_tokens(record_id, token) VALUES(NEW.id, randomblob(16)); END",
            "CREATE TRIGGER history_cleanup_update AFTER UPDATE ON clipboard_records WHEN 0 BEGIN INSERT INTO history_cleanup_tokens(record_id, token) VALUES(NEW.id, randomblob(16)) ON CONFLICT(record_id) DO UPDATE SET token=excluded.token; END",
            "CREATE TRIGGER history_cleanup_update AFTER UPDATE ON clipboard_records BEGIN INSERT INTO history_cleanup_tokens(record_id, token) VALUES(NEW.id, zeroblob(16)) ON CONFLICT(record_id) DO UPDATE SET token=excluded.token; END",
            "CREATE TRIGGER history_cleanup_update AFTER UPDATE ON pinboards BEGIN SELECT 1; END"
        ]
        for (index, body) in bodies.enumerated() {
            let name = "trigger-\(index)", original = try store(name)
            let record = try original.create(ClipboardRecord(text: "untouched"))
            let before = try token(original, record.id)
            try original.execute("DROP TRIGGER history_cleanup_update")
            if let body { try original.execute(body) }
            let storedDefinition = try original.syncScalar("SELECT sql FROM sqlite_master WHERE name='history_cleanup_update'", [])
            assertCorrupt { try self.store(name) }
            XCTAssertEqual(try original.syncScalar("SELECT sql FROM sqlite_master WHERE name='history_cleanup_update'", []), storedDefinition)
            XCTAssertEqual(try token(original, record.id), before)
        }
    }

    func testEquivalentQuotedTriggerDDLRemainsUsableWithoutRotatingExistingToken() throws {
        let original = try store(), record = try original.create(ClipboardRecord(text: "before", rtf: Data([1])))
        let before = try token(original, record.id)
        try original.execute("""
            DROP TRIGGER history_cleanup_update;
            create trigger if not exists "HISTORY_CLEANUP_UPDATE"
            after update on [CLIPBOARD_RECORDS] for each row begin
                -- Equivalent conflict handling, with differently quoted identifiers.
                insert or replace into `history_cleanup_tokens`("record_id", [token])
                values (new."id", /* fresh on every update */ RANDOMBLOB(16));
            end;
            """)
        let trace = StartupSQLTrace(), reopened = try store(trace: trace)
        XCTAssertTrue(trace.backfills.isEmpty)
        XCTAssertEqual(try token(reopened, record.id), before)
        try reopened.syncExecute("UPDATE clipboard_records SET rtf=X'02' WHERE id=?", [record.id.uuidString])
        XCTAssertNotEqual(try token(reopened, record.id), before)
    }

    func testMissingTokenRowIsNotSilentlyBackfilledAndCleanupFailsClosed() throws {
        let original = try store()
        let first = try original.create(ClipboardRecord(text: "first")), second = try original.create(ClipboardRecord(text: "second"))
        let plan = try original.prepareHistoryCleanup()
        try original.syncExecute("DELETE FROM history_cleanup_tokens WHERE record_id=?", [second.id.uuidString])
        let trace = StartupSQLTrace(), reopened = try store(trace: trace)
        XCTAssertTrue(trace.backfills.isEmpty)
        XCTAssertNil(try token(reopened, second.id))
        XCTAssertThrowsError(try reopened.prepareHistoryCleanup())
        XCTAssertThrowsError(try original.commitHistoryCleanup(plan))
        XCTAssertEqual(try reopened.item(id: first.id), first)
        XCTAssertEqual(try reopened.item(id: second.id), second)
    }

    func testReopenPreservesDivergentContentAndOrderingHeadsForFollowingEditAndDelete() throws {
        let a = try store("a"), b = try store("b")
        let (board, records) = try fixture(a)
        try b.configureSync(accountID: "account")
        let initial = try a.pendingSyncOperations(accountID: "account")
        try b.applyRemoteChanges(accountID: "account", changes: initial, nextCursor: nil)
        try a.acknowledgeSyncOperations(accountID: "account", operationIDs: Set(initial.map(\.operationID)))
        let target = records[3].id
        let content = try XCTUnwrap(a.syncHead(accountID: "account", kind: .clipboard, id: target, table: "sync_content_heads"))
        try a.move(recordIDs: [target], to: board.id, before: records[0].id)
        let ordering = try XCTUnwrap(a.syncOrderHead(accountID: "account", id: target))
        XCTAssertNotEqual(content.id, ordering.id)
        let trace = StartupSQLTrace(), reopened = try store("a", trace: trace)
        XCTAssertTrue(trace.backfills.isEmpty)
        XCTAssertEqual(try reopened.syncHead(accountID: "account", kind: .clipboard, id: target, table: "sync_content_heads")?.id, content.id)
        XCTAssertEqual(try reopened.syncOrderHead(accountID: "account", id: target)?.id, ordering.id)
        var edited = try XCTUnwrap(reopened.item(id: target)); edited.text = "edited after reopening"
        _ = try reopened.update(record: edited)
        let changes = try reopened.pendingSyncOperations(accountID: "account")
        let edit = try XCTUnwrap(changes.last)
        XCTAssertEqual(edit.baseOperationID, content.id)
        XCTAssertNotEqual(edit.orderingOnly, true)
        try b.applyRemoteChanges(accountID: "account", changes: Array(changes.reversed()), nextCursor: nil)
        XCTAssertEqual(try b.item(id: target)?.text, edited.text)
        XCTAssertEqual(try b.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id),
                       try reopened.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id))
        try reopened.delete(id: target)
        let deleted = try reopened.pendingSyncOperations(accountID: "account")
        XCTAssertEqual(deleted.last?.baseOperationID, edit.operationID)
        try b.applyRemoteChanges(accountID: "account", changes: deleted, nextCursor: nil)
        XCTAssertNil(try b.item(id: target))
    }

    func testFailedOldMigrationRollsBackBackfilledHeadTablesAndVersion() throws {
        let original = try store()
        let (_, records) = try fixture(original)
        let outbox = try rows(original, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid")
        try dropCleanupSchema(original)
        try original.execute("""
            DROP TABLE sync_content_heads; DROP TABLE sync_order_heads;
            CREATE VIEW history_cleanup_tokens AS SELECT id AS record_id, randomblob(16) AS token FROM clipboard_records;
            PRAGMA user_version = 6;
            """)
        XCTAssertThrowsError(try store())
        XCTAssertEqual(try original.syncScalar("PRAGMA user_version", []), "6")
        XCTAssertNil(try original.syncScalar("SELECT name FROM sqlite_master WHERE name='sync_content_heads'", []))
        XCTAssertNil(try original.syncScalar("SELECT name FROM sqlite_master WHERE name='sync_order_heads'", []))
        XCTAssertNil(try original.syncScalar("SELECT name FROM sqlite_master WHERE name='history_cleanup_insert'", []))
        XCTAssertEqual(try rows(original, "SELECT operation_id, hex(payload) FROM sync_outbox ORDER BY rowid"), outbox)
        XCTAssertEqual(try original.item(id: records[0].id), records[0])
    }
}
