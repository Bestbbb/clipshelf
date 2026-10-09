import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

private final class RotationConversionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClipboardRecord] = []
    private var mainThread = false
    var records: [ClipboardRecord] { lock.lock(); defer { lock.unlock() }; return values }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func capture(_ record: ClipboardRecord) {
        lock.lock(); defer { lock.unlock() }; values.append(record); mainThread = mainThread || Thread.isMainThread
    }
}

@MainActor private final class RotationInteractionHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-rotation-ui-\(UUID().uuidString)")
    let controller: ImagePreviewController
    let original: ClipboardRecord
    let cache: OCRDerivedCache
    let probe = RotationConversionProbe()
    var prepares: [(ClipboardSelectionReference, (Result<ClipboardEditSnapshot, Error>) -> Void)] = []
    var saves: [(ClipboardEditSnapshot, ClipboardRecord, (Result<ClipboardSelectionReference, Error>) -> Void)] = []
    var commits: [(ClipboardSelectionReference, ClipboardRecord)] = []
    var extracted: [ClipboardRecord] = []
    var recognitionCalls = 0, presentations = 0, dismissals = 0
    var recognizes: [(Data, CheckedContinuation<LocalIntelligenceService.OCRResult, Error>)] = []
    var validContext = true

    init(deferredOCR: Bool = false, sourceStore: HistoryStore? = nil, original: ClipboardRecord? = nil) throws {
        _ = NSApplication.shared
        let first = try Self.png(width: 2, height: 3)
        let rotated = try Self.png(width: 3, height: 2)
        self.original = original ?? ClipboardRecord(text: "图片 2 × 3", parts: [.init(representations: [.init(typeIdentifier: "public.png", data: first)])], revision: 4)
        cache = OCRDerivedCache(directory: directory.appendingPathComponent("cache"))
        controller = ImagePreviewController(record: self.original, cache: cache, sourceStore: sourceStore)
        controller.presentWindow = { [weak self] _, _ in self?.presentations += 1 }
        controller.isContextCurrent = { [weak self] in self?.validContext == true }
        controller.onPrepareEdit = { [weak self] ref, reply in self?.prepares.append((ref, reply)) }
        controller.onEdit = { [weak self] snapshot, record, reply in self?.saves.append((snapshot, record, reply)) }
        controller.onCommitted = { [weak self] old, record in self?.commits.append((old, record)) }
        controller.onExtractText = { [weak self] record in self?.extracted.append(record) }
        controller.onDismiss = { [weak self] in self?.dismissals += 1 }
        controller.recognizeImage = { [weak self] data in
            guard let self else { throw CancellationError() }
            self.recognitionCalls += 1
            if deferredOCR {
                return try await withCheckedThrowingContinuation { self.recognizes.append((data, $0)) }
            }
            return Self.ocr(data: data, text: "recognized \(self.recognitionCalls)")
        }
        let probe = self.probe
        controller.rotationConverter = { record in
            probe.capture(record)
            var result = record; result.text = "rotated \(record.revision)"
            result.parts = [.init(representations: [.init(typeIdentifier: "public.png", data: rotated)])]
            result.ocrText = nil
            return result
        }
        controller.present(relativeTo: nil)
    }
    static func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<height { for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = x == 0 ? 255 : 0; pixels[offset + 1] = 0
            pixels[offset + 2] = x == 0 ? 0 : 255; pixels[offset + 3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    static func ocr(data: Data, text: String) -> LocalIntelligenceService.OCRResult {
        .init(text: text, regions: [.init(text: text, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3), confidence: 0.9)],
              recognitionLanguages: LocalIntelligenceService.defaultRecognitionLanguages,
              sourceImageDigest: LocalIntelligenceService.imageDigest(data), engineIdentifier: LocalIntelligenceService.ocrEngineIdentifier,
              engineRevision: LocalIntelligenceService.ocrEngineRevision, engineVersion: LocalIntelligenceService.ocrEngineVersion,
              orientedPixelSize: CGSize(width: 3, height: 2))
    }
    func snapshot(_ record: ClipboardRecord? = nil) -> ClipboardEditSnapshot {
        .init(record: record ?? original, syncConfiguration: .init(accountID: "fixture-A", generation: 8),
              sharingConfiguration: .init(accountID: "fixture-A", generation: 12))
    }
    func prepare(_ snapshot: ClipboardEditSnapshot? = nil) { prepares.last?.1(.success(snapshot ?? self.snapshot())) }
    func rotate() { controller.perform(NSSelectorFromString("rotateImage")) }
    func extract() { controller.perform(NSSelectorFromString("extractText")) }
    func view<T: NSView>(_ type: T.Type, label: String? = nil, title: String? = nil) throws -> T {
        func find(_ view: NSView) -> T? {
            if let typed = view as? T, (label == nil || typed.accessibilityLabel() == label),
               (title == nil || (typed as? NSButton)?.title == title) { return typed }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(controller.window?.contentView.flatMap(find))
    }
    var status: String { (try? view(NSTextField.self, label: "图片预览状态"))?.stringValue ?? "" }
    var text: String { (try? view(NSTextView.self, label: "本机识别全文，可选择复制"))?.string ?? "" }
    func close() {
        controller.dismiss()
        let pending = recognizes; recognizes = []
        pending.forEach { $0.1.resume(throwing: CancellationError()) }
        try? FileManager.default.removeItem(at: directory)
    }
    func takeOCR(_ index: Int) -> (Data, CheckedContinuation<LocalIntelligenceService.OCRResult, Error>) {
        recognizes.remove(at: index)
    }
}

@MainActor final class ImageRotationInteractionTests: XCTestCase {
    private func eventually(_ predicate: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for a synthetic callback", file: file, line: line)
    }
    private func failure(_ message: String = "磁盘暂时不可写") -> Error { NSError(domain: "fixture.rotation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    func testReadonlyPreviewLoadsBeforeAnyWriteAuthorizationAndFailureRetainsOriginalCache() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        try await eventually { !h.text.isEmpty }
        XCTAssertTrue(h.prepares.isEmpty); XCTAssertTrue(h.saves.isEmpty)
        XCTAssertFalse(try XCTUnwrap(h.controller.window).isVisible)
        let originalText = h.text
        h.rotate(); XCTAssertEqual(h.prepares.count, 1)
        h.prepares[0].1(.failure(failure("共享板为只读")))
        XCTAssertEqual(h.controller.currentRecord, h.original); XCTAssertEqual(h.text, originalText)
        XCTAssertTrue(h.status.contains("只读")); XCTAssertTrue(h.saves.isEmpty); XCTAssertEqual(h.dismissals, 0)
        let cached = try await h.cache.result(for: h.original, imageData: try XCTUnwrap(OCRDerivedCache.imageData(in: h.original)))
        XCTAssertNotNil(cached)
    }

    func testPendingPreparationBlocksRepeatAndExtractionAndRetriesAfterPreparationFailure() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        try await eventually { !h.text.isEmpty }
        h.rotate(); h.rotate(); h.extract()
        XCTAssertEqual(h.prepares.count, 1); XCTAssertTrue(h.extracted.isEmpty)
        XCTAssertFalse(try h.view(NSButton.self, title: "向左旋转").isEnabled)
        h.prepares[0].1(.failure(failure()))
        XCTAssertTrue(try h.view(NSButton.self, title: "向左旋转").isEnabled)
        h.rotate(); XCTAssertEqual(h.prepares.count, 2)
    }

    func testFailedCommitRetryUsesIdenticalSnapshotAndConvertedBytesWithoutPreparingOrDecodingAgain() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        h.rotate(); let snapshot = h.snapshot(); h.prepare(snapshot); h.prepare(snapshot)
        try await eventually { h.saves.count == 1 }
        h.rotate(); XCTAssertEqual(h.saves.count, 1)
        XCTAssertFalse(h.probe.usedMainThread)
        h.saves[0].2(.failure(failure()))
        XCTAssertEqual(h.controller.currentRecord, h.original)
        XCTAssertTrue(h.status.contains("磁盘暂时不可写")); XCTAssertEqual(h.dismissals, 0)
        XCTAssertTrue(try h.view(NSButton.self, title: "重试保存旋转").isEnabled)
        h.rotate()
        XCTAssertEqual(h.saves.count, 2); XCTAssertEqual(h.prepares.count, 1); XCTAssertEqual(h.probe.records.count, 1)
        XCTAssertEqual(h.saves[0].0, snapshot); XCTAssertEqual(h.saves[1].0, snapshot)
        XCTAssertEqual(h.saves[0].1, h.saves[1].1)
        h.saves[1].2(.failure(SyncError.accountChanged))
        XCTAssertTrue(h.status.contains("重新打开")); XCTAssertEqual(h.prepares.count, 1)
    }

    func testClosedAndReopenedPreviewRejectsLatePrepareReply() throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        h.rotate(); let old = h.prepares[0].1
        h.controller.dismiss(); h.controller.present(relativeTo: nil); h.rotate()
        old(.success(h.snapshot()))
        XCTAssertEqual(h.prepares.count, 2); XCTAssertTrue(h.saves.isEmpty); XCTAssertTrue(h.probe.records.isEmpty)
        XCTAssertEqual(h.presentations, 2)
    }

    func testHiddenPreviewCancelsBackgroundConversionBeforeSubmission() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        let gate = DispatchSemaphore(value: 0), probe = RotationConversionProbe()
        h.controller.rotationConverter = { record in
            probe.capture(record); _ = gate.wait(timeout: .now() + 3)
            var result = record; result.text = "late conversion"; return result
        }
        h.rotate(); h.prepare()
        try await eventually { probe.records.count == 1 }
        h.controller.dismiss(); gate.signal()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(h.saves.isEmpty); XCTAssertEqual(h.controller.currentRecord, h.original)
        XCTAssertEqual(h.presentations, 1); XCTAssertEqual(h.dismissals, 1)
    }

    func testParentContextChangeRejectsPendingConversionWithoutWriting() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        let gate = DispatchSemaphore(value: 0), probe = RotationConversionProbe()
        h.controller.rotationConverter = { record in probe.capture(record); _ = gate.wait(timeout: .now() + 3); return record }
        h.rotate(); h.prepare(); try await eventually { probe.records.count == 1 }
        h.validContext = false; gate.signal()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(h.saves.isEmpty); XCTAssertTrue(h.commits.isEmpty)
    }

    func testAlreadySubmittedLateCommitCannotMutateReopenedSession() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        h.rotate(); h.prepare(); try await eventually { h.saves.count == 1 }
        h.controller.dismiss(); h.controller.present(relativeTo: nil); h.rotate()
        h.saves[0].2(.success(.init(id: h.original.id, revision: h.original.revision + 1)))
        XCTAssertEqual(h.controller.currentRecord, h.original); XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.prepares.count, 2); XCTAssertEqual(h.presentations, 2)
    }

    func testSuccessfulConsecutiveRotationsUseLatestRevisionAndExtractionUsesCurrentRecord() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        h.rotate(); h.prepare(); try await eventually { h.saves.count == 1 }
        let first = h.saves[0].1
        h.saves[0].2(.success(.init(id: first.id, revision: 5)))
        XCTAssertEqual(h.controller.currentRecord.revision, 5); XCTAssertEqual(h.controller.currentRecord.parts, first.parts)
        XCTAssertEqual(try h.view(NSTextField.self, label: "图片标题").stringValue, first.title)
        XCTAssertEqual(h.commits[0].0.revision, 4); XCTAssertEqual(h.commits[0].1.revision, 5)
        h.rotate(); XCTAssertEqual(h.prepares[1].0.revision, 5)
        var storeOriginal = h.controller.currentRecord; storeOriginal.ocrText = "App populated OCR in the same commit"
        h.prepare(h.snapshot(storeOriginal)); try await eventually { h.saves.count == 2 }
        XCTAssertEqual(h.saves[1].0.record.revision, 5)
        h.saves[1].2(.success(.init(id: first.id, revision: 6)))
        try await eventually { !h.text.isEmpty }
        h.extract()
        XCTAssertEqual(h.extracted.count, 1); XCTAssertEqual(h.extracted[0].revision, 6)
        XCTAssertEqual(h.extracted[0].parts, h.saves[1].1.parts)
        XCTAssertEqual(h.commits.count, 2)
    }

    func testOldOCRCannotOverwriteRotatedResultOrNewCache() async throws {
        let h = try RotationInteractionHarness(deferredOCR: true); defer { h.close() }
        try await eventually { h.recognizes.count == 1 }
        let old = h.takeOCR(0)
        h.rotate(); h.prepare(); try await eventually { h.saves.count == 1 }
        h.saves[0].2(.success(.init(id: h.original.id, revision: 5)))
        try await eventually { h.recognizes.count == 1 }
        let new = h.takeOCR(0)
        new.1.resume(returning: RotationInteractionHarness.ocr(data: new.0, text: "new coordinates"))
        try await eventually { h.text == "new coordinates" }
        old.1.resume(returning: RotationInteractionHarness.ocr(data: old.0, text: "stale coordinates"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(h.text, "new coordinates"); XCTAssertEqual(h.controller.currentRecord.revision, 5)
        let cached = try await h.cache.result(for: h.controller.currentRecord, imageData: new.0)
        XCTAssertEqual(cached?.text, "new coordinates")
    }

    func testMismatchedPreparationRecordOrRevisionNeverReachesConverter() throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        for mutation in 0..<3 {
            h.rotate(); var invalid = h.original
            if mutation == 0 { invalid.id = UUID() }
            else if mutation == 1 { invalid.revision += 1 }
            else { invalid.parts = [] }
            h.prepare(h.snapshot(invalid))
            XCTAssertTrue(h.status.contains("重新打开"))
        }
        XCTAssertTrue(h.saves.isEmpty); XCTAssertTrue(h.probe.records.isEmpty)
    }

    func testConversionFailureKeepsImageAndDoesNotClearExistingOCRCache() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        try await eventually { !h.text.isEmpty }
        let expectedText = h.text
        h.controller.rotationConverter = { _ in throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "不支持的图片格式"]) }
        h.rotate(); h.prepare(); try await eventually { h.status.contains("不支持的图片格式") }
        XCTAssertTrue(h.saves.isEmpty); XCTAssertEqual(h.text, expectedText); XCTAssertEqual(h.controller.currentRecord, h.original)
        let cached = try await h.cache.result(for: h.original, imageData: try XCTUnwrap(OCRDerivedCache.imageData(in: h.original)))
        XCTAssertNotNil(cached)
    }

    func testInvalidCommitReferenceKeepsPreparedRetryAndOriginalVersion() async throws {
        let h = try RotationInteractionHarness(); defer { h.close() }
        h.rotate(); h.prepare(); try await eventually { h.saves.count == 1 }
        h.saves[0].2(.success(.init(id: h.original.id, revision: h.original.revision)))
        XCTAssertEqual(h.controller.currentRecord, h.original); XCTAssertTrue(h.commits.isEmpty)
        XCTAssertTrue(h.status.contains("保存回执不匹配"))
        h.rotate(); XCTAssertEqual(h.saves.count, 2); XCTAssertEqual(h.prepares.count, 1)
        XCTAssertEqual(h.saves[0].0, h.saves[1].0)
    }
}
