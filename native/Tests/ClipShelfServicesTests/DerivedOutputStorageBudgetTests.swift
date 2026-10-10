import AppKit
import ClipShelfCore
import Darwin
import XCTest
@testable import ClipShelf

private final class DerivedOutputCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int64 = 1_000_000_000
    private var paths: [URL] = []
    func set(_ value: Int64) { lock.lock(); available = value; lock.unlock() }
    func read(_ directory: URL) -> StorageVolumeCapacity {
        lock.lock(); defer { lock.unlock() }
        paths.append(directory)
        // Distinct synthetic volumes prove the writer asks about its receiver/cache,
        // not the registry or HistoryStore database location.
        return .init(volumeID: directory.path.contains("receiver-volume") ? "receiver" : "local", availableBytes: available)
    }
    func measuredPaths() -> [URL] { lock.lock(); defer { lock.unlock() }; return paths }
}

private final class DerivedOutputCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var sawActualBytes = false
    private var largestWrite = 0
    private var failureOnCall: Int?
    init(failureOnCall: Int? = nil) { self.failureOnCall = failureOnCall }
    func visit(_ url: URL, _ bytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        count += 1
        largestWrite = max(largestWrite, bytes)
        var info = stat()
        sawActualBytes = sawActualBytes || (lstat(url.path, &info) == 0 && info.st_size >= bytes && bytes > 0)
        if count == failureOnCall { throw POSIXError(.ENOSPC) }
    }
    func reset(failureOnCall: Int? = nil) {
        lock.lock(); count = 0; sawActualBytes = false; largestWrite = 0; self.failureOnCall = failureOnCall; lock.unlock()
    }
    func snapshot() -> (calls: Int, wroteBytes: Bool, largestWrite: Int) {
        lock.lock(); defer { lock.unlock() }; return (count, sawActualBytes, largestWrite)
    }
}

