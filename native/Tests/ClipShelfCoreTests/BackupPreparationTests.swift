import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class BackupPreparationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-backup-preparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String) throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func archive() throws -> URL {
        let source = try store("source")
        try source.create(ClipboardRecord(text: "portable text"))
        let url = directory.appendingPathComponent("sample.clipshelfbackup")
        try source.exportBackup(to: url)
        return url
    }

    func testPreparedArchiveRetainsValidatedSnapshotAndDoesNotRereadSource() throws {
        let url = try archive(), target = try store("target")
        let before = try target.create(ClipboardRecord(text: "before"))
        let prepared = try target.prepareBackupRestore(from: url, mode: .merge)
        XCTAssertEqual(try target.load(), [before])
        try Data("replaced with untrusted bytes".utf8).write(to: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try target.restoreBackup(prepared).importedRecords, 1)
        XCTAssertEqual(Set(try target.load().map(\.text)), ["before", "portable text"])
    }

    func testPreparedArchiveRejectsDifferentStoreAndAccountGenerationChanges() throws {
        let url = try archive(), target = try store("target"), other = try store("other")
        let prepared = try target.prepareBackupRestore(from: url, mode: .merge)
        XCTAssertThrowsError(try other.restoreBackup(prepared))
        try target.configureSync(accountID: "A")
        try target.configureSync(accountID: nil)
        XCTAssertThrowsError(try target.restoreBackup(prepared))
        XCTAssertTrue(try target.load().isEmpty)
        let preparedAgain = try target.prepareBackupRestore(from: url, mode: .merge)
        try target.configureSharing(accountID: "A")
        try target.configureSharing(accountID: nil)
        XCTAssertThrowsError(try target.restoreBackup(preparedAgain))
        XCTAssertTrue(try target.load().isEmpty)
    }

    func testInvalidOrSymlinkArchivePreparationDoesNotCreateRecoveryOrChangeRows() throws {
        let url = try archive(), target = try store("target")
        let original = try target.create(ClipboardRecord(text: "untouched"))
        let link = directory.appendingPathComponent("alias.clipshelfbackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try target.prepareBackupRestore(from: link, mode: .replace))
        try Data("bad JSON".utf8).write(to: url)
        XCTAssertThrowsError(try target.prepareBackupRestore(from: url, mode: .replace))
        XCTAssertEqual(try target.load(), [original])
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.appendingPathComponent("target").path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".clipshelfbackup") })
    }

    func testBackupPreflightRejectsLargeDeclaredAttachmentsBeforeReadingMissingBlobs() throws {
        let target = try store("target")
        let record = try target.create(ClipboardRecord(text: "small row"))
        let metadata = try JSONEncoder().encode([Array(0..<8).map {
            StoredRepresentation(typeIdentifier: "public.test\($0)", digest: String(repeating: "0", count: 64),
                                 byteCount: 64 * 1_024 * 1_024)
        }])
        let statement = try target.prepare("UPDATE clipboard_records SET parts = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try target.bind(metadata, at: 1, to: statement)
        try target.bind(record.id.uuidString, at: 2, to: statement)
        try target.stepToCompletion(statement)
        let destination = directory.appendingPathComponent("oversize.clipshelfbackup")
        XCTAssertThrowsError(try target.exportBackup(to: destination)) { error in
            guard case HistoryStoreError.valueTooLarge = error else {
                return XCTFail("Must fail the budget before trying absent payload files: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testBackupPreflightIncludesEscapedTitlesAndOuterBase64() throws {
        let target = try store("target")
        _ = try target.create(ClipboardRecord(text: "small", renamedTitle: String(repeating: "\n", count: 1_000)))
        XCTAssertThrowsError(try target.preflightBackupPayload(pinboardBytes: 2, maximumArchiveBytes: 12_000))
        XCTAssertNoThrow(try target.preflightBackupPayload(pinboardBytes: 2, maximumArchiveBytes: 20_000))
    }
}
