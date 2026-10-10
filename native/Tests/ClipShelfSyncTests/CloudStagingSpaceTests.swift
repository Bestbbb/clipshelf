import CloudKit
import Darwin
import Foundation
import XCTest
import ClipShelfCore
@testable import ClipShelf

private final class CloudStagingCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func set(_ value: Int64) { lock.lock(); defer { lock.unlock() }; bytes = value }
    func read(_ url: URL) -> StorageVolumeCapacity {
        lock.lock(); defer { lock.unlock() }
        let temporary = url.pathComponents.contains("temporary-volume")
        return .init(volumeID: temporary ? "temporary" : "library", availableBytes: temporary ? bytes : 1_000_000_000)
    }
}

private final class CloudStreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failAt: Int?
    let cancel: Bool
    init(failAt: Int? = nil, cancel: Bool = false) { self.failAt = failAt; self.cancel = cancel }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func write(_ output: FileHandle, _ data: Data) throws {
        lock.lock(); count += 1; let call = count; lock.unlock()
        if call == failAt { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        try output.write(contentsOf: data)
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

final class CloudStagingSpaceTests: XCTestCase {
    private var root: URL!
    private var capacity: CloudStagingCapacity!
    private var temporary: URL { root.appendingPathComponent("temporary-volume") }
    private var scope: CloudOwnedBlobScope {
        .init(containerIdentifier: "iCloud.test.clipshelf", namespace: "test", zoneID: .init(zoneName: "test", ownerName: CKCurrentUserDefaultName), shared: false)
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("clipshelf-cloud-space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        capacity = CloudStagingCapacity()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func coordinator(_ bytes: Int64) throws -> StorageSpaceCoordinator {
        let capacity = capacity!; capacity.set(bytes)
        return try StorageSpaceCoordinator(directory: root.appendingPathComponent("budget"), capacityProvider: { capacity.read($0) })
    }
    private func descriptor(_ data: Data) -> SyncOwnedFileDescriptor {
        .init(digest: CloudSyncService.digest(data), byteCount: data.count, filename: "fixture.bin")
    }
    /// Synthetic provider-owned bytes represent CKAsset input; SDK allocation is outside our budget.
    private func providerRecord(_ data: Data) throws -> CKRecord {
        let file = root.appendingPathComponent("provider-" + UUID().uuidString)
        try data.write(to: file)
        let record = CKRecord(recordType: CloudOwnedBlobCodec.recordType, recordID: CloudOwnedBlobCodec.recordID(digest: CloudSyncService.digest(data), scope: scope))
        record["sha256"] = CloudSyncService.digest(data) as NSString
        record["byteCount"] = data.count as NSNumber; record["chunkCount"] = 1 as NSNumber
        record["formatVersion"] = 1 as NSNumber; record["container"] = scope.containerIdentifier as NSString
        record["namespace"] = scope.namespace as NSString; record["scopeKind"] = scope.kind as NSString
        record["zoneName"] = scope.zoneID.zoneName as NSString; record["chunk0"] = CKAsset(fileURL: file)
        return record
    }

    func testJSONBatchUsesAggregateActualTemporaryVolumeAndCleansOnFailure() throws {
        let budget = try coordinator(100)
        let staging = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary)
        _ = try staging.write(Data(repeating: 1, count: 60), name: "first.json")
        XCTAssertThrowsError(try staging.write(Data(repeating: 2, count: 41), name: "second.json")) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 101, availableBytes: 100))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
        let retry = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary)
        let file = try retry.write(Data(repeating: 3, count: 100), name: "retry.json")
        XCTAssertEqual(try Data(contentsOf: file).count, 100)
    }

    func testPublicationChecksIdentityAfterActualAvailableSpaceFalls() throws {
        let budget = try coordinator(60), capacity = capacity!
        let staging = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary, writer: { output, data in
            try output.write(contentsOf: data)
            capacity.set(0)
        })
        let file = try staging.write(Data(repeating: 3, count: 60), name: "written.json")
        XCTAssertEqual(try Data(contentsOf: file).count, 60)
    }

    func testDefaultTemporaryRootAcceptsSystemCapacityAndProtectedJSONWrite() throws {
        let staging = try CloudAssetStaging()
        let file = try staging.write(Data("{}".utf8), name: "fixture.json")
        XCTAssertFalse(file.path.hasPrefix("/var/"))
        XCTAssertFalse(file.path.hasPrefix("/tmp/"))
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
    }

    func testEncodeReservesTheWholeStreamBeforeAnEmptyChunkIsCreated() throws {
        let data = Data(repeating: 1, count: 1_024 * 1_024 + 3), budget = try coordinator(Int64(1_024 * 1_024 + 2))
        let source = root.appendingPathComponent("source"); try data.write(to: source)
        let writer = CloudStreamWriter()
        let staging = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary, writer: { try writer.write($0, $1) })
        XCTAssertThrowsError(try CloudOwnedBlobCodec.encode(file: source, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope, staging: staging)) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: Int64(data.count), availableBytes: Int64(data.count - 1)))
        }
        XCTAssertEqual(writer.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
    }

    func testOriginalAndChunksRemainBudgetedAcrossAwaitUntilBothLifetimesEnd() async throws {
        let data = Data(repeating: 2, count: 60), budget = try coordinator(120)
        var original: SyncOwnedFileStaging? = try SyncOwnedFileStaging.create(data: data, descriptor: descriptor(data),
            spaceCoordinator: budget, temporaryDirectory: temporary)
        var chunks: CloudAssetStaging? = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary)
        let originalURL = try XCTUnwrap(original).fileURL, chunksDirectory = try XCTUnwrap(chunks).directory
        _ = try CloudOwnedBlobCodec.encode(file: originalURL, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope, staging: XCTUnwrap(chunks))
        await Task.yield() // The upload would be suspended in CloudKit while both owners stay live.
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunksDirectory.path))
        XCTAssertThrowsError(try budget.reserve([.init(destination: temporary, bytes: 1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 121, availableBytes: 120))
        }
        chunks = nil; original = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunksDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        let next = try budget.reserve([.init(destination: temporary, bytes: 120)]); try next.release()
    }

    func testDownloadAssemblyAndCopiedPayloadBothCountAndRetryAfterLowCapacity() throws {
        let data = Data(repeating: 3, count: 60), record = try providerRecord(data), budget = try coordinator(59)
        let denied = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary)
        XCTAssertThrowsError(try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope, staging: denied)) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 60, availableBytes: 59))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: denied.directory.path))
        capacity.set(120)
        var assembly: CloudAssetStaging? = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary)
        let file = try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope, staging: XCTUnwrap(assembly))
        var copy: SyncOwnedFileStaging? = try SyncOwnedFileStaging.copy(from: file, descriptor: descriptor(data),
            spaceCoordinator: budget, temporaryDirectory: temporary)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copy).fileURL), data)
        XCTAssertThrowsError(try budget.reserve([.init(destination: temporary, bytes: 1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 121, availableBytes: 120))
        }
        assembly = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copy).fileURL), data)
        copy = nil
        let next = try budget.reserve([.init(destination: temporary, bytes: 120)]); try next.release()
    }

    func testMidstreamENOSPCCleansAssemblyImmediatelyAndASecondDownloadSucceeds() throws {
        let data = Data(repeating: 4, count: 2 * 1_024 * 1_024 + 3), record = try providerRecord(data)
        let budget = try coordinator(Int64(data.count)), writer = CloudStreamWriter(failAt: 2)
        let failed = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary, writer: { try writer.write($0, $1) })
        XCTAssertThrowsError(try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope, staging: failed)) {
            XCTAssertEqual($0 as? StorageWriteFailure, .diskFull)
        }
        XCTAssertEqual(writer.calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.directory.path))
        let retry = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary)
        let file = try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope, staging: retry)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testActualCancellationDuringUploadStreamRemovesChunksAndReleasesTheClaim() async throws {
        let data = Data(repeating: 5, count: 1_024 * 1_024 + 3), source = root.appendingPathComponent("source")
        try data.write(to: source)
        let budget = try coordinator(Int64(data.count)), writer = CloudStreamWriter(cancel: true)
        let staging = try CloudAssetStaging(spaceCoordinator: budget, temporaryDirectory: temporary, writer: { try writer.write($0, $1) })
        let scope = self.scope, digest = CloudSyncService.digest(data), count = data.count
        let task = Task.detached {
            _ = try CloudOwnedBlobCodec.encode(file: source, digest: digest, byteCount: count, scope: scope, staging: staging)
        }
        do { try await task.value; XCTFail("Cancelled chunks must never be returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(writer.calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
        let next = try budget.reserve([.init(destination: temporary, bytes: Int64(data.count))]); try next.release()
    }
}
