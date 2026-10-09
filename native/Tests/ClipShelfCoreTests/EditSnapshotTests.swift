import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class EditSnapshotTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-edit-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "history") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"))
    }
    private func ref(_ record: ClipboardRecord) -> ClipboardSelectionReference { .init(id: record.id, revision: record.revision) }
    private func revised(_ snapshot: ClipboardEditSnapshot, text: String = "edited") -> ClipboardRecord {
        var record = snapshot.record; record.text = text; return record
    }
    private func shared(_ store: HistoryStore) throws -> (Pinboard, ClipboardRecord) {
        let local = try store.createPinboard(name: "Local")
        _ = try store.create(ClipboardRecord(text: "shared original", pinboardID: local.id))
        try store.configureSharing(accountID: "A")
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "A", containerIdentifier: "iCloud.synthetic",
            zoneName: "fixture", zoneOwnerName: "fixture-owner", shareRecordName: "fixture-share")
        let board = try store.createSharedCopy(from: local.id, descriptor: descriptor)
        return (board, try XCTUnwrap(store.search(.init(pinboardIDs: [board.id])).first))
    }

    func testPrepareIsReadOnlyAndCommitUndoPreservesExactOriginalAndIndex() throws {
        let store = try store()
        let original = try store.create(ClipboardRecord(text: "原件", sourceApp: "Fixture", copiedAt: Date(timeIntervalSince1970: 123),
            rtf: Data([1, 2, 3]), html: Data("<p>原件</p>".utf8),
            parts: [.init(representations: [.init(typeIdentifier: "org.example.opaque", data: Data([0, 255, 8]))])],
            renamedTitle: "Keep title", ocrText: "old OCR", originDeviceID: UUID(), originDeviceName: "Origin"))
        let changes = sqlite3_total_changes64(store.database)
        let snapshot = try store.prepareEdit(ref(original))
        XCTAssertEqual(snapshot.record, original)
        XCTAssertEqual(snapshot.syncConfiguration, try store.syncConfiguration())
        XCTAssertEqual(snapshot.sharingConfiguration, try store.sharingConfiguration())
        XCTAssertEqual(sqlite3_total_changes64(store.database), changes)
        var edit = revised(snapshot, text: "新正文")
        edit.rtf = nil; edit.html = nil
        edit.parts = [.init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data(edit.text.utf8))])]
        let undo = try store.commitEdit(edit, snapshot: snapshot)
        let committed = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(undo.original, original)
        XCTAssertEqual(undo.committedReference, ref(committed))
        XCTAssertEqual(committed.revision, original.revision + 1)
        XCTAssertEqual(committed.originDeviceID, original.originDeviceID)
        XCTAssertNil(committed.ocrText)
        XCTAssertEqual(try store.searchMetadata(.init(text: "新正文")).map(\.id), [original.id])
        XCTAssertTrue(try store.searchMetadata(.init(text: "原件")).isEmpty)
        _ = try store.undoSelectionEdit(undo)
        var expected = original; expected.revision += 2
        XCTAssertEqual(try store.item(id: original.id), expected)
        XCTAssertThrowsError(try store.commitEdit(edit, snapshot: snapshot), "Undo must not make the old editor reusable")
        XCTAssertThrowsError(try store.undoSelectionEdit(undo))
    }

    func testStaleRevisionDeletedRecordAndForgedEditedIdentityAreRejected() throws {
        let store = try store(), peer = try self.store()
        let original = try store.create(ClipboardRecord(text: "original"))
        let snapshot = try store.prepareEdit(ref(original))
        var wrongID = revised(snapshot); wrongID.id = UUID()
        XCTAssertThrowsError(try store.commitEdit(wrongID, snapshot: snapshot))
        var wrongRevision = revised(snapshot); wrongRevision.revision += 1
        XCTAssertThrowsError(try store.commitEdit(wrongRevision, snapshot: snapshot))
        var external = original; external.text = "outside edit"
        let current = try peer.update(record: external)
        XCTAssertThrowsError(try store.prepareEdit(ref(original)))
        XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
        XCTAssertEqual(try store.item(id: original.id), current)
        let latest = try store.prepareEdit(ref(current))
        try peer.delete(id: current.id)
        XCTAssertThrowsError(try store.prepareEdit(ref(current)))
        XCTAssertThrowsError(try store.commitEdit(revised(latest), snapshot: latest))
        XCTAssertNil(try store.item(id: original.id))
    }

    func testDisplayOnlySnapshotAndCrossStoreIncludingSameDatabaseHandleCannotCommit() throws {
        let store = try store(), sameDatabase = try self.store(), other = try self.store("other")
        let original = try store.create(ClipboardRecord(text: "original"))
        _ = try other.create(original)
        let snapshot = try store.prepareEdit(ref(original))
        for forged in [ClipboardEditSnapshot(record: original),
                       ClipboardEditSnapshot(record: original, syncConfiguration: snapshot.syncConfiguration,
                                             sharingConfiguration: snapshot.sharingConfiguration)] {
            XCTAssertThrowsError(try store.commitEdit(revised(forged), snapshot: forged))
        }
        XCTAssertThrowsError(try sameDatabase.commitEdit(revised(snapshot), snapshot: snapshot))
        XCTAssertThrowsError(try other.commitEdit(revised(snapshot), snapshot: snapshot))
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertEqual(try other.item(id: original.id), original)
    }

    func testBothAccountConfigurationRoundTripsInvalidateAnOtherwiseIdenticalSnapshot() throws {
        for sharing in [false, true] {
            let store = try store(sharing ? "sharing" : "sync")
            if sharing { try store.configureSharing(accountID: "A") } else { try store.configureSync(accountID: "A") }
            let original = try store.create(ClipboardRecord(text: "original"))
            let snapshot = try store.prepareEdit(ref(original))
            if sharing {
                try store.configureSharing(accountID: "B"); try store.configureSharing(accountID: "A")
                XCTAssertNotEqual(snapshot.sharingConfiguration, try store.sharingConfiguration())
            } else {
                try store.configureSync(accountID: "B"); try store.configureSync(accountID: "A")
                XCTAssertNotEqual(snapshot.syncConfiguration, try store.syncConfiguration())
            }
            XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
            XCTAssertEqual(try store.item(id: original.id), original)
            let fresh = try store.prepareEdit(ref(original))
            XCTAssertNoThrow(try store.commitEdit(revised(fresh), snapshot: fresh))
        }
    }

    func testPrepareRejectsInactivePrivateAccountForPinnedAndUnpinnedRecords() throws {
        let store = try store()
        try store.configureSync(accountID: "A")
        let board = try store.createPinboard(name: "A board")
        let pinned = try store.create(ClipboardRecord(text: "pinned A", pinboardID: board.id))
        let unpinned = try store.create(ClipboardRecord(text: "unpinned A"))
        try store.configureSync(accountID: "B")
        XCTAssertThrowsError(try store.prepareEdit(ref(pinned)))
        XCTAssertThrowsError(try store.prepareEdit(ref(unpinned)))
        XCTAssertEqual(try store.item(id: pinned.id), pinned)
        XCTAssertEqual(try store.item(id: unpinned.id), unpinned)
    }

    func testSharedReadOnlyAndRevocationAreCheckedBothAtPrepareAndCommit() throws {
        for access in [SharedBoardAccess.readOnly, .revoked] {
            let store = try store(access == .readOnly ? "readonly" : "revoked")
            let (board, original) = try shared(store)
            let snapshot = try store.prepareEdit(ref(original))
            try store.updateSharedAccess(boardID: board.id, accountID: "A", access: access)
            XCTAssertEqual(try store.sharingConfiguration(), snapshot.sharingConfiguration,
                           "Permission loss is separate from the account-generation guard")
            XCTAssertThrowsError(try store.prepareEdit(ref(original)))
            XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
            XCTAssertEqual(try store.item(id: original.id), original)
        }
    }

    func testSharedCachedRecordCannotBePreparedForAnotherAccount() throws {
        let store = try store(), (_, original) = try shared(store)
        try store.configureSharing(accountID: "B")
        XCTAssertThrowsError(try store.prepareEdit(ref(original)))
        XCTAssertNotNil(try store.item(id: original.id))
    }

    func testSameRevisionExternalReplacementCannotBeOverwrittenByOldDraft() throws {
        let store = try store(), peer = try self.store()
        let original = try store.create(ClipboardRecord(text: "original", parts: [
            .init(representations: [.init(typeIdentifier: "org.example.opaque", data: Data([1, 2]))])]))
        let snapshot = try store.prepareEdit(ref(original))
        try peer.syncExecute("UPDATE clipboard_records SET text = ? WHERE id = ?", ["replacement at same revision", original.id.uuidString])
        XCTAssertEqual(try store.item(id: original.id)?.revision, original.revision)
        XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
        XCTAssertEqual(try store.item(id: original.id)?.text, "replacement at same revision")
        let changed = try store.prepareEdit(ref(original))
        let replacement = try peer.representations.encode([.init(representations: [.init(typeIdentifier: "org.example.opaque", data: Data([9, 8]))])])
        try peer.syncExecute("UPDATE clipboard_records SET parts = CAST(? AS BLOB) WHERE id = ?",
                             [String(decoding: replacement, as: UTF8.self), original.id.uuidString])
        XCTAssertThrowsError(try store.commitEdit(revised(changed), snapshot: changed))
        XCTAssertEqual(try store.item(id: original.id)?.parts[0].representations[0].data, Data([9, 8]))
    }

    func testBackupReplacementAtSameIDAndRevisionInvalidatesOpenEditor() throws {
        let store = try store(), donor = try self.store("donor")
        let original = try store.create(ClipboardRecord(text: "before restore"))
        let snapshot = try store.prepareEdit(ref(original))
        var replacement = original; replacement.text = "from backup"
        _ = try donor.create(replacement)
        let archive = directory.appendingPathComponent("replacement.clipshelf")
        try donor.exportBackup(to: archive)
        _ = try store.restoreBackup(from: archive, mode: .replace)
        XCTAssertEqual(try store.item(id: original.id)?.revision, snapshot.record.revision)
        XCTAssertEqual(try store.syncConfiguration(), snapshot.syncConfiguration)
        XCTAssertEqual(try store.sharingConfiguration(), snapshot.sharingConfiguration)
        XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
        XCTAssertEqual(try store.item(id: original.id)?.text, "from backup")
    }

    func testSnapshotCommitAndUndoKeepOwnedFileBindings() throws {
        let store = try store()
        let record = ClipboardRecord(text: "owned.txt", parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data("file:///synthetic/placeholder".utf8))])])
        let original = try store.create(record, ownedFiles: [.init(partIndex: 0, representationIndex: 0,
            filename: "owned.txt", data: Data("original owned bytes".utf8))],
            expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        let snapshot = try store.prepareEdit(ref(original)), bindings = try store.ownedFileBindings(recordID: original.id)
        var edit = snapshot.record; edit.renamedTitle = "Changed title"
        let undo = try store.commitEdit(edit, snapshot: snapshot)
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id), bindings)
        _ = try store.undoSelectionEdit(undo)
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id), bindings)
        var expected = original; expected.revision += 2
        XCTAssertEqual(try store.item(id: original.id), expected)
        let url = try XCTUnwrap(ClipboardFileAccess.url(from: original.parts[0].representations[0].data))
        XCTAssertEqual(try Data(contentsOf: url), Data("original owned bytes".utf8))
    }

    func testBudgetPreflightRejectsOversizedMetadataBeforeLoadingMissingAttachments() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "small"))
        let metadata = try JSONEncoder().encode((0..<9).map { index in
            [StoredRepresentation(typeIdentifier: "org.example.part\(index)", digest: String(repeating: "a", count: 64),
                                  byteCount: RepresentationStorage.maximumRepresentationBytes)]
        })
        try store.syncExecute("UPDATE clipboard_records SET parts = CAST(? AS BLOB) WHERE id = ?",
                              [String(decoding: metadata, as: UTF8.self), original.id.uuidString])
        XCTAssertThrowsError(try store.prepareEdit(ref(original))) { error in
            guard case HistoryStoreError.selectionPayloadTooLarge = error else { return XCTFail("Expected metadata budget refusal, got \(error)") }
        }
    }

    func testMissingOriginalRepresentationRefusesPrepareWithoutChangingMetadata() throws {
        let store = try store(), bytes = Data([4, 5, 6])
        let original = try store.create(ClipboardRecord(text: "original", parts: [.init(representations: [
            .init(typeIdentifier: "org.example.opaque", data: bytes)])]))
        try FileManager.default.removeItem(at: store.representations.url(for: RepresentationStorage.digest(bytes)))
        let before = try store.itemMetadata(id: original.id)
        XCTAssertThrowsError(try store.prepareEdit(ref(original)))
        XCTAssertEqual(try store.itemMetadata(id: original.id), before)
    }

    func testUpdateAndOutboxFailuresRollBackThenSameSnapshotCanSaveAndUndo() throws {
        for outbox in [false, true] {
            let store = try store(outbox ? "outbox-fail" : "update-fail")
            try store.configureSync(accountID: "A")
            let original = try store.create(ClipboardRecord(text: "original"))
            let snapshot = try store.prepareEdit(ref(original)), before = try store.pendingSyncOperations(accountID: "A")
            let table = outbox ? "sync_outbox" : "clipboard_records", event = outbox ? "INSERT" : "UPDATE"
            try store.execute("CREATE TRIGGER reject_edit BEFORE \(event) ON \(table) BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
            XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
            XCTAssertEqual(try store.item(id: original.id), original)
            XCTAssertEqual(try store.pendingSyncOperations(accountID: "A"), before)
            try store.execute("DROP TRIGGER reject_edit")
            let undo = try store.commitEdit(revised(snapshot), snapshot: snapshot)
            _ = try store.undoSelectionEdit(undo)
            var expected = original; expected.revision += 2
            XCTAssertEqual(try store.item(id: original.id), expected)
            XCTAssertEqual(try store.pendingSyncOperations(accountID: "A").count, before.count + 2)
        }
    }

    func testCommitFailureRollsBackRecordAndOutbox() throws {
        let store = try store(); try store.configureSync(accountID: "A")
        let original = try store.create(ClipboardRecord(text: "original"))
        let snapshot = try store.prepareEdit(ref(original)), before = try store.pendingSyncOperations(accountID: "A")
        sqlite3_commit_hook(store.database, { _ in 1 }, nil)
        XCTAssertThrowsError(try store.commitEdit(revised(snapshot), snapshot: snapshot))
        sqlite3_commit_hook(store.database, nil, nil)
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "A"), before)
        XCTAssertNoThrow(try store.commitEdit(revised(snapshot), snapshot: snapshot))
    }
}
