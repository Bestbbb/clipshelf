import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

private final class HistoryTestCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000_000
    private var measuringDescriptors = false
    private var peakDescriptors = 0
    func startDescriptorMeasurement() throws -> Int {
        let count = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        lock.lock(); defer { lock.unlock() }
        measuringDescriptors = true; peakDescriptors = count
        return count
    }
    func finishDescriptorMeasurement() -> Int {
        lock.lock(); defer { lock.unlock() }
        measuringDescriptors = false
        return peakDescriptors
    }
    func set(_ bytes: Int64) { lock.lock(); value = bytes; lock.unlock() }
    func read(_ destination: URL) -> StorageVolumeCapacity {
        lock.lock(); defer { lock.unlock() }
        if measuringDescriptors, let count = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count {
            peakDescriptors = max(peakDescriptors, count)
        }
        return .init(volumeID: "synthetic-test-volume", availableBytes: value)
    }
}

final class HistoryStorageSpaceTests: XCTestCase {
    private var directory: URL!
    private var capacity: HistoryTestCapacity!
    private var coordinator: StorageSpaceCoordinator!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capacity = HistoryTestCapacity()
        let capacity = capacity!
        coordinator = try StorageSpaceCoordinator(directory: directory.appendingPathComponent("reservations"),
                                                  capacityProvider: { capacity.read($0) })
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "target") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"), spaceCoordinator: coordinator)
    }
    private func insufficient(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let failure = error as? StorageWriteFailure, case .insufficientSpace = failure else {
                return XCTFail("Unexpected failure: \(error)", file: file, line: line)
            }
        }
    }
    private func binaryRecord(_ bytes: Data, text: String = "attachment") -> ClipboardRecord {
        ClipboardRecord(text: text, parts: [.init(representations: [.init(typeIdentifier: "public.data", data: bytes)])])
    }
    private func importOwned(_ store: HistoryStore, bytes: Data) throws -> ClipboardRecord {
        let record = ClipboardRecord(text: "example.txt", parts: [
            .init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])
        ])
        return try store.create(record, ownedFiles: [.init(partIndex: 0, representationIndex: 0,
            filename: "example.txt", data: bytes)], expectedSyncConfiguration: store.syncConfiguration(),
            expectedSharingConfiguration: store.sharingConfiguration())
    }

    func testCaptureAndEditFailBeforePublishingAndRetryAfterCapacityReturns() throws {
        let store = try store(), original = try store.record(.init(text: "keep original"))
        let candidate = ClipboardRecord(text: "next capture")
        var edited = original; edited.text = "edited content"
        capacity.set(0)
        insufficient { _ = try store.record(candidate) }
        insufficient { _ = try store.update(record: edited) }
        XCTAssertEqual(try store.load(), [original])
        capacity.set(10_000_000)
        XCTAssertEqual(try store.record(candidate).id, candidate.id)
        XCTAssertEqual(try store.update(record: edited).text, edited.text)
    }

    func testDuplicateCaptureIsBudgetedButDeletionAndReadRemainAvailable() throws {
        let store = try store(), original = try store.record(.init(text: "duplicate"))
        capacity.set(0)
        insufficient { _ = try store.record(.init(text: original.text)) }
        XCTAssertEqual(try store.load(), [original])
        try store.delete(id: original.id)
        XCTAssertTrue(try store.load().isEmpty)
        try store.clear()
        let reopened = try self.store()
        XCTAssertTrue(try reopened.load().isEmpty)
    }

    func testExistingDigestDoesNotReserveAnotherAttachmentCopy() throws {
        let store = try store(), bytes = Data(repeating: 37, count: 2_000_000)
        let first = try store.create(binaryRecord(bytes))
        // Enough for database pages, but nowhere near enough for another 2 MB blob.
        capacity.set(600_000)
        var same = first; same.id = UUID(); same.text = "same immutable bytes"
        XCTAssertEqual(try store.create(same).id, same.id)
        let fresh = binaryRecord(Data(repeating: 38, count: bytes.count), text: "new digest")
        insufficient { _ = try store.create(fresh) }
        XCTAssertEqual(try store.load().count, 2)
        let blobs = try FileManager.default.contentsOfDirectory(at: store.representations.directory,
                                                                includingPropertiesForKeys: nil).filter { $0.pathExtension == "blob" }
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(try Data(contentsOf: blobs[0]), bytes)
    }

    func testOwnedImportRequiresBothPhysicalCopiesAndRollsBackItsDatabaseRows() throws {
        let store = try store(), bytes = Data(repeating: 61, count: 1_000_000)
        // One copy fits; payload and editable projection together do not.
        capacity.set(Int64(bytes.count * 2) + 65_536 - 1)
        insufficient { _ = try importOwned(store, bytes: bytes) }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.ownedFileStorage.directory.path).isEmpty)
        capacity.set(10_000_000)
        let record = try importOwned(store, bytes: bytes)
        let binding = try XCTUnwrap(store.ownedFileBindings(recordID: record.id).first)
        let asset = try store.ownedFileAssetWithoutLock(id: binding.assetID)
        XCTAssertEqual(try store.ownedFileStorage.read(asset), bytes)
        XCTAssertEqual(try Data(contentsOf: store.ownedFileStorage.fileURL(asset)), bytes)
    }

    func testMissingOwnedProjectionNeedsOnlyOneNewCopyAndNeverChangesPayload() throws {
        let store = try store(), bytes = Data(repeating: 15, count: 1_000_000)
        let record = try importOwned(store, bytes: bytes)
        let binding = try XCTUnwrap(store.ownedFileBindings(recordID: record.id).first)
        let asset = try store.ownedFileAssetWithoutLock(id: binding.assetID)
        let url = try store.ownedFileStorage.fileURL(asset)
        try FileManager.default.removeItem(at: url)
        capacity.set(Int64(bytes.count - 1))
        insufficient { _ = try store.ownedFileStorage.restoreMissingProjection(asset) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.ownedFileStorage.read(asset), bytes)
        capacity.set(Int64(bytes.count))
        _ = try store.ownedFileStorage.restoreMissingProjection(asset)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testReplacementReservesRecoveryArchiveAlongsideNewLibraryAndLeavesOldDataOnFailure() throws {
        let source = try store("source"), target = try store()
        let incoming = try source.create(.init(text: "incoming"))
        let archive = directory.appendingPathComponent("source.clipshelfbackup")
        try source.exportBackup(to: archive)
        let original = try target.create(.init(text: String(repeating: "retain", count: 200_000)))
        let prepared = try target.prepareBackupRestore(from: archive, mode: .replace)
        // The small replacement fits on its own, but its mandatory recovery archive does not.
        capacity.set(1_000_000)
        insufficient { _ = try target.restoreBackup(prepared) }
        XCTAssertEqual(try target.load(), [original])
        let backups = directory.appendingPathComponent("Backups")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        capacity.set(100_000_000)
        let restored = try target.restoreBackup(prepared)
        XCTAssertEqual(try target.load(), [incoming])
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.recoveryBackupURL.path))
        let recovered = try store("recovered")
        _ = try recovered.restoreBackup(from: restored.recoveryBackupURL, mode: .replace)
        XCTAssertEqual(try recovered.load(), [original])
    }

    func testPreparedArchiveBytesRemainAvailableWithoutExportDiskCapacity() throws {
        let store = try store(), original = try store.create(.init(text: "frozen snapshot"))
        let bytes = try store.exportBackupData()
        capacity.set(0)
        XCTAssertEqual(try store.exportBackupData(), bytes)
        let destination = directory.appendingPathComponent("export.clipshelfbackup")
        insufficient { try store.exportBackup(to: destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.load(), [original])
        capacity.set(Int64(bytes.count))
        try store.exportBackup(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testRealSQLiteFullRollsBackEditAndLeavesConnectionAndRetryUsable() throws {
        let store = try store(), original = try store.create(.init(text: "durable original"))
        // SQLite's own database-page ceiling triggers SQLITE_FULL without filling any disk.
        try store.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let pages = try scalar(store, "PRAGMA page_count")
        try store.execute("PRAGMA max_page_count = \(pages)")
        var edited = original; edited.text = String(repeating: "new long value ", count: 100_000)
        XCTAssertThrowsError(try store.update(record: edited)) { error in
            XCTAssertEqual(error as? StorageWriteFailure, .diskFull)
        }
        XCTAssertEqual(try store.item(id: original.id), original)
        try store.execute("PRAGMA max_page_count = 2147483646")
        let retried = try store.update(record: edited)
        XCTAssertEqual(retried.text, edited.text)
        XCTAssertEqual(try self.store().item(id: original.id), retried)
        // No failed operation's cooperative lease remains held.
        capacity.set(500_000)
        XCTAssertEqual(try store.create(.init(text: "after failure")).text, "after failure")
    }

    func testOutboxFailureRemovesBothOwnedCopiesAndReleasesBudgetForRetry() throws {
        let store = try store(), bytes = Data(repeating: 3, count: 50_000)
        try store.configureSync(accountID: "space-test-account")
        try store.execute("CREATE TRIGGER synthetic_outbox_failure BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END")
        XCTAssertThrowsError(try importOwned(store, bytes: bytes))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.ownedFileStorage.directory.path).isEmpty)
        try store.execute("DROP TRIGGER synthetic_outbox_failure")
        capacity.set(1_000_000)
        let record = try importOwned(store, bytes: bytes)
        XCTAssertEqual(try store.load().map(\.id), [record.id])
    }

    func testPinboardCreationRenameAndSidebarOrderRequireAdmission() throws {
        let store = try store()
        let first = try store.createPinboard(name: "first"), second = try store.createPinboard(name: "second")
        var renamed = first; renamed.name = "renamed"
        capacity.set(0)
        insufficient { _ = try store.createPinboard(name: "new board") }
        insufficient { try store.updatePinboard(renamed) }
        insufficient { try store.reorderPinboards(ids: [second.id, first.id]) }
        XCTAssertEqual(try store.pinboards().map(\.id), [first.id, second.id])
        XCTAssertEqual(try store.pinboards().first?.name, first.name)
        capacity.set(2_000_000)
        try store.updatePinboard(renamed)
        try store.reorderPinboards(ids: [second.id, first.id])
        XCTAssertEqual(try store.pinboards().map(\.id), [second.id, first.id])
    }

    func testLocalMoveRequiresAdmissionAndLeavesPlacementAndRevisionIntactOnFailure() throws {
        let store = try store(), board = try store.createPinboard(name: "destination")
        let original = try store.create(.init(text: "local item"))
        capacity.set(0)
        insufficient { try store.move(recordID: original.id, to: board.id) }
        XCTAssertEqual(try store.item(id: original.id), original)
        capacity.set(2_000_000)
        try store.move(recordID: original.id, to: board.id)
        let moved = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(moved.pinboardID, board.id)
        XCTAssertEqual(moved.revision, original.revision + 1)
    }

    func testSyncedOrderingBudgetsTheActualLargeAttachmentOutboxPayload() throws {
        let store = try store(), account = "ordering-budget"
        try store.configureSync(accountID: account)
        let board = try store.createPinboard(name: "synced board")
        var candidate = binaryRecord(Data(repeating: 91, count: 2_000_000))
        candidate.pinboardID = board.id
        let first = try store.create(candidate)
        candidate.id = UUID(); candidate.text = "second attachment"
        let second = try store.create(candidate)
        let queued = try store.pendingSyncOperations(accountID: account)
        try store.acknowledgeSyncOperations(accountID: account, operationIDs: Set(queued.map(\.operationID)))
        // Placement metadata fits, but the serialized full image payload cannot fit.
        capacity.set(700_000)
        insufficient { try store.move(recordIDs: [second.id], to: board.id, before: first.id) }
        XCTAssertEqual(try store.item(id: second.id), second)
        XCTAssertTrue(try store.pendingSyncOperations(accountID: account).isEmpty)
        capacity.set(30_000_000)
        try store.move(recordIDs: [second.id], to: board.id, before: first.id)
        let operation = try XCTUnwrap(store.pendingSyncOperations(accountID: account).first)
        XCTAssertEqual(operation.entityID, second.id)
        XCTAssertEqual(operation.orderingOnly, true)
        XCTAssertEqual(operation.record?.parts, second.parts)
    }

    func testShrinkingLargeOldTextStillReservesItsOverflowAndIndexRewrite() throws {
        let store = try store()
        let original = try store.create(.init(text: String(repeating: "large old body ", count: 100_000)))
        var short = original; short.text = "small replacement"
        // Enough for the replacement alone, not for zeroing/rewriting old overflow and index pages.
        capacity.set(500_000)
        insufficient { _ = try store.update(record: short) }
        XCTAssertEqual(try store.item(id: original.id), original)
        capacity.set(50_000_000)
        let updated = try store.update(record: short)
        XCTAssertEqual(updated.text, short.text)
        XCTAssertEqual(updated.revision, original.revision + 1)
    }

    func testEmptyReplacementReservesOldDatabaseRewriteBeyondItsRecoveryArchive() throws {
        let empty = try store("empty"), target = try store()
        let archive = directory.appendingPathComponent("empty.clipshelfbackup")
        try empty.exportBackup(to: archive)
        let original = try target.create(.init(text: String(repeating: "old pages ", count: 150_000)))
        let recoveryBytes = try target.exportBackupData().count
        let prepared = try target.prepareBackupRestore(from: archive, mode: .replace)
        let oldDatabaseBytes = try scalar(target, "PRAGMA page_count") * scalar(target, "PRAGMA page_size")
        XCTAssertGreaterThan(oldDatabaseBytes, 500_000)
        // The archive and an empty new library fit; the existing database's secure-delete WAL pass does not.
        capacity.set(Int64(recoveryBytes) + 500_000)
        insufficient { _ = try target.restoreBackup(prepared) }
        XCTAssertEqual(try target.load(), [original])
        capacity.set(100_000_000)
        let result = try target.restoreBackup(prepared)
        XCTAssertTrue(try target.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recoveryBackupURL.path))
    }

    func testLowSpaceHistoryCleanupCanPreservePinnedContentAndEnqueueItsSyncState() throws {
        let store = try store(), account = "cleanup-budget"
        try store.configureSync(accountID: account)
        let board = try store.createPinboard(name: "keep")
        var candidate = binaryRecord(Data(repeating: 83, count: 100_000))
        candidate.pinboardID = board.id
        let pinned = try store.create(candidate)
        let unpinned = try store.create(.init(text: "remove from history"))
        let queued = try store.pendingSyncOperations(accountID: account)
        try store.acknowledgeSyncOperations(accountID: account, operationIDs: Set(queued.map(\.operationID)))
        let plan = try store.prepareHistoryCleanup()
        capacity.set(0)
        let result = try store.commitHistoryCleanup(plan)
        XCTAssertEqual(result.summary.deletedCount, 1)
        XCTAssertEqual(result.summary.preservedPinnedCount, 1)
        XCTAssertNil(try store.item(id: unpinned.id))
        let kept = try XCTUnwrap(store.item(id: pinned.id))
        XCTAssertFalse(kept.isInHistory)
        XCTAssertEqual(kept.parts, pinned.parts)
        XCTAssertEqual(kept.pinboardID, board.id)
        let pending = try store.pendingSyncOperations(accountID: account)
        XCTAssertTrue(pending.contains { $0.entityID == pinned.id && $0.record?.isInHistory == false })
        XCTAssertTrue(pending.contains { $0.entityID == unpinned.id && $0.action == .delete })
        // The reclaim-only exception does not leak into a later ordinary content mutation.
        var edited = kept; edited.text = "must wait for capacity"
        insufficient { _ = try store.update(record: edited) }
        XCTAssertEqual(try store.item(id: pinned.id), kept)
    }

    func testMissingParentInboxPayloadRequiresAdmissionAndReplayDoesNotReserveItAgain() throws {
        let store = try store(), account = "missing-parent-budget"
        try store.configureSync(accountID: account)
        let candidate = binaryRecord(Data(repeating: 29, count: 1_000_000))
        let operation = SyncOperation(accountID: account, entityID: candidate.id, entityKind: .clipboard,
            action: .upsert, baseRevision: 1, revision: 2, baseOperationID: UUID(), record: candidate)
        let cursor = Data("pending-parent".utf8)
        capacity.set(0)
        insufficient { try store.applyRemoteChanges(accountID: account, changes: [operation], nextCursor: cursor) }
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM sync_inbox"), 0)
        XCTAssertNil(try store.syncCursor(accountID: account))
        capacity.set(20_000_000)
        try store.applyRemoteChanges(accountID: account, changes: [operation], nextCursor: cursor)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM sync_inbox"), 1)
        XCTAssertNil(try store.item(id: candidate.id), "Missing parent keeps the durable payload outside record binding")
        capacity.set(0)
        try store.applyRemoteChanges(accountID: account, changes: [operation], nextCursor: cursor)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM sync_inbox"), 1)
        XCTAssertEqual(try store.syncCursor(accountID: account), cursor)
    }

    func testSharedMissingParentBudgetsBothAcceptedAndInboxCopiesAtomically() throws {
        let store = try store(), account = "shared-inbox-budget"
        try store.configureSharing(accountID: account)
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: account, containerIdentifier: "iCloud.synthetic",
            zoneName: "ClipShelfShared_synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        try store.registerSharedBoard(descriptor, access: .readOnly)
        var candidate = binaryRecord(Data(repeating: 33, count: 1_000_000))
        candidate.pinboardID = descriptor.boardID
        let operation = SyncOperation(accountID: descriptor.namespace, entityID: candidate.id, entityKind: .clipboard,
            action: .upsert, baseRevision: 1, revision: 2, baseOperationID: UUID(), record: candidate)
        let oneCopyBudget = Int64(try JSONEncoder().encode(operation).count) * 3 + 131_072
        capacity.set(oneCopyBudget + 100_000)
        insufficient { try store.applySharedChanges(boardID: descriptor.boardID, accountID: account,
            changes: [operation], nextCursor: Data("shared-cursor".utf8)) }
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM shared_accepted_operations"), 0)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM sync_inbox"), 0)
        XCTAssertNil(try store.sharedCursor(boardID: descriptor.boardID, accountID: account))
        capacity.set(oneCopyBudget * 2 + 100_000)
        try store.applySharedChanges(boardID: descriptor.boardID, accountID: account, changes: [operation], nextCursor: nil)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM shared_accepted_operations"), 1)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM sync_inbox"), 1)
        capacity.set(0)
        try store.applySharedChanges(boardID: descriptor.boardID, accountID: account, changes: [operation], nextCursor: nil)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM shared_accepted_operations"), 1)
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM sync_inbox"), 1)
    }

    func testSharedAcknowledgementReservesAcceptedCopyBeforeDeletingOutbox() throws {
        let store = try store(), account = "shared-ack-budget"
        let sourceBoard = try store.createPinboard(name: "source")
        var candidate = binaryRecord(Data(repeating: 72, count: 1_000_000))
        candidate.pinboardID = sourceBoard.id
        _ = try store.create(candidate)
        try store.configureSharing(accountID: account)
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: account, containerIdentifier: "iCloud.synthetic",
            zoneName: "ClipShelfShared_synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        _ = try store.createSharedCopy(from: sourceBoard.id, descriptor: descriptor)
        let operation = try XCTUnwrap(store.pendingSharedOperations(boardID: descriptor.boardID, accountID: account).first { $0.record != nil })
        capacity.set(500_000)
        insufficient { try store.acknowledgeSharedOperations(boardID: descriptor.boardID, accountID: account,
            operationIDs: [operation.operationID]) }
        XCTAssertTrue(try store.pendingSharedOperations(boardID: descriptor.boardID, accountID: account).contains(operation))
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM shared_accepted_operations"), 0)
        capacity.set(20_000_000)
        try store.acknowledgeSharedOperations(boardID: descriptor.boardID, accountID: account, operationIDs: [operation.operationID])
        XCTAssertFalse(try store.pendingSharedOperations(boardID: descriptor.boardID, accountID: account).contains(operation))
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM shared_accepted_operations"), 1)
        // Recreate a duplicate pending entry to model an interrupted acknowledgement replay.
        try store.syncExecute("INSERT INTO sync_outbox(operation_id, account_id, payload) SELECT operation_id, namespace, payload FROM shared_accepted_operations WHERE operation_id = ?", [operation.operationID.uuidString])
        capacity.set(0)
        try store.acknowledgeSharedOperations(boardID: descriptor.boardID, accountID: account, operationIDs: [operation.operationID])
        XCTAssertFalse(try store.pendingSharedOperations(boardID: descriptor.boardID, accountID: account).contains(operation))
        XCTAssertEqual(try scalar(store, "SELECT count(*) FROM shared_accepted_operations"), 1)
        // An ID match with different bytes is not proof that the pending operation was retained.
        try store.syncExecute("INSERT INTO sync_outbox(operation_id, account_id, payload) SELECT operation_id, namespace, payload FROM shared_accepted_operations WHERE operation_id = ?", [operation.operationID.uuidString])
        try store.syncExecute("UPDATE shared_accepted_operations SET payload = x'01' WHERE operation_id = ?", [operation.operationID.uuidString])
        XCTAssertThrowsError(try store.acknowledgeSharedOperations(boardID: descriptor.boardID, accountID: account,
            operationIDs: [operation.operationID]))
        XCTAssertTrue(try store.pendingSharedOperations(boardID: descriptor.boardID, accountID: account).contains(operation))
    }

    func testMergePrepaymentIncludesEveryRetainedSidebarPosition() throws {
        let source = try store("sidebar-source"), target = try store()
        let incoming = try source.createPinboard(name: "incoming")
        let archive = directory.appendingPathComponent("sidebar.clipshelfbackup")
        try source.exportBackup(to: archive)
        var originals: [Pinboard] = []
        for index in 0..<24 { originals.append(try target.createPinboard(name: "retained \(index)")) }
        let recoveryBytes = try target.exportBackupData().count
        let prepared = try target.prepareBackupRestore(from: archive, mode: .merge)
        // The incoming board and its order fit, but rewriting all 24 retained positions does not.
        capacity.set(Int64(recoveryBytes) + 450_000)
        insufficient { _ = try target.restoreBackup(prepared) }
        XCTAssertEqual(try target.pinboards(), originals)
        capacity.set(10_000_000)
        let result = try target.restoreBackup(prepared)
        XCTAssertEqual(result.importedPinboards, 1)
        XCTAssertEqual(try target.pinboards().map(\.id), originals.map(\.id) + [incoming.id])
    }

    func testMovingHundredsOfItemsKeepsTransactionReservationDescriptorsBounded() throws {
        let store = try store(), board = try store.createPinboard(name: "large selection")
        var records: [ClipboardRecord] = []
        for index in 0..<320 { records.append(try store.create(.init(text: "batch item \(index)"))) }
        let baseline = try capacity.startDescriptorMeasurement()
        try store.move(recordIDs: records.map(\.id), to: board.id)
        let peak = capacity.finishDescriptorMeasurement()
        XCTAssertLessThan(peak - baseline, 64,
            "A transaction must extend one reservation, not keep hundreds of lease descriptors alive")
        // A pinboard filter still defaults to recent capture order; validate the explicit
        // board placement order against the complete ordered selection passed to move.
        let moved = try store.search(.init(pinboardIDs: [board.id], limit: 1_000, sortOrder: .pinboard))
        XCTAssertEqual(moved.map(\.id), records.map(\.id))
        XCTAssertTrue(moved.allSatisfy { $0.revision == 2 })
        // The completed batch released its aggregate reservation rather than retaining its sum.
        capacity.set(500_000)
        XCTAssertEqual(try store.create(.init(text: "after large batch")).text, "after large batch")
    }

    private func scalar(_ store: HistoryStore, _ query: String) throws -> Int64 {
        let statement = try store.prepare(query)
        defer { sqlite3_finalize(statement) }
        try store.check(sqlite3_step(statement), allowingRow: true)
        return sqlite3_column_int64(statement, 0)
    }
}
