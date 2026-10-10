import ClipShelfCore
import Darwin
import Foundation
import XCTest
@testable import ClipShelf
@testable import ShareInboxShared

private final class ReceiptCapacityFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var receiptBytes: Int64 = 16 * 1_024 * 1_024
    private var allFull = false
    private var receiptQueries = 0
    var queries: Int { lock.lock(); defer { lock.unlock() }; return receiptQueries }
    func set(receiptBytes: Int64, allFull: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.receiptBytes = receiptBytes; self.allFull = allFull
    }
    func read(_ url: URL) -> StorageVolumeCapacity {
        lock.lock(); defer { lock.unlock() }
        let receipt = url.pathComponents.contains("ShareImports")
        if receipt { receiptQueries += 1 }
        return .init(volumeID: receipt ? "receipt-volume" : "database-volume",
                     availableBytes: allFull ? 0 : (receipt ? receiptBytes : 256 * 1_024 * 1_024))
    }
}

private final class ReceiptWriteFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var failCompletion = false
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func failCompletedWrites(_ enabled: Bool) { lock.lock(); defer { lock.unlock() }; failCompletion = enabled }
    func write(_ handle: FileHandle, _ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let completed = object?["completed"] as? [Int] ?? []
        lock.lock(); count += 1; let fail = failCompletion && !completed.isEmpty; lock.unlock()
        if fail {
            try handle.write(contentsOf: data.prefix(4))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        try handle.write(contentsOf: data)
    }
}

final class ShareInboxReceiptSpaceTests: XCTestCase {
    private struct ReceiptSnapshot: Decodable {
        let digest: String
        let recordIDs: [UUID]
        let attempted: Set<Int>
        let completed: Set<Int>
    }
    private var root: URL!
    private var capacity: ReceiptCapacityFixture!
    private var io: ReceiptWriteFixture!
    private var inbox: ShareInboxDirectory!
    private var store: HistoryStore!
    private var service: ShareInboxService!
    private var privateDirectory: URL { root.appendingPathComponent("private") }
    private var receipts: URL { privateDirectory.appendingPathComponent("ShareImports") }

