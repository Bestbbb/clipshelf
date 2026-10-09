import ClipShelfCore
import XCTest
@testable import ClipShelf

final class OwnedFileStackRetentionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-stack-retention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func owned(_ name: String, in store: HistoryStore) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: name, parts: [ClipboardPart(representations: [
            ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data())
        ])]), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: name, data: Data(name.utf8))],
        expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }

    private func url(_ record: ClipboardRecord) throws -> URL {
        try XCTUnwrap(ClipboardFileAccess.url(from: XCTUnwrap(record.parts.first?.representations.first?.data)))
    }

    @MainActor func testQueueDuplicatesAndRecoveryKeepFilesAfterHistoryDeletionThenClearReleasesThem() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let first = try owned("first.txt", in: store), second = try owned("second.txt", in: store)
        let firstURL = try url(first), secondURL = try url(second)
        let stack = StackCoordinator()
        stack.retainer = { try store.retainCapturedOwnedFiles($0, purpose: .stack) }
        stack.activate(); stack.append(first); stack.append(first); stack.append(second)
        try store.delete(id: first.id); try store.delete(id: second.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertEqual(stack.remove(at: 1)?.id, first.id)
        XCTAssertEqual(stack.markDispatched()?.id, first.id)
        XCTAssertEqual(stack.remove(at: 0)?.id, second.id)
        XCTAssertTrue(stack.queue.isEmpty)
        XCTAssertTrue(stack.canRestoreLastConsumed)
        // Only the removed second file may be reclaimed. Empty queue still has a
        // recoverable first occurrence, whose actual file must remain available.
        let firstCleanup = try store.prepareOwnedStorageCleanup()
        XCTAssertEqual(firstCleanup.candidateCount, 1)
        XCTAssertEqual(try store.commitOwnedStorageCleanup(firstCleanup).removedAssetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("first.txt".utf8))
        XCTAssertEqual(stack.restoreLastConsumed()?.id, first.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        stack.clear()
        let finalCleanup = try store.prepareOwnedStorageCleanup()
        XCTAssertEqual(finalCleanup.candidateCount, 1)
        XCTAssertEqual(try store.commitOwnedStorageCleanup(finalCleanup).removedAssetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    }

    @MainActor func testReplacingLastConsumedReleasesOnlyPreviousOccurrenceAndEndReleasesCurrent() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let first = try owned("previous.txt", in: store), second = try owned("current.txt", in: store)
        let firstURL = try url(first), secondURL = try url(second)
        let stack = StackCoordinator()
        stack.retainer = { try store.retainCapturedOwnedFiles($0, purpose: .stack) }
        stack.activate(); stack.append(first); stack.append(second)
        try store.delete(id: first.id); try store.delete(id: second.id)
        _ = stack.markDispatched(); _ = stack.markDispatched()
        let plan = try store.prepareOwnedStorageCleanup()
        XCTAssertEqual(plan.candidateCount, 1)
        XCTAssertEqual(try store.commitOwnedStorageCleanup(plan).removedAssetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("current.txt".utf8))
        stack.end()
        XCTAssertEqual(try store.commitOwnedStorageCleanup(store.prepareOwnedStorageCleanup()).removedAssetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor func testAtomicCaptureLeaseTransfersToStackAndReclaimedSnapshotCannotBeAppended() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let first = try owned("capture.txt", in: store), file = try url(first)
        let stack = StackCoordinator()
        stack.retainer = { try store.retainCapturedOwnedFiles($0, purpose: .stack) }
        var captured: RetainedClipboardRecords? = try store.recordRetainingCapturedOwnedFiles(first)
        stack.activate()
        stack.append(try XCTUnwrap(captured?.records.first), lease: captured?.lease)
        captured = nil
        try store.delete(id: first.id)
        XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 0)
        stack.end()
        XCTAssertEqual(try store.commitOwnedStorageCleanup(store.prepareOwnedStorageCleanup()).removedAssetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        var errors = 0
        stack.onRetentionError = { _ in errors += 1 }
        stack.activate(); stack.append(first)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(stack.queue.isEmpty, "A failed retention must not silently queue an unprotected owned path.")
    }
}
