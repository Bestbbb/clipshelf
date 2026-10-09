import Foundation

public enum SharedBoardAccess: String, Codable, Sendable {
    case owner, readWrite, readOnly, revoked
    public var canWrite: Bool { self == .owner || self == .readWrite }
}

public struct SharedBoardDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { boardID }
    public let boardID: UUID
    public let accountID: String
    public let containerIdentifier: String
    public let zoneName: String
    public let zoneOwnerName: String
    public let shareRecordName: String
    public let shareURL: URL?
    public var namespace: String { "shared:" + boardID.uuidString }
    public init(boardID: UUID, accountID: String, containerIdentifier: String, zoneName: String,
                zoneOwnerName: String, shareRecordName: String, shareURL: URL? = nil) {
        self.boardID = boardID
        self.accountID = accountID
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.shareRecordName = shareRecordName
        self.shareURL = shareURL
    }
}

public struct SharedBoardState: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { descriptor.boardID }
    public let descriptor: SharedBoardDescriptor
    public let access: SharedBoardAccess
}

public struct FailedSharedDraft: Identifiable, Codable, Sendable {
    public var id: UUID { operation.operationID }
    public let operation: SyncOperation
    public let reason: String
    public let failedAt: Date
}

public enum SharedBoardError: Error, LocalizedError {
    case readOnly, revoked, accountChanged, notRegistered, remotePermissionDenied
    public var errorDescription: String? {
        switch self {
        case .readOnly: return "此共享板当前为只读，未提交修改。"
        case .revoked: return "此共享板的访问权限已撤销，未提交的修改保留在失败草稿中。"
        case .accountChanged: return "共享板绑定的 iCloud 账号已改变。"
        case .notRegistered: return "此共享板尚未登记到当前账号。"
        case .remotePermissionDenied: return "CloudKit 拒绝了共享板写入，修改已保留为失败草稿。"
        }
    }
}

