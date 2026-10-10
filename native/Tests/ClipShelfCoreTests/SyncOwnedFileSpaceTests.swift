import Darwin
import Foundation
import XCTest
@testable import ClipShelfCore

final class SyncOwnedFileSpaceTests: XCTestCase {
    private var root: URL!
    private var temporary: URL { root.appendingPathComponent("temporary-volume") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("clipshelf-sync-space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func descriptor(_ data: Data) -> SyncOwnedFileDescriptor {
        .init(digest: RepresentationStorage.digest(data), byteCount: data.count, filename: "test.bin")
    }
    private func coordinator(_ bytes: Int64) throws -> StorageSpaceCoordinator {
        try StorageSpaceCoordinator(directory: root.appendingPathComponent("budget"), capacityProvider: { url in
            let temporary = url.pathComponents.contains("temporary-volume")
            return .init(volumeID: temporary ? "temporary" : "library", availableBytes: temporary ? bytes : 1_000_000)
        })
    }
    private func payloadDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ClipShelf-sync-") }
    }

    func testFullPayloadUsesItsTemporaryVolumeBeforeWriting() throws {
        let data = Data(repeating: 1, count: 60), budget = try coordinator(59)
        var wrote = false
        XCTAssertThrowsError(try SyncOwnedFileStaging.create(data: data, descriptor: descriptor(data), spaceCoordinator: budget,
            temporaryDirectory: temporary, writer: { _, _ in wrote = true })) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 60, availableBytes: 59))
        }
        XCTAssertFalse(wrote)
        XCTAssertTrue(try payloadDirectories().isEmpty)
    }

    func testPartialWriteENOSPCCleansPayloadAndBudgetThenRetrySucceeds() throws {
        let data = Data(repeating: 2, count: 60), budget = try coordinator(60)
        XCTAssertThrowsError(try SyncOwnedFileStaging.create(data: data, descriptor: descriptor(data), spaceCoordinator: budget,
            temporaryDirectory: temporary, writer: { data, url in
                try data.prefix(3).write(to: url)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            })) { XCTAssertEqual($0 as? StorageWriteFailure, .diskFull) }
        XCTAssertTrue(try payloadDirectories().isEmpty)
        var retry: SyncOwnedFileStaging? = try SyncOwnedFileStaging.create(data: data, descriptor: descriptor(data),
            spaceCoordinator: budget, temporaryDirectory: temporary)
        let path = try XCTUnwrap(retry).fileURL
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertThrowsError(try budget.reserve([.init(destination: temporary, bytes: 1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 61, availableBytes: 60))
        }
        retry = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let next = try budget.reserve([.init(destination: temporary, bytes: 60)]); try next.release()
    }

    func testCopyHoldsBudgetUntilStagingLifetimeEnds() throws {
        let data = Data(repeating: 3, count: 40), input = root.appendingPathComponent("provider-input")
        try data.write(to: input)
        let budget = try coordinator(40)
        var staging: SyncOwnedFileStaging? = try SyncOwnedFileStaging.copy(from: input, descriptor: descriptor(data),
            spaceCoordinator: budget, temporaryDirectory: temporary)
        let copy = try XCTUnwrap(staging).fileURL
        XCTAssertEqual(try Data(contentsOf: copy), data)
        XCTAssertThrowsError(try budget.reserve([.init(destination: temporary, bytes: 1)]))
        staging = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: input), data)
    }

    func testNilCoordinatorStillRegistersARealBudget() throws {
        let data = Data(repeating: 4, count: 60)
        let staging = try SyncOwnedFileStaging.create(data: data, descriptor: descriptor(data), temporaryDirectory: temporary)
        let observer = try StorageSpaceCoordinator(directory: temporary.appendingPathComponent(".clipshelf-storage-reservations"),
            capacityProvider: { url in try StorageSpaceCoordinator.systemCapacity(for: url).withAvailableBytes(60) })
        XCTAssertThrowsError(try observer.reserve([.init(destination: temporary, bytes: 1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 61, availableBytes: 60))
        }
        withExtendedLifetime(staging) {}
    }

    func testDefaultSystemTemporaryRootWorksWithRealCapacityAndNoFollowValidation() throws {
        let resolved = try SyncOwnedFileStaging.resolvedTemporaryDirectory()
        XCTAssertFalse(resolved.path.hasPrefix("/var/"))
        XCTAssertFalse(resolved.path.hasPrefix("/tmp/"))
        let system = try StorageSpaceCoordinator.systemCapacity(for: resolved)
        XCTAssertNotNil(system.availableBytes)
        let data = Data([7]), staging = try SyncOwnedFileStaging.create(data: data, descriptor: descriptor(data))
        XCTAssertEqual(staging.fileURL.deletingLastPathComponent().deletingLastPathComponent(), resolved)
        XCTAssertEqual(try Data(contentsOf: staging.fileURL), data)
    }

    func testCancellationAfterPartialWriteCleansFilesAndReleasesBudget() async throws {
        let data = Data(repeating: 5, count: 60), file = descriptor(data), budget = try coordinator(60), destination = temporary
        let task = Task.detached {
            try SyncOwnedFileStaging.create(data: data, descriptor: file, spaceCoordinator: budget,
                temporaryDirectory: destination, writer: { data, url in
                    try data.prefix(1).write(to: url)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; XCTFail("Cancelled staging must not be published") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try payloadDirectories().isEmpty)
        let next = try budget.reserve([.init(destination: temporary, bytes: 60)]); try next.release()
    }
}

private extension StorageVolumeCapacity {
    func withAvailableBytes(_ bytes: Int64) -> StorageVolumeCapacity { .init(volumeID: volumeID, availableBytes: bytes) }
}
