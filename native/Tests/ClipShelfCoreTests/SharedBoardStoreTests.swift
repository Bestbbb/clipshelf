import Foundation
import XCTest
@testable import ClipShelfCore

private actor MemorySharedBoardTransport: SharedBoardTransport {
    var permissions: [String: SharedBoardAccess] = [:]
    var logs: [String: [SyncOperation]] = [:]
    var revokeOnPush: String?
    var revokeOnPull: String?
    var downgradeOnPush: String?
    func set(_ account: String, access: SharedBoardAccess) { permissions[account] = access }
    func revokeDuringPush(_ account: String) { revokeOnPush = account }
    func revokeDuringPull(_ account: String) { revokeOnPull = account }
    func downgradeDuringPush(_ account: String) { downgradeOnPush = account }
    func access(for board: SharedBoardDescriptor) async throws -> SharedBoardAccess { permissions[board.accountID] ?? .revoked }
    func push(_ operations: [SyncOperation], board: SharedBoardDescriptor) async throws -> Set<UUID> {
        if downgradeOnPush == board.accountID {
            permissions[board.accountID] = .readOnly; downgradeOnPush = nil
            throw SharedBoardError.readOnly
        }
        if revokeOnPush == board.accountID { permissions[board.accountID] = .revoked; revokeOnPush = nil }
        guard (permissions[board.accountID] ?? .revoked).canWrite else { throw SharedBoardError.remotePermissionDenied }
        guard operations.allSatisfy({ $0.accountID == board.namespace }) else { throw SyncError.namespaceConflict }
        var log = logs[board.namespace] ?? []
        var ids = Set(log.map(\.operationID))
        for operation in operations where ids.insert(operation.operationID).inserted { log.append(operation) }
        logs[board.namespace] = log
        return Set(operations.map(\.operationID))
    }
    func pull(board: SharedBoardDescriptor, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        if revokeOnPull == board.accountID { permissions[board.accountID] = .revoked; revokeOnPull = nil }
        guard permissions[board.accountID] != .revoked else { throw SharedBoardError.revoked }
        let log = logs[board.namespace] ?? []
        let start = cursor.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        let end = min(log.count, start + limit)
        guard start <= end else { throw SyncError.invalidCursor }
        return SyncChangeBatch(operations: Array(log[start..<end]), cursor: Data(String(end).utf8), hasMore: end < log.count)
    }
    func count(_ namespace: String) -> Int { logs[namespace]?.count ?? 0 }
}

final class SharedBoardStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String) throws -> HistoryStore { try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3")) }
    private func descriptor(_ id: UUID, account: String) -> SharedBoardDescriptor {
        SharedBoardDescriptor(boardID: id, accountID: account, containerIdentifier: "iCloud.test.synthetic",
                              zoneName: "ClipShelfShared_" + id.uuidString, zoneOwnerName: "owner-record",
                              shareRecordName: "synthetic-share")
    }

