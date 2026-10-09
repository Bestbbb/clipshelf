import Foundation
import XCTest
@testable import ClipShelfCore

final class OriginDeviceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-origin-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local", stamp: Bool = false) throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"), recordsLocalOrigin: stamp)
    }

    func testLocalCreationStampsStableInstallationOnlyWhenEnabledAndPreservationIsExplicit() throws {
        let legacy = try store("legacy")
        XCTAssertNil(try legacy.create(ClipboardRecord(text: "unknown")).originDeviceID)
        let local = try store(stamp: true)
        let identity = try local.localDeviceIdentity()
        XCTAssertEqual(identity.name, "Mac")
        XCTAssertEqual(try store(stamp: true).localDeviceIdentity(), identity)
        XCTAssertNotEqual(try legacy.localDeviceIdentity().id, identity.id)
        let created = try local.create(ClipboardRecord(text: "created"))
        XCTAssertEqual(created.originDeviceID, identity.id)
        XCTAssertEqual(try local.item(id: created.id), created)
        let unknown = try local.create(ClipboardRecord(text: "restored unknown"), preserveOrigin: true)
        XCTAssertNil(unknown.originDeviceID)
        let remoteID = UUID()
        let remote = try local.create(ClipboardRecord(text: "same content", originDeviceID: remoteID, originDeviceName: "Mac"))
        let captured = try local.record(ClipboardRecord(text: "same content"))
        XCTAssertNotEqual(captured.id, remote.id, "Local capture cannot coalesce with the same text from another device")
        XCTAssertEqual(captured.originDeviceID, identity.id)
        XCTAssertEqual(try local.record(ClipboardRecord(text: "same content")).id, captured.id)
    }

    func testVersionSevenRecordsAndLegacyJSONStayUnknownAfterMigration() throws {
        let old = try store("old")
        let original = try old.create(ClipboardRecord(text: "old imported history"))
        try old.execute("DROP INDEX clipboard_origin_device; ALTER TABLE clipboard_records DROP COLUMN origin_device_id; ALTER TABLE clipboard_records DROP COLUMN origin_device_name; ALTER TABLE clipboard_records DROP COLUMN origin_device_conflict; DROP TABLE local_device_identity; PRAGMA user_version = 7")
        let migrated = try store("old", stamp: true)
        let recovered = try XCTUnwrap(migrated.item(id: original.id))
        XCTAssertNil(recovered.originDeviceID); XCTAssertFalse(recovered.originDeviceConflict)
        XCTAssertEqual(try migrated.searchMetadata(HistoryQuery(deviceFilter: .unknown)).map(\.id), [original.id])
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldJSON.removeValue(forKey: "originDeviceID"); oldJSON.removeValue(forKey: "originDeviceName"); oldJSON.removeValue(forKey: "originDeviceConflict")
        let decoded = try JSONDecoder().decode(ClipboardRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(decoded.originDeviceID); XCTAssertFalse(decoded.originDeviceConflict)
        XCTAssertNotNil(try migrated.record(ClipboardRecord(text: "new local capture")).originDeviceID)
    }

    func testEditingAndBackupRestorePreserveOriginAndDoNotReplaceLocalInstallationIdentity() throws {
        let source = try store("source", stamp: true)
        let original = try source.create(ClipboardRecord(text: "source content"))
        var edit = original; edit.text = "edited"; edit.originDeviceID = UUID(); edit.originDeviceName = "Injected"
        let updated = try source.update(record: edit)
        XCTAssertEqual(updated.originDeviceID, original.originDeviceID)
        XCTAssertEqual(updated.originDeviceName, original.originDeviceName)
        let unknown = try source.create(ClipboardRecord(text: "old unknown"), preserveOrigin: true)
        let conflict = try source.create(ClipboardRecord(text: "conflicted", originDeviceConflict: true), preserveOrigin: true)
        let backup = directory.appendingPathComponent("origins.clipshelfbackup")
        try source.exportBackup(to: backup)
        let destination = try store("destination", stamp: true)
        let localIdentity = try destination.localDeviceIdentity()
        _ = try destination.restoreBackup(from: backup, mode: .replace)
        XCTAssertEqual(try destination.localDeviceIdentity(), localIdentity)
        XCTAssertEqual(try destination.item(id: updated.id)?.originDeviceID, original.originDeviceID)
        XCTAssertNil(try destination.item(id: unknown.id)?.originDeviceID)
        XCTAssertEqual(try destination.item(id: conflict.id)?.originDeviceConflict, true)
        XCTAssertEqual(try destination.create(ClipboardRecord(text: "new after restore")).originDeviceID, localIdentity.id)
    }

    func testLegacyRemoteEditsKeepKnownOriginAndContradictionsRemainExplicitAcrossReplayAndBackup() throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: "account"); try b.configureSync(accountID: "account")
        let original = try a.create(ClipboardRecord(text: "original", originDeviceID: UUID(), originDeviceName: "Mac"))
        let root = try XCTUnwrap(a.pendingSyncOperations(accountID: "account").first)
        var legacy = original; legacy.text = "legacy body"; legacy.originDeviceID = nil; legacy.originDeviceName = nil
        let legacyOperation = SyncOperation(accountID: "account", entityID: original.id, entityKind: .clipboard, action: .upsert, baseRevision: root.revision, revision: root.revision + 1, baseOperationID: root.operationID, record: legacy)
        try a.applyRemoteChanges(accountID: "account", changes: [legacyOperation], nextCursor: nil)
        XCTAssertEqual(try a.item(id: original.id)?.originDeviceID, original.originDeviceID)
        var contradictory = legacy; contradictory.text = "contradictory body"; contradictory.originDeviceID = UUID(); contradictory.originDeviceName = "Other Mac"
        let conflict = SyncOperation(accountID: "account", entityID: original.id, entityKind: .clipboard, action: .upsert, baseRevision: legacyOperation.revision, revision: legacyOperation.revision + 1, baseOperationID: legacyOperation.operationID, record: contradictory)
        try a.applyRemoteChanges(accountID: "account", changes: [conflict], nextCursor: nil)
        try b.applyRemoteChanges(accountID: "account", changes: [conflict, legacyOperation, root], nextCursor: nil)
        for device in [a, b] {
            let resolved = try XCTUnwrap(device.item(id: original.id))
            XCTAssertNil(resolved.originDeviceID); XCTAssertNil(resolved.originDeviceName); XCTAssertTrue(resolved.originDeviceConflict)
            XCTAssertEqual(try device.searchMetadata(HistoryQuery(deviceFilter: .unknown)).map(\.id), [original.id])
            XCTAssertEqual(try device.metadataDevices(), [])
        }
        var newer = try XCTUnwrap(a.item(id: original.id)); newer.text = "later user edit"; newer.originDeviceConflict = false
        let saved = try a.update(record: newer)
        XCTAssertTrue(saved.originDeviceConflict)
        try b.applyRemoteChanges(accountID: "account", changes: a.pendingSyncOperations(accountID: "account"), nextCursor: nil)
        XCTAssertTrue(try XCTUnwrap(b.item(id: original.id)).originDeviceConflict)
        let latest = try XCTUnwrap(a.pendingSyncOperations(accountID: "account").last)
        var staleMetadata = saved; staleMetadata.text = "old client after conflict"; staleMetadata.originDeviceConflict = false
        let staleOperation = SyncOperation(accountID: "account", entityID: original.id, entityKind: .clipboard, action: .upsert, baseRevision: latest.revision, revision: latest.revision + 1, baseOperationID: latest.operationID, record: staleMetadata)
        for device in [a, b] {
            try device.applyRemoteChanges(accountID: "account", changes: [staleOperation], nextCursor: nil)
            XCTAssertTrue(try XCTUnwrap(device.item(id: original.id)).originDeviceConflict, "A later legacy client cannot wash away a recorded conflict")
            XCTAssertNil(try device.item(id: original.id)?.originDeviceID)
        }
        let backup = directory.appendingPathComponent("conflict.clipshelfbackup"); try b.exportBackup(to: backup)
        let restored = try store("restored", stamp: true); _ = try restored.restoreBackup(from: backup, mode: .replace)
        XCTAssertTrue(try XCTUnwrap(restored.load().first).originDeviceConflict)
        XCTAssertNil(try XCTUnwrap(restored.load().first).originDeviceID)
    }

    func testDeviceFilterRunsBeforePaginationAndCopiesKeepUnknownOrigin() throws {
        let local = try store(stamp: true)
        let board = try local.createPinboard(name: "Mixed origins")
        let own = try local.create(ClipboardRecord(text: "own searchable", pinboardID: board.id))
        let unknown = try local.create(ClipboardRecord(text: "unknown searchable", pinboardID: board.id), preserveOrigin: true)
        let other = UUID()
        let remote = try local.create(ClipboardRecord(text: "remote searchable", pinboardID: board.id, originDeviceID: other, originDeviceName: "Mac"))
        try local.create(ClipboardRecord(text: "conflicted searchable", pinboardID: board.id, originDeviceConflict: true), preserveOrigin: true)
        XCTAssertEqual(Set(try local.metadataDevices().map(\.id)), [other, try local.localDeviceIdentity().id])
        let query = HistoryQuery(text: "searchable", pinboardIDs: [board.id], limit: 1, sortOrder: .pinboard, deviceFilter: .device(other))
        XCTAssertEqual(try local.searchMetadata(query).map(\.id), [remote.id])
        XCTAssertEqual(try local.metadataOffset(of: remote.id, query: query), 0)
        XCTAssertNil(try local.metadataOffset(of: own.id, query: query))
        XCTAssertEqual(try local.searchMetadata(HistoryQuery(deviceFilter: .unknown)).count, 2)
        let copy = try local.copyBoardToLocal(boardID: board.id)
        let copied = try local.search(HistoryQuery(pinboardIDs: [copy.id]))
        XCTAssertNil(copied.first { $0.text == unknown.text }?.originDeviceID)
        XCTAssertEqual(copied.first { $0.text == own.text }?.originDeviceID, own.originDeviceID)
        XCTAssertEqual(copied.first { $0.text == "conflicted searchable" }?.originDeviceConflict, true)
    }
}
