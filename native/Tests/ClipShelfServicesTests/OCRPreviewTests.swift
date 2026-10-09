import ClipShelfCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import ClipShelf

@MainActor
final class OCRPreviewTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-ocr-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testVisionRecognizesSyntheticChineseAndEnglishAndActualBounds() async throws {
        let data = try Self.image()
        let result = try await LocalIntelligenceService().recognizeText(in: data)
        XCTAssertTrue(result.text.contains("剪贴板"), result.text)
        XCTAssertTrue(result.text.uppercased().contains("CLIPSHELF"), result.text)
        XCTAssertEqual(result.sourceImageDigest, LocalIntelligenceService.imageDigest(data))
        XCTAssertEqual(result.engineIdentifier, LocalIntelligenceService.ocrEngineIdentifier)
        XCTAssertGreaterThan(result.engineRevision, 0)
        XCTAssertFalse(result.engineVersion.isEmpty)
        XCTAssertFalse(result.recognitionLanguages.isEmpty)
        let chinese = try XCTUnwrap(result.regions.first { $0.text.contains("剪贴板") })
        let english = try XCTUnwrap(result.regions.first { $0.text.uppercased().contains("CLIPSHELF") })
        XCTAssertGreaterThan(english.boundingBox.minY, chinese.boundingBox.maxY)
        XCTAssertFalse(ImagePreviewGeometry.matches(in: chinese, query: "剪贴板").isEmpty)
        XCTAssertFalse(ImagePreviewGeometry.matches(in: english, query: "clipshelf").isEmpty)
        for region in result.regions {
            for span in region.spans {
                XCTAssertGreaterThan(span.boundingBox.width, 0)
                XCTAssertGreaterThan(span.boundingBox.height, 0)
                XCTAssertLessThanOrEqual(span.utf16Location + span.utf16Length, region.text.utf16.count)
            }
        }
        let cache = OCRDerivedCache(directory: directory)
        let record = Self.record(data)
        try await cache.store(result, for: record, imageData: data)
        let restored = try await cache.result(for: record, imageData: data)
        XCTAssertEqual(restored, result, "Actual Vision bounds/engine/confidence must survive JSON")
    }

    func testAspectFitAndLowerLeftCoordinatesAcrossPortraitAndLandscape() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let imageRect = ImagePreviewGeometry.aspectFit(imageSize: CGSize(width: 1000, height: 250), in: bounds)
        XCTAssertEqual(imageRect, CGRect(x: 10, y: 220, width: 800, height: 200))
        let box = ImagePreviewGeometry.rectangle(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), imageRect: imageRect)
        XCTAssertEqual(box.minX, 90, accuracy: 0.001); XCTAssertEqual(box.minY, 260, accuracy: 0.001)
        XCTAssertEqual(box.width, 240, accuracy: 0.001); XCTAssertEqual(box.height, 80, accuracy: 0.001)
        let portrait = ImagePreviewGeometry.aspectFit(imageSize: CGSize(width: 250, height: 1000), in: bounds)
        XCTAssertEqual(portrait, CGRect(x: 335, y: 20, width: 150, height: 600))
        XCTAssertEqual(ImagePreviewGeometry.aspectFit(imageSize: .zero, in: bounds), .zero)
    }

    func testSearchUsesActualSpansForChineseAndFoldedEnglishAndFallsBackToLine() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.15)
        let span = CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.15)
        let chinese = LocalIntelligenceService.OCRRegion(text: "记录剪贴板历史", boundingBox: box, confidence: 0.9,
            spans: [.init(utf16Location: 2, utf16Length: 3, boundingBox: span)])
        XCTAssertEqual(ImagePreviewGeometry.matches(in: chinese, query: "剪贴板"), [span])
        XCTAssertTrue(ImagePreviewGeometry.matches(in: chinese, query: "不存在").isEmpty)
        let english = LocalIntelligenceService.OCRRegion(text: "ＣＡＦÉ guide", boundingBox: box, confidence: 0.8)
        XCTAssertEqual(ImagePreviewGeometry.matches(in: english, query: "cafe"), [box])
        XCTAssertTrue(ImagePreviewGeometry.matches(in: english, query: "   ").isEmpty)
    }

    func testEXIFOrientationIsAppliedWithoutChangingOriginalBytes() throws {
        let data = try Self.image(orientation: 6)
        let original = data
        let decoded = try LocalIntelligenceService.decodedImage(in: data)
        XCTAssertEqual(decoded.width, 320); XCTAssertEqual(decoded.height, 1000)
        XCTAssertEqual(data, original)
    }

    func testCacheRejectsNewRevisionChangedPixelsLanguagesAndExpiry() async throws {
        let data = try Self.image(), record = Self.record(try Self.image())
        let cache = OCRDerivedCache(directory: directory)
        let result = Self.result(data)
        try await cache.store(result, for: record, imageData: data)
        var newer = record; newer.revision += 1
        let revisionMiss = try await cache.result(for: newer, imageData: data)
        XCTAssertNil(revisionMiss)
        let rotated = try Self.image(orientation: 6)
        var changed = record; changed.parts = Self.record(rotated).parts
        let changedMiss = try await cache.result(for: changed, imageData: rotated)
        XCTAssertNil(changedMiss)
        let languageMiss = try await cache.result(for: record, imageData: data, recognitionLanguages: ["en-US"])
        XCTAssertNil(languageMiss)
        let expired = try await OCRDerivedCache(directory: directory, maximumAge: -1).result(for: record, imageData: data)
        XCTAssertNil(expired)
        XCTAssertEqual(record.parts.first?.representations.first?.data, data)
    }

    func testCorruptOrDifferentEngineCacheIsRecomputedRatherThanTrusted() async throws {
        let data = try Self.image(), record = Self.record(try Self.image()), cache = OCRDerivedCache(directory: directory)
        try await cache.store(Self.result(data), for: record, imageData: data)
        let url = directory.appendingPathComponent(record.id.uuidString + ".json")
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var result = try XCTUnwrap(entry["result"] as? [String: Any]); result["engineRevision"] = -1
        entry["result"] = result
        try JSONSerialization.data(withJSONObject: entry).write(to: url)
        let engineMiss = try await cache.result(for: record, imageData: data)
        XCTAssertNil(engineMiss)
        try Data("broken derived cache".utf8).write(to: url)
        let corruptMiss = try await cache.result(for: record, imageData: data)
        XCTAssertNil(corruptMiss)
        try await cache.store(Self.result(data), for: record, imageData: data)
        let retry = try await cache.result(for: record, imageData: data)
        XCTAssertNotNil(retry)
    }

    func testMismatchedResultCannotBeSavedAndOlderResultCannotReplaceNewer() async throws {
        let data = try Self.image(), record = Self.record(try Self.image()), cache = OCRDerivedCache(directory: directory)
        do { try await cache.store(Self.result(Data("wrong pixels".utf8)), for: record, imageData: data); XCTFail("Expected digest rejection") }
        catch OCRDerivedCache.CacheError.invalidResult {} catch { XCTFail("Unexpected \(error)") }
        var newer = record; newer.revision += 1
        try await cache.store(Self.result(data), for: newer, imageData: data)
        try await cache.store(Self.result(data), for: record, imageData: data)
        let restored = try await cache.result(for: newer, imageData: data)
        XCTAssertNotNil(restored)
        try await cache.remove(recordID: newer.id)
        let removed = try await cache.result(for: newer, imageData: data)
        XCTAssertNil(removed)
        try await cache.store(Self.result(data), for: newer, imageData: data)
        try await cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testRecognitionCanRetryAfterFailureAndCancellation() async throws {
        let service = LocalIntelligenceService()
        do { _ = try await service.recognizeText(in: Data()); XCTFail("Invalid image must fail") } catch {}
        let data = try Self.image()
        let cancelled = Task { try await service.recognizeText(in: data) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled OCR must not publish") } catch { XCTAssertTrue(error is CancellationError) }
        let success = try await service.recognizeText(in: data)
        XCTAssertTrue(success.text.contains("剪贴板"), success.text)
    }

    func testPurgeDeletesMissingAndOlderRevisionEntriesButKeepsCurrent() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let cacheDirectory = directory.appendingPathComponent("derived")
        let cache = OCRDerivedCache(directory: cacheDirectory)
        let data = try Self.image()
        let deleted = try store.create(Self.record(data)), changed = try store.create(Self.record(data)), current = try store.create(Self.record(data))
        for record in [deleted, changed, current] { try await cache.store(Self.result(data), for: record, imageData: data) }
        try store.delete(id: deleted.id)
        var edited = changed; edited.renamedTitle = "updated fixture"
        _ = try store.update(record: edited)
        try await cache.purgeStaleEntries(using: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(deleted.id.uuidString + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(changed.id.uuidString + ".json").path))
        let kept = try await cache.result(for: current, imageData: data)
        XCTAssertNotNil(kept)
        XCTAssertEqual(try store.itemMetadata(id: current.id)?.revision, current.revision)
    }

    func testPurgeDeletesExpiredAndCorruptEntriesWithoutTouchingOtherFiles() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let cacheDirectory = directory.appendingPathComponent("derived")
        let cache = OCRDerivedCache(directory: cacheDirectory)
        let data = try Self.image()
        let expired = try store.create(Self.record(data)), corrupt = try store.create(Self.record(data))
        for record in [expired, corrupt] { try await cache.store(Self.result(data), for: record, imageData: data) }
        let expiredURL = cacheDirectory.appendingPathComponent(expired.id.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: expiredURL)) as? [String: Any])
        json["createdAt"] = Date().addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: json).write(to: expiredURL)
        let corruptURL = cacheDirectory.appendingPathComponent(corrupt.id.uuidString + ".json")
        try Data("broken derived file".utf8).write(to: corruptURL)
        let unrelated = cacheDirectory.appendingPathComponent("notes.json")
        let original = Data("unrelated fixture".utf8); try original.write(to: unrelated)
        try await cache.purgeStaleEntries(using: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), original)
    }

    func testPurgeNeverFollowsCacheSymlinksOrRecursesIntoDirectories() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let cacheDirectory = directory.appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.txt"), bytes = Data("outside the cache".utf8)
        try bytes.write(to: original)
        let link = cacheDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let nested = cacheDirectory.appendingPathComponent(UUID().uuidString + ".json", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try bytes.write(to: nested.appendingPathComponent("keep.txt"))
        try await OCRDerivedCache(directory: cacheDirectory).purgeStaleEntries(using: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("keep.txt")), bytes)
    }

    func testLateOCRCannotRecreateDeletedCacheAfterPurge() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let cacheDirectory = directory.appendingPathComponent("derived")
        let cache = OCRDerivedCache(directory: cacheDirectory), data = try Self.image()
        let record = try store.create(Self.record(data))
        let completedRecognition = Self.result(data)
        try await cache.store(completedRecognition, for: record, imageData: data, sourceStore: store)
        try store.delete(id: record.id)
        try await cache.purgeStaleEntries(using: store)
        do {
            try await cache.store(completedRecognition, for: record, imageData: data, sourceStore: store)
            XCTFail("Late preview recognition must not recreate deleted OCR text")
        } catch OCRDerivedCache.CacheError.sourceChanged {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(record.id.uuidString + ".json").path))
        XCTAssertThrowsError(try OCRDerivedCache.validateSource(record, in: store))
    }

    func testLateOldRevisionCannotReplaceOrDisplayCurrentSource() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let cache = OCRDerivedCache(directory: directory.appendingPathComponent("derived")), data = try Self.image()
        let old = try store.create(Self.record(data))
        var edited = old; edited.renamedTitle = "new revision fixture"
        let current = try store.update(record: edited)
        try await cache.store(Self.result(data), for: current, imageData: data, sourceStore: store)
        do {
            try await cache.store(Self.result(data), for: old, imageData: data, sourceStore: store)
            XCTFail("Stale source must be rejected even if its image digest is unchanged")
        } catch OCRDerivedCache.CacheError.sourceChanged {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertThrowsError(try OCRDerivedCache.validateSource(old, in: store))
        XCTAssertNoThrow(try OCRDerivedCache.validateSource(current, in: store))
        let preserved = try await cache.result(for: current, imageData: data)
        XCTAssertNotNil(preserved)
    }

    private static func record(_ data: Data) -> ClipboardRecord {
        ClipboardRecord(text: "synthetic image", parts: [.init(representations: [.init(typeIdentifier: "public.png", data: data)])], revision: 7)
    }
    private static func result(_ data: Data) -> LocalIntelligenceService.OCRResult {
        .init(text: "Fixture", regions: [.init(text: "Fixture", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1), confidence: 0.9)],
              recognitionLanguages: LocalIntelligenceService.defaultRecognitionLanguages, sourceImageDigest: LocalIntelligenceService.imageDigest(data),
              engineIdentifier: LocalIntelligenceService.ocrEngineIdentifier, engineRevision: LocalIntelligenceService.ocrEngineRevision,
              engineVersion: LocalIntelligenceService.ocrEngineVersion, orientedPixelSize: CGSize(width: 1000, height: 320))
    }
    private static func image(orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 320, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 320))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 52, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        for (text, y) in [("CLIPSHELF SEARCH 2026", 230.0), ("剪贴板历史记录", 90.0)] {
            context.textPosition = CGPoint(x: 45, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
