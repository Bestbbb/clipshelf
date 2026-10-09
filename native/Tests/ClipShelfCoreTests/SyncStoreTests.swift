import Foundation
import XCTest
@testable import ClipShelfCore

private actor MemorySyncTransport: SyncTransport {
    var account = "test-account"
    var logs: [String: [SyncOperation]] = [:]
    var loseNextResponse = false
    var pushCount = 0
    func setLoseNextResponse() { loseNextResponse = true }
    func push(_ operations: [SyncOperation], accountID: String) async throws -> Set<UUID> {
        guard accountID == account else { throw SyncError.accountChanged }
        guard operations.allSatisfy({ $0.accountID == accountID }) else { throw SyncError.invalidOperation }
        pushCount += 1
        var log = logs[accountID] ?? []
        var known = Set(log.map(\.operationID))
        for operation in operations where known.insert(operation.operationID).inserted { log.append(operation) }
        logs[accountID] = log
        if loseNextResponse { loseNextResponse = false; throw SyncError.unavailable("Simulated response loss after durable server write") }
        return Set(operations.map(\.operationID))
    }
    func pull(accountID: String, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        guard accountID == account else { throw SyncError.accountChanged }
        let log = logs[accountID] ?? []
        let start = cursor.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        guard start <= log.count else { throw SyncError.invalidCursor }
        let end = min(log.count, start + limit)
        return SyncChangeBatch(operations: Array(log[start..<end]), cursor: Data(String(end).utf8), hasMore: end < log.count)
    }
    func count() -> Int { logs.values.reduce(0) { $0 + $1.count } }
}

