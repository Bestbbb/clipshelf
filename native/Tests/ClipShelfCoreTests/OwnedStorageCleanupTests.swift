import CSQLite
import Darwin
import Foundation
import XCTest
@testable import ClipShelfCore

final class OwnedStorageCleanupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func store(_ name: String = "db") throws -> HistoryStore { try HistoryStore(databaseURL: root.appendingPathComponent(name + ".sqlite")) }
    private func imported(_ store: HistoryStore, bytes: Data = Data("original".utf8)) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: "file", parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])]),
                         ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "one.txt", data: bytes)],
                         expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }
    private func asset(_ store: HistoryStore, record: ClipboardRecord) throws -> OwnedFileAsset {
        try store.ownedFileAssetWithoutLock(id: XCTUnwrap(store.ownedFileBindings(recordID: record.id).first).assetID)
    }
    func testUnreferencedBytesAreActuallyRemovedOnlyAfterFrozenConfirmation() throws {
        let store = try store(), record = try imported(store), asset = try asset(store, record: record)
        try store.delete(id: record.id)
        let plan = try store.prepareOwnedStorageCleanup()
        XCTAssertEqual(plan.candidateCount, 1); XCTAssertEqual(plan.candidateLogicalBytes, 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.ownedFileStorage.assetDirectory(asset.id).path))
        let result = try store.commitOwnedStorageCleanup(plan)
        XCTAssertEqual(result.removedAssetCount, 1); XCTAssertEqual(result.removedFileCount, 2); XCTAssertEqual(result.removedLogicalBytes, 16)
        XCTAssertEqual(result.remainingPendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.ownedFileStorage.assetDirectory(asset.id).path))
        XCTAssertThrowsError(try store.ownedFileAssetWithoutLock(id: asset.id))
        XCTAssertThrowsError(try store.commitOwnedStorageCleanup(plan))
    }
    func testLeaseLivesAcrossConnectionsAndDeinitializationUnderStoreLockDoesNotDeadlock() throws {
        let a = try store(), b = try store(), record = try imported(a)
        var lease: OwnedAssetLease? = try a.retainCapturedOwnedFiles([record], purpose: .stack)
        try a.delete(id: record.id)
        XCTAssertEqual(try b.prepareOwnedStorageCleanup().candidateCount, 0)
        a.synchronized { lease = nil }
        XCTAssertNil(lease)
        XCTAssertEqual(try b.prepareOwnedStorageCleanup().candidateCount, 1)
        let result = try b.commitOwnedStorageCleanup(b.prepareOwnedStorageCleanup())
        XCTAssertEqual(result.removedAssetCount, 1)
    }
    func testActualChildProcessLockProtectsAssetUntilProcessExitWithoutATimeout() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Python required only for an independent-process flock fixture") }
        let store = try store(), record = try imported(store)
        var lease: OwnedAssetLease? = try store.retainCapturedOwnedFiles([record], purpose: .output)
        let id = try XCTUnwrap(lease).id
        lease = nil
        let path = store.ownedFileStorage.directory.appendingPathComponent(".leases").appendingPathComponent(id.uuidString).path
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'rb'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read(1)", path]
        child.standardOutput = output; child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("ready\n".utf8))
        try store.delete(id: record.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        child.terminate(); child.waitUntilExit()
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 1)
    }
    func testMissingLeaseLockCannotBeMistakenForDeadProcess() throws {
        let store = try store(), record = try imported(store)
        var lease: OwnedAssetLease? = try store.retainCapturedOwnedFiles([record], purpose: .output)
        let id = try XCTUnwrap(lease).id
        try store.delete(id: record.id)
        let lock = store.ownedFileStorage.directory.appendingPathComponent(".leases").appendingPathComponent(id.uuidString)
        try FileManager.default.removeItem(at: lock)
        lease = nil
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
    }
    func testEditPreviewAndUndoCapabilitiesOwnTheirFileLifetime() throws {
        for kind in 0..<3 {
            let store = try store("lease-\(kind)"), record = try imported(store), ref = ClipboardSelectionReference(id: record.id, revision: record.revision)
            var edit: ClipboardEditSnapshot?, preview: ClipboardFileRepairSnapshot?, undo: HistorySelectionDeleteUndo?
            switch kind {
            case 0: edit = try store.prepareEdit(ref); try store.delete(id: record.id)
            case 1: preview = try store.fileRepairSnapshot(ref); try store.delete(id: record.id)
            default: undo = try store.deleteSelection([ref])
            }
            XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
            withExtendedLifetime((edit, preview, undo)) {}
            edit = nil; preview = nil; undo = nil
            XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 1)
        }
    }
    func testPlainRecordReferenceRetainsRegisteredFileWithoutGainingOwnership() throws {
        let store = try store(), original = try imported(store)
        var copied = original; copied.id = UUID()
        _ = try store.create(copied)
        XCTAssertTrue(try store.ownedFileBindings(recordID: copied.id).isEmpty)
        try store.delete(id: original.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        try store.delete(id: copied.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 1)
    }
    func testEquivalentNoncanonicalFileURLRemainsAHistoryRoot() throws {
        let store = try store(), original = try imported(store)
        var copied = original; copied.id = UUID()
        let canonical = try XCTUnwrap(String(data: copied.parts[0].representations[0].data, encoding: .utf8))
        copied.parts[0].representations[0].data = Data(canonical.replacingOccurrences(of: "one.txt", with: "%6Fne.txt").utf8)
        _ = try store.create(copied)
        try store.delete(id: original.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        try store.delete(id: copied.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 1)
    }
    private final class RecoveryInterleave {
        let peer: HistoryStore
        var begins = 0
        var recovered = false
        init(peer: HistoryStore) { self.peer = peer }
    }
    func testOtherConnectionCannotRemoveIntentThenAllowUnjournaledQuarantine() throws {
        let a = try store(), b = try store(), record = try imported(a), asset = try asset(a, record: record)
        try a.delete(id: record.id)
        let plan = try a.prepareOwnedStorageCleanup(), interleave = RecoveryInterleave(peer: b)
        sqlite3_trace_v2(a.database, UInt32(SQLITE_TRACE_STMT), { _, raw, _, sql in
            guard let raw, let sql else { return 0 }
            let interleave = Unmanaged<RecoveryInterleave>.fromOpaque(raw).takeUnretainedValue()
            if String(cString: sql.assumingMemoryBound(to: CChar.self)) == "BEGIN IMMEDIATE" {
                interleave.begins += 1
                if interleave.begins == 2 { interleave.recovered = (try? interleave.peer.resumeOwnedStorageCleanup().remainingPendingCount) == 0 }
            }
            return 0
        }, Unmanaged.passUnretained(interleave).toOpaque())
        defer { sqlite3_trace_v2(a.database, 0, nil, nil) }
        XCTAssertThrowsError(try a.commitOwnedStorageCleanup(plan))
        XCTAssertTrue(interleave.recovered)
        XCTAssertEqual(try a.ownedFileStorage.read(a.ownedFileAssetWithoutLock(id: asset.id)), Data("original".utf8))
        XCTAssertEqual(try a.ownedStorageUsage().pendingReclamationCount, 0)
    }
    private final class CommitInterleave {
        let peer: HistoryStore
        let plan: OwnedStorageCleanupPlan
        var begins = 0
        var rejected = false
        var pendingAfterRejection: Int?
        init(peer: HistoryStore, plan: OwnedStorageCleanupPlan) { self.peer = peer; self.plan = plan }
    }
    func testTwoConnectionsCannotCreateOverlappingAssetIntents() throws {
        let a = try store(), b = try store(), record = try imported(a)
        try a.delete(id: record.id)
        let plan = try a.prepareOwnedStorageCleanup()
        let interleave = CommitInterleave(peer: b, plan: try b.prepareOwnedStorageCleanup())
        sqlite3_trace_v2(a.database, UInt32(SQLITE_TRACE_STMT), { _, raw, _, sql in
            guard let raw, let sql else { return 0 }
            let interleave = Unmanaged<CommitInterleave>.fromOpaque(raw).takeUnretainedValue()
            if String(cString: sql.assumingMemoryBound(to: CChar.self)) == "BEGIN IMMEDIATE" {
                interleave.begins += 1
                if interleave.begins == 2 {
                    do { _ = try interleave.peer.commitOwnedStorageCleanup(interleave.plan) }
                    catch { interleave.rejected = true }
                    interleave.pendingAfterRejection = try? interleave.peer.ownedStorageUsage().pendingReclamationCount
                }
            }
            return 0
        }, Unmanaged.passUnretained(interleave).toOpaque())
        defer { sqlite3_trace_v2(a.database, 0, nil, nil) }
        let result = try a.commitOwnedStorageCleanup(plan)
        XCTAssertTrue(interleave.rejected); XCTAssertEqual(interleave.pendingAfterRejection, 1)
        XCTAssertEqual(result.removedAssetCount, 1); XCTAssertEqual(result.remainingPendingCount, 0)
        XCTAssertEqual(try b.resumeOwnedStorageCleanup().remainingPendingCount, 0)
    }
    func testFailedJournalCompletionCountsPhysicalBytesOnceAndGroupOnlyAfterCommit() throws {
        let store = try store(), record = try imported(store)
        try store.delete(id: record.id)
        let plan = try store.prepareOwnedStorageCleanup()
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1); calls.initialize(to: 0)
        defer { sqlite3_commit_hook(store.database, nil, nil); calls.deinitialize(count: 1); calls.deallocate() }
        sqlite3_commit_hook(store.database, { raw in
            let counter = raw!.assumingMemoryBound(to: Int.self); counter.pointee += 1
            return counter.pointee == 3 ? 1 : 0
        }, calls)
        let first = try store.commitOwnedStorageCleanup(plan)
        XCTAssertEqual(first.removedAssetCount, 0); XCTAssertEqual(first.removedFileCount, 2)
        XCTAssertEqual(first.removedLogicalBytes, 16); XCTAssertEqual(first.remainingPendingCount, 1)
        sqlite3_commit_hook(store.database, nil, nil)
        let resumed = try store.resumeOwnedStorageCleanup()
        XCTAssertEqual(resumed.removedAssetCount, 1); XCTAssertEqual(resumed.removedFileCount, 0)
        XCTAssertEqual(resumed.removedLogicalBytes, 0); XCTAssertEqual(resumed.remainingPendingCount, 0)
        XCTAssertEqual(try store.resumeOwnedStorageCleanup().removedAssetCount, 0)
    }
    func testMetadataCommitFailureRestoresQuarantinedFilesAndCanRetry() throws {
        let store = try store(), record = try imported(store), asset = try asset(store, record: record)
        try store.delete(id: record.id)
        let plan = try store.prepareOwnedStorageCleanup()
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1); calls.initialize(to: 0)
        defer { sqlite3_commit_hook(store.database, nil, nil); calls.deinitialize(count: 1); calls.deallocate() }
        sqlite3_commit_hook(store.database, { raw in
            let counter = raw!.assumingMemoryBound(to: Int.self)
            counter.pointee += 1
            return counter.pointee == 2 ? 1 : 0
        }, calls)
        XCTAssertThrowsError(try store.commitOwnedStorageCleanup(plan))
        XCTAssertEqual(try store.ownedFileStorage.read(store.ownedFileAssetWithoutLock(id: asset.id)), Data("original".utf8))
        XCTAssertEqual(try store.ownedStorageUsage().pendingReclamationCount, 0)
        sqlite3_commit_hook(store.database, nil, nil)
        XCTAssertEqual(try store.commitOwnedStorageCleanup(store.prepareOwnedStorageCleanup()).removedAssetCount, 1)
    }
    func testPublicationSurvivesRestartAndDoesNotReleaseWhenLeaseEnds() throws {
        let a = try store(), record = try imported(a)
        var lease: OwnedAssetLease? = try a.retainCapturedOwnedFiles([record], purpose: .output)
        _ = try a.publishOwnedFiles(lease: XCTUnwrap(lease), purpose: .clipboard)
        lease = nil; try a.delete(id: record.id)
        let b = try store()
        XCTAssertEqual(try b.prepareOwnedStorageCleanup().candidateCount, 0)
        let publication = try XCTUnwrap(b.ownedPublications(purpose: .clipboard).first)
        try b.releaseOwnedPublication(publication)
        XCTAssertEqual(try b.prepareOwnedStorageCleanup().candidateCount, 1)
    }
    func testOldOutboxProtectsOriginalAndAcknowledgedPrivateSnapshotsCanBeRetired() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let record = try imported(store), queued = try store.pendingSyncOperations(accountID: "account")
        try store.delete(id: record.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        try store.acknowledgeSyncOperations(accountID: "account", operationIDs: Set(queued.map(\.operationID)))
        let plan = try store.prepareOwnedStorageCleanup(); XCTAssertEqual(plan.candidateCount, 1)
        _ = try store.commitOwnedStorageCleanup(plan)
        XCTAssertTrue(try store.ownedUUIDSet("SELECT operation_id FROM owned_file_operation_bindings").isEmpty)
    }
    func testAcceptedSharedReplayAndFailedDraftRemainPersistentRootsAfterRowsDisappear() throws {
        for accepted in [false, true] {
            let store = try store(accepted ? "accepted" : "failed"), board = try store.createPinboard(name: "source")
            var original = try imported(store); try store.move(recordID: original.id, to: board.id); original = try XCTUnwrap(store.item(id: original.id))
            try store.configureSharing(accountID: "account")
            let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "account", containerIdentifier: "iCloud.test", zoneName: "zone", zoneOwnerName: "owner", shareRecordName: "share")
            _ = try store.createSharedCopy(from: board.id, descriptor: descriptor)
            let shared = try XCTUnwrap(store.search(.init(pinboardIDs: [descriptor.boardID])).first)
            let pending = try store.pendingSharedOperations(boardID: descriptor.boardID, accountID: "account")
            if accepted {
                try store.acknowledgeSharedOperations(boardID: descriptor.boardID, accountID: "account", operationIDs: Set(pending.map(\.operationID)))
                try store.delete(id: shared.id)
            } else {
                try store.updateSharedAccess(boardID: descriptor.boardID, accountID: "account", access: .revoked)
                try store.rejectPendingSharedEdits(boardID: descriptor.boardID, accountID: "account", reason: "fixture", clearCachedContent: true)
            }
            try store.delete(id: original.id)
            XCTAssertTrue(try store.ownedUUIDSet("SELECT asset_id FROM owned_file_bindings").isEmpty)
            XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
            XCTAssertEqual(try store.ownedStorageUsage().protectedAssetCount, 1)
        }
    }
    func testNewReferenceAndProjectionEditInvalidateTheEntireFrozenPlan() throws {
        for editFile in [false, true] {
            let store = try store(editFile ? "edit" : "pin"), first = try imported(store), second = try imported(store)
            let originalAsset = try asset(store, record: first)
            try store.delete(id: first.id); try store.delete(id: second.id)
            let plan = try store.prepareOwnedStorageCleanup(); XCTAssertEqual(plan.candidateCount, 2)
            var lease: OwnedAssetLease?
            if editFile { try Data("external edit".utf8).write(to: store.ownedFileStorage.fileURL(originalAsset)) }
            else { lease = try store.retainCapturedOwnedFiles([first], purpose: .output) }
            XCTAssertThrowsError(try store.commitOwnedStorageCleanup(plan))
            XCTAssertEqual(try store.ownedAllAssetIDs().count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.ownedFileStorage.assetDirectory(originalAsset.id).path))
            withExtendedLifetime(lease) {}
        }
    }
    func testModifiedProjectionUnknownDirectoryAndExternalFileArePreservedAndCounted() throws {
        let store = try store(), record = try imported(store), asset = try asset(store, record: record)
        let projection = try store.ownedFileStorage.fileURL(asset)
        try Data("external unsaved edit".utf8).write(to: projection); try store.delete(id: record.id)
        let unknown = store.ownedFileStorage.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try Data([1,2,3]).write(to: unknown.appendingPathComponent("unknown"))
        let external = root.appendingPathComponent("external"); try Data([9]).write(to: external)
        let usage = try store.ownedStorageUsage()
        XCTAssertEqual(usage.assetCount, 2); XCTAssertGreaterThanOrEqual(usage.unverifiedAssetCount, 2)
        XCTAssertEqual(usage.reclaimableAssetCount, 0); XCTAssertGreaterThan(usage.totalLogicalBytes, 16)
        _ = try store.commitOwnedStorageCleanup(store.prepareOwnedStorageCleanup())
        XCTAssertEqual(try Data(contentsOf: projection), Data("external unsaved edit".utf8))
        XCTAssertEqual(try Data(contentsOf: external), Data([9]))
    }
    func testVersionElevenMigrationProtectsUnknownLegacyPublicationsUntilExplicitRelease() throws {
        let a = try store(), record = try imported(a)
        try a.delete(id: record.id); try a.execute("PRAGMA user_version=11")
        let b = try store()
        XCTAssertEqual(try b.syncScalar("PRAGMA user_version", []), "12")
        XCTAssertEqual(try b.ownedStorageUsage().legacyProtectedAssetCount, 1)
        XCTAssertEqual(try b.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertThrowsError(try b.clearLegacyOwnedPublications(expectedIDs: []))
        let legacy = try b.ownedPublications(purpose: .legacyExternal)
        try b.clearLegacyOwnedPublications(expectedIDs: Set(legacy.map(\.id)))
        XCTAssertEqual(try b.prepareOwnedStorageCleanup().candidateCount, 1)
    }
    func testCrashJournalBeforeCommitRestoresAndCommittedJournalFinishesDeletion() throws {
        for committed in [false, true] {
            let name = committed ? "committed" : "planned", a = try store(name), record = try imported(a)
            try a.delete(id: record.id)
            let plan = try a.prepareOwnedStorageCleanup(), candidate = try XCTUnwrap(plan.candidates.first)
            let token = a.ownedFileStorage.preparedQuarantine(candidate: candidate, operationID: UUID())
            try a.synchronized { try a.ownedRetentionTransaction { try a.writeOwnedGCJournal(token, phase: "planned") } }
            _ = try a.ownedFileStorage.quarantine(candidate, operationID: token.operationID)
            if committed {
                try a.synchronized { try a.ownedRetentionTransaction {
                    try a.syncExecute("DELETE FROM owned_file_assets WHERE id=?", [candidate.assetID.uuidString])
                    try a.writeOwnedGCJournal(token, phase: "quarantined")
                } }
            }
            let b = try store(name), result = try b.resumeOwnedStorageCleanup()
            XCTAssertEqual(result.remainingPendingCount, 0)
            if committed { XCTAssertEqual(result.removedAssetCount, 1); XCTAssertTrue(try b.ownedAllAssetIDs().isEmpty) }
            else { XCTAssertEqual(result.removedAssetCount, 0); XCTAssertEqual(try b.ownedAllAssetIDs(), [candidate.assetID]); XCTAssertTrue(FileManager.default.fileExists(atPath: b.ownedFileStorage.assetDirectory(candidate.assetID).path)) }
        }
    }
}
