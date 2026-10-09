import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

/// An actual byte store and immutable operation log. Devices never share filesystem paths.
private actor OwnedFileIntegrationCloud: SyncOwnedFileTransport, SharedBoardOwnedFileTransport {
    private var logs: [String: [SyncOperation]] = [:]
    private var payloads: [String: [UUID: Data]] = [:]
    private var blobs: [String: [String: Data]] = [:]
    private var permissions: [String: SharedBoardAccess] = [:]
    private var loseOperationReply = false
    private var denyOperationWrite = false
    private var unavailableBlobs = false
    private var corruptDownloads = false
    private var uploadEvents: [String] = []
    private var downloadEvents: [String] = []
    private var nextDownloadHook: (@Sendable () async throws -> Void)?

    func setPermission(_ account: String, _ access: SharedBoardAccess) { permissions[account] = access }
    func loseNextOperationReply() { loseOperationReply = true }
    func failNextOperationWrite() { denyOperationWrite = true }
    func setUnavailableBlobs(_ value: Bool) { unavailableBlobs = value }
    func setCorruptDownloads(_ value: Bool) { corruptDownloads = value }
    func onNextDownload(_ hook: @escaping @Sendable () async throws -> Void) { nextDownloadHook = hook }
    func operationLog(account: String) -> [SyncOperation] { logs[privateScope(account)] ?? [] }
    func operationLog(board: SharedBoardDescriptor) -> [SyncOperation] { logs[sharedScope(board)] ?? [] }
    func blobUploadEvents() -> [String] { uploadEvents }
    func blobDownloadEvents() -> [String] { downloadEvents }

    private func privateScope(_ account: String) -> String { "private|" + account }
    private func sharedScope(_ board: SharedBoardDescriptor) -> String {
        ["shared", board.containerIdentifier, board.zoneOwnerName, board.zoneName].joined(separator: "|")
    }
    private func blobScope(_ scope: SyncOwnedFileScope) -> String {
        if !scope.namespace.hasPrefix("shared:") { return privateScope(scope.accountID) }
        return ["shared", scope.containerIdentifier, scope.zoneOwnerName, scope.zoneName].joined(separator: "|")
    }
    func ownedFileScope(accountID: String) async throws -> SyncOwnedFileScope {
        .init(accountID: accountID, containerIdentifier: "iCloud.synthetic.integration", database: .privateDatabase,
              zoneOwnerName: "private-owner", zoneName: "private-zone", namespace: accountID)
    }
    func ownedFileScope(board: SharedBoardDescriptor) async throws -> SyncOwnedFileScope {
        .init(accountID: board.accountID, containerIdentifier: board.containerIdentifier,
              database: permissions[board.accountID] == .owner ? .privateDatabase : .sharedDatabase,
              zoneOwnerName: board.zoneOwnerName, zoneName: board.zoneName, namespace: board.namespace)
    }
    private func upload(_ upload: PreparedSyncOwnedUpload) throws {
        if unavailableBlobs { throw SyncError.unavailable("Synthetic file service unavailable") }
        let bytes = try SyncOwnedFileStaging.readVerified(fileURL: upload.fileURL, descriptor: upload.file)
        let scope = blobScope(upload.scope)
        if let previous = blobs[scope]?[upload.file.digest] {
            guard previous == bytes else { throw SyncError.invalidOperation }
        }
        blobs[scope, default: [:]][upload.file.digest] = bytes
        uploadEvents.append(scope + "|" + upload.file.digest)
    }
    private func download(_ request: SyncOwnedDownloadRequest) async throws -> SyncOwnedFileStaging {
        let scope = blobScope(request.scope)
        downloadEvents.append(scope + "|" + request.file.digest)
        if let hook = nextDownloadHook { nextDownloadHook = nil; try await hook() }
        if unavailableBlobs { throw SyncError.unavailable("Synthetic file service unavailable") }
        guard let bytes = blobs[scope]?[request.file.digest] else { throw SyncError.unavailable("Synthetic blob missing") }
        let stage = try SyncOwnedFileStaging.create(data: bytes, descriptor: request.file)
        if corruptDownloads { try Data(repeating: 0x7F, count: bytes.count).write(to: stage.fileURL) }
        return stage
    }
    func uploadOwnedFile(_ upload: PreparedSyncOwnedUpload) async throws {
        guard upload.scope.database == .privateDatabase else { throw SyncError.namespaceConflict }
        try self.upload(upload)
    }
    func downloadOwnedFile(_ request: SyncOwnedDownloadRequest) async throws -> SyncOwnedFileStaging {
        guard request.scope.database == .privateDatabase else { throw SyncError.namespaceConflict }
        return try await download(request)
    }
    func uploadOwnedFile(_ upload: PreparedSyncOwnedUpload, board: SharedBoardDescriptor) async throws {
        guard permissions[board.accountID]?.canWrite == true else { throw SharedBoardError.remotePermissionDenied }
        guard upload.scope == (try await ownedFileScope(board: board)) else { throw SyncError.namespaceConflict }
        try self.upload(upload)
    }
    func downloadOwnedFile(_ request: SyncOwnedDownloadRequest, board: SharedBoardDescriptor) async throws -> SyncOwnedFileStaging {
        guard let access = permissions[board.accountID], access != .revoked else { throw SharedBoardError.revoked }
        guard request.scope == (try await ownedFileScope(board: board)) else { throw SyncError.namespaceConflict }
        return try await download(request)
    }
    private func encode(_ operation: SyncOperation) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation)
    }
    private func append(_ operations: [SyncOperation], scope: String) throws -> Set<UUID> {
        if denyOperationWrite {
            denyOperationWrite = false
            throw SyncError.unavailable("Synthetic operation write failed after blob upload")
        }
        var log = logs[scope] ?? [], known = payloads[scope] ?? [:]
        for operation in operations {
            let payload = try encode(operation)
            if let previous = known[operation.operationID] {
                guard previous == payload else { throw SyncError.invalidOperation }
            } else {
                known[operation.operationID] = payload; log.append(operation)
            }
        }
        logs[scope] = log; payloads[scope] = known
        if loseOperationReply {
            loseOperationReply = false
            throw SyncError.unavailable("Synthetic response lost after immutable server write")
        }
        return Set(operations.map(\.operationID))
    }
    private func changes(scope: String, cursor: Data?, limit: Int) throws -> SyncChangeBatch {
        let log = logs[scope] ?? []
        let start = cursor.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        guard start <= log.count else { throw SyncError.invalidCursor }
        let end = min(log.count, start + limit)
        return .init(operations: Array(log[start..<end]), cursor: Data(String(end).utf8), hasMore: end < log.count)
    }
    func push(_ operations: [SyncOperation], accountID: String) async throws -> Set<UUID> {
        guard operations.allSatisfy({ $0.accountID == accountID }) else { throw SyncError.accountChanged }
        return try append(operations, scope: privateScope(accountID))
    }
    func pull(accountID: String, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        try changes(scope: privateScope(accountID), cursor: cursor, limit: limit)
    }
    func access(for board: SharedBoardDescriptor) async throws -> SharedBoardAccess {
        permissions[board.accountID] ?? .revoked
    }
    func push(_ operations: [SyncOperation], board: SharedBoardDescriptor) async throws -> Set<UUID> {
        guard permissions[board.accountID]?.canWrite == true else { throw SharedBoardError.remotePermissionDenied }
        guard operations.allSatisfy({ $0.accountID == board.namespace }) else { throw SyncError.namespaceConflict }
        return try append(operations, scope: sharedScope(board))
    }
    func pull(board: SharedBoardDescriptor, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        guard let access = permissions[board.accountID], access != .revoked else { throw SharedBoardError.revoked }
        return try changes(scope: sharedScope(board), cursor: cursor, limit: limit)
    }
}