    func testSharingCopyIsIndependentOfPrivateHistoryAndPrivateSyncQueue() throws {
        let local = try store("local")
        let source = try local.createPinboard(name: "Private source")
        let privateRecord = try local.create(ClipboardRecord(text: "share selected only", pinboardID: source.id))
        try local.create(ClipboardRecord(text: "never share this"))
        try local.configureSharing(accountID: "owner")
        let share = descriptor(UUID(), account: "owner")
        let shared = try local.createSharedCopy(from: source.id, descriptor: share)
        XCTAssertEqual(shared.id, share.boardID)
        let items = try local.search(HistoryQuery(pinboardIDs: [shared.id]))
        XCTAssertEqual(items.map(\.text), [privateRecord.text])
        XCTAssertNotEqual(items.first?.id, privateRecord.id)
        XCTAssertEqual(try local.item(id: privateRecord.id), privateRecord)
        let pending = try local.pendingSharedOperations(boardID: share.boardID, accountID: "owner")
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.accountID == share.namespace })
        try local.configureSync(accountID: "owner", includeLocalData: true)
        let privatePending = try local.pendingSyncOperations(accountID: "owner")
        XCTAssertFalse(privatePending.contains { $0.entityID == shared.id || $0.entityID == items.first?.id })
        XCTAssertEqual(privatePending.filter { $0.entityKind == .clipboard }.count, 2)
        XCTAssertThrowsError(try local.configureSync(accountID: share.namespace))
        XCTAssertThrowsError(try local.configureSharing(accountID: share.namespace))
    }

    func testReadOnlyReceiverDownloadsButAllLocalMutationsRollBack() async throws {
        let owner = try store("owner"), reader = try store("reader")
        try owner.configureSharing(accountID: "owner"); try reader.configureSharing(accountID: "reader")
        let source = try owner.createPinboard(name: "Source")
        try owner.create(ClipboardRecord(text: "read only", pinboardID: source.id))
        let id = UUID(), ownerBoard = descriptor(id, account: "owner"), readerBoard = descriptor(id, account: "reader")
        _ = try owner.createSharedCopy(from: source.id, descriptor: ownerBoard)
        try reader.registerSharedBoard(readerBoard, access: .readOnly)
        let cloud = MemorySharedBoardTransport()
        await cloud.set("owner", access: .owner); await cloud.set("reader", access: .readOnly)
        _ = try await SharedBoardCoordinator(store: owner, transport: cloud).synchronize(ownerBoard)
        _ = try await SharedBoardCoordinator(store: reader, transport: cloud).synchronize(readerBoard)
        let record = try XCTUnwrap(reader.search(HistoryQuery(pinboardIDs: [id])).first)
        var edited = record; edited.text = "forbidden"
        XCTAssertThrowsError(try reader.update(record: edited))
        XCTAssertThrowsError(try reader.delete(id: record.id))
        XCTAssertThrowsError(try reader.create(ClipboardRecord(text: "new forbidden", pinboardID: id)))
        var board = try XCTUnwrap(reader.pinboards().first); board.name = "forbidden rename"
        XCTAssertThrowsError(try reader.updatePinboard(board))
        XCTAssertEqual(try reader.item(id: record.id), record)
        XCTAssertEqual(try reader.search(HistoryQuery(pinboardIDs: [id])).count, 1)
    }

    func testOfflineRevocationRejectsOldEditAndKeepsRecoverableFailedDraftAcrossRestart() async throws {
        let owner = try store("owner"), writer = try store("writer")
        try owner.configureSharing(accountID: "owner"); try writer.configureSharing(accountID: "writer")
        let source = try owner.createPinboard(name: "Source")
        try owner.create(ClipboardRecord(text: "server original", pinboardID: source.id))
        let id = UUID(), ownerBoard = descriptor(id, account: "owner"), writerBoard = descriptor(id, account: "writer")
        _ = try owner.createSharedCopy(from: source.id, descriptor: ownerBoard)
        try writer.registerSharedBoard(writerBoard, access: .readWrite)
        let cloud = MemorySharedBoardTransport()
        await cloud.set("owner", access: .owner); await cloud.set("writer", access: .readWrite)
        _ = try await SharedBoardCoordinator(store: owner, transport: cloud).synchronize(ownerBoard)
        let syncWriter = SharedBoardCoordinator(store: writer, transport: cloud)
        _ = try await syncWriter.synchronize(writerBoard)
        var edited = try XCTUnwrap(writer.search(HistoryQuery(pinboardIDs: [id])).first)
        edited.text = "offline draft must survive"
        _ = try writer.update(record: edited)
        let before = await cloud.count(ownerBoard.namespace)
        await cloud.revokeDuringPush("writer")
        do { _ = try await syncWriter.synchronize(writerBoard); XCTFail("Server must reject revoked writer") } catch { }
        let after = await cloud.count(ownerBoard.namespace)
        XCTAssertEqual(after, before)
        let reopened = try store("writer")
        let drafts = try reopened.failedSharedDrafts(boardID: id, accountID: "writer")
        XCTAssertEqual(drafts.compactMap { $0.operation.record?.text }, ["offline draft must survive"])
        XCTAssertEqual(try reopened.search(HistoryQuery(pinboardIDs: [id])), [])
        let draft = try XCTUnwrap(drafts.first)
        let recovered = try reopened.recoverFailedSharedDraft(operationID: draft.id, boardID: id, accountID: "writer")
        XCTAssertNil(recovered.pinboardID)
        XCTAssertEqual(recovered.text, "offline draft must survive")
        XCTAssertNotEqual(recovered.id, edited.id)
        XCTAssertThrowsError(try reopened.pendingSharedOperations(boardID: id, accountID: "writer"))
    }

    func testSharedInputCannotOverwriteUnassignedPrivateEntityOrCrossAnotherBoard() throws {
        let local = try store("local")
        let privateRecord = ClipboardRecord(text: "private")
        try local.create(privateRecord)
        try local.configureSharing(accountID: "reader")
        let share = descriptor(UUID(), account: "reader")
        try local.registerSharedBoard(share, access: .readOnly)
        let forgedDelete = SyncOperation(accountID: share.namespace, entityID: privateRecord.id, entityKind: .clipboard,
                                         action: .delete, baseRevision: 0, revision: 1)
        XCTAssertThrowsError(try local.applySharedChanges(boardID: share.boardID, accountID: "reader", changes: [forgedDelete], nextCursor: nil))
        XCTAssertEqual(try local.item(id: privateRecord.id), privateRecord)
        let foreignBoard = Pinboard(name: "wrong board")
        let forgedBoard = SyncOperation(accountID: share.namespace, entityID: foreignBoard.id, entityKind: .pinboard,
                                        action: .upsert, baseRevision: 0, revision: 1, pinboard: foreignBoard)
        XCTAssertThrowsError(try local.applySharedChanges(boardID: share.boardID, accountID: "reader", changes: [forgedBoard], nextCursor: nil))
        try local.configureSharing(accountID: "different-account")
        XCTAssertThrowsError(try local.sharedBoards(accountID: "reader"))
        XCTAssertThrowsError(try local.registerSharedBoard(share, access: .readWrite))
    }

    func testRevocationDuringDownloadAlsoPreservesPendingDraftAndClearsCache() async throws {
        let local = try store("local")
        try local.configureSharing(accountID: "writer")
        let source = try local.createPinboard(name: "Source")
        try local.create(ClipboardRecord(text: "unsent offline content", pinboardID: source.id))
        let share = descriptor(UUID(), account: "writer")
        _ = try local.createSharedCopy(from: source.id, descriptor: share)
        let cloud = MemorySharedBoardTransport()
        await cloud.set("writer", access: .readWrite)
        await cloud.revokeDuringPull("writer")
        do { _ = try await SharedBoardCoordinator(store: local, transport: cloud).synchronize(share); XCTFail("Expected revocation") } catch { }
        XCTAssertEqual(try local.failedSharedDrafts(boardID: share.boardID, accountID: "writer").count, 2)
        XCTAssertEqual(try local.search(HistoryQuery(pinboardIDs: [share.boardID])), [])
        XCTAssertEqual(try local.sharedBoards(accountID: "writer").first?.access, .revoked)
    }

    func testDowngradeDuringPushPreservesAcceptedContentAndRejectsDraftWithoutUpload() async throws {
        let owner = try store("owner"), writer = try store("writer")
        try owner.configureSharing(accountID: "owner"); try writer.configureSharing(accountID: "writer")
        let source = try owner.createPinboard(name: "Source")
        try owner.create(ClipboardRecord(text: "accepted original", pinboardID: source.id))
        try owner.create(ClipboardRecord(text: "untouched cached item", pinboardID: source.id))
        let id = UUID(), ownerBoard = descriptor(id, account: "owner"), writerBoard = descriptor(id, account: "writer")
        _ = try owner.createSharedCopy(from: source.id, descriptor: ownerBoard)
        try writer.registerSharedBoard(writerBoard, access: .readWrite)
        let cloud = MemorySharedBoardTransport()
        await cloud.set("owner", access: .owner); await cloud.set("writer", access: .readWrite)
        _ = try await SharedBoardCoordinator(store: owner, transport: cloud).synchronize(ownerBoard)
        let synchronizer = SharedBoardCoordinator(store: writer, transport: cloud)
        _ = try await synchronizer.synchronize(writerBoard)
        let accepted = try writer.search(HistoryQuery(pinboardIDs: [id]))
        var edited = try XCTUnwrap(accepted.first { $0.text == "accepted original" })
        edited.text = "offline rejected draft"; _ = try writer.update(record: edited)
        let before = await cloud.count(writerBoard.namespace)
        await cloud.downgradeDuringPush("writer")
        do { _ = try await synchronizer.synchronize(writerBoard); XCTFail("Expected downgrade") }
        catch SharedBoardError.readOnly { }
        let after = await cloud.count(writerBoard.namespace)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try writer.sharedBoards(accountID: "writer").first?.access, .readOnly)
        XCTAssertEqual(Set(try writer.search(HistoryQuery(pinboardIDs: [id])).map(\.text)), Set(accepted.map(\.text)))
        let drafts = try writer.failedSharedDrafts(boardID: id, accountID: "writer")
        XCTAssertEqual(drafts.compactMap { $0.operation.record?.text }, ["offline rejected draft"])
        let reopened = try store("writer")
        XCTAssertEqual(Set(try reopened.search(HistoryQuery(pinboardIDs: [id])).map(\.text)), Set(accepted.map(\.text)))
        await cloud.set("writer", access: .readWrite)
        _ = try await synchronizer.synchronize(writerBoard)
        var replacement = try XCTUnwrap(writer.item(id: edited.id)); replacement.text = "new accepted version"
        _ = try writer.update(record: replacement)
        _ = try await synchronizer.synchronize(writerBoard)
        _ = try await SharedBoardCoordinator(store: owner, transport: cloud).synchronize(ownerBoard)
        XCTAssertEqual(try owner.item(id: edited.id)?.text, "new accepted version", "Rejected revisions cannot remain causal parents")
    }

    func testPersonalOrderAllowsReadOnlySharedBoardWithoutEnqueuingSharedMutations() async throws {
        let local = try store("local")
        try local.configureSharing(accountID: "reader")
        let privateBoard = try local.createPinboard(name: "Private")
        let sharedBoard = Pinboard(name: "Read only")
        let descriptor = descriptor(sharedBoard.id, account: "reader")
        try local.registerSharedBoard(descriptor, access: .readOnly)
        let operation = SyncOperation(accountID: descriptor.namespace, entityID: sharedBoard.id, entityKind: .pinboard,
                                      action: .upsert, baseRevision: 0, revision: 1, pinboard: sharedBoard)
        try local.applySharedChanges(boardID: sharedBoard.id, accountID: "reader", changes: [operation], nextCursor: nil)
        try local.reorderPinboards(ids: [sharedBoard.id, privateBoard.id])
        XCTAssertEqual(try local.pinboards().map(\.id), [sharedBoard.id, privateBoard.id])
        try local.updateSharedAccess(boardID: sharedBoard.id, accountID: "reader", access: .readWrite)
        XCTAssertEqual(try local.pendingSharedOperations(boardID: sharedBoard.id, accountID: "reader").count, 0)
    }
}