    override func setUpWithError() throws {
        root = try SyncOwnedFileStaging.resolvedTemporaryDirectory().appendingPathComponent("clipshelf-receipt-space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        capacity = ReceiptCapacityFixture(); io = ReceiptWriteFixture()
        let capacity = capacity!
        let budget = try StorageSpaceCoordinator(directory: root.appendingPathComponent("budget"), capacityProvider: { capacity.read($0) })
        inbox = try ShareInboxDirectory(root: root.appendingPathComponent("group"), spaceCoordinator: budget)
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite3"), spaceCoordinator: budget)
        service = try makeService()
    }
    override func tearDownWithError() throws {
        service = nil; store = nil; inbox = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func makeService() throws -> ShareInboxService {
        let io = io!
        return try ShareInboxService(store: store, privateDirectory: privateDirectory, inbox: inbox,
                                     receiptWriter: ShareInboxFileWriter(write: { try io.write($0, $1) }))
    }
    private func enqueue(_ text: String) throws -> UUID {
        let catalog = try inbox.readCatalog(), draft = try inbox.makeDraft(itemCount: 1)
        try draft.append(data: Data(text.utf8), typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        return try draft.publish(destination: XCTUnwrap(catalog.destinations.first), catalog: catalog)
    }
    private func receiptURL(_ id: UUID) -> URL { receipts.appendingPathComponent(id.uuidString + ".json") }
    private func receipt(_ id: UUID) throws -> ReceiptSnapshot {
        try JSONDecoder().decode(ReceiptSnapshot.self, from: Data(contentsOf: receiptURL(id)))
    }
    private func payload(_ id: UUID) throws -> Data {
        let envelope = try inbox.read(id).0
        return try inbox.data(for: XCTUnwrap(envelope.items.first?.representations.first), operationID: id)
    }
    private func assertNoPartialReceiptFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: receipts.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".share-write-") }, file: file, line: line)
    }

    func testReceiptBudgetFailurePrecedesAnyAttemptOrCoreCreateAndCanRetry() async throws {
        try await service.publishDestinations()
        let text = "receipt capacity boundary", id = try enqueue(text)
        capacity.set(receiptBytes: 0)
        let denied = try await service.importPending()
        XCTAssertEqual(denied.imported, 0); XCTAssertEqual(denied.alreadyImported, 0)
        XCTAssertEqual(denied.failures.map(\.operationID), [id])
        XCTAssertGreaterThan(capacity.queries, 0)
        XCTAssertEqual(io.calls, 0, "No initial or attempted receipt can precede the full receipt allowance")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(id).path))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try inbox.pendingIDs(), [id]); XCTAssertEqual(try payload(id), Data(text.utf8))
        try assertNoPartialReceiptFiles()

        capacity.set(receiptBytes: 16 * 1_024 * 1_024)
        let retry = try await service.importPending()
        XCTAssertEqual(retry.imported, 1); XCTAssertTrue(retry.failures.isEmpty)
        XCTAssertEqual(try store.load().map(\.text), [text])
        XCTAssertEqual(try receipt(id).completed, [0])
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }

    func testCompletionENOSPCKeepsAttemptAndInboxThenRetryAcknowledgesSameRecord() async throws {
        try await service.publishDestinations()
        let text = "commit survives receipt failure", id = try enqueue(text)
        io.failCompletedWrites(true)
        let failed = try await service.importPending()
        XCTAssertEqual(failed.imported, 0); XCTAssertEqual(failed.failures.map(\.operationID), [id])
        let record = try XCTUnwrap(store.load().first)
        XCTAssertEqual(try store.load().count, 1); XCTAssertEqual(record.text, text)
        let attempted = try receipt(id)
        XCTAssertEqual(attempted.recordIDs, [record.id]); XCTAssertEqual(attempted.attempted, [0])
        XCTAssertTrue(attempted.completed.isEmpty)
        XCTAssertEqual(try inbox.pendingIDs(), [id]); XCTAssertEqual(try payload(id), Data(text.utf8))
        try assertNoPartialReceiptFiles()

        io.failCompletedWrites(false)
        service = try makeService() // Recover exclusively from the durable receipt and database.
        let retry = try await service.importPending()
        XCTAssertEqual(retry.imported, 0); XCTAssertEqual(retry.alreadyImported, 1); XCTAssertTrue(retry.failures.isEmpty)
        let records = try store.load()
        XCTAssertEqual(records.map(\.id), [record.id]); XCTAssertEqual(records.first?.revision, record.revision)
        let completed = try receipt(id)
        XCTAssertEqual(completed.digest, attempted.digest); XCTAssertEqual(completed.recordIDs, attempted.recordIDs)
        XCTAssertEqual(completed.completed, [0]); XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        try assertNoPartialReceiptFiles()
    }

    func testCompletedReplayNeedsNoCapacityAndDoesNotResurrectADeletedRecord() async throws {
        try await service.publishDestinations()
        let id = try enqueue("a completed share remains completed")
        let incoming = inbox.inbox.appendingPathComponent(id.uuidString), saved = root.appendingPathComponent("saved-incoming")
        try FileManager.default.copyItem(at: incoming, to: saved)
        let initial = try await service.importPending()
        XCTAssertEqual(initial.imported, 1); XCTAssertTrue(initial.failures.isEmpty)
        let record = try XCTUnwrap(store.load().first)
        try store.delete(id: record.id)
        try FileManager.default.copyItem(at: saved, to: incoming)
        let durableReceipt = try Data(contentsOf: receiptURL(id)), calls = io.calls, queries = capacity.queries
        capacity.set(receiptBytes: 0, allFull: true)

        let replay = try await service.importPending()
        XCTAssertEqual(replay.imported, 0); XCTAssertEqual(replay.alreadyImported, 1); XCTAssertTrue(replay.failures.isEmpty)
        XCTAssertTrue(try store.load().isEmpty); XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        XCTAssertEqual(io.calls, calls); XCTAssertEqual(capacity.queries, queries)
        XCTAssertEqual(try Data(contentsOf: receiptURL(id)), durableReceipt)
        try assertNoPartialReceiptFiles()
    }
}
