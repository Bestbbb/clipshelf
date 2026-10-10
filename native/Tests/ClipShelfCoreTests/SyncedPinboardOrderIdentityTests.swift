import Foundation
import XCTest
@testable import ClipShelfCore

final class SyncedPinboardOrderIdentityTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("synced-pinboard-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func ref(_ record: ClipboardRecord) -> ClipboardSelectionReference { .init(id: record.id, revision: record.revision) }
    private func ids(_ store: HistoryStore, _ board: UUID) throws -> [UUID] {
        try store.selectionSnapshot(.init(pinboardIDs: [board], sortOrder: .pinboard)).references.map(\.id)
    }
    private func initial(_ store: HistoryStore, _ record: ClipboardRecord) throws -> SyncOperation {
        try XCTUnwrap(store.pendingSyncOperations(accountID: "account").last { $0.entityID == record.id })
    }
    private func next(_ base: SyncOperation, _ record: ClipboardRecord, orderOnly: Bool = false) -> SyncOperation {
        SyncOperation(accountID: "account", entityID: record.id, entityKind: .clipboard, action: .upsert,
                      baseRevision: base.revision, revision: base.revision + 1, baseOperationID: base.operationID,
                      record: record, orderingOnly: orderOnly ? true : nil)
    }

    func testSyncedUndoPreservesDuplicateRankPositionLocallyAndOnNewReplica() throws {
        let source = try store("source"), target = try store("target")
        try source.configureSync(accountID: "account"); try target.configureSync(accountID: "account")
        let board = try source.createPinboard(name: "Concurrent rank ties")
        let originalIDs = (1...3).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let records = try originalIDs.enumerated().map { index, id in
            try source.create(ClipboardRecord(id: id, text: "tie \(index)", pinboardID: board.id, pinboardOrder: 0))
        }
        XCTAssertEqual(try ids(source, board.id), originalIDs)
        let undo = try source.deleteSelection([ref(records[1])])
        XCTAssertEqual(undo.affectedRecordIDs, Set(originalIDs))
        let receipt = try source.restoreDeletedSelection([records[1]], undo: undo)
        let newID = receipt.references[0].id, expected = [originalIDs[0], newID, originalIDs[2]]
        let restored = try XCTUnwrap(source.item(id: newID))
        XCTAssertEqual(restored.pinboardOrderIdentity, records[1].id); XCTAssertEqual(restored.pinboardOrder, 0)
        XCTAssertEqual(try ids(source, board.id), expected)
        for operation in try source.pendingSyncOperations(accountID: "account").reversed() {
            try target.applyRemoteChanges(accountID: "account", changes: [operation], nextCursor: nil)
        }
        XCTAssertEqual(try ids(target, board.id), expected)
        XCTAssertEqual(try target.item(id: newID)?.pinboardOrderIdentity, originalIDs[1])
        XCTAssertNil(try target.item(id: originalIDs[1]))
    }

    func testLegacyFullSnapshotAndBoardMoveCannotEraseKnownTieIdentity() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let a = try store.createPinboard(name: "A"), b = try store.createPinboard(name: "B"), identity = UUID()
        let record = try store.create(ClipboardRecord(text: "before", pinboardID: a.id, pinboardOrder: 0, pinboardOrderIdentity: identity))
        let base = try initial(store, record)
        var legacy = record; legacy.pinboardOrderIdentity = nil; legacy.text = "legacy edit"; legacy.revision += 1
        let edit = next(base, legacy)
        try store.applyRemoteChanges(accountID: "account", changes: [edit], nextCursor: nil)
        XCTAssertEqual(try store.item(id: record.id)?.text, "legacy edit")
        XCTAssertEqual(try store.item(id: record.id)?.pinboardOrderIdentity, identity)
        legacy.pinboardID = b.id; legacy.pinboardOrder = 100; legacy.revision += 1
        let move = next(edit, legacy)
        try store.applyRemoteChanges(accountID: "account", changes: [move], nextCursor: nil)
        XCTAssertEqual(try store.item(id: record.id)?.pinboardID, b.id)
        XCTAssertEqual(try store.item(id: record.id)?.pinboardOrderIdentity, identity)
    }

    func testLegacyOrderingSnapshotKeepsTieAndExplicitOrderingCanAdoptIdentityAtSameRank() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Board")
        let record = try store.create(ClipboardRecord(text: "body", pinboardID: board.id, pinboardOrder: 0))
        let base = try initial(store, record), identity = UUID()
        var updated = record; updated.pinboardOrderIdentity = identity
        let adopt = next(base, updated, orderOnly: true)
        try store.applyRemoteChanges(accountID: "account", changes: [adopt], nextCursor: nil)
        let first = try XCTUnwrap(store.item(id: record.id))
        XCTAssertEqual(first.pinboardOrderIdentity, identity); XCTAssertEqual(first.revision, 2)
        updated.pinboardOrderIdentity = nil; updated.pinboardOrder = 200
        let legacy = next(adopt, updated, orderOnly: true)
        try store.applyRemoteChanges(accountID: "account", changes: [legacy], nextCursor: nil)
        let second = try XCTUnwrap(store.item(id: record.id))
        XCTAssertEqual(second.pinboardOrderIdentity, identity); XCTAssertEqual(second.pinboardOrder, 200)
        XCTAssertEqual(second.text, record.text); XCTAssertEqual(second.revision, 3)
        updated.pinboardOrderIdentity = UUID(); updated.pinboardOrder = 300
        let explicit = next(legacy, updated, orderOnly: true)
        try store.applyRemoteChanges(accountID: "account", changes: [explicit], nextCursor: nil)
        let third = try XCTUnwrap(store.item(id: record.id))
        XCTAssertEqual(third.pinboardOrderIdentity, updated.pinboardOrderIdentity)
        XCTAssertEqual(third.pinboardOrder, 300); XCTAssertEqual(third.revision, 4)
    }

    func testCanonicalFingerprintNormalizesImplicitTieButStillAuthenticatesExplicitTie() {
        let original = ClipboardRecord(text: "authentic")
        var replacement = original; replacement.pinboardOrderIdentity = original.id; replacement.id = UUID()
        let digest = ClipboardEditFingerprint.digest(original)
        XCTAssertEqual(ClipboardEditFingerprint.digest(replacement, canonicalIdentity: original.id), digest)
        replacement.pinboardOrderIdentity = UUID()
        XCTAssertNotEqual(ClipboardEditFingerprint.digest(replacement, canonicalIdentity: original.id), digest)
    }

    func testDeletionBaselineDetectsChangedSurvivorTieEvenWhenSurvivorSequenceIsUnchanged() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let board = try store.createPinboard(name: "Ties")
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id5 = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let id7 = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let id9 = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        _ = try store.create(ClipboardRecord(id: id1, text: "first", pinboardID: board.id, pinboardOrder: 0))
        let middle = try store.create(ClipboardRecord(id: id5, text: "middle", pinboardID: board.id, pinboardOrder: 0))
        _ = try store.create(ClipboardRecord(id: id9, text: "last", pinboardID: board.id, pinboardOrder: 0))
        let undo = try store.deleteSelection([ref(middle)])
        // An external writer bypasses the public content API's immutable ordering identity.
        try store.syncExecute("UPDATE clipboard_records SET pinboard_order_identity = ? WHERE id = ?", [id7.uuidString, id1.uuidString])
        XCTAssertEqual(try ids(store, board.id), [id1, id9])
        XCTAssertThrowsError(try store.restoreDeletedSelection([middle], undo: undo))
        XCTAssertEqual(try ids(store, board.id), [id1, id9])
    }
    func testPublicContentEditsKeepStableIdentityAndConvergeThroughRealOutboxReplay() throws {
        let source = try store("public-source"), target = try store("public-target")
        try source.configureSync(accountID: "account"); try target.configureSync(accountID: "account")
        let board = try source.createPinboard(name: "Board"), destination = try source.createPinboard(name: "Destination")
        let stableIdentity = UUID(), proposedIdentity = UUID()
        let explicit = try source.create(ClipboardRecord(text: "explicit", pinboardID: board.id,
                                                         pinboardOrder: 0, pinboardOrderIdentity: stableIdentity))
        let implicit = try source.create(ClipboardRecord(text: "implicit", pinboardID: board.id, pinboardOrder: 0))
        try target.applyRemoteChanges(accountID: "account", changes: source.pendingSyncOperations(accountID: "account"), nextCursor: nil)
        let attempts: [UUID?] = [proposedIdentity, nil, stableIdentity]
        for original in [explicit, implicit] {
            for (index, attemptedIdentity) in attempts.enumerated() {
                var edit = try XCTUnwrap(source.item(id: original.id))
                edit.text = "public edit \(original.text) \(index)"
                edit.pinboardOrderIdentity = attemptedIdentity
                let committed = try source.update(record: edit)
                XCTAssertEqual(committed.pinboardOrderIdentity, original.pinboardOrderIdentity)
                let outbox = try source.pendingSyncOperations(accountID: "account")
                XCTAssertEqual(outbox.last { $0.entityID == original.id }?.record?.pinboardOrderIdentity, original.pinboardOrderIdentity)
                try target.applyRemoteChanges(accountID: "account", changes: outbox, nextCursor: nil)
                XCTAssertEqual(try target.item(id: original.id), committed)
                XCTAssertEqual(try ids(target, board.id), try ids(source, board.id))
            }
            var movingEdit = try XCTUnwrap(source.item(id: original.id))
            movingEdit.pinboardID = destination.id; movingEdit.pinboardOrderIdentity = proposedIdentity
            let committed = try source.update(record: movingEdit)
            XCTAssertEqual(committed.pinboardOrderIdentity, original.pinboardOrderIdentity)
            try target.applyRemoteChanges(accountID: "account", changes: source.pendingSyncOperations(accountID: "account"), nextCursor: nil)
            XCTAssertEqual(try target.item(id: original.id), committed)
            XCTAssertEqual(try ids(target, destination.id), try ids(source, destination.id))
        }
    }

}