final class SyncStoreTests: XCTestCase {
    private var directory: URL!
    private let account = "test-account"
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String) throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }

    func testDisabledByDefaultAndOptInOnlyAdoptsUnassignedData() throws {
        let local = try store("local")
        let item = ClipboardRecord(text: "local only")
        try local.record(item)
        XCTAssertNil(try local.syncConfiguration().accountID)
        XCTAssertThrowsError(try local.pendingSyncOperations(accountID: account))
        try local.configureSync(accountID: account)
        XCTAssertEqual(try local.pendingSyncOperations(accountID: account), [])
        try local.configureSync(accountID: account, includeLocalData: true)
        let first = try local.pendingSyncOperations(accountID: account)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.entityID, item.id)
        try local.configureSync(accountID: "another-account", includeLocalData: true)
        XCTAssertEqual(try local.pendingSyncOperations(accountID: "another-account"), [])
        XCTAssertThrowsError(try local.pendingSyncOperations(accountID: account))
        XCTAssertThrowsError(try local.applyRemoteChanges(accountID: account, changes: first, nextCursor: Data()))
        try local.configureSync(accountID: account)
        XCTAssertEqual(try local.pendingSyncOperations(accountID: account), first)
    }

    func testOutboxPersistsStableIDsAndWritesAllMutationKindsAtomically() throws {
        let local = try store("local")
        try local.configureSync(accountID: account)
        let board = try local.createPinboard(name: "Board")
        let record = ClipboardRecord(text: "capture")
        try local.record(record)
        try local.move(recordID: record.id, to: board.id)
        var edit = try XCTUnwrap(local.item(id: record.id))
        edit.text = "edited"
        _ = try local.update(record: edit)
        try local.prune(before: Date.distantFuture)
        try local.delete(id: record.id)
        try local.deletePinboard(id: board.id)
        let pending = try local.pendingSyncOperations(accountID: account)
        XCTAssertEqual(pending.count, 7)
        XCTAssertEqual(Set(pending.map(\.operationID)).count, 7)
        XCTAssertEqual(pending.filter { $0.entityID == record.id }.map(\.revision), [1, 2, 3, 4, 5])
        XCTAssertEqual(pending.last?.action, .delete)
        XCTAssertTrue(try local.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: record.id))
        XCTAssertThrowsError(try local.create(record))
        XCTAssertEqual(try local.pendingSyncOperations(accountID: account), pending)
        XCTAssertNil(try local.item(id: record.id))
        let reopened = try store("local")
        XCTAssertEqual(try reopened.pendingSyncOperations(accountID: account), pending)
    }

    func testTwoDevicesOfflineConcurrentEditsConvergeWithConflictCopy() async throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let cloud = MemorySyncTransport()
        let syncA = SyncCoordinator(store: a, transport: cloud), syncB = SyncCoordinator(store: b, transport: cloud)
        let original = ClipboardRecord(text: "original")
        try a.record(original)
        _ = try await syncA.synchronize(accountID: account)
        _ = try await syncB.synchronize(accountID: account)
        XCTAssertEqual(try b.load(), [original])
        var editA = try XCTUnwrap(a.item(id: original.id)); editA.text = "offline A"
        var editB = try XCTUnwrap(b.item(id: original.id)); editB.text = "offline B"
        _ = try a.update(record: editA); _ = try b.update(record: editB)
        _ = try await syncA.synchronize(accountID: account)
        _ = try await syncB.synchronize(accountID: account)
        _ = try await syncA.synchronize(accountID: account)
        XCTAssertEqual(Set(try a.load().map(\.text)), ["offline A", "offline B"])
        XCTAssertEqual(Set(try a.load().map(\.id)), Set(try b.load().map(\.id)))
        XCTAssertEqual(try a.pendingSyncOperations(accountID: account), [])
        XCTAssertEqual(try b.pendingSyncOperations(accountID: account), [])
    }

    func testDeleteWinsIdentityWhileConcurrentEditRemainsRecoverable() async throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let cloud = MemorySyncTransport()
        let syncA = SyncCoordinator(store: a, transport: cloud), syncB = SyncCoordinator(store: b, transport: cloud)
        let original = ClipboardRecord(text: "original")
        try a.record(original)
        _ = try await syncA.synchronize(accountID: account); _ = try await syncB.synchronize(accountID: account)
        try a.delete(id: original.id)
        var edited = try XCTUnwrap(b.item(id: original.id)); edited.text = "offline edited content"
        _ = try b.update(record: edited)
        _ = try await syncA.synchronize(accountID: account); _ = try await syncB.synchronize(accountID: account)
        _ = try await syncA.synchronize(accountID: account)
        XCTAssertNil(try a.item(id: original.id)); XCTAssertNil(try b.item(id: original.id))
        XCTAssertEqual(try a.load().map(\.text), ["offline edited content"])
        XCTAssertEqual(try a.load().map(\.id), try b.load().map(\.id))
        XCTAssertTrue(try b.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: original.id))
    }

    func testDeletingWholeBoardPreservesConcurrentEditAsUnpinnedConflictAndSyncContinues() async throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let cloud = MemorySyncTransport()
        let syncA = SyncCoordinator(store: a, transport: cloud), syncB = SyncCoordinator(store: b, transport: cloud)
        let board = try a.createPinboard(name: "Delete with content")
        let original = try a.create(ClipboardRecord(text: "original", pinboardID: board.id))
        _ = try await syncA.synchronize(accountID: account); _ = try await syncB.synchronize(accountID: account)
        try a.deletePinboard(id: board.id, deleteItems: true)
        var edited = try XCTUnwrap(b.item(id: original.id)); edited.text = "offline edit survives deleted board"
        _ = try b.update(record: edited)
        _ = try await syncA.synchronize(accountID: account); _ = try await syncB.synchronize(accountID: account)
        _ = try await syncA.synchronize(accountID: account)
        for device in [a, b] {
            XCTAssertNil(try device.item(id: original.id))
            XCTAssertFalse(try device.pinboards().contains { $0.id == board.id })
            let recovered = try XCTUnwrap(device.load().first)
            XCTAssertEqual(try device.load().count, 1)
            XCTAssertEqual(recovered.text, edited.text)
            XCTAssertNil(recovered.pinboardID); XCTAssertNil(recovered.pinboardOrder)
            XCTAssertTrue(recovered.isInHistory)
            XCTAssertTrue(try device.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: original.id))
            XCTAssertEqual(try device.pendingSyncOperations(accountID: account), [])
        }
        let recoveredIDs = try a.load().map(\.id)
        XCTAssertEqual(recoveredIDs, try b.load().map(\.id))
        _ = try await syncA.synchronize(accountID: account); _ = try await syncB.synchronize(accountID: account)
        XCTAssertEqual(try store("a").load().map(\.id), recoveredIDs)
    }

    func testLostServerResponseRetriesSameOperationWithoutDuplicates() async throws {
        let local = try store("local")
        try local.configureSync(accountID: account)
        try local.record(ClipboardRecord(text: "once"))
        let pending = try local.pendingSyncOperations(accountID: account)
        let cloud = MemorySyncTransport()
        await cloud.setLoseNextResponse()
        let coordinator = SyncCoordinator(store: local, transport: cloud)
        do { _ = try await coordinator.synchronize(accountID: account); XCTFail("Expected lost response") } catch { }
        XCTAssertEqual(try local.pendingSyncOperations(accountID: account), pending)
        _ = try await coordinator.synchronize(accountID: account)
        XCTAssertEqual(try local.pendingSyncOperations(accountID: account), [])
        let count = await cloud.count()
        XCTAssertEqual(count, 1)
    }

    func testOutOfOrderChangesPersistInboxAndDoNotReenterOutbox() throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let original = ClipboardRecord(text: "original")
        try a.record(original)
        var edited = original; edited.text = "updated"
        _ = try a.update(record: edited)
        let changes = try a.pendingSyncOperations(accountID: account)
        try b.applyRemoteChanges(accountID: account, changes: [changes[1]], nextCursor: Data("partial".utf8))
        XCTAssertEqual(try b.load(), [])
        let reopened = try store("b")
        try reopened.applyRemoteChanges(accountID: account, changes: [changes[0]], nextCursor: Data("complete".utf8))
        XCTAssertEqual(try reopened.load().map(\.text), ["updated"])
        XCTAssertEqual(try reopened.pendingSyncOperations(accountID: account), [])
        try reopened.applyRemoteChanges(accountID: account, changes: changes, nextCursor: Data("repeat".utf8))
        XCTAssertEqual(try reopened.load().count, 1)
        XCTAssertEqual(try reopened.syncCursor(accountID: account), Data("repeat".utf8))
    }

    func testInvalidAccountCannotReadQueueAcknowledgeOrCallTransport() async throws {
        let local = try store("local")
        try local.configureSync(accountID: account)
        try local.record(ClipboardRecord(text: "private"))
        let operations = try local.pendingSyncOperations(accountID: account)
        try local.configureSync(accountID: nil)
        XCTAssertThrowsError(try local.acknowledgeSyncOperations(accountID: account, operationIDs: Set(operations.map(\.operationID))))
        let cloud = MemorySyncTransport()
        let coordinator = SyncCoordinator(store: local, transport: cloud)
        do { _ = try await coordinator.synchronize(accountID: account); XCTFail("Expected disabled account") } catch { }
        let count = await cloud.count()
        XCTAssertEqual(count, 0)
        try local.configureSync(accountID: account)
        XCTAssertEqual(try local.pendingSyncOperations(accountID: account), operations)
    }
}
