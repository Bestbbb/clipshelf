import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class ExtendedHistoryTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite3") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-extended-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func richRecord(text: String = "multi-object") -> ClipboardRecord {
        ClipboardRecord(text: text, parts: [
            ClipboardPart(representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("第一段\0x".utf8)),
                ClipboardRepresentation(typeIdentifier: "public.html", data: Data("<b>第一段</b>".utf8)),
            ]),
            ClipboardPart(representations: [
                ClipboardRepresentation(typeIdentifier: "public.png", data: Data([0, 255, 1, 10])),
                ClipboardRepresentation(typeIdentifier: "public.tiff", data: Data()),
            ]),
        ])
    }

    func testOrderedPartsAndAllRepresentationsRoundTripFromAttachmentFiles() throws {
        let original = richRecord()
        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            try store.record(original)
        }
        let reopened = try HistoryStore(databaseURL: databaseURL)
        XCTAssertEqual(try reopened.load(), [original])
        let attachmentDirectory = databaseURL.deletingPathExtension().appendingPathExtension("attachments")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachmentDirectory.path).count, 4)
        XCTAssertEqual(original.kind, .image)
    }

    func testMissingOrModifiedAttachmentFailsInsteadOfReturningPartialClipboard() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        try store.record(richRecord())
        let attachmentDirectory = databaseURL.deletingPathExtension().appendingPathExtension("attachments")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: attachmentDirectory, includingPropertiesForKeys: nil).first)
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
    }

    func testPinboardMembershipIsSingleAndClearHistoryPreservesPins() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let first = try store.createPinboard(name: "First", color: "#AABBCC")
        let second = try store.createPinboard(name: "Second")
        let pinned = ClipboardRecord(text: "pinned")
        let temporary = ClipboardRecord(text: "temporary")
        try store.record(pinned)
        try store.record(temporary)
        try store.move(recordID: pinned.id, to: first.id)
        try store.move(recordID: pinned.id, to: second.id)
        XCTAssertEqual(try store.search(HistoryQuery(pinboardIDs: [first.id])), [])
        XCTAssertEqual(try store.search(HistoryQuery(pinboardIDs: [second.id])).map(\.id), [pinned.id])
        try store.clearHistory()
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(try store.search(HistoryQuery()).map(\.id), [pinned.id])
        XCTAssertNil(try store.item(id: temporary.id))
        XCTAssertEqual(try store.item(id: pinned.id)?.isInHistory, false)
        try store.deletePinboard(id: second.id, deleteItems: false)
        XCTAssertEqual(try store.load().map(\.id), [pinned.id])
        XCTAssertNil(try store.item(id: pinned.id)?.pinboardID)
    }

    func testBoardDeleteContentsRemovesHistoryAndRenameReorderPersists() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let first = try store.createPinboard(name: "First")
        var second = try store.createPinboard(name: "Second")
        second.name = "Renamed"
        second.color = "#0099AA"
        second.sortOrder = -1
        try store.updatePinboard(second)
        XCTAssertEqual(try store.pinboards(), [second, first])
        let item = ClipboardRecord(text: "remove me")
        try store.record(item)
        try store.move(recordID: item.id, to: first.id)
        try store.deletePinboard(id: first.id, deleteItems: true)
        XCTAssertNil(try store.item(id: item.id))
        XCTAssertThrowsError(try store.createPinboard(name: " "))
        XCTAssertThrowsError(try store.createPinboard(name: "bad color", color: "red"))
        XCTAssertThrowsError(try store.move(recordID: UUID(), to: second.id))
    }

    func testAtomicPersonalPinboardOrderPersistsAndRejectsStaleLists() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let boards = try ["A", "B", "C"].map { try store.createPinboard(name: $0) }
        let ids = boards.map(\.id)
        try store.reorderPinboards(ids: [ids[2], ids[0], ids[1]])
        XCTAssertEqual(try HistoryStore(databaseURL: databaseURL).pinboards().map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertThrowsError(try store.reorderPinboards(ids: [ids[0], ids[0], ids[2]]))
        XCTAssertThrowsError(try store.reorderPinboards(ids: [ids[0], ids[1]]))
        XCTAssertThrowsError(try store.reorderPinboards(ids: [ids[0], ids[1], UUID()]))
        XCTAssertEqual(try store.pinboards().map(\.id), [ids[2], ids[0], ids[1]])
        let added = try store.createPinboard(name: "D")
        XCTAssertEqual(try store.pinboards().map(\.id), [ids[2], ids[0], ids[1], added.id])
        XCTAssertThrowsError(try store.reorderPinboards(ids: ids), "An old UI must not hide a newly synchronized board")
        try store.deletePinboard(id: ids[0])
        XCTAssertEqual(try store.pinboards().map(\.id), [ids[2], ids[1], added.id])
    }

    func testMidBatchOrderFailureRollsBackCompleteOrder() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let boards = try ["A", "B", "C"].map { try store.createPinboard(name: $0) }
        let ids = boards.map(\.id)
        try store.reorderPinboards(ids: ids)
        try store.execute("CREATE TRIGGER reject_reorder BEFORE INSERT ON pinboard_local_order WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END")
        XCTAssertThrowsError(try store.reorderPinboards(ids: ids.reversed()))
        XCTAssertEqual(try store.pinboards().map(\.id), ids)
        try store.execute("DROP TRIGGER reject_reorder")
        try store.reorderPinboards(ids: ids.reversed())
        XCTAssertEqual(try store.pinboards().map(\.id), Array(ids.reversed()))
    }

    func testPersonalPinboardOrderSurvivesLogicalBackupRestore() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let boards = try ["A", "B", "C"].map { try store.createPinboard(name: $0) }
        let order = Array(boards.map(\.id).reversed())
        try store.reorderPinboards(ids: order)
        let archive = directory.appendingPathComponent("ordered.clipshelfbackup")
        try store.exportBackup(to: archive)
        try store.reorderPinboards(ids: boards.map(\.id))
        _ = try store.restoreBackup(from: archive, mode: .replace)
        XCTAssertEqual(try store.pinboards().map(\.id), order)
        let merged = try HistoryStore(databaseURL: directory.appendingPathComponent("merged.sqlite3"))
        let existing = try merged.createPinboard(name: "Existing")
        _ = try merged.restoreBackup(from: archive, mode: .merge)
        XCTAssertEqual(try merged.pinboards().map(\.id), [existing.id] + order)
    }

    func testRetentionCountsHistoryAndKeepsExpiredPinnedItemsSearchable() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let board = try store.createPinboard(name: "Keep")
        let old = ClipboardRecord(text: "old", copiedAt: Date(timeIntervalSince1970: 10))
        let pin = ClipboardRecord(text: "old pin", copiedAt: Date(timeIntervalSince1970: 20))
        let fresh = ClipboardRecord(text: "fresh", copiedAt: Date(timeIntervalSince1970: 100))
        for record in [old, pin, fresh] { try store.record(record) }
        try store.move(recordID: pin.id, to: board.id)
        let cutoff = Date(timeIntervalSince1970: 50)
        XCTAssertEqual(try store.countHistory(before: cutoff), 2)
        XCTAssertEqual(try store.prune(before: cutoff), 2)
        XCTAssertEqual(try store.load(), [fresh])
        XCTAssertEqual(Set(try store.search(HistoryQuery()).map(\.id)), [pin.id, fresh.id])
        XCTAssertEqual(try store.search(HistoryQuery(includePinned: false)), [fresh])
        try store.move(recordID: pin.id, to: nil)
        XCTAssertEqual(try store.item(id: pin.id)?.isInHistory, true)
    }

    func testSearchCombinesChineseLiteralTextOCRSourceDateTypeAndMultipleBoards() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let a = try store.createPinboard(name: "A")
        let b = try store.createPinboard(name: "B")
        let chinese = ClipboardRecord(text: "中文_100% SQL ' ?", sourceBundleID: "app.editor", copiedAt: Date(timeIntervalSince1970: 10))
        let url = ClipboardRecord(text: "https://example.test", sourceBundleID: "app.browser", copiedAt: Date(timeIntervalSince1970: 20), ocrText: "图像文字")
        try store.record(chinese)
        try store.record(url)
        try store.move(recordID: chinese.id, to: a.id)
        try store.move(recordID: url.id, to: b.id)
        XCTAssertEqual(try store.search(HistoryQuery(text: "文_100% SQL '")).map(\.id), [chinese.id])
        XCTAssertEqual(try store.search(HistoryQuery(text: "图像文字", kind: .link, sourceBundleID: "app.browser", copiedAfter: Date(timeIntervalSince1970: 15), copiedBefore: Date(timeIntervalSince1970: 25), pinboardIDs: [a.id, b.id])).map(\.id), [url.id])
        XCTAssertEqual(try store.search(HistoryQuery(text: "中文", kind: .image)), [])
        XCTAssertEqual(try store.search(HistoryQuery(text: "' OR 1=1 --")), [])
        XCTAssertEqual(try store.search(HistoryQuery(limit: 0)), [])
    }

    func testEditPreservesIdentityAndOrderRejectsStaleRevisionAndInvalidatesOCR() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let original = ClipboardRecord(text: "old", ocrText: "derived old")
        let later = ClipboardRecord(text: "later")
        try store.record(original)
        try store.record(later)
        var edited = original
        edited.text = "edited"
        edited.renamedTitle = "我的标题"
        let saved = try store.update(record: edited)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertNil(saved.ocrText)
        XCTAssertEqual(try store.load().map(\.id), [later.id, original.id])
        XCTAssertEqual(try store.search(HistoryQuery(text: "我的标题")), [saved])
        XCTAssertThrowsError(try store.update(record: edited))
        XCTAssertEqual(try store.item(id: original.id), saved)
    }

    func testAdjacentDuplicateRetainsPinAndEditedMetadata() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let board = try store.createPinboard(name: "Keep")
        let first = ClipboardRecord(text: "same")
        try store.record(first)
        try store.move(recordID: first.id, to: board.id)
        var renamed = try XCTUnwrap(store.item(id: first.id))
        renamed.renamedTitle = "Custom title"
        _ = try store.update(record: renamed)
        try store.clearHistory()
        let captured = try store.record(ClipboardRecord(text: "same"))
        XCTAssertEqual(captured.id, first.id)
        XCTAssertEqual(captured.renamedTitle, "Custom title")
        XCTAssertEqual(captured.pinboardID, board.id)
        XCTAssertTrue(captured.isInHistory)
    }

    func testBackupReplaceRestoresPartsPinsAndRecoverySnapshot() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let board = try store.createPinboard(name: "资料")
        let record = richRecord()
        try store.record(record)
        try store.move(recordID: record.id, to: board.id)
        try store.clearHistory()
        let expected = try XCTUnwrap(store.item(id: record.id))
        let backup = directory.appendingPathComponent("export.clipshelfbackup")
        try store.exportBackup(to: backup)
        XCTAssertThrowsError(try store.exportBackup(to: backup))
        try store.clear()
        let temporary = ClipboardRecord(text: "recover this too")
        try store.record(temporary)
        let summary = try store.restoreBackup(from: backup, mode: .replace)
        XCTAssertEqual(summary.importedRecords, 1)
        XCTAssertEqual(summary.importedPinboards, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.recoveryBackupURL.path))
        XCTAssertEqual(try store.search(HistoryQuery()), [expected])
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(try store.pinboards(), [board])
        let recoveryDB = try HistoryStore(databaseURL: directory.appendingPathComponent("recovery/history.sqlite3"))
        _ = try recoveryDB.restoreBackup(from: summary.recoveryBackupURL, mode: .replace)
        XCTAssertEqual(try recoveryDB.load(), [temporary])
    }

    func testBackupMergeKeepsDifferentVersionsAndRejectsTamperingWithoutMutation() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let original = ClipboardRecord(text: "original")
        try store.record(original)
        let backup = directory.appendingPathComponent("merge.clipshelfbackup")
        try store.exportBackup(to: backup)
        var edited = original
        edited.text = "local edit"
        _ = try store.update(record: edited)
        let summary = try store.restoreBackup(from: backup, mode: .merge)
        XCTAssertEqual(summary.importedRecords, 1)
        XCTAssertEqual(Set(try store.load().map(\.text)), ["local edit", "original"])
        let before = try store.load()
        var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: Data(contentsOf: backup))
        envelope.payload.append(0)
        let bad = directory.appendingPathComponent("bad.clipshelfbackup")
        try JSONEncoder().encode(envelope).write(to: bad)
        XCTAssertThrowsError(try store.restoreBackup(from: bad, mode: .replace))
        XCTAssertEqual(try store.load(), before)
    }

    func testAttachmentCompactionPreservesSharedBlobsUntilLastReferenceIsGone() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let a = richRecord(text: "A")
        let b = richRecord(text: "B")
        try store.record(a)
        try store.record(b)
        try store.delete(id: a.id)
        XCTAssertEqual(try store.compactAttachments(), 0)
        XCTAssertEqual(try store.load(), [b])
        try store.delete(id: b.id)
        XCTAssertEqual(try store.compactAttachments(), 4)
    }

    func testVersionOneMigrationMakesRecoverySnapshotAndPreservesExactDate() throws {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 812345678.123456)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let fixture = """
            CREATE TABLE clipboard_records (id TEXT NOT NULL UNIQUE, text TEXT NOT NULL, source_app TEXT,
            source_bundle_id TEXT, copied_at REAL NOT NULL, rtf BLOB, html BLOB);
            INSERT INTO clipboard_records (id, text, copied_at) VALUES ('\(id.uuidString)', 'https://example.test', \(date.timeIntervalSinceReferenceDate));
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(database, fixture, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let store = try HistoryStore(databaseURL: databaseURL)
        let record = try XCTUnwrap(store.load().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.copiedAt, date)
        XCTAssertEqual(try store.search(HistoryQuery(kind: .link)).map(\.id), [id])
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Backups").path)
        XCTAssertEqual(backups.filter { $0.hasPrefix("pre-migration-v1-") && $0.hasSuffix(".sqlite3") }.count, 1)
    }

    func testContentClassificationAvoidsTreatingVerificationCodesAsColors() {
        XCTAssertEqual(ClipboardRecord(text: "123456").kind, .text)
        XCTAssertEqual(ClipboardRecord(text: "#FFF").kind, .text)
        XCTAssertEqual(ClipboardRecord(text: "rgb(1,2,3)").kind, .text)
        XCTAssertEqual(ClipboardRecord(text: "#123456").kind, .color)
        XCTAssertEqual(ClipboardRecord(text: "AABBCC").kind, .color)
        XCTAssertEqual(ClipboardRecord(text: "https://example.test/path").kind, .link)
        XCTAssertEqual(ClipboardRecord(text: "visit https://example.test").kind, .text)
    }

    func testLegacyRecordDecodingUsesNewFieldDefaults() throws {
        let original = ClipboardRecord(text: "legacy", sourceApp: "Editor")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["parts", "renamedTitle", "ocrText", "pinboardID", "isInHistory", "revision"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ClipboardRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, original)
    }

    func testMetadataQueryPaginatesAndDoesNotReadBinaryAttachments() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let first = richRecord(text: "first")
        let second = richRecord(text: "second")
        try store.record(first)
        try store.record(second)
        let attachmentDirectory = databaseURL.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.removeItem(at: attachmentDirectory)
        XCTAssertThrowsError(try store.load())
        let page = try store.searchMetadata(HistoryQuery(limit: 1), offset: 1)
        XCTAssertEqual(page.map(\.id), [first.id])
        XCTAssertEqual(page.first?.kind, .image)
        XCTAssertEqual(page.first?.representationTypes, [["public.utf8-plain-text", "public.html"], ["public.png", "public.tiff"]])
        XCTAssertEqual(try store.itemMetadata(id: second.id)?.text, "second")
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(limit: 1), offset: 2), [])
    }

    func testExplicitCreateDoesNotReuseAnIdenticalCaptureOrChangeItsPinboard() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let privateBoard = try store.createPinboard(name: "Private")
        let scopedBoard = try store.createPinboard(name: "Scoped")
        let captured = ClipboardRecord(text: "same", pinboardID: privateBoard.id)
        try store.record(captured)
        let created = ClipboardRecord(text: "same", pinboardID: scopedBoard.id, isInHistory: false)
        var expected = created
        expected.pinboardOrder = 0
        XCTAssertEqual(try store.create(created), expected)
        XCTAssertEqual(try store.item(id: captured.id)?.pinboardID, privateBoard.id)
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(pinboardIDs: [scopedBoard.id])).map(\.id), [created.id])
        XCTAssertThrowsError(try store.create(ClipboardRecord(text: "orphan", isInHistory: false)))
    }

    func testCaptureAndRetentionMutationsInvalidateAnOpenEditorRevision() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let board = try store.createPinboard(name: "Pinned")
        let original = ClipboardRecord(text: "same", pinboardID: board.id)
        try store.record(original)
        let recaptured = try store.record(ClipboardRecord(text: "same"))
        XCTAssertEqual(recaptured.revision, original.revision + 1)
        XCTAssertThrowsError(try store.update(record: original))
        try store.clearHistory()
        XCTAssertThrowsError(try store.update(record: recaptured))
        XCTAssertEqual(try store.item(id: original.id)?.isInHistory, false)
    }

    func testUnsupportedSchemaIsRejectedWithoutDowngrade() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        XCTAssertThrowsError(try HistoryStore(databaseURL: databaseURL))
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 999)
    }

    func testVersionTwoMigrationRecoveryContainsAttachmentFiles() throws {
        let original = richRecord()
        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            try store.record(original)
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let upgraded = try HistoryStore(databaseURL: databaseURL)
        XCTAssertEqual(try upgraded.load(), [original])
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let snapshot = try XCTUnwrap(backups.first { $0.pathExtension == "sqlite3" && $0.lastPathComponent.hasPrefix("pre-migration-v2-") })
        let recovered = try HistoryStore(databaseURL: snapshot)
        XCTAssertEqual(try recovered.load(), [original])
    }
}
