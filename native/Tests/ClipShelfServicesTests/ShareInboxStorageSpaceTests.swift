@testable import ClipShelfCore
import Darwin
import Foundation
import XCTest
@testable import ShareInboxShared

final class ShareInboxStorageSpaceTests: XCTestCase {
    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64
        init(_ bytes: Int64 = 1_000_000_000) { self.bytes = bytes }
        func set(_ value: Int64) { lock.lock(); bytes = value; lock.unlock() }
        func read(_ destination: URL) -> StorageVolumeCapacity {
            lock.lock(); defer { lock.unlock() }
            return StorageVolumeCapacity(volumeID: "synthetic-app-group", availableBytes: bytes)
        }
    }

    private final class WriteFault: @unchecked Sendable {
        enum Mode { case none, everyWrite, manifest }
        private let lock = NSLock()
        private var mode: Mode = .none
        func set(_ mode: Mode) { lock.lock(); self.mode = mode; lock.unlock() }
        func write(_ handle: FileHandle, data: Data) throws {
            lock.lock(); let current = mode; lock.unlock()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let shouldFail: Bool
            switch current {
            case .none: shouldFail = false
            case .everyWrite: shouldFail = true
            case .manifest: shouldFail = object?["items"] != nil
            }
            if shouldFail {
                try handle.write(contentsOf: data.prefix(4))
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
            try handle.write(contentsOf: data)
        }
        var writer: ShareInboxFileWriter { ShareInboxFileWriter { [self] in try write($0, data: $1) } }
    }

    private final class RegistryMoveFault: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true
        private var moved = false
        let registry: URL
        let displaced: URL
        init(registry: URL, displaced: URL) { self.registry = registry; self.displaced = displaced }
        func checkpoint(_ stage: StorageSpaceCheckpoint) {
            lock.lock(); defer { lock.unlock() }
            guard stage == .replacementPublished, armed else { return }
            armed = false
            moved = Darwin.rename(registry.path, displaced.path) == 0
        }
        var didMove: Bool { lock.lock(); defer { lock.unlock() }; return moved }
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-share-space-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func directory(capacity: Capacity, writer: ShareInboxFileWriter = .live) throws -> ShareInboxDirectory {
        let group = root.appendingPathComponent("group", isDirectory: true)
        let coordinator = try StorageSpaceCoordinator(directory: group.appendingPathComponent(".storage-reservations"),
            capacityProvider: { capacity.read($0) })
        return try ShareInboxDirectory(root: group, spaceCoordinator: coordinator, fileWriter: writer)
    }
    private func catalog(_ name: String = "History") -> ShareInboxCatalog {
        ShareInboxCatalog(contextBinding: "synthetic-context", destinations: [.init(boardID: nil, name: name)])
    }
    private func assertInsufficient(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case .insufficientSpace = StorageWriteFailure.classify(error) else {
            return XCTFail("Expected storage admission failure, got \(error)", file: file, line: line)
        }
    }
    private func stagedFiles(_ directory: ShareInboxDirectory, draft: ShareInboxDraft) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.staging.appendingPathComponent(draft.id.uuidString),
                                                    includingPropertiesForKeys: nil)
    }

    func testLiveDefaultsShareTheAppGroupRegistry() throws {
        let group = root.appendingPathComponent("default-group")
        let host = try ShareInboxDirectory(root: group)
        let extensionCopy = try ShareInboxDirectory(root: group)
        XCTAssertEqual(host.spaceCoordinator.directory, group.appendingPathComponent(".storage-reservations", isDirectory: true))
        XCTAssertEqual(extensionCopy.spaceCoordinator.directory, host.spaceCoordinator.directory)
        try host.writeCatalog(catalog())
        XCTAssertEqual(try extensionCopy.readCatalog().destinations, catalog().destinations)
    }

    func testCatalogLowCapacityPreservesPreviousBytesThenRetries() throws {
        let capacity = Capacity(), inbox = try directory(capacity: capacity)
        try inbox.writeCatalog(catalog())
        let url = inbox.root.appendingPathComponent("destinations.json")
        let previous = try Data(contentsOf: url)
        capacity.set(0)
        XCTAssertThrowsError(try inbox.writeCatalog(catalog("New board"))) { self.assertInsufficient($0) }
        XCTAssertEqual(try Data(contentsOf: url), previous)
        capacity.set(1_000_000)
        try inbox.writeCatalog(catalog("New board"))
        XCTAssertEqual(try inbox.readCatalog().destinations[0].name, "New board")
    }

    func testCatalogPartialENOSPCNeverReplacesPreviousCatalog() throws {
        let capacity = Capacity(), fault = WriteFault()
        let inbox = try directory(capacity: capacity, writer: fault.writer)
        try inbox.writeCatalog(catalog())
        let url = inbox.root.appendingPathComponent("destinations.json")
        let previous = try Data(contentsOf: url)
        fault.set(.everyWrite)
        XCTAssertThrowsError(try inbox.writeCatalog(catalog("Updated"))) {
            XCTAssertEqual(StorageWriteFailure.classify($0), .diskFull)
        }
        XCTAssertEqual(try Data(contentsOf: url), previous)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: inbox.root.path).contains { $0.hasPrefix(".share-write-") })
        fault.set(.none)
        try inbox.writeCatalog(catalog("Updated"))
        XCTAssertEqual(try inbox.readCatalog().destinations[0].name, "Updated")
    }

    func testDraftLowCapacityCanRetryWithoutLosingItsIdentity() throws {
        let capacity = Capacity(), inbox = try directory(capacity: capacity)
        let destination = catalog()
        try inbox.writeCatalog(destination)
        let draft = try inbox.makeDraft(itemCount: 1), bytes = Data("retained share".utf8)
        capacity.set(0)
        XCTAssertThrowsError(try draft.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)) {
            self.assertInsufficient($0)
        }
        XCTAssertTrue(try stagedFiles(inbox, draft: draft).isEmpty)
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        capacity.set(1_000_000)
        try draft.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        let id = try draft.publish(destination: destination.destinations[0], catalog: destination)
        XCTAssertEqual(id, draft.id)
        let representation = try XCTUnwrap(inbox.read(id).0.items.first?.representations.first)
        XCTAssertEqual(try inbox.data(for: representation, operationID: id), bytes)
    }

    func testSeparateInstancesCompeteForOneDraftBudgetUntilCancellation() throws {
        let capacity = Capacity(600)
        let first = try directory(capacity: capacity), second = try directory(capacity: capacity)
        let one = try first.makeDraft(itemCount: 1), two = try second.makeDraft(itemCount: 1)
        let bytes = Data(repeating: 0x41, count: 400)
        try one.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        XCTAssertThrowsError(try two.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)) {
            self.assertInsufficient($0)
        }
        XCTAssertEqual(try stagedFiles(first, draft: one).count, 1)
        XCTAssertTrue(try stagedFiles(second, draft: two).isEmpty)
        one.cancel()
        try two.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        XCTAssertEqual(try stagedFiles(second, draft: two).count, 1)
        two.cancel()
        let released = try first.spaceCoordinator.reserve([.init(destination: first.staging, bytes: 600)])
        try released.release()
    }

    func testPartialPayloadFailureRetainsPriorRepresentationAndRetryHeadroom() throws {
        let capacity = Capacity(), fault = WriteFault()
        let inbox = try directory(capacity: capacity, writer: fault.writer), destination = catalog()
        try inbox.writeCatalog(destination)
        let draft = try inbox.makeDraft(itemCount: 1)
        let plain = Data("original text".utf8), html = Data("<p>original text</p>".utf8)
        try draft.append(data: plain, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        fault.set(.everyWrite)
        XCTAssertThrowsError(try draft.append(data: html, typeIdentifier: "public.html", itemIndex: 0)) {
            XCTAssertEqual(StorageWriteFailure.classify($0), .diskFull)
        }
        let retained = try stagedFiles(inbox, draft: draft)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), plain)
        // Existing reservation covers retry: no second admission of the same failed bytes.
        capacity.set(Int64(plain.count + html.count))
        fault.set(.none)
        try draft.append(data: html, typeIdentifier: "public.html", itemIndex: 0)
        capacity.set(1_000_000)
        let id = try draft.publish(destination: destination.destinations[0], catalog: destination)
        let representations = try inbox.read(id).0.items[0].representations
        XCTAssertEqual(representations.map(\.typeIdentifier), ["public.utf8-plain-text", "public.html"])
        XCTAssertEqual(try representations.map { try inbox.data(for: $0, operationID: id) }, [plain, html])
    }

    func testExpansionPublishedThenRegistryFailureRetriesWithoutDoubleReservation() throws {
        let capacity = Capacity()
        let group = root.appendingPathComponent("group", isDirectory: true)
        let registry = group.appendingPathComponent(".storage-reservations", isDirectory: true)
        let fault = RegistryMoveFault(registry: registry, displaced: group.appendingPathComponent("displaced-reservations"))
        let coordinator = try StorageSpaceCoordinator(directory: registry, capacityProvider: { capacity.read($0) },
                                                       checkpoint: { fault.checkpoint($0) })
        let inbox = try ShareInboxDirectory(root: group, spaceCoordinator: coordinator), destination = catalog()
        try inbox.writeCatalog(destination)
        let draft = try inbox.makeDraft(itemCount: 1)
        let plain = Data(repeating: 0x41, count: 400), html = Data(repeating: 0x42, count: 300)
        try draft.append(data: plain, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        XCTAssertThrowsError(try draft.append(data: html, typeIdentifier: "public.html", itemIndex: 0)) {
            XCTAssertEqual(StorageWriteFailure.classify($0), .coordinationUnavailable)
        }
        XCTAssertTrue(fault.didMove, "Failure must occur after the larger claim became authoritative")
        let retained = try stagedFiles(inbox, draft: draft)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), plain)
        try FileManager.default.moveItem(at: fault.displaced, to: registry)
        // Exactly the two payloads fit. Re-adding the failed 300-byte expansion would not.
        capacity.set(Int64(plain.count + html.count))
        try draft.append(data: html, typeIdentifier: "public.html", itemIndex: 0)
        capacity.set(1_000_000)
        let id = try draft.publish(destination: destination.destinations[0], catalog: destination)
        let representations = try inbox.read(id).0.items[0].representations
        XCTAssertEqual(representations.map(\.typeIdentifier), ["public.utf8-plain-text", "public.html"])
        XCTAssertEqual(try representations.map { try inbox.data(for: $0, operationID: id) }, [plain, html])
    }

    func testManifestRetryReacquiresPreviouslyWrittenPayloadAfterGrowthRejection() throws {
        let capacity = Capacity(), inbox = try directory(capacity: capacity), destination = catalog()
        try inbox.writeCatalog(destination)
        let draft = try inbox.makeDraft(itemCount: 1), bytes = Data(repeating: 0x41, count: 4_000)
        try draft.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        capacity.set(Int64(bytes.count))
        XCTAssertThrowsError(try draft.publish(destination: destination.destinations[0], catalog: destination)) {
            self.assertInsufficient($0)
        }
        // The rejected growth retires its lease. A fresh manifest attempt must still include
        // all 4 KB of staged payload, even though only the manifest would fit this allowance.
        capacity.set(2_000)
        XCTAssertThrowsError(try draft.publish(destination: destination.destinations[0], catalog: destination)) {
            self.assertInsufficient($0)
        }
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        let retained = try stagedFiles(inbox, draft: draft)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), bytes)
        capacity.set(1_000_000)
        let id = try draft.publish(destination: destination.destinations[0], catalog: destination)
        XCTAssertEqual(try inbox.data(for: inbox.read(id).0.items[0].representations[0], operationID: id), bytes)
    }

    func testPartialManifestFailureRetainsPayloadAndCanPublishSameDraft() throws {
        let capacity = Capacity(), fault = WriteFault()
        let inbox = try directory(capacity: capacity, writer: fault.writer), destination = catalog()
        try inbox.writeCatalog(destination)
        let draft = try inbox.makeDraft(itemCount: 1), bytes = Data("manifest retry".utf8)
        try draft.append(data: bytes, typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        fault.set(.manifest)
        XCTAssertThrowsError(try draft.publish(destination: destination.destinations[0], catalog: destination)) {
            XCTAssertTrue(ShareInboxDraft.canRetryPublication(after: $0))
            XCTAssertEqual(StorageWriteFailure.classify($0), .diskFull)
        }
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        let files = try stagedFiles(inbox, draft: draft)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), bytes)
        fault.set(.none)
        let id = try draft.publish(destination: destination.destinations[0], catalog: destination)
        let representation = try inbox.read(id).0.items[0].representations[0]
        XCTAssertEqual(try inbox.data(for: representation, operationID: id), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inbox.staging.path).isEmpty)
        // Publishing also retires the draft claim, although the incoming files remain on disk.
        capacity.set(100)
        let released = try inbox.spaceCoordinator.reserve([.init(destination: inbox.inbox, bytes: 100)])
        try released.release()
    }

    func testRetryEligibilityIsLimitedToRecoverableStorageFailures() {
        XCTAssertTrue(ShareInboxDraft.canRetryPublication(after: StorageWriteFailure.insufficientSpace(requiredBytes: 10, availableBytes: 0)))
        XCTAssertTrue(ShareInboxDraft.canRetryPublication(after: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(ShareInboxDraft.canRetryPublication(after: StorageWriteFailure.capacityUnavailable))
        XCTAssertTrue(ShareInboxDraft.canRetryPublication(after: StorageWriteFailure.coordinationUnavailable))
        XCTAssertFalse(ShareInboxDraft.canRetryPublication(after: StorageWriteFailure.destinationChanged))
        XCTAssertFalse(ShareInboxDraft.canRetryPublication(after: StorageWriteFailure.invalidRequirement))
        XCTAssertFalse(ShareInboxDraft.canRetryPublication(after: ShareInboxError.unavailableDestination))
        XCTAssertFalse(ShareInboxDraft.canRetryPublication(after: ShareInboxError.cancelled))
    }
}
