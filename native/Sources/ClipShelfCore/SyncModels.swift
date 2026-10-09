import Foundation

public enum SyncEntityKind: String, Codable, Sendable { case clipboard, pinboard }
public enum SyncAction: String, Codable, Sendable { case upsert, delete }

/// Immutable operations make retries idempotent. Their IDs are generated inside the local write transaction.
public struct SyncOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let accountID: String
    public let entityID: UUID
    public let entityKind: SyncEntityKind
    public let action: SyncAction
    public let baseRevision: Int
    public let revision: Int
    public let baseOperationID: UUID?
    public let createdAt: Date
    public let record: ClipboardRecord?
    public let pinboard: Pinboard?
    /// True for position-only edits. Older peers omit this field and remain full-content operations.
    public let orderingOnly: Bool?

    public init(operationID: UUID = UUID(), accountID: String, entityID: UUID,
                entityKind: SyncEntityKind, action: SyncAction, baseRevision: Int,
                revision: Int, baseOperationID: UUID? = nil, createdAt: Date = Date(),
                record: ClipboardRecord? = nil, pinboard: Pinboard? = nil, orderingOnly: Bool? = nil) {
        self.operationID = operationID
        self.accountID = accountID
        self.entityID = entityID
        self.entityKind = entityKind
        self.action = action
        self.baseRevision = baseRevision
        self.revision = revision
        self.baseOperationID = baseOperationID
        self.createdAt = createdAt
        self.record = record
        self.pinboard = pinboard
        self.orderingOnly = orderingOnly
    }
}

public struct SyncChangeBatch: Sendable {
    public let operations: [SyncOperation]
    public let cursor: Data?
    public let hasMore: Bool
    public init(operations: [SyncOperation], cursor: Data?, hasMore: Bool = false) {
        self.operations = operations
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public struct SyncConfiguration: Equatable, Sendable {
    public let accountID: String?
    public let generation: Int64
}

public enum SyncError: Error, LocalizedError {
    case disabled, accountChanged, invalidOperation, namespaceConflict, invalidCursor
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .disabled: return "Synchronization is disabled."
        case .accountChanged: return "The synchronization account changed; this operation was stopped."
        case .invalidOperation: return "The synchronization operation is invalid."
        case .namespaceConflict: return "This item belongs to a different synchronization account."
        case .invalidCursor: return "The synchronization cursor is invalid."
        case .unavailable(let reason): return reason
        }
    }
}

public protocol SyncTransport: Sendable {
    func push(_ operations: [SyncOperation], accountID: String) async throws -> Set<UUID>
    func pull(accountID: String, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch
}

public struct SyncRunSummary: Sendable {
    public let uploadedOperations: Int
    public let downloadedOperations: Int
}

/// No timers or implicit enablement: the application invokes this only after explicit opt-in.
public actor SyncCoordinator {
    private let store: HistoryStore
    private let transport: any SyncTransport
    private var running = false
    public init(store: HistoryStore, transport: any SyncTransport) {
        self.store = store
        self.transport = transport
    }

    public func synchronize(accountID: String) async throws -> SyncRunSummary {
        guard !running else { throw SyncError.unavailable("A synchronization pass is already running.") }
        running = true
        defer { running = false }
        let configuration = try store.syncConfiguration()
        guard configuration.accountID == accountID else { throw SyncError.accountChanged }
        var downloaded = 0
        var uploaded = 0
        func checkAccount() throws {
            guard try store.syncConfiguration() == configuration else { throw SyncError.accountChanged }
        }
        func download() async throws {
            var batches = 0
            while true {
                try Task.checkCancellation()
                try checkAccount()
                let cursor = try store.syncCursor(accountID: accountID)
                let batch = try await transport.pull(accountID: accountID, after: cursor, limit: 100)
                try checkAccount()
                try store.applyRemoteChanges(accountID: accountID, changes: batch.operations, nextCursor: batch.cursor)
                downloaded += batch.operations.count
                batches += 1
                if !batch.hasMore { break }
                guard batches < 1_000, batch.cursor != cursor else { throw SyncError.invalidCursor }
            }
        }
        try await download()
        while true {
            try Task.checkCancellation()
            try checkAccount()
            let pending = try store.pendingSyncOperations(accountID: accountID, limit: 100)
            if pending.isEmpty { break }
            let acknowledged = try await transport.push(pending, accountID: accountID)
            try checkAccount()
            guard !acknowledged.isEmpty, acknowledged.isSubset(of: Set(pending.map(\.operationID))) else {
                throw SyncError.invalidOperation
            }
            try store.acknowledgeSyncOperations(accountID: accountID, operationIDs: acknowledged)
            uploaded += acknowledged.count
        }
        try await download()
        return SyncRunSummary(uploadedOperations: uploaded, downloadedOperations: downloaded)
    }
}
