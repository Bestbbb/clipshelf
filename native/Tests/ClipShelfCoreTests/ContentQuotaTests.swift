import CSQLite
import Darwin
import Foundation
import XCTest
@testable import ClipShelfCore

final class ContentQuotaTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("content-quota-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func store(_ name: String = "history.sqlite") throws -> HistoryStore {
        try HistoryStore(databaseURL: root.appendingPathComponent(name))
    }
    private func limit(_ store: HistoryStore, _ bytes: Int64?) throws {
        _ = try store.setContentQuotaLimit(bytes, expectedRevision: store.contentQuotaStatus().policyRevision)
    }
    private func part(_ bytes: Data, type: String = "public.data") -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: type, data: bytes)])
    }
    private func blobNames(_ store: HistoryStore) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: store.representations.directory.path))
    }
    private func scalarBytes(_ store: HistoryStore, _ sql: String) throws -> Int64 {
        try XCTUnwrap(try store.syncScalar(sql, []).flatMap(Int64.init))
    }
    private func assertExceeded<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ContentQuotaError.exceeded = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }
    private func removeQuotaSchema(_ store: HistoryStore) throws {
        let statement = try store.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'content_quota_%'")
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(try XCTUnwrap(store.textColumn(statement, 0))) }
        sqlite3_finalize(statement)
        for name in names { try store.execute("DROP TRIGGER \(name)") }
        try store.execute("DROP TABLE content_quota_dirty; DROP TABLE content_quota_representations; DROP TABLE content_quota_items; DROP TABLE content_quota_totals; DROP TABLE content_quota_policy; PRAGMA user_version=12")
    }

    func testUTF8InlinePartsAndGlobalDigestDeduplicationAreExact() throws {
        let store = try store(), a = Data([0, 1, 2, 255]), b = Data("你好".utf8)
        let record = try store.create(ClipboardRecord(text: "A\0🙂", sourceApp: "应用", sourceBundleID: "example.app",
            rtf: Data([4, 5, 6]), html: Data("<b>中</b>".utf8),
            parts: [part(a), part(a, type: "public.png"), part(b)], renamedTitle: "标题", ocrText: "识别",
            originDeviceID: UUID(), originDeviceName: "设备"), preserveOrigin: true)
        let inline = Int64(record.text.utf8.count + record.sourceApp!.utf8.count + record.sourceBundleID!.utf8.count
            + record.rtf!.count + record.html!.count + record.renamedTitle!.utf8.count + record.ocrText!.utf8.count
            + record.originDeviceName!.utf8.count)
        let metadata = try scalarBytes(store, "SELECT length(parts) FROM clipboard_records")
        let first = try store.contentQuotaStatus()
        XCTAssertEqual(first.recordBytes, inline + metadata)
        XCTAssertEqual(first.representationBytes, Int64(a.count + b.count))
        XCTAssertEqual(first.usedBytes, first.recordBytes + first.representationBytes)
        XCTAssertNil(first.limitBytes); XCTAssertEqual(first.policyRevision, 0)
        let duplicate = try store.create(ClipboardRecord(text: "duplicate", parts: [part(a)]))
        XCTAssertEqual(try store.contentQuotaStatus().representationBytes, Int64(a.count + b.count))
        try store.delete(id: record.id)
        XCTAssertEqual(try store.contentQuotaStatus().representationBytes, Int64(a.count))
        try store.delete(id: duplicate.id)
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
        XCTAssertTrue(try blobNames(store).contains(where: { $0.hasSuffix(".blob") }), "Unreferenced physical blobs are excluded before explicit compaction")
    }

    func testPolicyIsLocalPersistentRevisionCheckedAndDoesNotEnqueueSync() throws {
        let a = try store(), b = try store()
        try a.configureSync(accountID: "quota-account")
        let first = try a.setContentQuotaLimit(100, expectedRevision: 0)
        XCTAssertEqual(first.limitBytes, 100); XCTAssertEqual(first.policyRevision, 1)
        XCTAssertEqual(try b.contentQuotaStatus(), first)
        XCTAssertThrowsError(try b.setContentQuotaLimit(200, expectedRevision: 0)) { XCTAssertEqual($0 as? ContentQuotaError, .stalePolicy) }
        for invalid in [Int64(0), -1] {
            XCTAssertThrowsError(try a.setContentQuotaLimit(invalid, expectedRevision: 1)) { XCTAssertEqual($0 as? ContentQuotaError, .invalidLimit) }
        }
        let reopened = try store()
        XCTAssertEqual(try reopened.contentQuotaStatus(), first)
        XCTAssertTrue(try a.pendingSyncOperations(accountID: "quota-account").isEmpty)
        let unlimited = try reopened.setContentQuotaLimit(nil, expectedRevision: 1)
        XCTAssertNil(unlimited.limitBytes); XCTAssertEqual(unlimited.policyRevision, 2)
        XCTAssertEqual(try a.contentQuotaStatus(), unlimited)
    }

    func testCaptureAndEditRollbackNewBlobAndPreserveExistingBlobAndOutbox() throws {
        let store = try store(), existingBytes = Data([1, 2]), newBytes = Data([7, 8, 9])
        try store.configureSync(accountID: "quota-account")
        let original = try store.create(ClipboardRecord(text: "keep", parts: [part(existingBytes)]))
        let pending = try store.pendingSyncOperations(accountID: "quota-account")
        try limit(store, store.contentQuotaStatus().usedBytes)
        let before = try store.contentQuotaStatus(), files = try blobNames(store)
        assertExceeded { try store.record(ClipboardRecord(text: "reject", parts: [part(existingBytes), part(newBytes)])) }
        XCTAssertEqual(try blobNames(store), files)
        XCTAssertEqual(try store.contentQuotaStatus(), before)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "quota-account"), pending)
        var edit = original; edit.text = "growing edit"; edit.parts.append(part(newBytes))
        assertExceeded { try store.update(record: edit) }
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertEqual(try blobNames(store), files)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "quota-account"), pending)
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM content_quota_dirty", []), "0")
        try limit(store, nil)
        _ = try store.record(ClipboardRecord(text: "later succeeds", parts: [part(newBytes)]))
        XCTAssertEqual(try store.load().count, 2)
    }

    func testAboveLimitAllowsShrinkingSameSizeAndExplicitDeleteEvenWhenTombstoneGrows() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: String(repeating: "x", count: 40)))
        try limit(store, 1)
        let over = try store.contentQuotaStatus()
        XCTAssertEqual(over.exceededBytes, over.usedBytes - 1)
        var edit = original; edit.text = "short"
        let smaller = try store.update(record: edit)
        XCTAssertLessThan(try store.contentQuotaStatus().usedBytes, over.usedBytes)
        var same = smaller; same.text = "equal"
        let sameSize = try store.update(record: same)
        var bigger = sameSize; bigger.text += "!"
        assertExceeded { try store.update(record: bigger) }
        try store.delete(id: original.id)
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)

        try limit(store, nil); try store.configureSync(accountID: "quota-account")
        let tiny = try store.create(ClipboardRecord(text: "x"))
        let operations = try store.pendingSyncOperations(accountID: "quota-account")
        try store.acknowledgeSyncOperations(accountID: "quota-account", operationIDs: Set(operations.map(\.operationID)))
        try limit(store, 1)
        let beforeDelete = try store.contentQuotaStatus().usedBytes
        try store.delete(id: tiny.id)
        XCTAssertNil(try store.item(id: tiny.id))
        XCTAssertGreaterThan(try store.contentQuotaStatus().usedBytes, beforeDelete, "Explicit reclamation may queue a durable tombstone")
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "quota-account").last?.action, .delete)
    }

    func testOutboxIsChargedAfterFlushAndAcknowledgementReleasesPayload() throws {
        let store = try store()
        try store.configureSync(accountID: "quota-account")
        try limit(store, 3) // "x" + the two UTF-8 bytes in [] fit; the outbox does not.
        assertExceeded { try store.record(ClipboardRecord(text: "x")) }
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
        XCTAssertTrue(try store.pendingSyncOperations(accountID: "quota-account").isEmpty)
        try limit(store, nil)
        _ = try store.record(ClipboardRecord(text: "x"))
        let status = try store.contentQuotaStatus()
        XCTAssertEqual(status.syncPayloadBytes, try scalarBytes(store, "SELECT sum(length(payload)) FROM sync_outbox"))
        let operations = try store.pendingSyncOperations(accountID: "quota-account")
        try store.acknowledgeSyncOperations(accountID: "quota-account", operationIDs: Set(operations.map(\.operationID)))
        XCTAssertEqual(try store.contentQuotaStatus().syncPayloadBytes, 0)
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, status.recordBytes)
    }

    func testRemoteInboxAndReplayAreAtomicAtQuotaBoundary() throws {
        let store = try store()
        try store.configureSync(accountID: "quota-account")
        let initial = ClipboardRecord(text: "remote content")
        let parent = SyncOperation(accountID: "quota-account", entityID: initial.id, entityKind: .clipboard,
            action: .upsert, baseRevision: 0, revision: 1, record: initial)
        var edited = initial; edited.text = "remote edited content"; edited.revision = 2
        let child = SyncOperation(accountID: "quota-account", entityID: initial.id, entityKind: .clipboard,
            action: .upsert, baseRevision: 1, revision: 2, baseOperationID: parent.operationID, record: edited)
        try limit(store, 1)
        assertExceeded { try store.applyRemoteChanges(accountID: "quota-account", changes: [child], nextCursor: Data([1])) }
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
        XCTAssertNil(try store.syncCursor(accountID: "quota-account"))
        try limit(store, nil)
        try store.applyRemoteChanges(accountID: "quota-account", changes: [child], nextCursor: Data([1]))
        XCTAssertNil(try store.item(id: initial.id))
        XCTAssertEqual(try store.contentQuotaStatus().syncPayloadBytes, try scalarBytes(store, "SELECT sum(length(payload)) FROM sync_inbox"))
        try store.applyRemoteChanges(accountID: "quota-account", changes: [parent], nextCursor: Data([2]))
        XCTAssertEqual(try store.item(id: initial.id)?.text, edited.text)
        XCTAssertEqual(try store.contentQuotaStatus().syncPayloadBytes, 0)
        let final = try store.contentQuotaStatus()
        try store.applyRemoteChanges(accountID: "quota-account", changes: [parent, child], nextCursor: Data([3]))
        XCTAssertEqual(try store.contentQuotaStatus(), final)
    }

    func testAllPersistentPayloadTablesUseStoredBlobBytesAndFinalNetDelta() throws {
        let store = try store()
        // Different JSON encodings, including whitespace/escaped Unicode, count their actual
        // persisted bytes. These fixtures exercise the raw SQL paths used by shared replay.
        try store.transaction {
            try store.execute("INSERT INTO sync_inbox VALUES('i','a',X'7b7d'); INSERT INTO sync_outbox VALUES('o','a',X'5b5d'); INSERT INTO shared_accepted_operations VALUES('s','a',X'207b7d20'); INSERT INTO shared_failed_drafts VALUES('f','a','a',X'7b2261223a225c7534633264227d')")
        }
        let status = try store.contentQuotaStatus()
        XCTAssertEqual(status.syncPayloadBytes, 22)
        try limit(store, 1)
        try store.transaction {
            try store.execute("INSERT INTO shared_failed_drafts VALUES('moved','a','a',X'207b7d20'); DELETE FROM shared_accepted_operations WHERE operation_id='s'")
        }
        XCTAssertEqual(try store.contentQuotaStatus().syncPayloadBytes, 22)
        try store.transaction { try store.execute("DELETE FROM shared_failed_drafts; DELETE FROM sync_inbox; DELETE FROM sync_outbox") }
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
    }

    func testOwnedOriginalRemainsChargedAfterDeletionUntilExistingGCRemovesRegistration() throws {
        let store = try store(), bytes = Data(repeating: 9, count: 137)
        let record = try store.create(ClipboardRecord(text: "owned", parts: [part(Data(), type: "public.file-url")]),
            ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "owned.bin", data: bytes)],
            expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        XCTAssertEqual(try store.contentQuotaStatus().ownedFileBytes, 137)
        try limit(store, 1)
        try store.delete(id: record.id)
        let retained = try store.contentQuotaStatus()
        XCTAssertEqual(retained.ownedFileBytes, 137); XCTAssertEqual(retained.usedBytes, 137)
        let plan = try store.prepareOwnedStorageCleanup()
        XCTAssertEqual(plan.candidateCount, 1)
        XCTAssertEqual(try store.commitOwnedStorageCleanup(plan).removedAssetCount, 1)
        XCTAssertEqual(try store.contentQuotaStatus().ownedFileBytes, 0)
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
    }

    func testQuotaRejectedOwnedImportLeavesNeitherRegistrationNorFiles() throws {
        let store = try store()
        try limit(store, 1)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: store.ownedFileStorage.directory.path))
        let attachmentsBefore = try blobNames(store)
        assertExceeded {
            try store.create(ClipboardRecord(text: "owned", parts: [part(Data(), type: "public.file-url")]),
                ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "new.bin", data: Data([1, 2, 3]))],
                expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        }
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM owned_file_assets", []), "0")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.ownedFileStorage.directory.path)), before)
        XCTAssertEqual(try blobNames(store), attachmentsBefore, "Preserve the existing owned directory without new blobs or staging files")
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
    }

    func testBackupReplacementPreservesPolicyAndChecksFinalSavedSize() throws {
        let source = try store("source.sqlite"), target = try store()
        let incoming = try source.create(ClipboardRecord(text: "restored", parts: [part(Data([1, 3, 5]))]))
        let backup = root.appendingPathComponent("fixture.clipshelfbackup")
        try source.exportBackup(to: backup)
        let old = try target.create(ClipboardRecord(text: "old"))
        try limit(target, 1)
        let before = try target.contentQuotaStatus(), files = try blobNames(target)
        assertExceeded { try target.restoreBackup(from: backup, mode: .replace) }
        XCTAssertEqual(try target.load(), [old]); XCTAssertEqual(try target.contentQuotaStatus(), before)
        XCTAssertEqual(try blobNames(target), files)
        try limit(target, nil)
        var large = old; large.text = String(repeating: "x", count: 2_000)
        _ = try target.update(record: large)
        try limit(target, 1)
        let policy = try target.contentQuotaStatus()
        _ = try target.restoreBackup(from: backup, mode: .replace)
        XCTAssertEqual(try target.load().map(\.id), [incoming.id])
        let restored = try target.contentQuotaStatus()
        XCTAssertEqual(restored.limitBytes, 1); XCTAssertEqual(restored.policyRevision, policy.policyRevision)
        XCTAssertLessThan(restored.usedBytes, policy.usedBytes)
        XCTAssertEqual(restored.usedBytes, try source.contentQuotaStatus().usedBytes)
    }

    func testVersion12MigrationMeasuresExistingRowsAndSurvivesReopening() throws {
        let original = try store()
        _ = try original.create(ClipboardRecord(text: "旧数据🙂", parts: [part(Data([1, 2, 3]))]))
        let expected = try original.contentQuotaStatus()
        try removeQuotaSchema(original)
        let migrated = try store()
        XCTAssertEqual(try migrated.syncScalar("PRAGMA user_version", []), "14")
        XCTAssertEqual(try migrated.contentQuotaStatus(), expected)
        XCTAssertEqual(try store().contentQuotaStatus(), expected)
    }

    func testMalformedBaselineAndMissingLedgerNeverBecomeZeroUsage() throws {
        let bad = try store("bad.sqlite")
        _ = try bad.create(ClipboardRecord(text: "keep"))
        try removeQuotaSchema(bad)
        try bad.execute("UPDATE clipboard_records SET parts=X'ff'")
        XCTAssertThrowsError(try store("bad.sqlite")) { XCTAssertEqual($0 as? ContentQuotaError, .measurementUnavailable) }
        XCTAssertEqual(try bad.syncScalar("PRAGMA user_version", []), "12")
        XCTAssertNil(try bad.syncScalar("SELECT name FROM sqlite_master WHERE name='content_quota_policy'", []))
        for table in ["content_quota_items", "content_quota_representations", "content_quota_totals"] {
            let name = table + ".sqlite", missing = try store(table + ".sqlite")
            try missing.execute("DROP TABLE \(table)")
            XCTAssertThrowsError(try store(name)) { XCTAssertEqual($0 as? ContentQuotaError, .measurementUnavailable) }
        }
    }

    func testReopeningRepairsLegacyDirtyTriggerBeforeForeignKeyBoardDeletion() throws {
        let original = try store()
        let board = try original.createPinboard(name: "Quota fixture")
        let record = try original.create(ClipboardRecord(text: "keep", pinboardID: board.id))
        try limit(original, original.contentQuotaStatus().usedBytes)
        let before = try original.contentQuotaStatus()
        try original.execute("""
            DROP TRIGGER content_quota_clipboard_records_update;
            CREATE TRIGGER content_quota_clipboard_records_update AFTER UPDATE ON clipboard_records BEGIN
                INSERT OR IGNORE INTO content_quota_dirty VALUES('record',OLD.id);
                INSERT OR IGNORE INTO content_quota_dirty VALUES('record',NEW.id);
            END;
            """)
        let reopened = try store()
        try reopened.deletePinboard(id: board.id, deleteItems: false)
        XCTAssertNil(try reopened.item(id: record.id)?.pinboardID)
        XCTAssertEqual(try reopened.item(id: record.id)?.text, record.text)
        XCTAssertEqual(try reopened.contentQuotaStatus(), before)
        XCTAssertEqual(try reopened.syncScalar("SELECT count(*) FROM content_quota_dirty", []), "0")
    }

    func testMalformedChangedMetadataFailsAndCanBeReclaimedWithoutZeroFallback() throws {
        let store = try store(), record = try store.create(ClipboardRecord(text: "keep"))
        let before = try store.contentQuotaStatus()
        XCTAssertThrowsError(try store.transaction { try store.execute("UPDATE clipboard_records SET parts=X'ff'") }) {
            XCTAssertEqual($0 as? ContentQuotaError, .measurementUnavailable)
        }
        XCTAssertEqual(try store.contentQuotaStatus(), before)
        XCTAssertEqual(try store.item(id: record.id), record)
        try store.execute("UPDATE clipboard_records SET parts=X'ff'") // Simulate an interrupted legacy writer.
        XCTAssertThrowsError(try store.contentQuotaStatus())
        try store.delete(id: record.id)
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, 0)
    }

    func testCheckedOverflowAndInvalidDigestMetadataRejectAndRollback() throws {
        let store = try store(), record = try store.create(ClipboardRecord(text: "keep"))
        let before = try store.contentQuotaStatus()
        XCTAssertThrowsError(try store.transaction {
            try store.execute("UPDATE content_quota_totals SET record_bytes=9223372036854775807,representation_bytes=1")
        }) { XCTAssertEqual($0 as? ContentQuotaError, .measurementUnavailable) }
        XCTAssertEqual(try store.contentQuotaStatus(), before)
        for metadata in ["[[{\"typeIdentifier\":\"public.data\",\"digest\":\"bad\",\"byteCount\":3}]]",
                         "[[{\"typeIdentifier\":\"public.data\",\"digest\":\"\(String(repeating: "a", count: 64))\",\"byteCount\":-1}]]"] {
            XCTAssertThrowsError(try store.transaction {
                let statement = try store.prepare("UPDATE clipboard_records SET parts=? WHERE id=?")
                defer { sqlite3_finalize(statement) }
                try store.bind(Data(metadata.utf8), at: 1, to: statement)
                try store.bind(record.id.uuidString, at: 2, to: statement)
                try store.stepToCompletion(statement)
            }) { XCTAssertEqual($0 as? ContentQuotaError, .measurementUnavailable) }
        }
        XCTAssertEqual(try store.contentQuotaStatus(), before)
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        var successes = 0
        var errors: [Error] = []
        func append(_ result: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result { case .success: successes += 1; case .failure(let error): errors.append(error) }
        }
    }
    func testConcurrentConnectionsCannotBothSpendTheSameRemainingLimit() throws {
        let a = try store(), b = try store(), outcomes = Outcomes(), group = DispatchGroup(), start = DispatchSemaphore(value: 0)
        try limit(a, 12) // One ten-byte record plus its [] metadata.
        for store in [a, b] {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                outcomes.append(Result { _ = try store.create(ClipboardRecord(text: "0123456789")) })
                group.leave()
            }
        }
        start.signal(); start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(outcomes.successes, 1); XCTAssertEqual(outcomes.errors.count, 1)
        if let error = outcomes.errors.first { guard case ContentQuotaError.exceeded = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try a.contentQuotaStatus().usedBytes, 12)
        XCTAssertEqual(try b.load().count, 1)
    }

    func testRollbackCleanupDoesNotDeleteAReplacedInode() throws {
        let store = try store(), data = Data([1, 2, 3])
        var created: NewRepresentationFile?
        _ = try store.representations.encode([part(data)], didCreate: { created = $0 })
        let token = try XCTUnwrap(created), file = try store.representations.url(for: RepresentationStorage.digest(data))
        let replacement = root.appendingPathComponent("replacement")
        try Data("replacement".utf8).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, file.path), 0)
        token.removeIfUnchanged()
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }

    func testDifferentDatabasesSharingAttachmentDirectoryCannotAdoptUncommittedBlob() throws {
        let rejecting = try store("shared.sqlite"), succeeding = try store("shared.db")
        XCTAssertEqual(rejecting.representations.directory, succeeding.representations.directory)
        try limit(rejecting, 1)
        let staged = DispatchSemaphore(value: 0), mayRollback = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0), secondFinished = DispatchSemaphore(value: 0)
        let group = DispatchGroup(), firstOutcome = Outcomes(), secondOutcome = Outcomes()
        let bytes = Data([1, 2, 3, 4]), record = ClipboardRecord(text: "shared", parts: [part(bytes)])
        group.enter()
        DispatchQueue.global().async {
            firstOutcome.append(Result {
                try rejecting.synchronized {
                    try rejecting.transaction {
                        try rejecting.insert(record)
                        staged.signal()
                        guard mayRollback.wait(timeout: .now() + 5) == .success else { throw ContentQuotaError.measurementUnavailable }
                    }
                }
            })
            group.leave()
        }
        defer { mayRollback.signal() }
        XCTAssertEqual(staged.wait(timeout: .now() + 5), .success)
        group.enter()
        DispatchQueue.global().async {
            secondStarted.signal()
            secondOutcome.append(Result { _ = try succeeding.create(record) })
            secondFinished.signal()
            group.leave()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.1), .timedOut)
        mayRollback.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(firstOutcome.successes, 0); XCTAssertEqual(firstOutcome.errors.count, 1)
        if let error = firstOutcome.errors.first { guard case ContentQuotaError.exceeded = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(secondOutcome.successes, 1); XCTAssertTrue(secondOutcome.errors.isEmpty)
        XCTAssertNil(try rejecting.item(id: record.id))
        XCTAssertEqual(try succeeding.item(id: record.id)?.parts, record.parts)
        XCTAssertEqual(try Data(contentsOf: succeeding.representations.url(for: RepresentationStorage.digest(bytes))), bytes)
    }
}
