import Foundation
import XCTest
@testable import ClipShelfCore

final class EditUndoFingerprintTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("edit-undo-fingerprint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "history") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"))
    }
    private func part(_ text: String) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))])
    }
    private func commit(_ store: HistoryStore, _ text: String, record: ClipboardRecord) throws -> HistorySelectionEditUndo {
        let snapshot = try store.prepareEdit(.init(id: record.id, revision: record.revision))
        return try store.commitPartEdit(.init(partIndex: 0, replacement: part(text), text: text, rtf: nil, html: nil), snapshot: snapshot)
    }
    private func replaceUsingBackup(_ record: ClipboardRecord, in target: HistoryStore) throws {
        let id = UUID().uuidString, source = try store(UUID().uuidString)
        _ = try source.create(record, preserveOrigin: true)
        let archive = directory.appendingPathComponent(id + ".clipshelfbackup")
        try source.exportBackup(to: archive)
        _ = try target.restoreBackup(from: archive, mode: .replace)
    }

    func testSameIDAndRevisionBackupReplacementCannotBeOverwrittenByOldUndo() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "original", parts: [part("original")]))
        let undo = try commit(store, "edited", record: original)
        var replacement = try XCTUnwrap(store.item(id: original.id))
        replacement.text = "restored content"; replacement.parts = [part("restored content")]
        try replaceUsingBackup(replacement, in: store)
        XCTAssertEqual(try store.item(id: original.id), replacement)
        let usage = try store.contentQuotaStatus()
        XCTAssertThrowsError(try store.undoSelectionEdit(undo)) { XCTAssertEqual(($0 as? HistoryStoreError)?.errorDescription, HistoryStoreError.staleRevision.errorDescription) }
        XCTAssertEqual(try store.item(id: original.id), replacement)
        XCTAssertEqual(try store.contentQuotaStatus(), usage)
    }

    func testTrustedReceiptCannotRebaseAwayDifferentPayloadAtSameRevision() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "original", parts: [part("original"), part("other")]))
        let oldUndo = try commit(store, "first edit", record: original)
        var replacement = try XCTUnwrap(store.item(id: original.id))
        replacement.parts[1] = part("other restored bytes") // Visible summary and revision remain identical.
        try replaceUsingBackup(replacement, in: store)
        let newUndo = try commit(store, "later", record: replacement)
        let receipt = try store.undoSelectionEdit(newUndo)
        let rebased = try store.rebaseSelectionEditUndo(oldUndo, after: receipt)
        XCTAssertEqual(rebased.committedReference, receipt.references[0])
        XCTAssertThrowsError(try store.undoSelectionEdit(rebased)) { error in
            guard case HistoryStoreError.staleRevision = error else { return XCTFail("\(error)") }
        }
        var expected = replacement; expected.revision = receipt.references[0].revision
        XCTAssertEqual(try store.item(id: original.id), expected)
    }

    func testFingerprintIncludesMetadataWhenPayloadAndRevisionAreUnchanged() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "original", parts: [part("original")]))
        let undo = try commit(store, "edited", record: original)
        var replacement = try XCTUnwrap(store.item(id: original.id)); replacement.renamedTitle = "restored title"
        try replaceUsingBackup(replacement, in: store)
        XCTAssertThrowsError(try store.undoSelectionEdit(undo))
        XCTAssertEqual(try store.item(id: original.id), replacement)
    }

    func testConsecutivePartEditsUndoThroughTrustedRevisionOnlyRebase() throws {
        let store = try store(), original = try store.create(ClipboardRecord(text: "original", parts: [part("original"), part("unchanged")]))
        let first = try commit(store, "first", record: original)
        let second = try commit(store, "second", record: XCTUnwrap(store.item(id: original.id)))
        let receipt = try store.undoSelectionEdit(second)
        let rebased = try store.rebaseSelectionEditUndo(first, after: receipt)
        XCTAssertEqual(first.expectedContentFingerprint, rebased.expectedContentFingerprint)
        _ = try store.undoSelectionEdit(rebased)
        var expected = original; expected.revision += 4
        XCTAssertEqual(try store.item(id: original.id), expected)
    }

    func testQuotaFailureDoesNotConsumeUndoAndRetryRestoresCompactedOriginalBlob() throws {
        let store = try store(), large = String(repeating: "original", count: 500)
        let original = try store.create(ClipboardRecord(text: large, parts: [part(large)]))
        let undo = try commit(store, "small", record: original)
        let edited = try XCTUnwrap(store.item(id: original.id)), usage = try store.contentQuotaStatus()
        _ = try store.setContentQuotaLimit(usage.usedBytes, expectedRevision: usage.policyRevision)
        XCTAssertGreaterThan(try store.compactAttachments(), 0)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: store.representations.directory.path))
        XCTAssertThrowsError(try store.undoSelectionEdit(undo)) { error in
            guard case ContentQuotaError.exceeded = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.item(id: original.id), edited)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.representations.directory.path)), files)
        XCTAssertEqual(try store.contentQuotaStatus().usedBytes, usage.usedBytes)
        _ = try store.setContentQuotaLimit(nil, expectedRevision: store.contentQuotaStatus().policyRevision)
        _ = try store.undoSelectionEdit(undo)
        var restored = original; restored.revision += 2
        XCTAssertEqual(try store.item(id: original.id), restored)
    }

    func testEditMoveEditUndoChainRetainsExactPinnedPlacementFingerprint() throws {
        let store = try store(), firstBoard = try store.createPinboard(name: "First"), secondBoard = try store.createPinboard(name: "Second")
        _ = try store.create(ClipboardRecord(text: "neighbour", pinboardID: firstBoard.id))
        let original = try store.create(ClipboardRecord(text: "original", parts: [part("original")],
                                                       pinboardID: firstBoard.id, isInHistory: false))
        let first = try commit(store, "first edit", record: original)
        let move = try store.moveSelection([first.committedReference], to: secondBoard.id)
        let moved = try XCTUnwrap(store.item(id: original.id))
        let second = try commit(store, "second edit", record: moved)
        let undoSecond = try store.undoSelectionEdit(second)
        let undoMove = try store.undoSelectionMove(store.rebaseSelectionMoveUndo(move, after: undoSecond))
        let rebasedFirst = try store.rebaseSelectionEditUndo(first, after: undoMove)
        XCTAssertEqual(rebasedFirst.expectedContentFingerprint, first.expectedContentFingerprint)
        _ = try store.undoSelectionEdit(rebasedFirst)
        var expected = original; expected.revision += 6
        XCTAssertEqual(try store.item(id: original.id), expected)
        XCTAssertEqual(try store.item(id: original.id)?.pinboardOrder, original.pinboardOrder)
        XCTAssertFalse(try XCTUnwrap(store.item(id: original.id)).isInHistory)
    }

    func testFractionalAndSignedZeroDatesRoundTripThroughSQLiteBeforeUndo() throws {
        let store = try store()
        for timestamp in [0.0, -0.0, 0.0000001, -12345.123456789, 812345678.123456, Double.pi] {
            let original = try store.create(ClipboardRecord(text: "original", copiedAt: Date(timeIntervalSinceReferenceDate: timestamp), parts: [part("original")]))
            let undo = try commit(store, "edited", record: original)
            let persisted = try XCTUnwrap(store.item(id: original.id))
            XCTAssertEqual(ClipboardEditFingerprint.digest(persisted), undo.expectedContentFingerprint)
            _ = try store.undoSelectionEdit(undo)
            var expected = original; expected.revision += 2
            XCTAssertEqual(try store.item(id: original.id), expected)
        }
    }
}
