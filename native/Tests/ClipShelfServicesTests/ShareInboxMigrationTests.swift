import ClipShelfCore
import Foundation
import XCTest
@testable import ClipShelf

final class ShareInboxMigrationTests: XCTestCase {
    private var root: URL!
    private var privateDirectory: URL!
    private var store: HistoryStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-legacy-share-\(UUID())")
        privateDirectory = root.appendingPathComponent("private")
        store = try HistoryStore(databaseURL: root.appendingPathComponent("db/history.sqlite"))
    }
    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: root)
    }
    private var imports: URL { privateDirectory.appendingPathComponent("ShareImports") }
    private func writeReceipt(operationID: UUID = UUID(), ids: [UUID], attempted: [Int]? = nil, completed: [Int]? = nil) throws {
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let object: [String: Any] = ["digest": String(repeating: "a", count: 64), "recordIDs": ids.map(\.uuidString),
                                   "attempted": attempted ?? Array(ids.indices), "completed": completed ?? Array(ids.indices)]
        try JSONSerialization.data(withJSONObject: object).write(to: imports.appendingPathComponent(operationID.uuidString + ".json"))
    }
    private func legacyRecord(bytes: Data = Data("legacy snapshot".utf8), boardID: UUID? = nil) throws -> (ClipboardRecord, URL) {
        let id = UUID()
        let file = imports.appendingPathComponent("Files/\(id.uuidString)/旧文件.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file)
        let record = ClipboardRecord(id: id, text: "旧文件.txt", sourceApp: "系统分享", copiedAt: Date(timeIntervalSince1970: 50),
                                     parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(file.absoluteString.utf8))])], pinboardID: boardID)
        return (try store.create(record), file)
    }
    private func url(_ record: ClipboardRecord) throws -> URL {
        let representation = try XCTUnwrap(record.parts.first?.representations.first)
        return try XCTUnwrap(URL(string: XCTUnwrap(String(data: representation.data, encoding: .utf8))))
    }
    private func migrate() throws -> ShareInboxService.LegacyMigrationReport {
        try ShareInboxService.migrateLegacyFiles(store: store, privateDirectory: privateDirectory)
    }

    func testNoLegacyDirectoryNeedsNoAppGroupAndDoesNotCreateAnything() throws {
        let report = try migrate()
        XCTAssertEqual(report.migratedRecords, 0); XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imports.path))
    }

    func testCompletedReceiptMigratesCurrentSnapshotPreservingIdentityThenRegistryMakesRetryIdempotent() throws {
        let board = try store.createPinboard(name: "Legacy board")
        let (original, oldURL) = try legacyRecord(boardID: board.id)
        try writeReceipt(ids: [original.id])
        let current = Data("bytes changed since original share".utf8)
        try current.write(to: oldURL)
        let first = try migrate()
        XCTAssertEqual(first.migratedRecords, 1); XCTAssertTrue(first.failures.isEmpty)
        XCTAssertTrue(first.snapshotNotice.contains("迁移时快照")); XCTAssertTrue(first.snapshotNotice.contains("未核对"))
        let migrated = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(migrated.revision, original.revision + 1)
        XCTAssertEqual(migrated.pinboardID, original.pinboardID)
        XCTAssertEqual(migrated.sourceApp, original.sourceApp); XCTAssertEqual(migrated.copiedAt, original.copiedAt)
        let newURL = try url(migrated)
        XCTAssertNotEqual(newURL, oldURL); XCTAssertEqual(try Data(contentsOf: newURL), current)
        XCTAssertEqual(try Data(contentsOf: oldURL), current, "Legacy files are retained; migration does not delete the original")
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id).count, 1)
        try FileManager.default.removeItem(at: imports.appendingPathComponent("Files"))
        let replay = try migrate()
        XCTAssertEqual(replay.alreadyManagedRecords, 1); XCTAssertTrue(replay.failures.isEmpty)
        XCTAssertEqual(try store.item(id: original.id)?.revision, migrated.revision)
    }

    func testMissingFileReportsFailureWithoutChangingRecordAndCanRetry() throws {
        let (original, oldURL) = try legacyRecord()
        try writeReceipt(ids: [original.id]); try FileManager.default.removeItem(at: oldURL)
        let failed = try migrate()
        XCTAssertEqual(failed.failures.count, 1); XCTAssertThrowsError(try failed.requireComplete())
        XCTAssertEqual(try store.item(id: original.id)?.parts, original.parts)
        XCTAssertEqual(try store.item(id: original.id)?.revision, original.revision)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        try Data("retried bytes".utf8).write(to: oldURL)
        XCTAssertEqual(try migrate().migratedRecords, 1)
    }

    func testDeletedRecordIsNeverResurrectedAndUnreferencedFilesAreNotScanned() throws {
        let (original, oldURL) = try legacyRecord()
        try writeReceipt(ids: [original.id]); try store.delete(id: original.id)
        let orphan = imports.appendingPathComponent("Files/\(UUID())/orphan.txt")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("do not claim".utf8).write(to: orphan)
        let result = try migrate()
        XCTAssertEqual(result.deletedRecords, 1); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testEditedRecordPointingOutsideControlledRecordDirectoryIsNotAdopted() throws {
        let (original, _) = try legacyRecord()
        try writeReceipt(ids: [original.id])
        let outside = root.appendingPathComponent("external.txt")
        try Data("external user's file".utf8).write(to: outside)
        var edited = original
        edited.parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(outside.absoluteString.utf8))])]
        let saved = try store.update(record: edited)
        let result = try migrate()
        XCTAssertEqual(result.failures.count, 1); XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        XCTAssertEqual(try store.item(id: original.id)?.parts, saved.parts)
        XCTAssertEqual(try Data(contentsOf: outside), Data("external user's file".utf8))
    }

    func testFilesParentRecordDirectoryAndFileSymlinksAreRejected() throws {
        for component in ["Files", "record", "file"] {
            let (original, file) = try legacyRecord()
            let operation = UUID(); try writeReceipt(operationID: operation, ids: [original.id])
            let path = component == "Files" ? imports.appendingPathComponent("Files") : component == "record" ? file.deletingLastPathComponent() : file
            let elsewhere = root.appendingPathComponent("elsewhere-\(component)")
            try FileManager.default.moveItem(at: path, to: elsewhere)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere)
            let result = try migrate()
            XCTAssertEqual(result.failures.count, 1, component)
            XCTAssertEqual(try store.item(id: original.id)?.parts, original.parts)
            XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
            try FileManager.default.removeItem(at: path)
            try FileManager.default.moveItem(at: elsewhere, to: path)
            try FileManager.default.removeItem(at: imports.appendingPathComponent(operation.uuidString + ".json"))
        }
    }

    func testHardlinkedFileAndWrongRecordDirectoryAreRejected() throws {
        let (original, file) = try legacyRecord()
        try writeReceipt(ids: [original.id])
        let alias = root.appendingPathComponent("alias.txt")
        try FileManager.default.linkItem(at: file, to: alias)
        XCTAssertEqual(try migrate().failures.count, 1)
        try FileManager.default.removeItem(at: alias)
        let otherFile = imports.appendingPathComponent("Files/\(UUID())/wrong-record.txt")
        try FileManager.default.createDirectory(at: otherFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("wrong record".utf8).write(to: otherFile)
        var changed = original
        changed.parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(otherFile.absoluteString.utf8))])]
        _ = try store.update(record: changed)
        XCTAssertEqual(try migrate().failures.count, 1)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
    }

    func testPrivateParentImportsRootAndReceiptSymlinksAreRejected() throws {
        let (original, _) = try legacyRecord()
        let operation = UUID(); try writeReceipt(operationID: operation, ids: [original.id])
        for (index, path) in [privateDirectory!, imports].enumerated() {
            let elsewhere = root.appendingPathComponent("root-link-\(index)")
            try FileManager.default.moveItem(at: path, to: elsewhere)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere)
            XCTAssertThrowsError(try migrate())
            XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
            try FileManager.default.removeItem(at: path)
            try FileManager.default.moveItem(at: elsewhere, to: path)
        }
        let receipt = imports.appendingPathComponent(operation.uuidString + ".json")
        let elsewhere = root.appendingPathComponent("receipt-copy.json")
        try FileManager.default.moveItem(at: receipt, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: elsewhere)
        XCTAssertEqual(try migrate().failures.count, 1)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
    }

    func testIncompleteAndMalformedReceiptsDoNotSilentlyClaimComplete() throws {
        let (original, _) = try legacyRecord()
        let operation = UUID()
        try writeReceipt(operationID: operation, ids: [original.id], attempted: [0], completed: [])
        var result = try migrate()
        XCTAssertEqual(result.failures.count, 1); XCTAssertEqual(result.migratedRecords, 0)
        try writeReceipt(operationID: operation, ids: [original.id], attempted: [0], completed: [2])
        result = try migrate()
        XCTAssertEqual(result.failures.count, 1); XCTAssertThrowsError(try result.requireComplete())
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        try writeReceipt(operationID: operation, ids: [original.id])
        XCTAssertEqual(try migrate().migratedRecords, 1)
    }

    func testAccountMismatchKeepsLegacyRecordAndFileForAuthorizedRetry() throws {
        try store.configureSync(accountID: "account-one")
        let board = try store.createPinboard(name: "Account one")
        let (original, file) = try legacyRecord(boardID: board.id)
        try writeReceipt(ids: [original.id])
        try store.configureSync(accountID: "account-two")
        let rejected = try migrate()
        XCTAssertEqual(rejected.failures.count, 1); XCTAssertEqual(rejected.migratedRecords, 0)
        XCTAssertEqual(try store.item(id: original.id)?.revision, original.revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try store.configureSync(accountID: "account-one")
        XCTAssertEqual(try migrate().migratedRecords, 1)
    }

    func testReadOnlySharedRecordKeepsLegacyBytesUntilWritableRetry() throws {
        try store.configureSharing(accountID: "sharing-account")
        let source = try store.createPinboard(name: "Share fixture")
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "sharing-account", containerIdentifier: "iCloud.synthetic",
                                               zoneName: "zone", zoneOwnerName: "owner", shareRecordName: "share")
        let board = try store.createSharedCopy(from: source.id, descriptor: descriptor)
        let (original, file) = try legacyRecord(boardID: board.id)
        try writeReceipt(ids: [original.id])
        try store.updateSharedAccess(boardID: board.id, accountID: descriptor.accountID, access: .readOnly)
        let rejected = try migrate()
        XCTAssertEqual(rejected.failures.count, 1)
        XCTAssertEqual(try store.item(id: original.id)?.parts, original.parts)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try store.updateSharedAccess(boardID: board.id, accountID: descriptor.accountID, access: .readWrite)
        XCTAssertEqual(try migrate().migratedRecords, 1)
    }
}
