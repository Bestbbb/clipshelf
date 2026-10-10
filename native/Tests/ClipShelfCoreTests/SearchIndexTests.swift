import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class SearchIndexTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-search-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func reference(_ store: HistoryStore, _ text: String) throws -> [UUID] {
        let statement = try store.prepare("SELECT id FROM clipboard_records WHERE (is_in_history = 1 OR pinboard_id IS NOT NULL) AND instr(lower(text || char(10) || coalesce(renamed_title, '') || char(10) || coalesce(ocr_text, '') || char(10) || coalesce(source_app, '')), lower(?)) > 0 ORDER BY rowid DESC")
        defer { sqlite3_finalize(statement) }
        try store.bind(text, at: 1, to: statement)
        var result: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(UUID(uuidString: store.textColumn(statement, 0)!)!) }
        return result
    }
    private func checkIntegrity(_ store: HistoryStore) throws {
        try store.execute("INSERT INTO clipboard_search(clipboard_search, rank) VALUES('integrity-check', 1)")
    }

    func testIndexedLiteralQueriesExactlyMatchOriginalUnicodeAndASCIISemantics() throws {
        let store = try store()
        XCTAssertEqual(store.searchIndexStatus(), .trigram)
        let samples = [
            "HELLO World hello-world", "中文剪贴板搜索，繁體中文與English混合。", "你好👨‍👩‍👧‍👦😀🚀世界",
            "const name = foo?.bar(); a_b %100 [x] {y} OR NOT AND NEAR()", "SQL ' OR 1=1 -- \"quoted\" * ^ + :",
            "Case ÄÖÜ äöü Σ σ İ i École e\u{301}cole", "before\0AFTER next", "tab\tspace\nline\r\nlast",
            "abc---bcd---cde", "abcde", String(repeating: "prefix", count: 30) + "unique尾部"
        ]
        for sample in samples { try store.create(ClipboardRecord(text: sample)) }
        try store.create(ClipboardRecord(text: "boundary", sourceApp: "FinalApp", renamedTitle: "Title", ocrText: "识别文字"))
        let queries = ["HELLO", "lo wo", "中文剪", "剪贴", "中", "", "👨‍👩", "😀🚀世", "😀", "a_b", "%100", "[x]", "foo?.bar", "OR NOT AND", "\"quoted\"", "' OR 1=1 --", "* ^ +", "ÄÖÜ", "äöü", "Éco", "éco", "e\u{301}co", "AFTER", "before\0AFTER", "\tsp", "line\r\n", "abcde", "ary\nTitle", "le\n识", "字\nFinal", "not present", String(repeating: "prefix", count: 25) + "NO"]
        for query in queries {
            let expected = try reference(store, query)
            XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: query)).map(\.id), expected, "query: \(query.debugDescription)")
            XCTAssertEqual(try store.search(HistoryQuery(text: query)).map(\.id), expected, "full record query: \(query.debugDescription)")
        }
        XCTAssertEqual(try store.search(HistoryQuery(text: "abcde")).count, 1, "Trigram candidates must still pass the complete substring check")
        try checkIntegrity(store)
    }

    func testSelectiveIndexedSearchAvoidsScanningUnrelatedHistoryRows() throws {
        let store = try store()
        try store.transaction {
            for index in 0..<2_000 { try store.insert(ClipboardRecord(text: "ordinary item \(index)")) }
            try store.insert(ClipboardRecord(text: "distinctneedle"))
        }
        let statement = try store.prepareSearch(HistoryQuery(text: "distinctneedle"), metadataOnly: true, offset: 0)
        defer { sqlite3_finalize(statement) }
        var hits = 0
        while sqlite3_step(statement) == SQLITE_ROW { hits += 1 }
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0), 0,
                       "The candidate index should retrieve rowids rather than scan all history rows")
    }

    func testTriggersCoverAllSearchFieldsDeletesAndTransactionRollback() throws {
        let store = try store()
        var record = try store.create(ClipboardRecord(text: "oldbody", sourceApp: "OldApp", renamedTitle: "OldTitle", ocrText: "旧识别文字"))
        record.text = "newbody"; record.sourceApp = "NewApp"; record.renamedTitle = "NewTitle"; record.ocrText = "新识别文字"
        record = try store.update(record: record)
        for query in ["newbody", "NewApp", "NewTitle", "新识别"] { XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: query)).map(\.id), [record.id]) }
        for query in ["oldbody", "OldApp", "OldTitle", "旧识别"] { XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: query)), []) }
        enum Rollback: Error { case intentional }
        XCTAssertThrowsError(try store.transaction {
            var changed = record; changed.text = "rolledbackbody"
            try store.replaceContents(changed)
            throw Rollback.intentional
        })
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "newbody")).map(\.id), [record.id])
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "rolledbackbody")), [])
        try checkIntegrity(store)
        try store.delete(id: record.id)
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "newbody")), [])
        try store.create(ClipboardRecord(text: "clear searchable")); try store.clear()
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "searchable")), [])
        try checkIntegrity(store)
    }

    func testFallbackWritesRebuildWhenTrigramBecomesAvailable() throws {
        let store = try store()
        var original = try store.create(ClipboardRecord(text: "before fallback"))
        try store.transaction { try store.initializeSearchIndex(capabilityOverride: false) }
        XCTAssertEqual(store.searchIndexStatus(), .literalScan)
        original.text = "edited during fallback"; _ = try store.update(record: original)
        let added = try store.create(ClipboardRecord(text: "新增搜索内容"))
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "新增搜")).map(\.id), [added.id])
        try store.transaction { try store.initializeSearchIndex(capabilityOverride: true) }
        XCTAssertEqual(store.searchIndexStatus(), .trigram)
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "before fallback")), [])
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "edited during")).map(\.id), [original.id])
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(text: "新增搜")).map(\.id), [added.id])
        try checkIntegrity(store)
    }

    func testVersionSevenMigrationAndBackupRestoreBuildSearchIndexWithoutSyncMutation() throws {
        let original = try store()
        try original.configureSync(accountID: "account")
        let record = try original.create(ClipboardRecord(text: "旧版迁移中文内容"))
        let operations = try original.pendingSyncOperations(accountID: "account")
        try original.execute("DROP TRIGGER clipboard_search_insert; DROP TRIGGER clipboard_search_update; DROP TRIGGER clipboard_search_delete; DROP TABLE clipboard_search; DROP VIEW clipboard_search_documents; DROP TABLE search_index_state; PRAGMA user_version = 7")
        let migrated = try store()
        XCTAssertEqual(try migrated.searchMetadata(HistoryQuery(text: "迁移中文")).map(\.id), [record.id])
        XCTAssertEqual(try migrated.pendingSyncOperations(accountID: "account"), operations)
        XCTAssertEqual(try migrated.syncScalar("PRAGMA user_version", []), "14")
        let backup = directory.appendingPathComponent("search.clipshelfbackup")
        try migrated.exportBackup(to: backup)
        let restored = try store("restored")
        _ = try restored.restoreBackup(from: backup, mode: .replace)
        XCTAssertEqual(try restored.searchMetadata(HistoryQuery(text: "迁移中文")).map(\.text), [record.text])
        try checkIntegrity(migrated); try checkIntegrity(restored)
    }

    func testSyncMutationsAndOrderingPaginationShareTheSameFilteredIndex() throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: "account"); try b.configureSync(accountID: "account")
        let board = try a.createPinboard(name: "search board")
        let records = try (0..<8).map { try a.create(ClipboardRecord(text: "indexed common \($0)", pinboardID: board.id)) }
        try a.reorderPinboardItems(boardID: board.id, orderedIDs: records.reversed().map(\.id))
        try b.applyRemoteChanges(accountID: "account", changes: a.pendingSyncOperations(accountID: "account"), nextCursor: nil)
        let query = HistoryQuery(text: "common", pinboardIDs: [board.id], limit: 2, sortOrder: .pinboard)
        XCTAssertEqual(try b.searchMetadata(query, offset: 3).map(\.id), [records[4].id, records[3].id])
        XCTAssertEqual(try b.metadataOffset(of: records[0].id, query: query), 7)
        var edited = try XCTUnwrap(a.item(id: records[4].id)); edited.text = "replacement remote text"; _ = try a.update(record: edited)
        try a.delete(id: records[3].id)
        try b.applyRemoteChanges(accountID: "account", changes: a.pendingSyncOperations(accountID: "account"), nextCursor: nil)
        XCTAssertEqual(try b.searchMetadata(HistoryQuery(text: "replacement")).map(\.id), [edited.id])
        XCTAssertEqual(try b.searchMetadata(query, offset: 3).map(\.id), [records[2].id, records[1].id])
        try checkIntegrity(b)
    }
}
