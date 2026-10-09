import ClipShelfCore
import Darwin
import Foundation
import XCTest
@testable import ClipShelf

private final class BackupCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int64 = 1_000_000_000
    func set(_ value: Int64) { lock.lock(); limit = value; lock.unlock() }
    func read(_ url: URL) -> StorageVolumeCapacity {
        lock.lock(); defer { lock.unlock() }
        return .init(volumeID: "backup-test-volume", availableBytes: limit)
    }
}

final class EncryptedBackupSpaceTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!
    private var capacity: BackupCapacity!
    private var original: ClipboardRecord!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("backup-space-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        capacity = BackupCapacity()
        let capacity = capacity!
        let coordinator = try StorageSpaceCoordinator(directory: root.appendingPathComponent("budget"), capacityProvider: { capacity.read($0) })
        store = try HistoryStore(databaseURL: root.appendingPathComponent("profile/history.sqlite"), spaceCoordinator: coordinator)
        original = try store.create(.init(text: "synthetic retained content"))
    }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }

    private func assertNoStaging(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".ClipShelf-backup-") }, file: file, line: line)
    }
    private func assertSpaceFailure(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertNotNil(StorageWriteFailure.classify(error), file: file, line: line)
        }
    }

    func testEncryptedExportRejectsLowCapacityBeforeWritingAndRetriesWithoutPlaintextFiles() throws {
        let destination = root.appendingPathComponent("archive.clipshelf")
        var writes = 0
        let writer = EncryptedBackupService.FileOperations(write: { data, url in
            writes += 1
            XCTAssertEqual(data.prefix(4), Data([0x43, 0x53, 0x42, 0x4b]))
            XCTAssertEqual(url.lastPathComponent, "encrypted.clipshelf")
            try EncryptedBackupService.FileOperations.live.write(data, url)
        }, publish: EncryptedBackupService.FileOperations.live.publish)
        capacity.set(0)
        assertSpaceFailure { try EncryptedBackupService.export(store: store, to: destination, password: "test-password", files: writer) }
        XCTAssertEqual(writes, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.load(), [original]); try assertNoStaging(in: root)
        capacity.set(1_000_000_000)
        try EncryptedBackupService.export(store: store, to: destination, password: "test-password", files: writer)
        XCTAssertEqual(writes, 1); XCTAssertTrue(try EncryptedBackupService.isEncrypted(destination))
        XCTAssertFalse(try EncryptedBackupService.open(Data(contentsOf: destination), password: "test-password").isEmpty)
        try assertNoStaging(in: root)
    }

    func testActualDiskFullDuringWriteOrPublishLeavesNoCompletedArchiveAndPreservesStore() throws {
        for failAtPublish in [false, true] {
            let destination = root.appendingPathComponent("archive-\(failAtPublish).clipshelf")
            let files = EncryptedBackupService.FileOperations(write: { data, url in
                if failAtPublish { try EncryptedBackupService.FileOperations.live.write(data, url) }
                else {
                    try Data(data.prefix(19)).write(to: url)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
            }, publish: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
            XCTAssertThrowsError(try EncryptedBackupService.export(store: store, to: destination, password: "test-password", files: files)) {
                XCTAssertEqual($0 as? StorageWriteFailure, .diskFull)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try store.load(), [original]); try assertNoStaging(in: root)
        }
    }

    func testCompletedCiphertextCanPublishAfterConsumingItsBudgetAndNeverOverwritesExistingFile() throws {
        let destination = root.appendingPathComponent("archive.clipshelf")
        let capacity = capacity!
        let files = EncryptedBackupService.FileOperations(write: { data, url in
            try EncryptedBackupService.FileOperations.live.write(data, url)
            capacity.set(0)
        }, publish: EncryptedBackupService.FileOperations.live.publish)
        try EncryptedBackupService.export(store: store, to: destination, password: "test-password", files: files)
        let existing = try Data(contentsOf: destination)
        capacity.set(1_000_000_000)
        XCTAssertThrowsError(try EncryptedBackupService.export(store: store, to: destination, password: "different-password"))
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        try assertNoStaging(in: root)
    }

    func testDecryptStagingChecksCapacityAndCleansPartialFileWithoutChangingLibrary() throws {
        let archive = root.appendingPathComponent("archive.clipshelf")
        try EncryptedBackupService.export(store: store, to: archive, password: "test-password")
        let local = root.appendingPathComponent("restore-staging")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        capacity.set(0)
        assertSpaceFailure {
            _ = try EncryptedBackupService.prepareRestore(from: archive, password: "test-password", mode: .replace,
                                                          store: store, temporaryRoot: local)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: local.path).isEmpty)
        capacity.set(1_000_000_000)
        let files = EncryptedBackupService.FileOperations(write: { data, url in
            try Data(data.prefix(7)).write(to: url)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }, publish: EncryptedBackupService.FileOperations.live.publish)
        XCTAssertThrowsError(try EncryptedBackupService.prepareRestore(from: archive, password: "test-password", mode: .replace,
            store: store, temporaryRoot: local, files: files)) { XCTAssertEqual($0 as? StorageWriteFailure, .diskFull) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: local.path).isEmpty)
        XCTAssertEqual(try store.load(), [original])
        _ = try EncryptedBackupService.prepareRestore(from: archive, password: "test-password", mode: .replace,
                                                       store: store, temporaryRoot: local)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: local.path).isEmpty)
        XCTAssertEqual(try store.load(), [original])
    }
}
