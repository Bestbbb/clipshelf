import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class OwnedPublicationControlsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-external-publication-controls-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func store() throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
    }
    private func owned(_ store: HistoryStore, name: String) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: name, parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data())
        ])]), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: name, data: Data(name.utf8))],
        expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }
    private func url(_ record: ClipboardRecord) throws -> URL {
        try XCTUnwrap(ClipboardFileAccess.url(from: XCTUnwrap(record.parts.first?.representations.first?.data)))
    }
    private func publish(_ record: ClipboardRecord, store: HistoryStore, purpose: OwnedAssetPublicationPurpose) throws -> OwnedAssetPublication {
        let lease = try store.retainCapturedOwnedFiles([record], purpose: .output)
        return try store.publishOwnedFiles(lease: lease, purpose: purpose)
    }
    private func ids(_ store: HistoryStore) throws -> Set<UUID> {
        Set(try store.ownedPublications().map(\.id))
    }
    private func externalIDs(_ store: HistoryStore) throws -> Set<UUID> {
        Set(try store.ownedPublications().filter { $0.purpose != .clipboard }.map(\.id))
    }

    func testConfirmedExternalUsesReleaseTogetherWithoutDeletingBytesOrClipboardHistoryAndLeaseRoots() throws {
        let store = try store()
        let orphan = try owned(store, name: "external-only.txt"), clipboard = try owned(store, name: "clipboard.txt")
        let live = try owned(store, name: "in-history.txt"), transient = try owned(store, name: "stack-held.txt")
        for purpose: OwnedAssetPublicationPurpose in [.drag, .sharing, .externalOpen, .legacyExternal] {
            _ = try publish(orphan, store: store, purpose: purpose)
        }
        let clipboardPublication = try publish(clipboard, store: store, purpose: .clipboard)
        _ = try publish(clipboard, store: store, purpose: .sharing)
        _ = try publish(live, store: store, purpose: .drag)
        _ = try publish(transient, store: store, purpose: .externalOpen)
        var lease: OwnedAssetLease? = try store.retainCapturedOwnedFiles([transient], purpose: .stack)
        try store.delete(id: orphan.id); try store.delete(id: clipboard.id); try store.delete(id: transient.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)

        let confirmed = try externalIDs(store)
        XCTAssertEqual(confirmed.count, 7)
        try store.clearConfirmedExternalOwnedPublications(expectedIDs: confirmed)
        XCTAssertEqual(try ids(store), [clipboardPublication.id])
        XCTAssertNotNil(try store.item(id: live.id))
        XCTAssertNotNil(lease)
        let plan = try store.prepareOwnedStorageCleanup()
        XCTAssertEqual(plan.usage.assetCount, 4)
        XCTAssertEqual(plan.usage.protectedAssetCount, 3)
        XCTAssertEqual(plan.candidateCount, 1)
        for record in [orphan, clipboard, live, transient] {
            XCTAssertEqual(try Data(contentsOf: url(record)), Data(record.text.utf8), "Releasing publications is metadata-only; the separate GC confirmation owns file deletion.")
        }
        // An empty external set does not authorize touching the current clipboard.
        try store.clearConfirmedExternalOwnedPublications(expectedIDs: [])
        XCTAssertEqual(try ids(store), [clipboardPublication.id])
        lease = nil
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 2)
        XCTAssertEqual(try Data(contentsOf: url(transient)), Data(transient.text.utf8))
    }

    func testPublicationArrivingOnAnotherConnectionRejectsEntireOldConfirmationAndNewClipboardIsNeverIncluded() throws {
        let first = try store(), second = try store(), record = try owned(first, name: "concurrent.txt")
        let old = try publish(record, store: first, purpose: .drag)
        try first.delete(id: record.id)
        let displayed: Set<UUID> = [old.id]
        let late = try publish(record, store: second, purpose: .sharing)
        XCTAssertThrowsError(try first.clearConfirmedExternalOwnedPublications(expectedIDs: displayed)) { error in
            guard case OwnedStorageError.changed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try ids(first), [old.id, late.id])
        XCTAssertEqual(try ids(second), [old.id, late.id])
        XCTAssertEqual(try first.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertEqual(try Data(contentsOf: url(record)), Data(record.text.utf8))

        let refreshed = try externalIDs(first)
        let clipboard = try publish(record, store: second, purpose: .clipboard)
        try first.clearConfirmedExternalOwnedPublications(expectedIDs: refreshed)
        XCTAssertEqual(try ids(second), [clipboard.id])
        XCTAssertEqual(try second.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertEqual(try Data(contentsOf: url(record)), Data(record.text.utf8))
    }

    func testCommitFailureRollsBackWholePublicationSetAndRetryStillDoesNotDeleteFiles() throws {
        let store = try store(), record = try owned(store, name: "commit-rollback.txt")
        for purpose: OwnedAssetPublicationPurpose in [.drag, .sharing, .externalOpen, .legacyExternal] {
            _ = try publish(record, store: store, purpose: purpose)
        }
        try store.delete(id: record.id)
        let before = try ids(store)
        defer { sqlite3_commit_hook(store.database, nil, nil) }
        sqlite3_commit_hook(store.database, { _ in 1 }, nil)
        XCTAssertThrowsError(try store.clearConfirmedExternalOwnedPublications(expectedIDs: before))
        sqlite3_commit_hook(store.database, nil, nil)
        XCTAssertEqual(try ids(store), before)
        let reopened = try self.store()
        XCTAssertEqual(try ids(reopened), before)
        XCTAssertEqual(try reopened.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertEqual(try Data(contentsOf: url(record)), Data(record.text.utf8))
        try reopened.clearConfirmedExternalOwnedPublications(expectedIDs: before)
        XCTAssertTrue(try ids(store).isEmpty)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 1)
        XCTAssertEqual(try Data(contentsOf: url(record)), Data(record.text.utf8))
    }

    func testMissingExtraAndClipboardIDsCannotPartiallyReleaseAnExternalSet() throws {
        let store = try store(), record = try owned(store, name: "exact-set.txt")
        let drag = try publish(record, store: store, purpose: .drag)
        let sharing = try publish(record, store: store, purpose: .sharing)
        let clipboard = try publish(record, store: store, purpose: .clipboard)
        try store.delete(id: record.id)
        let before = try ids(store)
        let invalidSets: [Set<UUID>] = [[], [drag.id], [drag.id, sharing.id, UUID()], [drag.id, sharing.id, clipboard.id]]
        for invalid in invalidSets {
            XCTAssertThrowsError(try store.clearConfirmedExternalOwnedPublications(expectedIDs: invalid)) { error in
                guard case OwnedStorageError.changed = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try ids(store), before)
            XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
            XCTAssertEqual(try Data(contentsOf: url(record)), Data(record.text.utf8))
        }
    }
}
