import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class CleanupPlanTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "history") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"))
    }
    private func create(_ store: HistoryStore, _ text: String, time: Double = 10, board: UUID? = nil) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: text, copiedAt: Date(timeIntervalSinceReferenceDate: time), pinboardID: board))
    }
    private func shared(_ store: HistoryStore) throws -> (Pinboard, ClipboardRecord) {
        let source = try store.createPinboard(name: "source")
        _ = try create(store, "shared source", board: source.id)
        try store.configureSharing(accountID: "sharing-A")
        let board = try store.createSharedCopy(from: source.id, descriptor: .init(boardID: UUID(), accountID: "sharing-A",
            containerIdentifier: "iCloud.fixture", zoneName: "fixture", zoneOwnerName: "fixture", shareRecordName: "fixture"))
        let record = try XCTUnwrap(store.searchMetadata(.init(pinboardIDs: [board.id])).first)
        // Model a remotely received shared record also visible in history; do not publish a fixture edit.
        try store.syncExecute("UPDATE clipboard_records SET is_in_history = 1 WHERE id = ?", [record.id.uuidString])
        try store.execute("DELETE FROM sync_dirty")
        return (board, try XCTUnwrap(store.item(id: record.id)))
    }

    func testFrozenMixedScopePreservesPinsNewCapturesAndUnrelatedHiddenRows() throws {
        let store = try store(), board = try store.createPinboard(name: "keep")
        let expired = try create(store, "expired"), pinned = try create(store, "pinned", board: board.id)
        let fresh = try create(store, "fresh", time: 100)
        var hidden = ClipboardRecord(text: "outside scope", isInHistory: false)
        // A hidden unpinned row can exist in a restored or externally written database.
        try store.synchronized { try store.transaction { try store.insert(hidden) } }
        hidden = try XCTUnwrap(store.item(id: hidden.id))
        let before = sqlite3_total_changes64(store.database)
        let plan = try store.prepareHistoryCleanup(before: Date(timeIntervalSinceReferenceDate: 50))
        XCTAssertEqual(sqlite3_total_changes64(store.database), before)
        XCTAssertEqual(plan.summary, .init(deletedCount: 1, preservedPinnedCount: 1, privateSyncCount: 0, sharedSyncCount: 0, excludedCount: 0))
        let later = try create(store, "new after confirmation", time: 5)
        let result = try store.commitHistoryCleanup(plan)
        XCTAssertEqual(result.summary, plan.summary); XCTAssertEqual(result.deletedIDs, [expired.id])
        XCTAssertEqual(result.preservedReferences, [.init(id: pinned.id, revision: pinned.revision + 1)])
        XCTAssertNil(try store.item(id: expired.id))
        var expected = pinned; expected.isInHistory = false; expected.revision += 1
        XCTAssertEqual(try store.item(id: pinned.id), expected)
        XCTAssertEqual(try store.item(id: fresh.id), fresh); XCTAssertEqual(try store.item(id: later.id), later)
        XCTAssertEqual(try store.item(id: hidden.id), hidden)
        XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
    }

    func testAnyCandidateEditPinMoveHideOrDeleteRejectsTheEntireBatch() throws {
        for operation in 0..<5 {
            let store = try store("change-\(operation)"), board = try store.createPinboard(name: "keep")
            let first = try create(store, "must survive"), changed = try create(store, "candidate")
            let plan = try store.prepareHistoryCleanup()
            switch operation {
            case 0: var edit = changed; edit.text = "edited"; _ = try store.update(record: edit)
            case 1: try store.move(recordID: changed.id, to: board.id)
            case 2: try store.syncExecute("UPDATE clipboard_records SET is_in_history = 0 WHERE id = ?", [changed.id.uuidString])
            case 3: try store.delete(id: changed.id)
            default: try store.syncExecute("UPDATE clipboard_records SET copied_at = 100 WHERE id = ?", [changed.id.uuidString])
            }
            XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
            XCTAssertEqual(try store.item(id: first.id), first)
        }
    }

    func testMutationTokensCatchCrossConnectionSameRevisionRewriteAndDeleteReinsert() throws {
        for reinsert in [false, true] {
            let name = reinsert ? "reinsert" : "same-revision", store = try store(name), peer = try self.store(name)
            let original = try store.create(ClipboardRecord(text: "same metadata", rtf: Data([1, 2, 3])))
            let plan = try store.prepareHistoryCleanup()
            if reinsert { try peer.delete(id: original.id); try peer.synchronized { try peer.transaction { try peer.insert(original) } } }
            else { try peer.syncExecute("UPDATE clipboard_records SET rtf = X'030201' WHERE id = ?", [original.id.uuidString]) }
            XCTAssertEqual(try store.itemMetadata(id: original.id)?.revision, original.revision)
            XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
            XCTAssertNotNil(try store.item(id: original.id))
        }
    }

    func testPlanCannotCrossStoreOrEitherAccountABAAndEmptyPlansAreOneUse() throws {
        for sharing in [false, true] {
            let store = try store(sharing ? "sharing" : "private")
            let original = try create(store, "keep")
            let plan = try store.prepareHistoryCleanup()
            if sharing { try store.configureSharing(accountID: "B"); try store.configureSharing(accountID: nil) }
            else { try store.configureSync(accountID: "B"); try store.configureSync(accountID: nil) }
            XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
            XCTAssertEqual(try store.item(id: original.id), original)
        }
        let store = try store(), peer = try self.store()
        let empty = try store.prepareHistoryCleanup()
        XCTAssertThrowsError(try peer.commitHistoryCleanup(empty))
        XCTAssertEqual(try store.commitHistoryCleanup(empty).summary.affectedCount, 0)
        XCTAssertThrowsError(try store.commitHistoryCleanup(empty))
    }

    func testSameRecordBackupReplacementInvalidatesConfirmationWithoutChangingRevision() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "unchanged", rtf: Data([1, 2, 3])))
        let backup = directory.appendingPathComponent("original.clipshelfbackup")
        try store.exportBackup(to: backup)
        let plan = try store.prepareHistoryCleanup()
        _ = try store.restoreBackup(from: backup, mode: .replace)
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
        XCTAssertEqual(try store.item(id: original.id), original)
    }

    func testPreviouslyExcludedSharedItemDoesNotJoinThePlanAfterBecomingWritable() throws {
        let store = try store(), (board, record) = try shared(store)
        try store.updateSharedAccess(boardID: board.id, accountID: "sharing-A", access: .readOnly)
        let plan = try store.prepareHistoryCleanup()
        XCTAssertEqual(plan.summary.excludedCount, 1)
        try store.updateSharedAccess(boardID: board.id, accountID: "sharing-A", access: .owner)
        let result = try store.commitHistoryCleanup(plan)
        XCTAssertEqual(result.summary.excludedCount, 1)
        XCTAssertFalse(result.deletedIDs.contains(record.id)); XCTAssertFalse(result.preservedReferences.contains { $0.id == record.id })
        XCTAssertEqual(try store.item(id: record.id), record)
    }

    func testPrivateNamespaceExclusionsAndActualOutboxImpactCounts() throws {
        let store = try store()
        let localOnly = try create(store, "explicitly local")
        try store.markSyncLocalOnly(kind: .clipboard, id: localOnly.id)
        try store.configureSync(accountID: "old")
        let oldBoard = try store.createPinboard(name: "old account")
        let old = try create(store, "old account item"), oldPin = try create(store, "old account pin", board: oldBoard.id)
        try store.configureSync(accountID: "current")
        let currentBoard = try store.createPinboard(name: "current account")
        let current = try create(store, "current item"), currentPin = try create(store, "current pin", board: currentBoard.id)
        let plan = try store.prepareHistoryCleanup()
        XCTAssertEqual(plan.summary, .init(deletedCount: 2, preservedPinnedCount: 1, privateSyncCount: 2, sharedSyncCount: 0, excludedCount: 2))
        let before = try store.pendingSyncOperations(accountID: "current")
        let result = try store.commitHistoryCleanup(plan)
        XCTAssertEqual(Set(result.deletedIDs), [localOnly.id, current.id])
        XCTAssertEqual(try store.item(id: old.id), old); XCTAssertEqual(try store.item(id: oldPin.id), oldPin)
        let appended = try store.pendingSyncOperations(accountID: "current").dropFirst(before.count)
        XCTAssertEqual(Set(appended.map(\.entityID)), [current.id, currentPin.id])
    }

    func testSharedPermissionsOtherAccountsAndUnknownNamespacesAreExcluded() throws {
        let store = try store(), (board, sharedRecord) = try shared(store)
        let writable = try store.prepareHistoryCleanup()
        XCTAssertEqual(writable.summary.sharedSyncCount, 1)
        try store.updateSharedAccess(boardID: board.id, accountID: "sharing-A", access: .readOnly)
        let readonly = try store.prepareHistoryCleanup()
        XCTAssertEqual(readonly.summary.sharedSyncCount, 0); XCTAssertEqual(readonly.summary.excludedCount, 1)
        XCTAssertThrowsError(try store.commitHistoryCleanup(writable))
        try store.updateSharedAccess(boardID: board.id, accountID: "sharing-A", access: .revoked)
        XCTAssertEqual(try store.prepareHistoryCleanup().summary.excludedCount, 1)
        try store.updateSharedAccess(boardID: board.id, accountID: "sharing-A", access: .owner)
        try store.configureSharing(accountID: "sharing-B")
        XCTAssertEqual(try store.prepareHistoryCleanup().summary.excludedCount, 1)
        let unknown = try create(store, "unknown namespace")
        try store.syncExecute("INSERT INTO sync_namespaces(entity_kind,entity_id,account_id) VALUES ('clipboard',?,?)",
                              [unknown.id.uuidString, "shared:" + UUID().uuidString])
        XCTAssertEqual(try store.prepareHistoryCleanup().summary.excludedCount, 2)
        _ = try store.commitHistoryCleanup(store.prepareHistoryCleanup())
        XCTAssertEqual(try store.item(id: sharedRecord.id), sharedRecord); XCTAssertNotNil(try store.item(id: unknown.id))
    }

    func testNamespaceAndWritablePermissionChangesWithoutRecordRevisionStillReject() throws {
        let store = try store(), board = try store.createPinboard(name: "local")
        let item = try create(store, "pinned", board: board.id), plan = try store.prepareHistoryCleanup()
        try store.syncExecute("INSERT INTO sync_namespaces(entity_kind,entity_id,account_id) VALUES ('pinboard',?,?)", [board.id.uuidString, "old-account"])
        XCTAssertEqual(try store.itemMetadata(id: item.id)?.revision, item.revision)
        XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
        XCTAssertEqual(try store.prepareHistoryCleanup().summary.excludedCount, 1, "Board namespace is checked even when record namespace is nil")
        let sharedStore = try self.store("permission"), (sharedBoard, record) = try shared(sharedStore)
        let sharedPlan = try sharedStore.prepareHistoryCleanup()
        try sharedStore.updateSharedAccess(boardID: sharedBoard.id, accountID: "sharing-A", access: .readWrite)
        XCTAssertEqual(try sharedStore.itemMetadata(id: record.id)?.revision, record.revision)
        XCTAssertThrowsError(try sharedStore.commitHistoryCleanup(sharedPlan), "Owner-to-writer is still a changed authorization context")
    }

    func testSQLAndOutboxAndCommitFailuresRollbackEveryRowAndPermitSamePlanRetry() throws {
        for failure in 0..<3 {
            let store = try store("failure-\(failure)")
            try store.configureSync(accountID: "account")
            let board = try store.createPinboard(name: "pin"), first = try create(store, "first")
            let second = try create(store, "second", board: board.id), plan = try store.prepareHistoryCleanup()
            let pending = try store.pendingSyncOperations(accountID: "account")
            if failure == 0 {
                try store.execute("CREATE TRIGGER reject_cleanup BEFORE UPDATE ON clipboard_records BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            } else if failure == 1 {
                try store.execute("CREATE TRIGGER reject_cleanup BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            } else { sqlite3_commit_hook(store.database, { _ in 1 }, nil) }
            XCTAssertThrowsError(try store.commitHistoryCleanup(plan))
            if failure < 2 { try store.execute("DROP TRIGGER reject_cleanup") }
            else { sqlite3_commit_hook(store.database, nil, nil) }
            XCTAssertEqual(try store.item(id: first.id), first); XCTAssertEqual(try store.item(id: second.id), second)
            XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), pending)
            XCTAssertEqual(try store.commitHistoryCleanup(plan).summary.affectedCount, 2)
        }
    }

    func testPreparationNeverReadsPayloadColumnsAndLocalCleanupWorksWithMissingAttachments() throws {
        let store = try store(), board = try store.createPinboard(name: "pin"), payload = Data(repeating: 42, count: 128 * 1_024)
        let representation = ClipboardPart(representations: [.init(typeIdentifier: "public.png", data: payload)])
        let unpinned = try store.create(ClipboardRecord(text: String(repeating: "正文", count: 20_000), rtf: payload, parts: [representation]))
        let pinned = try store.create(ClipboardRecord(text: "pin", parts: [representation], pinboardID: board.id))
        try FileManager.default.removeItem(at: store.representations.url(for: RepresentationStorage.digest(payload)))
        sqlite3_set_authorizer(store.database, { _, action, table, column, _, _ in
            if action == SQLITE_READ, let table, let column, String(cString: table) == "clipboard_records",
               ["text", "rtf", "html", "parts", "ocr_text"].contains(String(cString: column)) { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        let plan: HistoryCleanupPlan
        do { plan = try store.prepareHistoryCleanup() }
        catch { sqlite3_set_authorizer(store.database, nil, nil); throw error }
        sqlite3_set_authorizer(store.database, nil, nil)
        XCTAssertEqual(plan.summary.affectedCount, 2)
        let result = try store.commitHistoryCleanup(plan)
        XCTAssertEqual(result.deletedIDs, [unpinned.id]); XCTAssertEqual(result.preservedReferences.map(\.id), [pinned.id])
        XCTAssertNil(try store.itemMetadata(id: unpinned.id)); XCTAssertEqual(try store.itemMetadata(id: pinned.id)?.isInHistory, false)
    }

    func testOwnedAssetsAndUnrelatedHiddenRowsAreNeverGarbageCollectedByLegacyClearOrPrune() throws {
        for prune in [false, true] {
            let store = try store(prune ? "prune" : "clear")
            let record = try store.create(ClipboardRecord(text: "owned", copiedAt: Date(timeIntervalSinceReferenceDate: 10),
                parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])]),
                ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "owned.txt", data: Data("owned bytes".utf8))],
                expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
            let binding = try XCTUnwrap(store.ownedFileBindings(recordID: record.id).first)
            let file = try store.ownedFileURLWithoutLock(assetID: binding.assetID)
            let hidden = ClipboardRecord(text: "hidden", isInHistory: false)
            try store.synchronized { try store.transaction { try store.insert(hidden) } }
            if prune { XCTAssertEqual(try store.prune(before: Date(timeIntervalSinceReferenceDate: 20)), 1) }
            else { try store.clearHistory() }
            XCTAssertNil(try store.item(id: record.id)); XCTAssertEqual(try store.item(id: hidden.id), hidden)
            XCTAssertEqual(try Data(contentsOf: file), Data("owned bytes".utf8))
            XCTAssertNoThrow(try store.ownedFileAssetWithoutLock(id: binding.assetID))
        }
    }

    func testV9MigrationPreservesRowOrderOwnedBindingsAndBackfillsStableTokens() throws {
        let store = try store(), board = try store.createPinboard(name: "ordered")
        let first = try create(store, "first", board: board.id), second = try create(store, "second", board: board.id)
        let owned = try store.create(ClipboardRecord(text: "owned", parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])]),
            ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "owned.txt", data: Data([1, 2, 3]))],
            expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        let bindings = try store.ownedFileBindings(recordID: owned.id)
        let oldRowids = try [first, second, owned].map { try store.syncScalar("SELECT rowid FROM clipboard_records WHERE id = ?", [$0.id.uuidString]) }
        try store.execute("DROP TRIGGER history_cleanup_insert; DROP TRIGGER history_cleanup_update; DROP TRIGGER history_cleanup_delete; DROP TABLE history_cleanup_tokens; PRAGMA user_version = 9")
        let migrated = try self.store()
        XCTAssertEqual(try migrated.syncScalar("PRAGMA user_version", []), "10")
        XCTAssertEqual(try [first, second, owned].map { try migrated.syncScalar("SELECT rowid FROM clipboard_records WHERE id = ?", [$0.id.uuidString]) }, oldRowids)
        XCTAssertEqual(try migrated.ownedFileBindings(recordID: owned.id), bindings)
        XCTAssertEqual(try migrated.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id), [first.id, second.id])
        let plan = try migrated.prepareHistoryCleanup()
        _ = try self.store() // Opening another v10 connection must not rotate existing tokens.
        XCTAssertEqual(try migrated.commitHistoryCleanup(plan).summary.affectedCount, 3)
    }

    func testFailedV9MigrationRollsBackNewTriggersAndLeavesRowsReadable() throws {
        let store = try store(), original = try create(store, "keep")
        try store.execute("DROP TRIGGER history_cleanup_insert; DROP TRIGGER history_cleanup_update; DROP TRIGGER history_cleanup_delete; DROP TABLE history_cleanup_tokens; PRAGMA user_version = 9; CREATE VIEW history_cleanup_tokens AS SELECT id AS record_id, randomblob(16) AS token FROM clipboard_records")
        XCTAssertThrowsError(try self.store())
        XCTAssertEqual(try store.syncScalar("PRAGMA user_version", []), "9")
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertNil(try store.syncScalar("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'history_cleanup_insert'", []))
    }

    func testLargeMetadataScopeCommitsBeyondSQLiteBindLimit() throws {
        let store = try store()
        for index in 0..<1_050 { _ = try create(store, "item \(index)") }
        let plan = try store.prepareHistoryCleanup()
        XCTAssertEqual(plan.summary.deletedCount, 1_050)
        XCTAssertEqual(try store.commitHistoryCleanup(plan).deletedIDs.count, 1_050)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testMoveUndoDependenciesIncludeUnselectedBoardBaselinesAffectedByCleanup() throws {
        let store = try store(), source = try store.createPinboard(name: "source"), destination = try store.createPinboard(name: "destination")
        let selected = try create(store, "selected", time: 100, board: source.id)
        let sourceNeighbour = try create(store, "old source neighbour", board: source.id)
        let destinationNeighbour = try create(store, "destination neighbour", time: 100, board: destination.id)
        let unrelated = try create(store, "unrelated", time: 100)
        let undo = try store.moveSelection([.init(id: selected.id, revision: selected.revision)], to: destination.id)
        XCTAssertEqual(undo.references.map(\.id), [selected.id])
        XCTAssertEqual(undo.affectedRecordIDs, Set([selected.id, sourceNeighbour.id, destinationNeighbour.id]))
        XCTAssertFalse(undo.affectedRecordIDs.contains(unrelated.id))
        let result = try store.commitHistoryCleanup(store.prepareHistoryCleanup(before: Date(timeIntervalSinceReferenceDate: 50)))
        XCTAssertEqual(result.preservedReferences.map(\.id), [sourceNeighbour.id])
        XCTAssertFalse(undo.affectedRecordIDs.isDisjoint(with: result.preservedReferences.map(\.id)))
        XCTAssertThrowsError(try store.undoSelectionMove(undo), "Cleanup changes an unselected board baseline, so the UI must retire this ticket")
    }
}
