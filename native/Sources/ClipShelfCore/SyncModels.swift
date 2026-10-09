import ClipShelfLocalization
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
    public let formatVersion: Int?
    public let ownedFiles: SyncOwnedFileManifest?

    enum CodingKeys: String, CodingKey { case operationID, accountID, entityID, entityKind, action, baseRevision, revision, baseOperationID, createdAt, record, pinboard, orderingOnly, formatVersion, ownedFiles }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try values.decode(UUID.self, forKey: .operationID)
        accountID = try values.decode(String.self, forKey: .accountID)
        entityID = try values.decode(UUID.self, forKey: .entityID)
        entityKind = try values.decode(SyncEntityKind.self, forKey: .entityKind)
        action = try values.decode(SyncAction.self, forKey: .action)
        baseRevision = try values.decode(Int.self, forKey: .baseRevision)
        revision = try values.decode(Int.self, forKey: .revision)
        baseOperationID = try values.decodeIfPresent(UUID.self, forKey: .baseOperationID)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        record = try values.decodeIfPresent(ClipboardRecord.self, forKey: .record)
        pinboard = try values.decodeIfPresent(Pinboard.self, forKey: .pinboard)
        orderingOnly = try values.decodeIfPresent(Bool.self, forKey: .orderingOnly)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion)
        ownedFiles = try values.decodeIfPresent(SyncOwnedFileManifest.self, forKey: .ownedFiles)
        if let ownedFiles {
            guard formatVersion == 2, entityKind == .clipboard, action == .upsert, let record else { throw SyncError.invalidOperation }
            try ownedFiles.validate(record: record)
        } else if formatVersion != nil && formatVersion != 1 { throw SyncError.invalidOperation }
    }

    public init(operationID: UUID = UUID(), accountID: String, entityID: UUID,
                entityKind: SyncEntityKind, action: SyncAction, baseRevision: Int,
                revision: Int, baseOperationID: UUID? = nil, createdAt: Date = Date(),
                record: ClipboardRecord? = nil, pinboard: Pinboard? = nil, orderingOnly: Bool? = nil,
                formatVersion: Int? = nil, ownedFiles: SyncOwnedFileManifest? = nil) {
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
        self.formatVersion = formatVersion
        self.ownedFiles = ownedFiles
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
        case .disabled: return L10n.text("Synchronization is disabled.")
        case .accountChanged: return L10n.text("The synchronization account changed; this operation was stopped.")
        case .invalidOperation: return L10n.text("The synchronization operation is invalid.")
        case .namespaceConflict: return L10n.text("This item belongs to a different synchronization account.")
        case .invalidCursor: return L10n.text("The synchronization cursor is invalid.")
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
    public let pendingFiles: Int
    public let failedFiles: Int
    public init(uploadedOperations: Int, downloadedOperations: Int, pendingFiles: Int = 0, failedFiles: Int = 0) {
        self.uploadedOperations = uploadedOperations; self.downloadedOperations = downloadedOperations
        self.pendingFiles = pendingFiles; self.failedFiles = failedFiles
    }
}

