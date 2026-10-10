import Foundation
import XCTest
@testable import ClipShelfCore

final class SyncedDeletionUndoTests: XCTestCase {
    private var directory: URL!
    private let account = "undo-private-account"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-synced-undo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }

    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        .init(id: record.id, revision: record.revision)
    }

    private func descriptor(_ id: UUID, account: String) -> SharedBoardDescriptor {
        .init(boardID: id, accountID: account, containerIdentifier: "iCloud.synthetic.undo",
              zoneName: "ClipShelfShared_" + id.uuidString, zoneOwnerName: "owner-record", shareRecordName: "share")
    }

    private func sharedRecord(_ store: HistoryStore) throws -> (SharedBoardDescriptor, ClipboardRecord) {
        let source = try store.createPinboard(name: "Private source")
        _ = try store.create(ClipboardRecord(text: "shared deletion candidate", pinboardID: source.id))
        try store.configureSharing(accountID: "owner")
        let board = descriptor(UUID(), account: "owner")
        _ = try store.createSharedCopy(from: source.id, descriptor: board)
        return (board, try XCTUnwrap(store.search(.init(pinboardIDs: [board.boardID])).first))
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values
            let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }

    func testPrivateRestoreAndItsNextEditConvergeForEveryOperationArrivalOrder() throws {
        let source = try store("source")
        try source.configureSync(accountID: account)
        let original = try source.create(ClipboardRecord(text: "before deletion"))
        let undo = try source.deleteSelection([reference(original)])
        let receipt = try source.restoreDeletedSelection([original], undo: undo)
        var restored = try XCTUnwrap(source.resolveSelection(receipt.references).first)
        XCTAssertNotEqual(restored.id, original.id)
        let creation = try XCTUnwrap(source.pendingSyncOperations(accountID: account).first { $0.entityID == restored.id })
        XCTAssertEqual(creation.baseRevision, 0)
        XCTAssertEqual(creation.revision, 1)
        XCTAssertNil(creation.baseOperationID, "A restored entity must not depend on the permanently deleted entity's chain")
        restored.text = "edited after undo"
        restored = try source.update(record: restored)
        let operations = try source.pendingSyncOperations(accountID: account)
        XCTAssertEqual(operations.count, 4)
        let successor = try XCTUnwrap(operations.last)
        XCTAssertEqual(successor.entityID, restored.id)
        XCTAssertEqual(successor.baseOperationID, creation.operationID)
        XCTAssertEqual(successor.revision, 2)

        for (index, delivery) in permutations(operations).enumerated() {
            let replica = try store("replica-\(index)")
            try replica.configureSync(accountID: account)
            for operation in delivery {
                try replica.applyRemoteChanges(accountID: account, changes: [operation], nextCursor: nil)
            }
            let reopened = try store("replica-\(index)")
            // Replaying server pages must not create another restored copy or an echo upload.
            try reopened.applyRemoteChanges(accountID: account, changes: delivery, nextCursor: Data("replayed".utf8))
            XCTAssertNil(try reopened.item(id: original.id), "Delivery permutation \(index)")
            XCTAssertTrue(try reopened.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: original.id))
            XCTAssertEqual(try reopened.load().map(\.id), [restored.id])
            XCTAssertEqual(try reopened.item(id: restored.id)?.text, restored.text)
            XCTAssertTrue(try reopened.pendingSyncOperations(accountID: account).isEmpty)
            XCTAssertEqual(try reopened.syncScalar("SELECT count(*) FROM sync_inbox", []), "0")
        }
    }

    func testSharedRestoreReplaysOutOfOrderToReadOnlyParticipantWithoutPrivateUpload() throws {
        let owner = try store("owner")
        let (board, original) = try sharedRecord(owner)
        try owner.configureSync(accountID: account)
        let undo = try owner.deleteSelection([reference(original)])
        let receipt = try owner.restoreDeletedSelection([original], undo: undo)
        let restored = try XCTUnwrap(owner.resolveSelection(receipt.references).first)
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.pinboardID, board.boardID)
        let operations = try owner.pendingSharedOperations(boardID: board.boardID, accountID: "owner")
        let boardOperations = operations.filter { $0.entityKind == .pinboard }
        let itemOperations = operations.filter { $0.entityKind == .clipboard }
        XCTAssertEqual(itemOperations.count, 3)
        XCTAssertTrue(itemOperations.allSatisfy { $0.accountID == board.namespace })
        XCTAssertTrue(try owner.pendingSyncOperations(accountID: account).isEmpty)

        for (index, delivery) in permutations(itemOperations).enumerated() {
            let reader = try store("reader-\(index)")
            try reader.configureSharing(accountID: "reader")
            try reader.configureSync(accountID: "reader-private")
            let readerBoard = descriptor(board.boardID, account: "reader")
            try reader.registerSharedBoard(readerBoard, access: .readOnly)
            try reader.applySharedChanges(boardID: board.boardID, accountID: "reader", changes: boardOperations, nextCursor: nil)
            for operation in delivery {
                try reader.applySharedChanges(boardID: board.boardID, accountID: "reader", changes: [operation], nextCursor: nil)
            }
            try reader.applySharedChanges(boardID: board.boardID, accountID: "reader", changes: operations, nextCursor: nil)
            XCTAssertNil(try reader.item(id: original.id))
            XCTAssertTrue(try reader.syncIsDeleted(accountID: board.namespace, kind: .clipboard, id: original.id))
            XCTAssertEqual(try reader.search(.init(pinboardIDs: [board.boardID])).map(\.id), [restored.id])
            XCTAssertEqual(try reader.item(id: restored.id)?.text, original.text)
            XCTAssertTrue(try reader.pendingSyncOperations(accountID: "reader-private").isEmpty)
            XCTAssertEqual(try reader.syncScalar("SELECT count(*) FROM sync_outbox", []), "0")
        }
    }

    func testSyncedOwnedFilesRestoreBindingsUnderNewIDAfterCompaction() throws {
        let store = try store()
        try store.configureSync(accountID: account)
        let bytes = [Data([0, 255, 4, 0]), Data("附件第二份".utf8)]
        let candidate = ClipboardRecord(text: "two files", parts: bytes.map { _ in
            .init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])
        })
        let original = try store.create(candidate, ownedFiles: bytes.enumerated().map {
            .init(partIndex: $0.offset, representationIndex: 0, filename: "file-\($0.offset).txt", data: $0.element)
        }, expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        let bindings = try store.ownedFileBindings(recordID: original.id)
        let undo = try store.deleteSelection([reference(original)])
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        _ = try store.compactAttachments()
        let receipt = try store.restoreDeletedSelection([original], undo: undo)
        let restored = try XCTUnwrap(store.resolveSelection(receipt.references).first)
        XCTAssertNotEqual(restored.id, original.id)
        let remapped = bindings.map {
            OwnedFileBinding(recordID: restored.id, partIndex: $0.partIndex,
                             representationIndex: $0.representationIndex, assetID: $0.assetID)
        }
        XCTAssertEqual(try store.ownedFileBindings(recordID: restored.id), remapped)
        XCTAssertTrue(try store.ownedFileBindings(recordID: original.id).isEmpty)
        let archive = try store.synchronized { try store.transaction { try store.backupOwnedFilesWithoutLock(records: [restored]) } }
        XCTAssertEqual(Set(archive.assets.map(\.data)), Set(bytes))
        XCTAssertEqual(Set(archive.bindings.map(\.recordID)), [restored.id])
        let operation = try XCTUnwrap(store.pendingSyncOperations(accountID: account).last)
        XCTAssertEqual(operation.entityID, restored.id)
        XCTAssertEqual(operation.formatVersion, 2)
        XCTAssertEqual(operation.ownedFiles?.bindings.count, 2)
    }

    func testLocalOnlyFlagSurvivesDeleteUndoWhilePrivateSyncIsEnabled() throws {
        let store = try store()
        let candidate = ClipboardRecord(text: "explicitly local")
        // This is the same marker used by local backup imports; create the fixture before sync capture.
        let original = try store.synchronized {
            try store.transaction {
                try store.markSyncLocalOnly(kind: .clipboard, id: candidate.id)
                try store.insert(candidate)
                return candidate
            }
        }
        try store.configureSync(accountID: account)
        let undo = try store.deleteSelection([reference(original)])
        let receipt = try store.restoreDeletedSelection([original], undo: undo)
        let restored = try XCTUnwrap(store.resolveSelection(receipt.references).first)
        XCTAssertTrue(try store.isSyncLocalOnly(kind: .clipboard, id: restored.id))
        XCTAssertNil(try store.syncNamespace(kind: .clipboard, id: restored.id))
        XCTAssertTrue(try store.pendingSyncOperations(accountID: account).isEmpty)
        var edited = restored; edited.text = "still local after edit"
        _ = try store.update(record: edited)
        XCTAssertTrue(try store.pendingSyncOperations(accountID: account).isEmpty)
    }

    func testRecoveredSharedDraftStaysLocalAfterUndoAndExplicitIncludeLocalData() throws {
        let store = try store()
        let (board, original) = try sharedRecord(store)
        let pending = try store.pendingSharedOperations(boardID: board.boardID, accountID: "owner")
        let draft = try XCTUnwrap(pending.first { $0.entityID == original.id })
        try store.updateSharedAccess(boardID: board.boardID, accountID: "owner", access: .revoked)
        try store.rejectPendingSharedEdits(boardID: board.boardID, accountID: "owner", reason: "synthetic revoked", clearCachedContent: true)
        let recovered = try store.recoverFailedSharedDraft(operationID: draft.operationID, boardID: board.boardID, accountID: "owner")
        try store.configureSync(accountID: account)
        let undo = try store.deleteSelection([reference(recovered)])
        let receipt = try store.restoreDeletedSelection([recovered], undo: undo)
        let restored = try XCTUnwrap(store.resolveSelection(receipt.references).first)
        XCTAssertEqual(try store.syncScalar("SELECT record_id FROM owned_sync_local_recovery WHERE record_id = ?", [restored.id.uuidString]), restored.id.uuidString)
        try store.configureSync(accountID: account, includeLocalData: true)
        XCTAssertTrue(try store.isSyncLocalOnly(kind: .clipboard, id: restored.id))
        XCTAssertNil(try store.syncNamespace(kind: .clipboard, id: restored.id))
        XCTAssertFalse(try store.pendingSyncOperations(accountID: account).contains { $0.entityID == restored.id })
        XCTAssertEqual(try store.item(id: restored.id)?.text, recovered.text)
    }

    func testPrivateAccountABAReturnDoesNotAuthorizeOldUndoToken() throws {
        let store = try store()
        try store.configureSync(accountID: account)
        let original = try store.create(ClipboardRecord(text: "account A only"))
        let undo = try store.deleteSelection([reference(original)])
        let pending = try store.pendingSyncOperations(accountID: account)
        try store.configureSync(accountID: "B")
        XCTAssertThrowsError(try store.restoreDeletedSelection([original], undo: undo))
        XCTAssertTrue(try store.pendingSyncOperations(accountID: "B").isEmpty)
        try store.configureSync(accountID: account)
        XCTAssertThrowsError(try store.restoreDeletedSelection([original], undo: undo))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: account), pending)
        XCTAssertTrue(try store.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: original.id))
    }

    func testSharingAccountABAReturnDoesNotAuthorizeOldUndoToken() throws {
        let store = try store()
        let (board, original) = try sharedRecord(store)
        let undo = try store.deleteSelection([reference(original)])
        let pending = try store.pendingSharedOperations(boardID: board.boardID, accountID: "owner")
        try store.configureSharing(accountID: "different-owner")
        XCTAssertThrowsError(try store.restoreDeletedSelection([original], undo: undo))
        try store.configureSharing(accountID: "owner")
        XCTAssertThrowsError(try store.restoreDeletedSelection([original], undo: undo))
        XCTAssertTrue(try store.search(.init(pinboardIDs: [board.boardID])).isEmpty)
        XCTAssertEqual(try store.pendingSharedOperations(boardID: board.boardID, accountID: "owner"), pending)
    }

    func testSharedPermissionFailuresRestoreNothingAndSameTokenRetriesWhenWritable() throws {
        let store = try store()
        let (board, shared) = try sharedRecord(store)
        try store.configureSync(accountID: account)
        let privateRecord = try store.create(ClipboardRecord(text: "private batch peer"))
        let originals = [privateRecord, shared]
        let undo = try store.deleteSelection(originals.map(reference))
        let privateQueue = try store.pendingSyncOperations(accountID: account)
        let sharedQueue = try store.pendingSharedOperations(boardID: board.boardID, accountID: "owner")
        let count = try store.syncScalar("SELECT count(*) FROM clipboard_records", [])
        for access in [SharedBoardAccess.readOnly, .revoked] {
            try store.updateSharedAccess(boardID: board.boardID, accountID: "owner", access: access)
            XCTAssertThrowsError(try store.restoreDeletedSelection(originals, undo: undo))
            XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM clipboard_records", []), count)
            XCTAssertEqual(try store.pendingSyncOperations(accountID: account), privateQueue)
            XCTAssertNil(try store.item(id: privateRecord.id))
            XCTAssertNil(try store.item(id: shared.id))
        }
        try store.updateSharedAccess(boardID: board.boardID, accountID: "owner", access: .owner)
        XCTAssertEqual(try store.pendingSharedOperations(boardID: board.boardID, accountID: "owner"), sharedQueue)
        let receipt = try store.restoreDeletedSelection(originals, undo: undo)
        let restored = try store.resolveSelection(receipt.references)
        XCTAssertEqual(restored.map(\.text), originals.map(\.text))
        XCTAssertTrue(Set(restored.map(\.id)).isDisjoint(with: Set(originals.map(\.id))))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: account).count, privateQueue.count + 1)
        XCTAssertEqual(try store.pendingSharedOperations(boardID: board.boardID, accountID: "owner").count, sharedQueue.count + 1)
    }

    func testOutboxFailureRollsBackWholeRestoredBatchAndTokenCanRetry() throws {
        let store = try store()
        try store.configureSync(accountID: account)
        let originals = try ["first", "second"].map { try store.create(ClipboardRecord(text: $0)) }
        let undo = try store.deleteSelection(originals.map(reference))
        let pending = try store.pendingSyncOperations(accountID: account)
        let namespaceCount = try store.syncScalar("SELECT count(*) FROM sync_namespaces", [])
        let quota = try store.contentQuotaStatus()
        // Let one restored operation enter the transaction, then fail the next one.
        try store.execute("CREATE TRIGGER fail_second_undo_outbox BEFORE INSERT ON sync_outbox WHEN (SELECT count(*) FROM sync_outbox) > \(pending.count) BEGIN SELECT RAISE(ABORT, 'synthetic undo outbox failure'); END")
        XCTAssertThrowsError(try store.restoreDeletedSelection(originals, undo: undo))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: account), pending)
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM sync_namespaces", []), namespaceCount)
        XCTAssertEqual(try store.contentQuotaStatus(), quota)
        try store.execute("DROP TRIGGER fail_second_undo_outbox")
        let receipt = try store.restoreDeletedSelection(originals, undo: undo)
        XCTAssertEqual(try store.resolveSelection(receipt.references).map(\.text), originals.map(\.text))
        XCTAssertEqual(try store.pendingSyncOperations(accountID: account).count, pending.count + originals.count)
        XCTAssertThrowsError(try store.restoreDeletedSelection(originals, undo: undo))
    }

    func testQuotaFailureRollsBackRestoreAndCanRetryAfterLimitIsRaised() throws {
        let store = try store()
        try store.configureSync(accountID: account)
        let original = try store.create(ClipboardRecord(text: String(repeating: "quota restored content ", count: 100)))
        let undo = try store.deleteSelection([reference(original)])
        let pending = try store.pendingSyncOperations(accountID: account)
        let status = try store.contentQuotaStatus()
        let limited = try store.setContentQuotaLimit(status.usedBytes, expectedRevision: status.policyRevision)
        XCTAssertThrowsError(try store.restoreDeletedSelection([original], undo: undo)) {
            guard case .exceeded = $0 as? ContentQuotaError else { return XCTFail("Expected quota rejection, got \($0)") }
        }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: account), pending)
        XCTAssertEqual(try store.contentQuotaStatus(), limited)
        _ = try store.setContentQuotaLimit(nil, expectedRevision: limited.policyRevision)
        let receipt = try store.restoreDeletedSelection([original], undo: undo)
        XCTAssertEqual(try store.resolveSelection(receipt.references).map(\.text), [original.text])
        XCTAssertTrue(try store.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: original.id))
    }
}