final class DerivedOutputStorageBudgetTests: XCTestCase {
    private var root: URL!
    private var capacity: DerivedOutputCapacity!
    private var coordinator: StorageSpaceCoordinator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("derived-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        capacity = DerivedOutputCapacity()
        let capacity = capacity!
        coordinator = try StorageSpaceCoordinator(directory: root.appendingPathComponent("reservations"),
                                                  capacityProvider: { capacity.read($0) })
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func assertInsufficient(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? StorageWriteFailure, case .insufficientSpace = failure else {
            return XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
    private func assertBudgetReleased(at directory: URL) throws {
        capacity.set(1_000_000_000)
        let lease = try coordinator.reserve([.init(destination: directory, bytes: 1_000_000_000)])
        try lease.release()
    }
    private func ocrRecord(_ data: Data) -> ClipboardRecord {
        .init(text: "image", parts: [.init(representations: [.init(typeIdentifier: "public.png", data: data)])], revision: 3)
    }
    private func ocrResult(_ data: Data, text: String = "before") -> LocalIntelligenceService.OCRResult {
        .init(text: text, regions: [.init(text: text, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2), confidence: 0.9)],
              recognitionLanguages: LocalIntelligenceService.defaultRecognitionLanguages,
              sourceImageDigest: LocalIntelligenceService.imageDigest(data),
              engineIdentifier: LocalIntelligenceService.ocrEngineIdentifier,
              engineRevision: LocalIntelligenceService.ocrEngineRevision,
              engineVersion: LocalIntelligenceService.ocrEngineVersion, orientedPixelSize: CGSize(width: 10, height: 10))
    }
    @MainActor private func image(_ width: Int, height: Int = 3, noise: Bool = false) throws -> ClipboardPart {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        if noise {
            var seed: UInt32 = 17
            for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bitmap.bitmapData![offset] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        return .init(representations: [.init(typeIdentifier: "public.png",
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))])
    }

    func testOCRLowCapacityPreservesPreviousJSONAndCanRetryOnCacheVolume() async throws {
        let cacheRoot = try folder("receiver-volume"), data = Data([1, 2, 3]), record = ocrRecord(data)
        let checkpoint = DerivedOutputCheckpoint()
        let cache = OCRDerivedCache(directory: cacheRoot, spaceCoordinator: coordinator,
                                    writeCheckpoint: { try checkpoint.visit($0, $1) })
        try await cache.store(ocrResult(data), for: record, imageData: data)
        let file = cacheRoot.appendingPathComponent(record.id.uuidString + ".json")
        let original = try Data(contentsOf: file)
        checkpoint.reset(); capacity.set(0)
        do {
            try await cache.store(ocrResult(data, text: "after"), for: record, imageData: data)
            XCTFail("Expected budget refusal")
        } catch { assertInsufficient(error) }
        XCTAssertEqual(checkpoint.snapshot().calls, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(capacity.measuredPaths().allSatisfy { $0.lastPathComponent == "receiver-volume" })
        capacity.set(1_000_000_000)
        try await cache.store(ocrResult(data, text: "after"), for: record, imageData: data)
        let result = try await cache.result(for: record, imageData: data)
        XCTAssertEqual(result?.text, "after")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [file.lastPathComponent])
        try assertBudgetReleased(at: cacheRoot)
    }

    func testOCRSourceStoreCoordinatorTakesPriorityOverInjectedFallback() async throws {
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"), spaceCoordinator: coordinator)
        let data = Data([1, 2, 3]), record = try store.create(ocrRecord(data))
        let cacheRoot = try folder("cache")
        let generous = try StorageSpaceCoordinator(directory: root.appendingPathComponent("other-reservations"),
            capacityProvider: { _ in .init(volumeID: "other", availableBytes: 1_000_000_000) })
        let cache = OCRDerivedCache(directory: cacheRoot, spaceCoordinator: generous)
        capacity.set(0)
        do {
            try await cache.store(ocrResult(data), for: record, imageData: data, sourceStore: store)
            XCTFail("Live sourceStore must control reservation")
        } catch { assertInsufficient(error) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).isEmpty)
        XCTAssertNotNil(try store.itemMetadata(id: record.id))
    }

    func testOCRRealStagedBytesAreRemovedOnENOSPCWithoutReplacingPreviousJSON() async throws {
        let cacheRoot = try folder("cache"), data = Data([1, 2, 3]), record = ocrRecord(data)
        let checkpoint = DerivedOutputCheckpoint()
        let cache = OCRDerivedCache(directory: cacheRoot, spaceCoordinator: coordinator,
                                    writeCheckpoint: { try checkpoint.visit($0, $1) })
        try await cache.store(ocrResult(data), for: record, imageData: data)
        let file = cacheRoot.appendingPathComponent(record.id.uuidString + ".json"), original = try Data(contentsOf: file)
        checkpoint.reset(failureOnCall: 1)
        do {
            try await cache.store(ocrResult(data, text: String(repeating: "new", count: 30_000)), for: record, imageData: data)
            XCTFail("Expected midstream disk-full error")
        } catch { XCTAssertEqual(error as? StorageWriteFailure, .diskFull) }
        XCTAssertTrue(checkpoint.snapshot().wroteBytes)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [file.lastPathComponent])
        try assertBudgetReleased(at: cacheRoot)
        checkpoint.reset()
        try await cache.store(ocrResult(data, text: "retry"), for: record, imageData: data)
    }

    func testOCRTaskCancellationAfterWritingKeepsOldJSONAndReleasesLease() async throws {
        let cacheRoot = try folder("cache"), data = Data([1, 2, 3]), record = ocrRecord(data)
        let first = OCRDerivedCache(directory: cacheRoot, spaceCoordinator: coordinator)
        try await first.store(ocrResult(data), for: record, imageData: data)
        let file = cacheRoot.appendingPathComponent(record.id.uuidString + ".json"), original = try Data(contentsOf: file)
        let cache = OCRDerivedCache(directory: cacheRoot, spaceCoordinator: coordinator, writeCheckpoint: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let next = ocrResult(data, text: "cancelled replacement")
        let task = Task { try await cache.store(next, for: record, imageData: data) }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [file.lastPathComponent])
        try assertBudgetReleased(at: cacheRoot)
    }