/// No timers or implicit enablement: the application invokes this only after explicit opt-in.
public actor SyncCoordinator {
    private let store: HistoryStore
    private let transport: any SyncTransport
    private let maximumTransferBytes: Int
    private var running = false
    public init(store: HistoryStore, transport: any SyncTransport, maximumTransferBytes: Int = SyncOwnedFileLimits.maximumPassBytes) {
        self.maximumTransferBytes = max(0, min(maximumTransferBytes, SyncOwnedFileLimits.maximumPassBytes))
        self.store = store
        self.transport = transport
    }

    public func synchronize(accountID: String) async throws -> SyncRunSummary {
        guard !running else { throw SyncError.unavailable(L10n.text("A synchronization pass is already running.")) }
        running = true; defer { running = false }
        let configuration = try store.syncConfiguration()
        guard configuration.accountID == accountID else { throw SyncError.accountChanged }
        var activeContext: SyncTransferContext?
        func checkAccount() throws {
            guard try store.syncConfiguration() == configuration else { throw SyncError.accountChanged }
            if let activeContext { try store.validateSyncTransferContext(activeContext) }
        }
        let capable = transport as? any SyncOwnedFileTransport
        let context: SyncTransferContext?
        if let capable {
            let scope: SyncOwnedFileScope
            do { scope = try await capable.ownedFileScope(accountID: accountID) }
            catch { try checkAccount(); throw error }
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
                        let staging = try await capable.downloadOwnedFile(request)
                        try checkAccount(); try store.validateSyncTransferContext(context)
                        guard staging.descriptor == request.file else { throw SyncError.invalidOperation }
                        try store.acceptSyncOwnedDownload(request, stagedFileURL: staging.fileURL, context: context)
                    } catch {
                        try checkAccount(); try store.validateSyncTransferContext(context)
                        if error is CancellationError { throw error }
                        try store.failSyncOwnedDownload(request, context: context, error: error.localizedDescription)
                    }
                }
            }
        }
        func download() async throws {
            var batches = 0
            while true {
                try Task.checkCancellation(); try checkAccount()
                let cursor = try store.syncCursor(accountID: accountID)
                let batch: SyncChangeBatch
                do { batch = try await transport.pull(accountID: accountID, after: cursor, limit: 100) }
                catch { try checkAccount(); throw error }
                try checkAccount()
                try store.applyRemoteChanges(accountID: accountID, changes: batch.operations, nextCursor: batch.cursor)
                if capable == nil, try store.hasPendingOwnedFileOperations(namespace: accountID) { throw SyncError.unavailable(L10n.text("此同步服务不支持托管文件传输，请升级后重试。")) }
                downloaded += batch.operations.count; batches += 1
                try await downloadFiles()
                if !batch.hasMore { break }
                guard batches < 1_000, batch.cursor != cursor else { throw SyncError.invalidCursor }
            }
        }
        try await download()
        var attempted = Set<UUID>()
        while true {
            try Task.checkCancellation(); try checkAccount()
            let pending = try store.pendingSyncOperations(accountID: accountID, limit: 100, excluding: attempted)
            if pending.isEmpty { break }
            for operation in pending {
                attempted.insert(operation.operationID)
                var ready = true
                for file in operation.ownedFiles?.files ?? [] {
                    guard let capable, let context else { throw SyncError.unavailable(L10n.text("此同步服务不支持托管文件传输，请升级后重试。")) }
                    if try store.syncOwnedUploadIsComplete(operationID: operation.operationID, file: file, context: context) { continue }
                    guard file.byteCount <= maximumTransferBytes - bytes else { ready = false; continue }
                    bytes += file.byteCount
                    do {
                        let upload = try store.prepareSyncOwnedUpload(operationID: operation.operationID, file: file, context: context)
                        try await capable.uploadOwnedFile(upload)
                        try checkAccount(); try store.recordSyncOwnedUpload(operationID: operation.operationID, file: file, context: context)
                    } catch {
                        try checkAccount(); try store.validateSyncTransferContext(context, writing: true)
                        if error is CancellationError { throw error }
                        try store.recordSyncOwnedUpload(operationID: operation.operationID, file: file, context: context, error: error.localizedDescription)
                        ready = false
                    }
                }
                if !ready { continue }
                let acknowledged: Set<UUID>
                do { acknowledged = try await transport.push([operation], accountID: accountID) }
                catch { try checkAccount(); throw error }
                try checkAccount()
                guard acknowledged == [operation.operationID] else { throw SyncError.invalidOperation }
                try store.acknowledgeSyncOperations(accountID: accountID, operationIDs: acknowledged)
                uploaded += acknowledged.count
            }
        }
        try await download()
        let states = try context.map { try store.syncOwnedTransferStates(context: $0) } ?? []
        return SyncRunSummary(uploadedOperations: uploaded, downloadedOperations: downloaded,
                              pendingFiles: states.filter { $0.status == .pending }.count,
                              failedFiles: states.filter { $0.status == .failed }.count)
    }
}