/// Deliberately lacks the optional file transport capability, like an older adapter.
private struct OperationsOnlyIntegrationTransport: SyncTransport {
    let cloud: OwnedFileIntegrationCloud
    func push(_ operations: [SyncOperation], accountID: String) async throws -> Set<UUID> {
        try await cloud.push(operations, accountID: accountID)
    }
    func pull(accountID: String, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        try await cloud.pull(accountID: accountID, after: cursor, limit: limit)
    }
}

final class OwnedFileSyncIntegrationTests: XCTestCase {
    private var directory: URL!
    private let account = "synthetic-private-account"
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-file-sync-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store(_ name: String) throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func file(_ store: HistoryStore, bytes: [Data] = [Data("original 中文\0bytes".utf8)],
                      board: UUID? = nil) throws -> ClipboardRecord {
        let parts = bytes.map { _ in ClipboardPart(representations: [.init(typeIdentifier: "public.file-url", data: Data())]) }
        let candidate = ClipboardRecord(text: "托管文件", parts: parts, pinboardID: board)
        return try store.create(candidate, ownedFiles: bytes.enumerated().map {
            .init(partIndex: $0.offset, representationIndex: 0, filename: "示例-\($0.offset).bin", data: $0.element)
        }, expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }
    private func url(_ record: ClipboardRecord, part: Int = 0) throws -> URL {
        try XCTUnwrap(String(data: record.parts[part].representations[0].data, encoding: .utf8).flatMap(URL.init(string:)))
    }
    private func assertFile(_ store: HistoryStore, id: UUID, bytes: [Data], file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try XCTUnwrap(store.item(id: id), file: file, line: line)
        let bindings = try store.ownedFileBindings(recordID: id)
        XCTAssertEqual(bindings.count, bytes.count, file: file, line: line)
        for (index, expected) in bytes.enumerated() {
            XCTAssertTrue(bindings.contains { $0.partIndex == index && $0.representationIndex == 0 }, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: url(record, part: index)), expected, file: file, line: line)
        }
    }
    private func descriptor(_ id: UUID, account: String, zone: String? = nil) -> SharedBoardDescriptor {
        .init(boardID: id, accountID: account, containerIdentifier: "iCloud.synthetic.integration",
              zoneName: zone ?? "shared-" + id.uuidString, zoneOwnerName: "real-owner-record", shareRecordName: "share-" + id.uuidString)
    }
    private func run(_ store: HistoryStore, cloud: OwnedFileIntegrationCloud) async throws {
        _ = try await SyncCoordinator(store: store, transport: cloud).synchronize(accountID: account)
    }

