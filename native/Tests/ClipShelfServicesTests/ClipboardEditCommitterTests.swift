import CSQLite
import Foundation
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor
final class ClipboardEditCommitterTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-edit-commit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store() throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    }
    private func cache() -> OCRDerivedCache { OCRDerivedCache(directory: directory.appendingPathComponent("ocr")) }
    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference {
        .init(id: record.id, revision: record.revision)
    }
    private func image(_ value: String = "original-image") -> ClipboardRecord {
        ClipboardRecord(text: "image caption", parts: [.init(representations: [
            .init(typeIdentifier: "public.png", data: Data(value.utf8))])], ocrText: "old recognition")
    }
    private func changed(_ record: ClipboardRecord) -> ClipboardRecord {
        var record = record
        record.parts[0].representations[0].data.append(42)
        record.ocrText = nil
        return record
    }
    private func result(_ image: Data, text: String = "rotated recognition") -> LocalIntelligenceService.OCRResult {
        .init(text: text, regions: [], recognitionLanguages: LocalIntelligenceService.defaultRecognitionLanguages,
              sourceImageDigest: LocalIntelligenceService.imageDigest(image),
              engineIdentifier: LocalIntelligenceService.ocrEngineIdentifier,
              engineRevision: LocalIntelligenceService.ocrEngineRevision,
              engineVersion: LocalIntelligenceService.ocrEngineVersion, orientedPixelSize: CGSize(width: 3, height: 2))
    }

    func testImageAndSearchableOCRCommitAtOneRevisionAndRepeatedEditUndoRemainsUsable() async throws {
        let store = try store(), cache = cache(), original = try store.create(image())
        let snapshot = try store.prepareEdit(reference(original)), edited = changed(original)
        let undo = try await ClipboardEditCommitter.commit(edited, snapshot: snapshot, store: store, cache: cache) {
            self.result($0)
        }
        let saved = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(saved.revision, original.revision + 1)
        XCTAssertEqual(saved.ocrText, "rotated recognition")
        XCTAssertEqual(undo.committedReference, reference(saved))
        XCTAssertEqual(try store.searchMetadata(.init(text: "rotated recognition")).map(\.id), [original.id])
        let cached = try await cache.result(for: saved, imageData: XCTUnwrap(OCRDerivedCache.imageData(in: saved)))
        XCTAssertEqual(cached?.text, saved.ocrText)
        let secondSnapshot = try store.prepareEdit(undo.committedReference)
        let secondUndo = try await ClipboardEditCommitter.commit(changed(saved), snapshot: secondSnapshot,
                                                               store: store, cache: cache) { self.result($0) }
        XCTAssertEqual(secondUndo.committedReference.revision, original.revision + 2)
        var expectedSecond = changed(saved)
        expectedSecond.revision += 1; expectedSecond.ocrText = saved.ocrText
        XCTAssertEqual(try store.item(id: original.id), expectedSecond,
                       "Identical new OCR is still newly derived, not stale copied text")
        XCTAssertEqual(try store.searchMetadata(.init(text: "rotated recognition")).map(\.id), [original.id])
        let receipt = try store.undoSelectionEdit(secondUndo)
        var expectedIntermediate = saved; expectedIntermediate.revision = receipt.references[0].revision
        XCTAssertEqual(try store.item(id: original.id), expectedIntermediate,
                       "Undo must restore the complete original, including identical OCR text")
        XCTAssertEqual(try store.searchMetadata(.init(text: "rotated recognition")).map(\.id), [original.id])
        let rebased = try store.rebaseSelectionEditUndo(undo, after: receipt)
        _ = try store.undoSelectionEdit(rebased)
        var expected = original; expected.revision += 4
        XCTAssertEqual(try store.item(id: original.id), expected)
    }

    func testRenameDoesNotRecognizeOrRemoveCacheAndPreservesExistingOCR() async throws {
        let store = try store(), cache = cache(), original = try store.create(image())
        let data = try XCTUnwrap(OCRDerivedCache.imageData(in: original)), oldResult = result(data, text: "old recognition")
        try await cache.store(oldResult, for: original, imageData: data, sourceStore: store)
        var renamed = original; renamed.renamedTitle = "New title"
        _ = try await ClipboardEditCommitter.commit(renamed, snapshot: store.prepareEdit(reference(original)),
                                                    store: store, cache: cache) { _ in
            XCTFail("Renaming must not invoke recognition"); throw CancellationError()
        }
        XCTAssertEqual(try store.item(id: original.id)?.ocrText, original.ocrText)
        let oldCache = try await cache.result(for: original, imageData: data)
        XCTAssertEqual(oldCache, oldResult, "A metadata edit should not proactively purge image bytes")
    }

    func testRecognitionFailureStillCommitsImageAndClearsOldDerivedContent() async throws {
        let store = try store(), cache = cache(), original = try store.create(image())
        let data = try XCTUnwrap(OCRDerivedCache.imageData(in: original))
        try await cache.store(result(data), for: original, imageData: data)
        let undo = try await ClipboardEditCommitter.commit(changed(original), snapshot: store.prepareEdit(reference(original)),
                                                           store: store, cache: cache) { _ in
            throw LocalIntelligenceService.RecognitionError.invalidImage
        }
        let saved = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(saved.parts, changed(original).parts)
        XCTAssertNil(saved.ocrText)
        XCTAssertEqual(saved.revision, original.revision + 1)
        let oldCache = try await cache.result(for: original, imageData: data)
        XCTAssertNil(oldCache)
        _ = try store.undoSelectionEdit(undo)
    }

    func testCommitFailurePreservesOriginalAndOldOCRCache() async throws {
        let store = try store(), cache = cache(), original = try store.create(image())
        let data = try XCTUnwrap(OCRDerivedCache.imageData(in: original)), oldResult = result(data)
        try await cache.store(oldResult, for: original, imageData: data)
        let snapshot = try store.prepareEdit(reference(original))
        XCTAssertEqual(sqlite3_exec(store.database, "CREATE TRIGGER fail_edit BEFORE UPDATE ON clipboard_records BEGIN SELECT RAISE(ABORT, 'injected save failure'); END", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await ClipboardEditCommitter.commit(changed(original), snapshot: snapshot, store: store, cache: cache) {
                self.result($0)
            }
            XCTFail("Expected transaction failure")
        } catch {}
        XCTAssertEqual(try store.item(id: original.id), original)
        let cached = try await cache.result(for: original, imageData: data)
        XCTAssertEqual(cached, oldResult)
    }

    func testAccountRoundTripDuringOCRCannotCommitAndDoesNotPurgeCache() async throws {
        let store = try store(), cache = cache()
        try store.configureSync(accountID: "A")
        let original = try store.create(image()), snapshot = try store.prepareEdit(reference(original))
        let data = try XCTUnwrap(OCRDerivedCache.imageData(in: original)), oldResult = result(data)
        try await cache.store(oldResult, for: original, imageData: data)
        do {
            _ = try await ClipboardEditCommitter.commit(changed(original), snapshot: snapshot, store: store, cache: cache) { image in
                try store.configureSync(accountID: "B")
                try store.configureSync(accountID: "A")
                return self.result(image)
            }
            XCTFail("Expected account-generation rejection")
        } catch SyncError.accountChanged {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(try store.item(id: original.id), original)
        let cached = try await cache.result(for: original, imageData: data)
        XCTAssertEqual(cached, oldResult)
    }

    func testCancellationDuringOCRMakesNoWrite() async throws {
        let store = try store(), cache = cache(), original = try store.create(image())
        do {
            _ = try await ClipboardEditCommitter.commit(changed(original), snapshot: store.prepareEdit(reference(original)),
                                                        store: store, cache: cache) { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(try store.item(id: original.id), original)
    }

    func testCacheFailureAfterCommitDoesNotTurnSuccessfulSaveIntoRetryableFailure() async throws {
        let store = try store(), original = try store.create(image())
        let badDirectory = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: badDirectory)
        let cache = OCRDerivedCache(directory: badDirectory)
        let undo = try await ClipboardEditCommitter.commit(changed(original), snapshot: store.prepareEdit(reference(original)),
                                                          store: store, cache: cache) { self.result($0) }
        XCTAssertEqual(try store.item(id: original.id)?.revision, undo.committedReference.revision)
        _ = try store.undoSelectionEdit(undo)
    }

    func testDelayedCommitCleanupKeepsSameAndNewerRevisionOCR() async throws {
        let cache = cache(), original = image()
        let data = try XCTUnwrap(OCRDerivedCache.imageData(in: original))
        var newer = original; newer.revision += 1
        let recognized = result(data)
        try await cache.store(recognized, for: newer, imageData: data)
        try await cache.remove(recordID: original.id, beforeRevision: original.revision)
        try await cache.remove(recordID: original.id, beforeRevision: newer.revision)
        let kept = try await cache.result(for: newer, imageData: data)
        XCTAssertEqual(kept, recognized)
        try await cache.remove(recordID: original.id, beforeRevision: newer.revision + 1)
        let removed = try await cache.result(for: newer, imageData: data)
        XCTAssertNil(removed)
    }
}
