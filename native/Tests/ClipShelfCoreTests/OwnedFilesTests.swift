import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class OwnedFilesTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "history") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"))
    }
    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        .init(id: record.id, revision: record.revision)
    }
    private func candidate(board: UUID? = nil) -> ClipboardRecord {
        ClipboardRecord(text: "示例.txt", parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])], pinboardID: board)
    }
    private func imported(_ store: HistoryStore, board: UUID? = nil, data: Data = Data("original 中文\0bytes".utf8)) throws -> ClipboardRecord {
        try store.create(candidate(board: board), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "示例.txt", data: data)],
                         expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }
    private func archive(_ store: HistoryStore, _ records: [ClipboardRecord]) throws -> (assets: [OwnedFileBackupAsset], bindings: [OwnedFileBinding]) {
        try store.synchronized { try store.transaction { try store.backupOwnedFilesWithoutLock(records: records) } }
    }
    private func folders(_ store: HistoryStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.ownedFileStorage.directory.path).sorted()
    }

    func testExplicitImportPersistsPrivateBytesAndProjectionEditsDoNotChangeOriginal() throws {
        let store = try store(), bytes = Data([0, 1, 255, 10])
        let record = try imported(store, data: bytes)
        let binding = try XCTUnwrap(store.ownedFileBindings(recordID: record.id).first)
        let url = try store.ownedFileURLWithoutLock(assetID: binding.assetID)
        XCTAssertEqual(url.lastPathComponent, "示例.txt")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try Data("external edit".utf8).write(to: url)
        let reopened = try self.store()
        XCTAssertEqual(try reopened.ownedFileBindings(recordID: record.id), [binding])
        XCTAssertEqual(try archive(reopened, [record]).assets.map(\.data), [bytes])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testPlainCreateAndRemoteInsertNeverAcquireOwnershipFromKnownURL() throws {
        let store = try store(), original = try imported(store)
        var copy = original; copy.id = UUID()
        let local = try store.create(copy)
        XCTAssertTrue(try store.ownedFileBindings(recordID: local.id).isEmpty)
        try store.configureSync(accountID: "synthetic")
        copy.id = UUID()
        let operation = SyncOperation(accountID: "synthetic", entityID: copy.id, entityKind: .clipboard,
                                      action: .upsert, baseRevision: 0, revision: 1, record: copy)
        try store.applyRemoteChanges(accountID: "synthetic", changes: [operation], nextCursor: nil)
        XCTAssertTrue(try store.ownedFileBindings(recordID: copy.id).isEmpty)
        XCTAssertTrue(try archive(store, [local, copy]).assets.isEmpty)
    }

    func testUpdateKeepsOnlyUnchangedOwnedSlotsAndNeverInfersNewOwnership() throws {
        let store = try store(), original = try imported(store)
        var edited = original; edited.renamedTitle = "renamed"
        let renamed = try store.update(record: edited)
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id).count, 1)
        edited = renamed; edited.parts[0].representations[0].data = Data("file:///tmp/unowned".utf8)
        var removed = try store.update(record: edited)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        removed.parts = original.parts
        _ = try store.update(record: removed)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
    }

    func testEditDeleteAndConsecutiveUndoRestoreTrustedBindingSnapshots() throws {
        let store = try store(), original = try imported(store)
        let expected = try store.ownedFileBindings(recordID: original.id)
        var changed = original; changed.parts = []; changed.text = "edit one"
        let first = try store.editSelectionRecord(changed)
        var current = try XCTUnwrap(store.item(id: original.id)); current.text = "edit two"
        let second = try store.editSelectionRecord(current)
        let receipt = try store.undoSelectionEdit(second)
        _ = try store.undoSelectionEdit(store.rebaseSelectionEditUndo(first, after: receipt))
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id), expected)
        current = try XCTUnwrap(store.item(id: original.id))
        let deletion = try store.deleteSelection([reference(current)])
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        XCTAssertEqual(try store.compactAttachments(), 1)
        _ = try store.restoreDeletedSelection([current], undo: deletion)
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id), expected)
        XCTAssertEqual(try archive(store, [current]).assets.count, 1)
    }

    func testUndoOwnedBindingsCannotCrossStoreOrAccountABA() throws {
        let store = try store(), original = try imported(store)
        var edit = original; edit.parts = []
        let undo = try store.editSelectionRecord(edit)
        XCTAssertThrowsError(try self.store("other").undoSelectionEdit(undo))
        let old = try store.syncConfiguration()
        try store.configureSync(accountID: "different")
        try store.configureSync(accountID: old.accountID)
        XCTAssertThrowsError(try store.undoSelectionEdit(undo))
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
    }

    func testTrustedBoardCopiesAndLocalConflictKeepOwnership() throws {
        let store = try store(), board = try store.createPinboard(name: "Source")
        let original = try imported(store, board: board.id)
        let copiedBoard = try store.copyBoardToLocal(boardID: board.id)
        let copy = try XCTUnwrap(store.search(.init(pinboardIDs: [copiedBoard.id])).first)
        XCTAssertEqual(try store.ownedFileBindings(recordID: copy.id).map(\.assetID), try store.ownedFileBindings(recordID: original.id).map(\.assetID))
        let operationID = UUID()
        try store.synchronized { try store.transaction { try store.preserveConflict(kind: .clipboard, id: original.id, operationID: operationID, accountID: "synthetic") } }
        XCTAssertEqual(try store.ownedFileBindings(recordID: store.conflictID(operationID)).count, 1)
    }

    func testSharedCopyAndRejectedDraftRetainOnlyLocallyRegisteredOwnership() throws {
        let store = try store(), board = try store.createPinboard(name: "Source")
        _ = try imported(store, board: board.id)
        try store.configureSharing(accountID: "owner")
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "owner", containerIdentifier: "iCloud.synthetic",
                                                            zoneName: "ClipShelfShared_synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        let shared = try store.createSharedCopy(from: board.id, descriptor: descriptor)
        let copy = try XCTUnwrap(store.search(.init(pinboardIDs: [shared.id])).first)
        XCTAssertEqual(try store.ownedFileBindings(recordID: copy.id).count, 1)
        let operation = try XCTUnwrap(store.pendingSharedOperations(boardID: shared.id, accountID: "owner").first { $0.record?.id == copy.id })
        try store.updateSharedAccess(boardID: shared.id, accountID: "owner", access: .revoked)
        try store.rejectPendingSharedEdits(boardID: shared.id, accountID: "owner", reason: "synthetic revocation", clearCachedContent: true)
        XCTAssertNil(try store.item(id: copy.id))
        try store.synchronized { try store.recoveryDatabaseBackup(reason: "failed-draft") }
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "sqlite3" })
        let reopened = try HistoryStore(databaseURL: backup)
        let recovered = try reopened.recoverFailedSharedDraft(operationID: operation.operationID, boardID: shared.id, accountID: "owner")
        XCTAssertEqual(try reopened.ownedFileBindings(recordID: recovered.id).count, 1)
        XCTAssertEqual(try archive(reopened, [recovered]).assets.count, 1)
    }

    func testImportRollbackIncludesOutboxAndCommitFailures() throws {
        let store = try store()
        let before = try folders(store)
        try store.configureSync(accountID: "synthetic")
        try store.execute("CREATE TRIGGER fail_owned_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'synthetic outbox failure'); END")
        XCTAssertThrowsError(try imported(store))
        XCTAssertEqual(try folders(store), before); XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM owned_file_assets", []), "0")
        try store.execute("DROP TRIGGER fail_owned_outbox")
        sqlite3_commit_hook(store.database, { _ in 1 }, nil)
        XCTAssertThrowsError(try imported(store))
        sqlite3_commit_hook(store.database, nil, nil)
        XCTAssertEqual(try folders(store), before); XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM owned_file_assets", []), "0")
    }

    func testDuplicateRecordRollbackPreservesPreviouslyOwnedFiles() throws {
        let store = try store(), original = try imported(store)
        let before = try folders(store), archiveBefore = try archive(store, [original])
        XCTAssertThrowsError(try store.create(original, ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "new.txt", data: Data([3]))],
                                               expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration()))
        XCTAssertEqual(try folders(store), before)
        XCTAssertEqual(try archive(store, [original]).assets, archiveBefore.assets)
    }

    func testInvalidNamesSlotsAndSymlinkPayloadAreRejected() throws {
        let store = try store()
        for name in ["../outside", "/absolute", "a/b", "a\\b", ".", "..", "bad\0name", ""] {
            XCTAssertThrowsError(try store.create(candidate(), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: name, data: Data())],
                                                   expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration()))
        }
        XCTAssertTrue(try folders(store).isEmpty)
        let original = try imported(store)
        let asset = try XCTUnwrap(archive(store, [original]).assets.first?.asset)
        let payload = store.ownedFileStorage.assetDirectory(asset.id).appendingPathComponent("payload")
        let external = directory.appendingPathComponent("outside")
        try Data("original 中文\0bytes".utf8).write(to: external)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)
        XCTAssertThrowsError(try archive(store, [original]))
        XCTAssertEqual(try Data(contentsOf: external), Data("original 中文\0bytes".utf8))
        XCTAssertNotNil(try store.itemMetadata(id: original.id))
    }

    func testAdoptionUsesExactRevisionAndAccountGenerationWithoutCloudPathEdit() throws {
        let store = try store()
        try store.configureSync(accountID: "A")
        let old = try store.create(candidate())
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        let queue = try store.pendingSyncOperations(accountID: "A")
        let imports = [OwnedFileImport(partIndex: 0, representationIndex: 0, filename: "legacy.txt", data: Data([4, 5]))]
        XCTAssertThrowsError(try store.registerOwnedFiles(recordID: old.id, expectedRevision: old.revision + 1, ownedFiles: imports,
                                                        expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing))
        let adopted = try store.registerOwnedFiles(recordID: old.id, expectedRevision: old.revision, ownedFiles: imports,
                                                   expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing)
        XCTAssertEqual(adopted.revision, old.revision + 1)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "A"), queue)
        XCTAssertEqual(try store.ownedFileBindings(recordID: old.id).count, 1)
        try store.configureSync(accountID: "B")
        let current = try store.syncConfiguration()
        XCTAssertThrowsError(try store.registerOwnedFiles(recordID: old.id, expectedRevision: adopted.revision, ownedFiles: [],
                                                        expectedSyncConfiguration: current, expectedSharingConfiguration: sharing))
        try store.configureSync(accountID: "A")
        XCTAssertThrowsError(try store.registerOwnedFiles(recordID: old.id, expectedRevision: adopted.revision, ownedFiles: [],
                                                        expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing))
    }

    func testPhysicalRecoverySnapshotRebasesOnlyTrustedRegisteredURLs() throws {
        let source = try store(), original = try imported(source)
        try source.synchronized { try source.recoveryDatabaseBackup(reason: "owned-test") }
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "sqlite3" })
        let recovered = try HistoryStore(databaseURL: backup)
        let record = try XCTUnwrap(recovered.item(id: original.id))
        XCTAssertNotEqual(record.parts, original.parts)
        let binding = try XCTUnwrap(recovered.ownedFileBindings(recordID: original.id).first)
        let url = try recovered.ownedFileURLWithoutLock(assetID: binding.assetID)
        XCTAssertEqual(try Data(contentsOf: url), Data("original 中文\0bytes".utf8))
        XCTAssertEqual(try archive(recovered, [record]).assets.count, 1)
        // Tampering with a stored URL cannot be hidden by read-time path relocation.
        var changed = record; changed.parts[0].representations[0].data = Data("file:///unrelated".utf8)
        let parts = try recovered.representations.encode(changed.parts)
        let statement = try recovered.prepare("UPDATE clipboard_records SET parts = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try recovered.bind(parts, at: 1, to: statement); try recovered.bind(record.id.uuidString, at: 2, to: statement)
        try recovered.stepToCompletion(statement)
        XCTAssertThrowsError(try recovered.item(id: record.id))
    }

    func testAcceptedSharedCacheRebuildPreservesOwnedFilesAfterPhysicalRelocation() throws {
        let source = try store(), board = try source.createPinboard(name: "Source")
        _ = try imported(source, board: board.id)
        try source.configureSharing(accountID: "owner")
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "owner", containerIdentifier: "iCloud.synthetic",
                                               zoneName: "ClipShelfShared_synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        let shared = try source.createSharedCopy(from: board.id, descriptor: descriptor)
        let operations = try source.pendingSharedOperations(boardID: shared.id, accountID: "owner")
        try source.acknowledgeSharedOperations(boardID: shared.id, accountID: "owner", operationIDs: Set(operations.map(\.operationID)))
        try source.synchronized { try source.recoveryDatabaseBackup(reason: "accepted-owned") }
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "sqlite3" })
        let reopened = try HistoryStore(databaseURL: backup)
        var current = try XCTUnwrap(reopened.search(.init(pinboardIDs: [shared.id])).first)
        current.renamedTitle = "rejected rename"
        _ = try reopened.update(record: current)
        try reopened.updateSharedAccess(boardID: shared.id, accountID: "owner", access: .readOnly)
        try reopened.rejectPendingSharedEdits(boardID: shared.id, accountID: "owner", reason: "downgraded")
        let restored = try XCTUnwrap(reopened.item(id: current.id))
        XCTAssertNil(restored.renamedTitle)
        XCTAssertEqual(try reopened.ownedFileBindings(recordID: restored.id).count, 1)
        XCTAssertEqual(try archive(reopened, [restored]).assets.count, 1)
    }

    func testOwnedSubdirectorySymlinkCannotRedirectReadsOrNewImports() throws {
        let store = try store(), original = try imported(store)
        let asset = try XCTUnwrap(archive(store, [original]).assets.first?.asset)
        let path = store.ownedFileStorage.assetDirectory(asset.id)
        let moved = directory.appendingPathComponent("moved-asset")
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
        XCTAssertThrowsError(try archive(store, [original]))
        let owned = store.ownedFileStorage.directory
        let oldOwned = owned.deletingLastPathComponent().appendingPathComponent("owned-previous")
        try FileManager.default.moveItem(at: owned, to: oldOwned)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: oldOwned)
        XCTAssertThrowsError(try imported(store))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldOwned.path).count, 1)
    }
}