    func testTwoSeparateDeviceRootsRoundTripAllFilesAndKeepLocalIdentityAfterRestart() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = [Data([0, 1, 255, 0, 4]), Data("second original 中文".utf8)]
        let original = try file(a, bytes: bytes)
        try await run(a, cloud: cloud); try await run(b, cloud: cloud)
        try assertFile(b, id: original.id, bytes: bytes)
        let received = try XCTUnwrap(b.item(id: original.id))
        XCTAssertNotEqual(try url(original), try url(received))
        XCTAssertTrue(Set(try a.ownedFileBindings(recordID: original.id).map(\.assetID))
            .isDisjoint(with: Set(try b.ownedFileBindings(recordID: original.id).map(\.assetID))))
        let receivedBindings = try b.ownedFileBindings(recordID: original.id)
        var renamed = received; renamed.renamedTitle = "从另一台 Mac 重命名"
        _ = try b.update(record: renamed)
        try await run(b, cloud: cloud); try await run(a, cloud: cloud)
        XCTAssertEqual(try a.load().count, 1); XCTAssertEqual(try b.load().count, 1)
        XCTAssertEqual(try a.item(id: original.id)?.renamedTitle, renamed.renamedTitle)
        try assertFile(a, id: original.id, bytes: bytes)
        let reopened = try store("b")
        try await run(reopened, cloud: cloud)
        XCTAssertEqual(try reopened.ownedFileBindings(recordID: original.id), receivedBindings)
        try assertFile(reopened, id: original.id, bytes: bytes)
        XCTAssertTrue(try reopened.pendingSyncOperations(accountID: account).isEmpty)
    }

    func testProjectionEditsAndNewRevisionCannotChangeAlreadyQueuedOriginalUpload() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("immutable first original".utf8), original = try file(a, bytes: [bytes])
        let firstOperation = try XCTUnwrap(a.pendingSyncOperations(accountID: account).first)
        try Data("external editor changed projection".utf8).write(to: url(original))
        var changed = original; changed.renamedTitle = "later revision"
        _ = try a.update(record: changed)
        try await run(a, cloud: cloud); try await run(b, cloud: cloud)
        let log = await cloud.operationLog(account: account)
        XCTAssertEqual(log.first { $0.operationID == firstOperation.operationID }, firstOperation)
        XCTAssertEqual(try b.item(id: original.id)?.renamedTitle, changed.renamedTitle)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testBlobUploadThenOperationWriteFailureAndLostReplyRetryImmutableIDs() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("retry durable bytes".utf8), original = try file(a, bytes: [bytes])
        let pending = try a.pendingSyncOperations(accountID: account)
        await cloud.failNextOperationWrite()
        do { try await run(a, cloud: cloud); XCTFail("Expected synthetic failed operation write") } catch { }
        XCTAssertEqual(try a.pendingSyncOperations(accountID: account), pending)
        let firstLog = await cloud.operationLog(account: account)
        XCTAssertTrue(firstLog.isEmpty)
        let uploads = await cloud.blobUploadEvents()
        XCTAssertFalse(uploads.isEmpty, "The immutable bytes must precede operation publication")
        await cloud.loseNextOperationReply()
        do { try await run(a, cloud: cloud); XCTFail("Expected synthetic lost acknowledgment") } catch { }
        let accepted = await cloud.operationLog(account: account)
        XCTAssertEqual(accepted, pending)
        try await run(try store("a"), cloud: cloud); try await run(b, cloud: cloud)
        let retried = await cloud.operationLog(account: account)
        XCTAssertEqual(retried, pending)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testReadOnlySharedParticipantWithDifferentAccountDownloadsOwnedBytes() async throws {
        let a = try store("owner"), b = try store("reader"), cloud = OwnedFileIntegrationCloud()
        let source = try a.createPinboard(name: "Source"), bytes = Data("shared original".utf8)
        _ = try file(a, bytes: [bytes], board: source.id)
        try a.configureSharing(accountID: "owner-account"); try b.configureSharing(accountID: "reader-account")
        let id = UUID(), owner = descriptor(id, account: "owner-account"), reader = descriptor(id, account: "reader-account")
        _ = try a.createSharedCopy(from: source.id, descriptor: owner)
        try b.registerSharedBoard(reader, access: .readOnly)
        await cloud.setPermission(owner.accountID, .owner); await cloud.setPermission(reader.accountID, .readOnly)
        _ = try await SharedBoardCoordinator(store: a, transport: cloud).synchronize(owner)
        _ = try await SharedBoardCoordinator(store: b, transport: cloud).synchronize(reader)
        let sourceCopy = try XCTUnwrap(a.search(.init(pinboardIDs: [id])).first)
        let remote = try XCTUnwrap(b.search(.init(pinboardIDs: [id])).first)
        XCTAssertEqual(remote.id, sourceCopy.id)
        XCTAssertNotEqual(try url(remote), try url(sourceCopy))
        try assertFile(b, id: remote.id, bytes: [bytes])
        XCTAssertThrowsError(try b.pendingSharedOperations(boardID: id, accountID: reader.accountID))
        XCTAssertEqual(try b.syncScalar("SELECT count(*) FROM sync_outbox WHERE account_id=?", [reader.namespace]), "0")
        var forbidden = remote; forbidden.renamedTitle = "forbidden"
        XCTAssertThrowsError(try b.update(record: forbidden))
    }

    func testDurableInboxAdvancesCursorButWaitsForEveryVerifiedBlobAcrossRestart() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = [Data("first".utf8), Data("second".utf8)], original = try file(a, bytes: bytes)
        try await run(a, cloud: cloud)
        let operations = await cloud.operationLog(account: account), cursor = Data("already-durable".utf8)
        try b.applyRemoteChanges(accountID: account, changes: operations, nextCursor: cursor)
        XCTAssertEqual(try b.syncCursor(accountID: account), cursor)
        XCTAssertNil(try b.item(id: original.id), "Wire tokens must never become output-ready file URLs")
        let scope = try await cloud.ownedFileScope(accountID: account)
        let context = try b.makeSyncTransferContext(scope: scope)
        let requests = try b.pendingSyncOwnedDownloads(context: context)
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first), last = try XCTUnwrap(requests.last)
        let firstStage = try await cloud.downloadOwnedFile(first)
        try b.acceptSyncOwnedDownload(first, stagedFileURL: firstStage.fileURL, context: context)
        XCTAssertNil(try b.item(id: original.id))
        await cloud.setCorruptDownloads(true)
        let corrupt = try await cloud.downloadOwnedFile(last)
        XCTAssertThrowsError(try b.acceptSyncOwnedDownload(last, stagedFileURL: corrupt.fileURL, context: context))
        XCTAssertNil(try b.item(id: original.id)); XCTAssertEqual(try b.syncCursor(accountID: account), cursor)
        let reopened = try store("b"), resumedContext = try reopened.makeSyncTransferContext(scope: scope)
        let resumed = try reopened.pendingSyncOwnedDownloads(context: resumedContext)
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed.first?.file, last.file)
        await cloud.setCorruptDownloads(false)
        let request = try XCTUnwrap(resumed.first), stage = try await cloud.downloadOwnedFile(request)
        try reopened.acceptSyncOwnedDownload(request, stagedFileURL: stage.fileURL, context: resumedContext)
        try assertFile(reopened, id: original.id, bytes: bytes)
        XCTAssertTrue(try reopened.pendingSyncOwnedDownloads(context: resumedContext).isEmpty)
        XCTAssertTrue(try reopened.pendingSyncOperations(accountID: account).isEmpty)
    }

    func testDownloadMaterializationCommitFailureRollsBackFilesBindingsAndRetrySucceeds() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("transaction original".utf8), original = try file(a, bytes: [bytes])
        try await run(a, cloud: cloud)
        let operations = await cloud.operationLog(account: account)
        try b.applyRemoteChanges(accountID: account, changes: operations, nextCursor: Data("1".utf8))
        let scope = try await cloud.ownedFileScope(accountID: account), context = try b.makeSyncTransferContext(scope: scope)
        let request = try XCTUnwrap(b.pendingSyncOwnedDownloads(context: context).first)
        let stage = try await cloud.downloadOwnedFile(request)
        let before = try FileManager.default.contentsOfDirectory(atPath: b.ownedFileStorage.directory.path).sorted()
        sqlite3_commit_hook(b.database, { _ in 1 }, nil)
        XCTAssertThrowsError(try b.acceptSyncOwnedDownload(request, stagedFileURL: stage.fileURL, context: context))
        sqlite3_commit_hook(b.database, nil, nil)
        XCTAssertNil(try b.item(id: original.id))
        XCTAssertTrue(try b.ownedFileBindings(recordID: original.id).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.ownedFileStorage.directory.path).sorted(), before)
        XCTAssertEqual(try b.pendingSyncOwnedDownloads(context: context).count, 1)
        try b.acceptSyncOwnedDownload(request, stagedFileURL: stage.fileURL, context: context)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testFailedFileDoesNotStarveIndependentTextUploadAndDownload() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("temporarily unavailable".utf8), original = try file(a, bytes: [bytes])
        let text = try a.create(ClipboardRecord(text: "independent text must synchronize"))
        await cloud.setUnavailableBlobs(true)
        do { try await run(a, cloud: cloud) } catch { /* A reported attachment error must not cancel independent work. */ }
        let partial = await cloud.operationLog(account: account)
        XCTAssertTrue(partial.contains { $0.entityID == text.id })
        XCTAssertFalse(partial.contains { $0.entityID == original.id })
        try await run(b, cloud: cloud)
        XCTAssertEqual(try b.item(id: text.id)?.text, text.text)
        XCTAssertNil(try b.item(id: original.id))
        await cloud.setUnavailableBlobs(false)
        try await run(a, cloud: cloud)
        await cloud.setUnavailableBlobs(true)
        do { try await run(b, cloud: cloud) } catch { }
        XCTAssertEqual(try b.item(id: text.id)?.text, text.text)
        XCTAssertNil(try b.item(id: original.id))
        XCTAssertNotNil(try b.syncCursor(accountID: account))
        let scope = try await cloud.ownedFileScope(accountID: account), context = try b.makeSyncTransferContext(scope: scope)
        XCTAssertFalse(try b.syncOwnedTransferStates(context: context).filter { $0.direction == .download && $0.status == .failed }.isEmpty)
        await cloud.setUnavailableBlobs(false)
        try await run(try store("b"), cloud: cloud)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testPrivateAccountABARejectsOldSuccessfulDownloadAndResumesInNewContext() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("account bound bytes".utf8), original = try file(a, bytes: [bytes])
        try await run(a, cloud: cloud)
        let activeAccount = account
        await cloud.onNextDownload {
            try b.configureSync(accountID: "different-real-account")
            try b.configureSync(accountID: activeAccount)
        }
        do { try await run(b, cloud: cloud); XCTFail("A stale download must fail the account-generation check") }
        catch SyncError.accountChanged { }
        XCTAssertNil(try b.item(id: original.id))
        XCTAssertTrue(try b.ownedFileBindings(recordID: original.id).isEmpty)
        try await run(b, cloud: cloud)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testSameDigestRequiresSeparatePrivateAndSharedScopeUpload() async throws {
        let a = try store("a"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try a.configureSharing(accountID: account)
        let source = try a.createPinboard(name: "private"), bytes = Data("same digest separate scopes".utf8)
        _ = try file(a, bytes: [bytes], board: source.id)
        try await run(a, cloud: cloud)
        let shared = descriptor(UUID(), account: account)
        _ = try a.createSharedCopy(from: source.id, descriptor: shared)
        await cloud.setPermission(account, .owner)
        _ = try await SharedBoardCoordinator(store: a, transport: cloud).synchronize(shared)
        let digest = RepresentationStorage.digest(bytes), uploads = await cloud.blobUploadEvents()
        XCTAssertEqual(Set(uploads.filter { $0.hasSuffix("|" + digest) }).count, 2)
        XCTAssertTrue(uploads.contains { $0.hasPrefix("private|") })
        XCTAssertTrue(uploads.contains { $0.hasPrefix("shared|") })
    }

    func testSharedAcceptedReplayAndRevokedFailedDraftRecoveryRetainDownloadedOriginals() async throws {
        for access: SharedBoardAccess in [.readOnly, .revoked] {
            let a = try store("owner-" + access.rawValue), b = try store("writer-" + access.rawValue)
            let cloud = OwnedFileIntegrationCloud(), bytes = Data("downloaded shared original \(access.rawValue)".utf8)
            let source = try a.createPinboard(name: "Source")
            _ = try file(a, bytes: [bytes], board: source.id)
            try a.configureSharing(accountID: "owner"); try b.configureSharing(accountID: "writer")
            let id = UUID(), owner = descriptor(id, account: "owner"), writer = descriptor(id, account: "writer")
            _ = try a.createSharedCopy(from: source.id, descriptor: owner)
            try b.registerSharedBoard(writer, access: .readWrite)
            await cloud.setPermission("owner", .owner); await cloud.setPermission("writer", .readWrite)
            _ = try await SharedBoardCoordinator(store: a, transport: cloud).synchronize(owner)
            _ = try await SharedBoardCoordinator(store: b, transport: cloud).synchronize(writer)
            let accepted = try XCTUnwrap(b.search(.init(pinboardIDs: [id])).first)
            var edited = accepted; edited.renamedTitle = "offline title must survive as a local draft"
            _ = try b.update(record: edited)
            await cloud.setPermission("writer", access)
            do { _ = try await SharedBoardCoordinator(store: b, transport: cloud).synchronize(writer) }
            catch SharedBoardError.revoked { XCTAssertEqual(access, .revoked) }
            if access == .readOnly {
                XCTAssertEqual(try b.item(id: accepted.id)?.renamedTitle, accepted.renamedTitle)
                try assertFile(b, id: accepted.id, bytes: [bytes])
            } else { XCTAssertNil(try b.item(id: accepted.id)) }
            let reopened = try store("writer-" + access.rawValue)
            let drafts = try reopened.failedSharedDrafts(boardID: id, accountID: "writer")
            let draft = try XCTUnwrap(drafts.first { $0.operation.entityID == accepted.id })
            let recovered = try reopened.recoverFailedSharedDraft(operationID: draft.id, boardID: id, accountID: "writer")
            XCTAssertNil(recovered.pinboardID); XCTAssertNotEqual(recovered.id, accepted.id)
            XCTAssertEqual(recovered.renamedTitle, edited.renamedTitle)
            try assertFile(reopened, id: recovered.id, bytes: [bytes])
            try reopened.configureSync(accountID: "writer", includeLocalData: true)
            XCTAssertFalse(try reopened.pendingSyncOperations(accountID: "writer").contains { $0.entityID == recovered.id },
                           "Explicitly recovered failed drafts must remain local-only")
        }
    }

    func testSharedAccountABAIgnoresBothOldDownloadSuccessAndOldPermissionFailure() async throws {
        for oldPermissionError in [false, true] {
            let suffix = oldPermissionError ? "permission-error" : "success"
            let a = try store("owner-" + suffix), b = try store("reader-" + suffix), cloud = OwnedFileIntegrationCloud()
            let bytes = Data("shared ABA original".utf8), source = try a.createPinboard(name: "Source")
            _ = try file(a, bytes: [bytes], board: source.id)
            try a.configureSharing(accountID: "owner"); try b.configureSharing(accountID: "reader")
            let id = UUID(), owner = descriptor(id, account: "owner"), reader = descriptor(id, account: "reader")
            _ = try a.createSharedCopy(from: source.id, descriptor: owner)
            try b.registerSharedBoard(reader, access: .readOnly)
            await cloud.setPermission("owner", .owner); await cloud.setPermission("reader", .readOnly)
            _ = try await SharedBoardCoordinator(store: a, transport: cloud).synchronize(owner)
            let sent = try XCTUnwrap(a.search(.init(pinboardIDs: [id])).first)
            await cloud.onNextDownload {
                try b.configureSharing(accountID: "another-account")
                try b.configureSharing(accountID: "reader")
                if oldPermissionError { throw SharedBoardError.revoked }
            }
            do {
                _ = try await SharedBoardCoordinator(store: b, transport: cloud).synchronize(reader)
                XCTFail("A stale async result must not enter the new sharing generation")
            } catch { }
            XCTAssertNil(try b.item(id: sent.id))
            XCTAssertEqual(try b.sharedBoards(accountID: "reader").first?.access, .readOnly)
            XCTAssertTrue(try b.failedSharedDrafts(boardID: id, accountID: "reader").isEmpty)
            let scope = try await cloud.ownedFileScope(board: reader), context = try b.makeSyncTransferContext(scope: scope)
            XCTAssertFalse(try b.syncOwnedTransferStates(context: context).contains { $0.status == .failed },
                           "Old-account errors must not overwrite the new generation's transfer state")
            _ = try await SharedBoardCoordinator(store: b, transport: cloud).synchronize(reader)
            try assertFile(b, id: sent.id, bytes: [bytes])
        }
    }

    func testDeletionArrivingWhileBlobDownloadsCannotResurrectDeletedIdentity() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let original = try file(a)
        try await run(a, cloud: cloud)
        let first = await cloud.operationLog(account: account)
        try b.applyRemoteChanges(accountID: account, changes: first, nextCursor: Data("1".utf8))
        let scope = try await cloud.ownedFileScope(accountID: account), context = try b.makeSyncTransferContext(scope: scope)
        let request = try XCTUnwrap(b.pendingSyncOwnedDownloads(context: context).first)
        let stage = try await cloud.downloadOwnedFile(request)
        try a.delete(id: original.id)
        try await run(a, cloud: cloud)
        let all = await cloud.operationLog(account: account)
        try b.applyRemoteChanges(accountID: account, changes: all, nextCursor: Data(String(all.count).utf8))
        XCTAssertNil(try b.item(id: original.id))
        do { try b.acceptSyncOwnedDownload(request, stagedFileURL: stage.fileURL, context: context) } catch { }
        XCTAssertNil(try b.item(id: original.id))
        XCTAssertTrue(try b.hasSyncTombstone(accountID: account, kind: .clipboard, entityID: original.id))
        XCTAssertTrue(try b.ownedFileBindings(recordID: original.id).isEmpty)
        try await run(b, cloud: cloud)
        XCTAssertNil(try b.item(id: original.id))
    }

    func testConcurrentReorderAndRenameCompareOriginalIdentityAcrossDevicePaths() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let board = try a.createPinboard(name: "Ordered files"), bytes = Data("same original despite local paths".utf8)
        let original = try file(a, bytes: [bytes], board: board.id)
        let other = try a.create(ClipboardRecord(text: "second item", pinboardID: board.id))
        try await run(a, cloud: cloud); try await run(b, cloud: cloud)
        var renamed = try XCTUnwrap(b.item(id: original.id)); renamed.renamedTitle = "remote title"
        _ = try b.update(record: renamed)
        let first = try XCTUnwrap(a.item(id: original.id)), anchor = try XCTUnwrap(a.item(id: other.id))
        _ = try a.moveSelection([.init(id: anchor.id, revision: anchor.revision)], to: board.id,
                                before: .init(id: first.id, revision: first.revision))
        try await run(a, cloud: cloud); try await run(b, cloud: cloud); try await run(a, cloud: cloud)
        for device in [a, b] {
            XCTAssertEqual(Set(try device.load().map(\.id)), [original.id, other.id], "Ordering must not create a content-conflict duplicate")
            XCTAssertEqual(try device.item(id: original.id)?.renamedTitle, renamed.renamedTitle)
            try assertFile(device, id: original.id, bytes: [bytes])
        }
        XCTAssertEqual(try a.search(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id),
                       try b.search(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id))
    }

    func testLegacyURLOnlyUpdateCannotSilentlyRemoveVerifiedRemoteOwnership() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("retain across legacy peer".utf8), original = try file(a, bytes: [bytes])
        try await run(a, cloud: cloud); try await run(b, cloud: cloud)
        let acceptedLog = await cloud.operationLog(account: account)
        let accepted = try XCTUnwrap(acceptedLog.last)
        var legacy = original; legacy.revision += 1; legacy.renamedTitle = "old peer title"
        let operation = SyncOperation(accountID: account, entityID: original.id, entityKind: .clipboard,
                                      action: .upsert, baseRevision: accepted.revision, revision: accepted.revision + 1,
                                      baseOperationID: accepted.operationID, record: legacy)
        do { try b.applyRemoteChanges(accountID: account, changes: [operation], nextCursor: Data("legacy".utf8)) }
        catch { /* Rejecting an unverifiable downgrade is allowed; silently discarding the original is not. */ }
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testQueuedRevisionKeepsOldPayloadAfterOwnedFileReplacement() async throws {
        let a = try store("a"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account)
        let oldBytes = Data("old immutable payload".utf8), newBytes = Data("replacement immutable payload".utf8)
        let original = try file(a, bytes: [oldBytes])
        let oldOperation = try XCTUnwrap(a.pendingSyncOperations(accountID: account).first)
        var replaced = original
        replaced.parts[0].representations[0].data = Data("file:///synthetic/explicit-replacement".utf8)
        let changed = try a.update(record: replaced)
        let adopted = try a.registerOwnedFiles(recordID: changed.id, expectedRevision: changed.revision,
                                               ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "replacement.bin", data: newBytes)],
                                               expectedSyncConfiguration: a.syncConfiguration(), expectedSharingConfiguration: a.sharingConfiguration())
        try Data("old projection external edit".utf8).write(to: url(original))
        try Data("new projection external edit".utf8).write(to: url(adopted))
        let scope = try await cloud.ownedFileScope(accountID: account), context = try a.makeSyncTransferContext(scope: scope)
        let newOperation = try XCTUnwrap(a.pendingSyncOperations(accountID: account).last)
        XCTAssertEqual(try a.pendingSyncOperations(accountID: account).first, oldOperation)
        let oldFile = try XCTUnwrap(oldOperation.ownedFiles?.files.first), newFile = try XCTUnwrap(newOperation.ownedFiles?.files.first)
        let oldUpload = try a.prepareSyncOwnedUpload(operationID: oldOperation.operationID, file: oldFile, context: context)
        let newUpload = try a.prepareSyncOwnedUpload(operationID: newOperation.operationID, file: newFile, context: context)
        XCTAssertEqual(try Data(contentsOf: oldUpload.fileURL), oldBytes)
        XCTAssertEqual(try Data(contentsOf: newUpload.fileURL), newBytes)
        XCTAssertNotEqual(oldUpload.file.digest, newUpload.file.digest)
    }

    func testPortableFilePartRemovesSenderAliasesButRetainsOtherParts() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let stale = "file:///Users/synthetic-sender/private/original.bin", bytes = Data("owned bytes only".utf8)
        let unchanged = ClipboardPart(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("separate text part".utf8))])
        let candidate = ClipboardRecord(text: "aliases", parts: [
            .init(representations: [
                .init(typeIdentifier: "public.file-url", data: Data(stale.utf8)),
                .init(typeIdentifier: "public.utf8-plain-text", data: Data(stale.utf8)),
                .init(typeIdentifier: "NSFilenamesPboardType", data: Data(stale.utf8)),
                .init(typeIdentifier: "com.apple.pasteboard.promised-file-content-type", data: Data(stale.utf8))
            ]), unchanged
        ])
        let original = try a.create(candidate, ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "original.bin", data: bytes)],
                                    expectedSyncConfiguration: a.syncConfiguration(), expectedSharingConfiguration: a.sharingConfiguration())
        try await run(a, cloud: cloud); try await run(b, cloud: cloud)
        let log = await cloud.operationLog(account: account), wire = try XCTUnwrap(log.first?.record)
        XCTAssertEqual(wire.parts[0].representations.count, 1)
        XCTAssertEqual(wire.parts[1], unchanged)
        XCTAssertFalse(wire.parts.flatMap(\.representations).contains { String(data: $0.data, encoding: .utf8) == stale })
        let received = try XCTUnwrap(b.item(id: original.id))
        XCTAssertEqual(received.parts[0].representations.count, 1)
        XCTAssertEqual(received.parts[1], unchanged)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testSchemaTenMigrationPreservesOldOutboxBytesAndPublishesNewCausalOwnedOperation() async throws {
        let cloud = OwnedFileIntegrationCloud(), bytes = Data("legacy registered immutable original".utf8)
        func legacyFixture() throws -> (ClipboardRecord, SyncOperation, Data) {
            let legacy = try store("legacy")
            try legacy.configureSync(accountID: account)
            let original = try file(legacy, bytes: [bytes])
            let current = try XCTUnwrap(legacy.pendingSyncOperations(accountID: account).first)
            // Construct the previous schema's real v1 payload; it has an explicit local registry,
            // but its already-published operation contains only the sender's URL.
            let oldOperation = SyncOperation(operationID: current.operationID, accountID: current.accountID,
                                             entityID: current.entityID, entityKind: current.entityKind, action: current.action,
                                             baseRevision: current.baseRevision, revision: current.revision,
                                             baseOperationID: current.baseOperationID, createdAt: current.createdAt, record: original)
            let payload = try JSONEncoder().encode(oldOperation)
            let statement = try legacy.prepare("UPDATE sync_outbox SET payload=? WHERE operation_id=?")
            defer { sqlite3_finalize(statement) }
            try legacy.bind(payload, at: 1, to: statement); try legacy.bind(current.operationID.uuidString, at: 2, to: statement)
            try legacy.stepToCompletion(statement)
            for table in ["owned_sync_assets", "owned_sync_transfers", "owned_sync_scopes", "owned_sync_access", "owned_sync_backfill"] {
                try legacy.execute("DROP TABLE " + table)
            }
            try legacy.execute("PRAGMA user_version=10")
            return (original, oldOperation, payload)
        }
        let (original, old, oldBytes) = try legacyFixture()
        let upgraded = try store("legacy")
        XCTAssertEqual(try upgraded.pendingSyncOperations(accountID: account), [old], "Opening the migrated database must not rewrite or publish legacy operations")
        let scope = try await cloud.ownedFileScope(accountID: account)
        _ = try upgraded.makeSyncTransferContext(scope: scope)
        let pending = try upgraded.pendingSyncOperations(accountID: account)
        XCTAssertEqual(pending.count, 2); XCTAssertEqual(pending.first, old)
        let successor = try XCTUnwrap(pending.last)
        XCTAssertNotEqual(successor.operationID, old.operationID)
        XCTAssertEqual(successor.baseOperationID, old.operationID)
        XCTAssertEqual(successor.formatVersion, 2)
        XCTAssertEqual(successor.ownedFiles?.files.first?.digest, RepresentationStorage.digest(bytes))
        let statement = try upgraded.prepare("SELECT payload FROM sync_outbox WHERE operation_id=?")
        defer { sqlite3_finalize(statement) }
        try upgraded.bind(old.operationID.uuidString, at: 1, to: statement)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(upgraded.dataColumn(statement, 0), oldBytes)
        let b = try store("b"); try b.configureSync(accountID: account)
        try await run(upgraded, cloud: cloud); try await run(b, cloud: cloud)
        try assertFile(b, id: original.id, bytes: [bytes])
        XCTAssertEqual(try b.load().count, 1)
    }

    func testAdapterWithoutFileCapabilityKeepsReportingDurablePendingFilesAfterCursorAdvances() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let original = try file(a)
        try await run(a, cloud: cloud)
        let legacy = SyncCoordinator(store: b, transport: OperationsOnlyIntegrationTransport(cloud: cloud))
        for _ in 0..<2 {
            do {
                _ = try await legacy.synchronize(accountID: account)
                XCTFail("An unsupported durable attachment cannot become a successful empty pull")
            } catch SyncError.unavailable(let message) {
                XCTAssertTrue(message.contains("不支持托管文件"))
            }
            XCTAssertNotNil(try b.syncCursor(accountID: account))
            XCTAssertNil(try b.item(id: original.id))
        }
        try await run(b, cloud: cloud)
        try assertFile(b, id: original.id, bytes: [Data("original 中文\0bytes".utf8)])
    }

    func testSameOperationIDInSharedNamespaceCannotBorrowPrivateVerifiedBindings() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("private original must stay private".utf8), original = try file(a, bytes: [bytes])
        try await run(a, cloud: cloud); try await run(b, cloud: cloud)
        let log = await cloud.operationLog(account: account), privateOperation = try XCTUnwrap(log.first)
        let board = descriptor(UUID(), account: "reader")
        try b.configureSharing(accountID: "reader"); try b.registerSharedBoard(board, access: .readOnly)
        let boardOperation = SyncOperation(accountID: board.namespace, entityID: board.boardID, entityKind: .pinboard,
                                           action: .upsert, baseRevision: 0, revision: 1,
                                           pinboard: Pinboard(id: board.boardID, name: "Shared target"))
        try b.applySharedChanges(boardID: board.boardID, accountID: "reader", changes: [boardOperation], nextCursor: nil)
        var forgedRecord = try XCTUnwrap(privateOperation.record)
        forgedRecord.id = UUID(); forgedRecord.pinboardID = board.boardID
        let forged = SyncOperation(operationID: privateOperation.operationID, accountID: board.namespace,
                                    entityID: forgedRecord.id, entityKind: .clipboard, action: .upsert,
                                    baseRevision: 0, revision: 1, record: forgedRecord,
                                    formatVersion: 2, ownedFiles: privateOperation.ownedFiles)
        do { try b.applySharedChanges(boardID: board.boardID, accountID: "reader", changes: [forged], nextCursor: Data("forged".utf8)) }
        catch { /* A namespace collision must be refused, never resolved using another scope's proof. */ }
        XCTAssertNil(try b.item(id: forgedRecord.id))
        XCTAssertTrue(try b.ownedFileBindings(recordID: forgedRecord.id).isEmpty)
        XCTAssertTrue(try b.search(.init(pinboardIDs: [board.boardID])).isEmpty)
        try assertFile(b, id: original.id, bytes: [bytes])
    }

    func testAmbiguousOwnedAndUnownedURLsInOnePartAreRejectedWithoutPartialImport() throws {
        let a = try store("a")
        try a.configureSync(accountID: account)
        let candidate = ClipboardRecord(text: "two distinct files in one ambiguous part", parts: [
            .init(representations: [
                .init(typeIdentifier: "public.file-url", data: Data("file:///synthetic/owned.bin".utf8)),
                .init(typeIdentifier: "public.file-url", data: Data("file:///synthetic/unowned.bin".utf8))
            ])
        ])
        let beforeFolders = try FileManager.default.contentsOfDirectory(atPath: a.ownedFileStorage.directory.path).sorted()
        XCTAssertThrowsError(try a.create(candidate,
                                         ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "owned.bin", data: Data("owned".utf8))],
                                         expectedSyncConfiguration: a.syncConfiguration(), expectedSharingConfiguration: a.sharingConfiguration()))
        XCTAssertNil(try a.item(id: candidate.id))
        XCTAssertTrue(try a.pendingSyncOperations(accountID: account).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.ownedFileStorage.directory.path).sorted(), beforeFolders)
    }

    func testOneBlobCompletingSeveralRevisionsLeavesNoStalePendingTransferRows() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = Data("one blob several immutable revisions".utf8), original = try file(a, bytes: [bytes])
        var renamed = original
        for name in ["first title", "second title"] {
            renamed.renamedTitle = name; renamed = try a.update(record: renamed)
        }
        try await run(a, cloud: cloud)
        let receiver = SyncCoordinator(store: b, transport: cloud)
        let summary = try await receiver.synchronize(accountID: account)
        try assertFile(b, id: original.id, bytes: [bytes])
        XCTAssertEqual(try b.item(id: original.id)?.renamedTitle, "second title")
        XCTAssertEqual(summary.pendingFiles, 0); XCTAssertEqual(summary.failedFiles, 0)
        XCTAssertFalse(try b.syncOwnedTransferStates().contains { $0.status != .complete })
        let retry = try await receiver.synchronize(accountID: account)
        XCTAssertEqual(retry.pendingFiles, 0); XCTAssertEqual(retry.failedFiles, 0)
    }

    func testPassByteBudgetDefersUploadsWithVisiblePendingStateAndLaterConverges() async throws {
        let a = try store("a"), b = try store("b"), cloud = OwnedFileIntegrationCloud()
        try a.configureSync(accountID: account); try b.configureSync(accountID: account)
        let bytes = [Data("one!".utf8), Data("two!".utf8), Data("tri!".utf8)]
        let records = try bytes.map { try file(a, bytes: [$0]) }
        let bounded = SyncCoordinator(store: a, transport: cloud, maximumTransferBytes: 8)
        let first = try await bounded.synchronize(accountID: account)
        XCTAssertEqual(first.uploadedOperations, 2)
        XCTAssertEqual(first.pendingFiles, 1, "The UI must not show completion while a budget-deferred file remains in outbox")
        XCTAssertEqual(first.failedFiles, 0)
        let pending = try a.syncOwnedTransferStates().filter { $0.status == .pending }
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?.entityID, records.last?.id)
        let retry = try await bounded.synchronize(accountID: account)
        XCTAssertEqual(retry.uploadedOperations, 1)
        XCTAssertEqual(retry.pendingFiles, 0); XCTAssertEqual(retry.failedFiles, 0)
        try await run(b, cloud: cloud)
        for (record, data) in zip(records, bytes) { try assertFile(b, id: record.id, bytes: [data]) }
        XCTAssertTrue(try a.pendingSyncOperations(accountID: account).isEmpty)
    }
}