public protocol SharedBoardTransport: Sendable {
    /// Must read current CKShare membership; cached client permissions are not authoritative.
    func access(for board: SharedBoardDescriptor) async throws -> SharedBoardAccess
    func push(_ operations: [SyncOperation], board: SharedBoardDescriptor) async throws -> Set<UUID>
    func pull(board: SharedBoardDescriptor, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch
}

public protocol SharedBoardLifecycleTransport: SharedBoardTransport {
    func resolveAccount(expectedAccountID: String?) async throws -> String
    func createShare(boardID: UUID, title: String, allowEditing: Bool, expectedAccountID: String) async throws -> SharedBoardDescriptor
    func acceptShare(url: URL, expectedAccountID: String) async throws -> SharedBoardDescriptor
    func stopSharing(_ board: SharedBoardDescriptor) async throws
    func leave(_ board: SharedBoardDescriptor) async throws
    func updateLinkPermission(board: SharedBoardDescriptor, allowEditing: Bool) async throws
}

public actor SharedBoardCoordinator {
    private let store: HistoryStore
    private let transport: any SharedBoardTransport
    private let maximumTransferBytes: Int
    private var running = Set<UUID>()
    public init(store: HistoryStore, transport: any SharedBoardTransport, maximumTransferBytes: Int = SyncOwnedFileLimits.maximumPassBytes) { self.store = store; self.transport = transport; self.maximumTransferBytes = max(0, min(maximumTransferBytes, SyncOwnedFileLimits.maximumPassBytes)) }

    public func synchronize(_ board: SharedBoardDescriptor) async throws -> SyncRunSummary {
        guard running.insert(board.boardID).inserted else { throw SyncError.unavailable("此共享板正在同步。") }
        defer { running.remove(board.boardID) }
        let configuration = try store.sharingConfiguration()
        do {
            return try await synchronizePass(board)
        } catch let error as SharedBoardError {
            guard try store.sharingConfiguration() == configuration else { throw SharedBoardError.accountChanged }
            switch error {
            case .readOnly:
                try store.updateSharedAccess(boardID: board.boardID, accountID: board.accountID, access: .readOnly)
                try store.rejectPendingSharedEdits(boardID: board.boardID, accountID: board.accountID,
                                                  reason: "共享权限已变为只读")
            case .revoked, .remotePermissionDenied:
                try store.updateSharedAccess(boardID: board.boardID, accountID: board.accountID, access: .revoked)
                try store.rejectPendingSharedEdits(boardID: board.boardID, accountID: board.accountID,
                                                  reason: "服务端共享访问已撤销", clearCachedContent: true)
            default: break
            }
            throw error
        }
    }

    private func synchronizePass(_ board: SharedBoardDescriptor) async throws -> SyncRunSummary {
        let configuration = try store.sharingConfiguration()
        guard configuration.accountID == board.accountID else { throw SharedBoardError.accountChanged }
        var activeContext: SyncTransferContext?
        var expectedAccessGeneration = try store.synchronized { try store.ownedAccessGeneration(board.namespace) }
        func checkAccount() throws {
            guard try store.sharingConfiguration() == configuration,
                  try store.sharedBoards(accountID: board.accountID).first(where: { $0.descriptor.boardID == board.boardID })?.descriptor == board,
                  try store.synchronized({ try store.ownedAccessGeneration(board.namespace) }) == expectedAccessGeneration else { throw SharedBoardError.accountChanged }
            if let activeContext { try store.validateSyncTransferContext(activeContext) }
        }
        let access: SharedBoardAccess
        do { access = try await transport.access(for: board) } catch { try checkAccount(); throw error }
        try checkAccount()
        try store.updateSharedAccess(boardID: board.boardID, accountID: board.accountID, access: access)
        expectedAccessGeneration = try store.synchronized { try store.ownedAccessGeneration(board.namespace) }
        if !access.canWrite {
            try store.rejectPendingSharedEdits(boardID: board.boardID, accountID: board.accountID,
                                              reason: access == .revoked ? "共享访问已撤销" : "共享权限已变为只读", clearCachedContent: access == .revoked)
            if access == .revoked { throw SharedBoardError.revoked }
        }
        let capable = transport as? any SharedBoardOwnedFileTransport
        let context: SyncTransferContext?
        if let capable {
            let scope: SyncOwnedFileScope
            do { scope = try await capable.ownedFileScope(board: board) } catch { try checkAccount(); throw error }
            try checkAccount(); context = try store.makeSyncTransferContext(scope: scope)
        } else { context = nil }
        activeContext = context
        var downloaded = 0, uploaded = 0, bytes = 0
        var attemptedDownloads = Set<String>()
        func downloadFiles() async throws {
            guard let capable, let context else { return }
            while true {
                let requests = try store.pendingSyncOwnedDownloads(context: context, limit: 100, excluding: attemptedDownloads)
                if requests.isEmpty { return }
                for request in requests {
                    attemptedDownloads.insert(request.transferID)
                    guard request.file.byteCount <= maximumTransferBytes - bytes else { continue }
                    bytes += request.file.byteCount
                    do {
                        let staging = try await capable.downloadOwnedFile(request, board: board)
                        try checkAccount(); try store.validateSyncTransferContext(context)
                        guard staging.descriptor == request.file else { throw SyncError.invalidOperation }
                        try store.acceptSyncOwnedDownload(request, stagedFileURL: staging.fileURL, context: context)
                    } catch {
                        try checkAccount(); try store.validateSyncTransferContext(context)
                        if error is CancellationError || error is SharedBoardError { throw error }
                        try store.failSyncOwnedDownload(request, context: context, error: error.localizedDescription)
                    }
                }
            }
        }
        func download() async throws {
            var batches = 0
            while true {
                try Task.checkCancellation(); try checkAccount()
                let cursor = try store.sharedCursor(boardID: board.boardID, accountID: board.accountID)
                let batch: SyncChangeBatch
                do { batch = try await transport.pull(board: board, after: cursor, limit: 100) } catch { try checkAccount(); throw error }
                try checkAccount()
                try store.applySharedChanges(boardID: board.boardID, accountID: board.accountID, changes: batch.operations, nextCursor: batch.cursor)
                if capable == nil, try store.hasPendingOwnedFileOperations(namespace: board.namespace) { throw SyncError.unavailable("此共享服务不支持托管文件传输，请升级后重试。") }
                downloaded += batch.operations.count; batches += 1
                try await downloadFiles()
                if !batch.hasMore { return }
                guard batches < 1_000, batch.cursor != cursor else { throw SyncError.invalidCursor }
            }
        }
        try await download()
        if access.canWrite {
            var attempted = Set<UUID>()
            while true {
                try Task.checkCancellation(); try checkAccount()
                let pending = try store.pendingSharedOperations(boardID: board.boardID, accountID: board.accountID, limit: 100, excluding: attempted)
                if pending.isEmpty { break }
                for operation in pending {
                    attempted.insert(operation.operationID)
                    var ready = true
                    for file in operation.ownedFiles?.files ?? [] {
                        guard let capable, let context else { throw SyncError.unavailable("此共享服务不支持托管文件传输，请升级后重试。") }
                        if try store.syncOwnedUploadIsComplete(operationID: operation.operationID, file: file, context: context) { continue }
                        guard file.byteCount <= maximumTransferBytes - bytes else { ready = false; continue }
                        bytes += file.byteCount
                        do {
                            let upload = try store.prepareSyncOwnedUpload(operationID: operation.operationID, file: file, context: context)
                            try await capable.uploadOwnedFile(upload, board: board)
                            try checkAccount(); try store.recordSyncOwnedUpload(operationID: operation.operationID, file: file, context: context)
                        } catch {
                            try checkAccount(); try store.validateSyncTransferContext(context, writing: true)
                            if error is CancellationError || error is SharedBoardError { throw error }
                            try store.recordSyncOwnedUpload(operationID: operation.operationID, file: file, context: context, error: error.localizedDescription)
                            ready = false
                        }
                    }
                    if !ready { continue }
                    let acknowledged: Set<UUID>
                    do { acknowledged = try await transport.push([operation], board: board) } catch { try checkAccount(); throw error }
                    try checkAccount()
                    guard acknowledged == [operation.operationID] else { throw SyncError.invalidOperation }
                    try store.acknowledgeSharedOperations(boardID: board.boardID, accountID: board.accountID, operationIDs: acknowledged)
                    uploaded += acknowledged.count
                }
            }
            try await download()
        }
        let states = try context.map { try store.syncOwnedTransferStates(context: $0) } ?? []
        return SyncRunSummary(uploadedOperations: uploaded, downloadedOperations: downloaded,
                              pendingFiles: states.filter { $0.status == .pending }.count,
                              failedFiles: states.filter { $0.status == .failed }.count)
    }
}
