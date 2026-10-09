import ClipShelfCore
import Darwin
import Foundation
import XCTest
@testable import ClipShelf

final class EncryptedBackupTests: XCTestCase {
    func testRandomizedEncryptionAuthenticatesPasswordHeaderAndCiphertext() throws {
        let data = Data("Synthetic backup 中文 fixture".utf8)
        let first = try EncryptedBackupService.seal(data, password: "test-password")
        let second = try EncryptedBackupService.seal(data, password: "test-password")
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: data))
        XCTAssertEqual(try EncryptedBackupService.open(first, password: "test-password"), data)
        XCTAssertThrowsError(try EncryptedBackupService.open(first, password: "wrong-password"))
        var tampered = first; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try EncryptedBackupService.open(tampered, password: "test-password"))
        tampered = first; tampered[8] ^= 1
        XCTAssertThrowsError(try EncryptedBackupService.open(tampered, password: "test-password"))
        tampered = first; tampered[4] = 99
        XCTAssertThrowsError(try EncryptedBackupService.open(tampered, password: "test-password"))
    }

    func testWrongPasswordDoesNotMutateStoreAndValidRestorePreservesOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try HistoryStore(databaseURL: root.appendingPathComponent("source/history.sqlite"))
        let destination = try HistoryStore(databaseURL: root.appendingPathComponent("destination/history.sqlite"))
        let fixture = ClipboardRecord(text: "original", parts: [ClipboardPart(representations: [
            ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("original".utf8)),
            ClipboardRepresentation(typeIdentifier: "com.example.opaque", data: Data([0, 1, 255]))])])
        _ = try source.create(fixture)
        let kept = try destination.create(ClipboardRecord(text: "keep until successful restore"))
        let url = root.appendingPathComponent("backup.clipshelf")
        try EncryptedBackupService.export(store: source, to: url, password: "test-password")
        XCTAssertTrue(try EncryptedBackupService.isEncrypted(url))
        XCTAssertThrowsError(try EncryptedBackupService.restore(store: destination, from: url, password: "wrong", mode: .replace))
        XCTAssertEqual(try destination.load().map(\.id), [kept.id])
        _ = try EncryptedBackupService.restore(store: destination, from: url, password: "test-password", mode: .replace)
        XCTAssertEqual(try destination.item(id: fixture.id)?.parts, fixture.parts)
        XCTAssertNil(try destination.item(id: kept.id))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".ClipShelf-backup-") })
    }

    func testEncryptedManagedFileRestoresAtNewLocationAfterSourceStorageIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("old-installation")
        var source: HistoryStore? = try HistoryStore(databaseURL: sourceDirectory.appendingPathComponent("history.sqlite"))
        let payload = Data("Managed file bytes 中文\u{0} retained in encrypted archive".utf8)
        let input = ClipboardRecord(text: "共享资料.txt", parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data())])])
        let record = try XCTUnwrap(source).create(input, ownedFiles: [
            .init(partIndex: 0, representationIndex: 0, filename: "共享资料.txt", data: payload)],
            expectedSyncConfiguration: XCTUnwrap(source).syncConfiguration(),
            expectedSharingConfiguration: XCTUnwrap(source).sharingConfiguration())
        let oldURL = try fileURL(record)
        let archive = root.appendingPathComponent("portable.clipshelf")
        try EncryptedBackupService.export(store: XCTUnwrap(source), to: archive, password: "test-password")
        source = nil
        try FileManager.default.removeItem(at: sourceDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))

        let destination = try HistoryStore(databaseURL: root.appendingPathComponent("new-installation/history.sqlite"))
        let prepared = try EncryptedBackupService.prepareRestore(from: archive, password: "test-password", mode: .replace, store: destination)
        // Prepared values retain the validated bytes, independent of encrypted and temporary source files.
        try FileManager.default.removeItem(at: archive)
        XCTAssertTrue(try destination.load().isEmpty)
        let summary = try destination.restoreBackup(prepared)
        XCTAssertEqual(summary.importedRecords, 1)
        let restored = try XCTUnwrap(destination.item(id: record.id))
        let restoredURL = try fileURL(restored)
        XCTAssertNotEqual(restoredURL, oldURL)
        let resolvedParent = try XCTUnwrap(realpath(root.appendingPathComponent("new-installation").path, nil))
        defer { free(resolvedParent) }
        XCTAssertTrue(restoredURL.path.hasPrefix(String(cString: resolvedParent) + "/"))
        XCTAssertEqual(try Data(contentsOf: restoredURL), payload)
        XCTAssertEqual(try destination.ownedFileBindings(recordID: restored.id).count, 1)
    }

    func testPrepareRejectsWrongPasswordAndAuthenticatedInvalidArchiveWithoutChangingLegacyRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("db/history.sqlite"))
        let legacyFile = root.appendingPathComponent("private/ShareImports/Files/\(UUID())/legacy.txt")
        try FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("legacy bytes before authentication".utf8)
        try bytes.write(to: legacyFile)
        let existing = try store.create(.init(text: "legacy.txt", parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data(legacyFile.absoluteString.utf8))])]))
        let archive = root.appendingPathComponent("invalid.clipshelf")
        try EncryptedBackupService.seal(Data("not a Core backup".utf8), password: "test-password").write(to: archive)
        for password in ["wrong-password", "test-password"] {
            XCTAssertThrowsError(try EncryptedBackupService.prepareRestore(from: archive, password: password, mode: .replace, store: store))
            XCTAssertEqual(try store.item(id: existing.id)?.parts, existing.parts)
            XCTAssertEqual(try store.item(id: existing.id)?.revision, existing.revision)
            XCTAssertTrue(try store.ownedFileBindings(recordID: existing.id).isEmpty)
            XCTAssertEqual(try Data(contentsOf: legacyFile), bytes)
        }
    }

    func testEncryptedSourcesRejectSymlinkDirectoryFIFOAndOversizedFileBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("db/history.sqlite"))
        let existing = try store.create(.init(text: "unchanged"))
        let real = root.appendingPathComponent("regular.clipshelf")
        try Data([0x43, 0x53, 0x42, 0x4b]).write(to: real)
        XCTAssertTrue(try EncryptedBackupService.isEncrypted(real))
        let link = root.appendingPathComponent("linked.clipshelf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let fifo = root.appendingPathComponent("pipe.clipshelf")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let large = root.appendingPathComponent("large.clipshelf")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(512 * 1024 * 1024 + 50)); try handle.close()
        for source in [link, root, fifo, large] {
            XCTAssertThrowsError(try EncryptedBackupService.isEncrypted(source), source.lastPathComponent)
            XCTAssertThrowsError(try EncryptedBackupService.prepareRestore(from: source, password: "test-password", mode: .replace, store: store), source.lastPathComponent)
            XCTAssertEqual(try store.load().map(\.id), [existing.id])
        }
    }

    private func fileURL(_ record: ClipboardRecord) throws -> URL {
        let bytes = try XCTUnwrap(record.parts.first?.representations.first?.data)
        return try XCTUnwrap(URL(string: XCTUnwrap(String(data: bytes, encoding: .utf8))))
    }
}
