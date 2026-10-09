import ClipShelfCore
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
}
