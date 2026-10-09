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
    private var running = Set<UUID>()
    public init(store: HistoryStore, transport: any SharedBoardTransport) { self.store = store; self.transport = transport }

    public func synchronize(_ board: SharedBoardDescriptor) async throws -> SyncRunSummary {
        guard running.insert(board.boardID).inserted else { throw SyncError.unavailable("此共享板正在同步。") }
        defer { running.remove(board.boardID) }
        do {
            return try await synchronizePass(board)
        } catch let error as SharedBoardError {
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
        func checkAccount() throws {
            guard try store.sharingConfiguration() == configuration else { throw SharedBoardError.accountChanged }
        }
        let access = try await transport.access(for: board)
        try checkAccount()
        try store.updateSharedAccess(boardID: board.boardID, accountID: board.accountID, access: access)
        if !access.canWrite {
            try store.rejectPendingSharedEdits(boardID: board.boardID, accountID: board.accountID,
                                              reason: access == .revoked ? "共享访问已撤销" : "共享权限已变为只读", clearCachedContent: access == .revoked)
            if access == .revoked { throw SharedBoardError.revoked }
        }
        var downloaded = 0, uploaded = 0
        func download() async throws {
            var batches = 0
            while true {
                try Task.checkCancellation(); try checkAccount()
                let cursor = try store.sharedCursor(boardID: board.boardID, accountID: board.accountID)
                let batch = try await transport.pull(board: board, after: cursor, limit: 100)
                try checkAccount()
                try store.applySharedChanges(boardID: board.boardID, accountID: board.accountID, changes: batch.operations, nextCursor: batch.cursor)
                downloaded += batch.operations.count
                batches += 1
                if !batch.hasMore { return }
                guard batches < 1_000, batch.cursor != cursor else { throw SyncError.invalidCursor }
            }
        }
        try await download()
        if access.canWrite {
            while true {
                try Task.checkCancellation(); try checkAccount()
                let pending = try store.pendingSharedOperations(boardID: board.boardID, accountID: board.accountID, limit: 100)
                if pending.isEmpty { break }
                do {
                    let acknowledged = try await transport.push(pending, board: board)
                    try checkAccount()
                    guard !acknowledged.isEmpty, acknowledged.isSubset(of: Set(pending.map(\.operationID))) else { throw SyncError.invalidOperation }
                    try store.acknowledgeSharedOperations(boardID: board.boardID, accountID: board.accountID, operationIDs: acknowledged)
                    uploaded += acknowledged.count
                } catch SharedBoardError.remotePermissionDenied {
                    try store.updateSharedAccess(boardID: board.boardID, accountID: board.accountID, access: .revoked)
                    try store.rejectPendingSharedEdits(boardID: board.boardID, accountID: board.accountID,
                                                      reason: "服务端已拒绝离线修改", clearCachedContent: true)
                    throw SharedBoardError.remotePermissionDenied
                }
            }
            try await download()
        }
        return SyncRunSummary(uploadedOperations: uploaded, downloadedOperations: downloaded)
    }
}