    func testOCRPublicationValidatesIdentityWithoutDemandingConsumedBudgetAgain() async throws {
        let cacheRoot = try folder("cache"), data = Data([1, 2, 3]), record = ocrRecord(data), capacity = capacity!
        let cache = OCRDerivedCache(directory: cacheRoot, spaceCoordinator: coordinator,
                                    writeCheckpoint: { _, _ in capacity.set(0) })
        try await cache.store(ocrResult(data), for: record, imageData: data)
        let result = try await cache.result(for: record, imageData: data)
        XCTAssertEqual(result?.text, "before")
        try assertBudgetReleased(at: cacheRoot)
    }

    @MainActor func testImageBatchIsFullyPrepaidBeforeFirstOutputAndRetrySucceeds() throws {
        let output = try folder("exports"), checkpoint = DerivedOutputCheckpoint()
        let prepared = try ImageFileOutput.prepare([.init(text: "two", parts: [try image(4), try image(5)])],
            spaceCoordinator: coordinator, writeCheckpoint: { try checkpoint.visit($0, $1) })
        let probe = try prepared.exportReceipt(directory: output)
        let sizes = try probe.fileURLs.map { Int64(try Data(contentsOf: $0).count) }
        probe.discardUnpublished(); checkpoint.reset(); capacity.set(try XCTUnwrap(sizes.first))
        XCTAssertThrowsError(try prepared.exportReceipt(directory: output)) { error in
            self.assertInsufficient(error)
            guard let failure = error as? StorageWriteFailure, case .insufficientSpace(let required, _) = failure else { return }
            XCTAssertEqual(required, sizes.reduce(0, +))
        }
        XCTAssertEqual(checkpoint.snapshot().calls, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        capacity.set(sizes.reduce(0, +))
        let receipt = try prepared.exportReceipt(directory: output)
        XCTAssertEqual(receipt.fileURLs.count, 2)
        receipt.discardUnpublished()
        try assertBudgetReleased(at: output)
    }

    @MainActor func testImageENOSPCOnLaterFileRollsBackWholeBatchAndReleasesLease() throws {
        let output = try folder("exports"), checkpoint = DerivedOutputCheckpoint(failureOnCall: 2)
        let largeImage = try image(256, height: 256, noise: true)
        XCTAssertGreaterThan(largeImage.representations[0].data.count, 65_536)
        let prepared = try ImageFileOutput.prepare([.init(text: "two", parts: [try image(4), largeImage])],
            spaceCoordinator: coordinator, writeCheckpoint: { try checkpoint.visit($0, $1) })
        XCTAssertThrowsError(try prepared.exportReceipt(directory: output)) { error in
            XCTAssertEqual(error as? StorageWriteFailure, .diskFull)
        }
        XCTAssertEqual(checkpoint.snapshot().calls, 2)
        XCTAssertTrue(checkpoint.snapshot().wroteBytes)
        XCTAssertEqual(checkpoint.snapshot().largestWrite, 65_536)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        try assertBudgetReleased(at: output)
        checkpoint.reset()
        let receipt = try prepared.exportReceipt(directory: output)
        XCTAssertEqual(receipt.fileURLs.count, 2)
        receipt.discardUnpublished()
    }

    @MainActor func testImageTaskCancellationAfterActualWriteRollsBackBatch() async throws {
        let output = try folder("exports")
        let prepared = try ImageFileOutput.prepare([.init(text: "two", parts: [try image(4), try image(5)])],
            spaceCoordinator: coordinator, writeCheckpoint: { _, _ in withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task.detached { try prepared.exportReceipt(directory: output) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        try assertBudgetReleased(at: output)
    }

    @MainActor func testImageBatchChecksDestinationsWithoutRechargingAlreadyWrittenBytes() throws {
        let output = try folder("exports"), capacity = capacity!
        let prepared = try ImageFileOutput.prepare([.init(text: "two", parts: [try image(4), try image(5)])],
            spaceCoordinator: coordinator, writeCheckpoint: { _, _ in capacity.set(0) })
        let receipt = try prepared.exportReceipt(directory: output)
        XCTAssertEqual(receipt.fileURLs.count, 2)
        receipt.discardUnpublished()
        try assertBudgetReleased(at: output)
    }

    private final class PromiseRequest: @unchecked Sendable {
        let provider: NSFilePromiseProvider
        let delegate: NSFilePromiseProviderDelegate
        @MainActor init(_ provider: NSFilePromiseProvider) { self.provider = provider; delegate = provider.delegate! }
        func write(to url: URL, completion: @escaping (Error?) -> Void) {
            delegate.filePromiseProvider(provider, writePromiseTo: url, completionHandler: completion)
        }
    }

    @MainActor func testFilePromiseBudgetsActualReceiverAndRetainsCoordinatorForRetry() async throws {
        let receiver = try folder("receiver-volume"), destination = receiver.appendingPathComponent("chosen.png")
        var prepared: PreparedImageFileOutput? = try ImageFileOutput.prepare([.init(text: "one", parts: [try image(4)])],
                                                                           spaceCoordinator: coordinator)
        let provider = try XCTUnwrap(prepared?.draggingWriters().first as? NSFilePromiseProvider)
        prepared = nil
        let request = PromiseRequest(provider), queue = try XCTUnwrap(provider.delegate?.operationQueue?(for: provider))
        capacity.set(0)
        let rejected = expectation(description: "one low-space callback"); rejected.assertForOverFulfill = true
        queue.addOperation {
            request.write(to: destination) { error in
                guard let failure = error as? StorageWriteFailure, case .insufficientSpace = failure else {
                    XCTFail("Expected receiver volume refusal, got \(String(describing: error))"); rejected.fulfill(); return
                }
                rejected.fulfill()
            }
        }
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(capacity.measuredPaths().allSatisfy { $0.lastPathComponent == "receiver-volume" })
        capacity.set(1_000_000_000)
        let completed = expectation(description: "retry callback"); completed.assertForOverFulfill = true
        queue.addOperation { request.write(to: destination) { error in XCTAssertNil(error); completed.fulfill() } }
        await fulfillment(of: [completed], timeout: 5)
        await queueFinished(queue)
        XCTAssertEqual(NSImage(contentsOf: destination)?.size.width, 4)
        try assertBudgetReleased(at: receiver)
    }

    @MainActor func testFilePromiseENOSPCCleansRealPartialFileAndReportsOnce() async throws {
        let receiver = try folder("receiver-volume"), destination = receiver.appendingPathComponent("chosen.png")
        let checkpoint = DerivedOutputCheckpoint(failureOnCall: 1)
        let largeImage = try image(256, height: 256, noise: true)
        XCTAssertGreaterThan(largeImage.representations[0].data.count, 65_536)
        let prepared = try ImageFileOutput.prepare([.init(text: "one", parts: [largeImage])], spaceCoordinator: coordinator,
                                                   writeCheckpoint: { try checkpoint.visit($0, $1) })
        let provider = try XCTUnwrap(prepared.draggingWriters().first as? NSFilePromiseProvider)
        let request = PromiseRequest(provider), queue = try XCTUnwrap(provider.delegate?.operationQueue?(for: provider))
        let completed = expectation(description: "disk full callback"); completed.assertForOverFulfill = true
        queue.addOperation {
            request.write(to: destination) { error in
                XCTAssertEqual(error as? StorageWriteFailure, .diskFull); completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        await queueFinished(queue)
        XCTAssertTrue(checkpoint.snapshot().wroteBytes)
        XCTAssertEqual(checkpoint.snapshot().largestWrite, 65_536)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertBudgetReleased(at: receiver)
    }

    private func queueFinished(_ queue: OperationQueue) async {
        await withCheckedContinuation { continuation in queue.addOperation { continuation.resume() } }
    }
}
