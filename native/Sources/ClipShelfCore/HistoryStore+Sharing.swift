import ClipShelfLocalization
import CSQLite
import Foundation

extension HistoryStore {
    public func configureSharing(accountID: String?) throws {
        if let accountID { guard !accountID.isEmpty, !accountID.hasPrefix("shared:"), accountID.utf8.count <= 512 else { throw SyncError.invalidOperation } }
        try synchronized {
            try transaction { try syncExecute("UPDATE shared_configuration SET account_id = ?, generation = generation + 1 WHERE singleton = 1", [accountID]) }
        }
    }

    public func sharingConfiguration() throws -> SyncConfiguration {
        try synchronized { try sharingConfigurationWithoutLock() }
    }

    public func sharedBoards(accountID: String) throws -> [SharedBoardState] {
        try synchronized {
            try requireSharingAccount(accountID)
            let statement = try prepare("SELECT descriptor, access FROM shared_boards WHERE account_id = ? ORDER BY rowid")
            defer { sqlite3_finalize(statement) }
            try bind(accountID, at: 1, to: statement)
            var boards: [SharedBoardState] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return boards }
                try check(status, allowingRow: true)
                boards.append(try decodeSharedState(statement))
            }
        }
    }

    public func registerSharedBoard(_ descriptor: SharedBoardDescriptor, access: SharedBoardAccess) throws {
        try synchronized {
            try requireSharingAccount(descriptor.accountID)
            try transaction { try registerSharedBoardWithoutLock(descriptor, access: access) }
        }
    }

    /// Sharing starts from a distinct copy, so private history IDs and account ownership never silently change.
    @discardableResult
    public func createSharedCopy(from sourceBoardID: UUID, descriptor: SharedBoardDescriptor) throws -> Pinboard {
        try synchronized {
            try requireSharingAccount(descriptor.accountID)
            guard sourceBoardID != descriptor.boardID else { throw SyncError.namespaceConflict }
            return try transaction {
                guard var board = try pinboardsWithoutLock().first(where: { $0.id == sourceBoardID }) else { throw HistoryStoreError.pinboardNotFound }
                guard !(try pinboardsWithoutLock().contains { $0.id == descriptor.boardID }) else { throw SyncError.namespaceConflict }
                let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records WHERE pinboard_id = ? ORDER BY local_history_order")
                defer { sqlite3_finalize(statement) }
                try bind(sourceBoardID.uuidString, at: 1, to: statement)
                let contents = try readRecords(statement)
                try registerSharedBoardWithoutLock(descriptor, access: .owner)
                board.id = descriptor.boardID
                board.name = String(board.name.prefix(180)) + L10n.text(" (共享)")
                try setSyncNamespace(kind: .pinboard, id: board.id, accountID: descriptor.namespace)
                try savePinboard(board, replace: false)
                for var record in contents {
                    let originalID = record.id
                    record.pinboardOrderIdentity = record.pinboardOrderIdentity ?? record.id
                    record.id = UUID()
                    record.pinboardID = board.id
                    record.isInHistory = false
                    record.revision = 1
                    try setSyncNamespace(kind: .clipboard, id: record.id, accountID: descriptor.namespace)
                    try insert(record)
                    try copyOwnedFileBindingsWithoutLock(from: originalID, to: record)
                }
                return board
            }
        }
    }

    public func updateSharedAccess(boardID: UUID, accountID: String, access: SharedBoardAccess) throws {
        try synchronized {
            _ = try requireSharedBoard(boardID: boardID, accountID: accountID)
            try transaction {
                let namespace = "shared:" + boardID.uuidString
                if try sharedStateForNamespace(namespace)?.access != access {
                    try syncExecute("INSERT INTO owned_sync_access(namespace,generation) VALUES (?,1) ON CONFLICT(namespace) DO UPDATE SET generation=generation+1", [namespace])
                }
                try syncExecute("UPDATE shared_boards SET access = ? WHERE board_id = ? AND account_id = ?", [access.rawValue, boardID.uuidString, accountID])
            }
        }
    }

    public func pendingSharedOperations(boardID: UUID, accountID: String, limit: Int = 100, excluding: Set<UUID> = []) throws -> [SyncOperation] {
        try synchronized {
            let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
            guard state.access.canWrite else { throw state.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
            let exclusions = excluding.map { "'" + $0.uuidString + "'" }.joined(separator: ",")
            let statement = try prepare("SELECT payload FROM sync_outbox WHERE account_id = ?" + (excluding.isEmpty ? "" : " AND operation_id NOT IN (" + exclusions + ")") + " ORDER BY rowid LIMIT ?")
            defer { sqlite3_finalize(statement) }
            try bind(state.descriptor.namespace, at: 1, to: statement)
            try check(sqlite3_bind_int64(statement, 2, Int64(max(0, min(1_000, limit)))))
            return try syncReadOperations(statement)
        }
    }

    public func acknowledgeSharedOperations(boardID: UUID, accountID: String, operationIDs: Set<UUID>) throws {
        try synchronized {
            let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
            try transaction {
                for id in operationIDs {
                    let statement = try prepare("""
                        SELECT length(o.payload), a.namespace, a.payload = o.payload
                        FROM sync_outbox o LEFT JOIN shared_accepted_operations a ON a.operation_id = o.operation_id
                        WHERE o.account_id = ? AND o.operation_id = ?
                        """)
                    defer { sqlite3_finalize(statement) }
                    try bind(state.descriptor.namespace, at: 1, to: statement)
                    try bind(id.uuidString, at: 2, to: statement)
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { continue }
                    try check(status, allowingRow: true)
                    if let namespace = textColumn(statement, 1) {
                        guard namespace == state.descriptor.namespace else { throw SyncError.namespaceConflict }
                        guard sqlite3_column_int(statement, 2) == 1 else { throw SyncError.invalidOperation }
                        // The exact accepted copy already exists; only queue cleanup remains.
                    } else {
                        let byteCount = sqlite3_column_int64(statement, 0)
                        try reserveSyncPayloadWithoutLock(byteCount: byteCount, retiringByteCount: byteCount)
                        try syncExecute("INSERT INTO shared_accepted_operations(operation_id, namespace, payload) SELECT operation_id, account_id, payload FROM sync_outbox WHERE account_id = ? AND operation_id = ?", [state.descriptor.namespace, id.uuidString])
                    }
                    try syncExecute("DELETE FROM sync_outbox WHERE account_id = ? AND operation_id = ?", [state.descriptor.namespace, id.uuidString])
                }
            }
        }
    }

    public func sharedCursor(boardID: UUID, accountID: String) throws -> Data? {
        try synchronized {
            let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
            let statement = try prepare("SELECT cursor FROM sync_cursors WHERE account_id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(state.descriptor.namespace, at: 1, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            try check(status, allowingRow: true)
            return dataColumn(statement, 0)
        }
    }

    public func applySharedChanges(boardID: UUID, accountID: String, changes: [SyncOperation], nextCursor: Data?) throws {
        try synchronized {
            let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
            guard state.access != .revoked else { throw SharedBoardError.revoked }
            for operation in changes {
                try validateSyncOperation(operation, accountID: state.descriptor.namespace)
                if operation.entityKind == .pinboard, operation.entityID != boardID { throw SyncError.namespaceConflict }
                if let record = operation.record, record.pinboardID != boardID { throw SyncError.namespaceConflict }
                let existing = try syncNamespace(kind: operation.entityKind, id: operation.entityID)
                if let existing, existing != state.descriptor.namespace { throw SyncError.namespaceConflict }
                if existing == nil {
                    if operation.entityKind == .clipboard, try itemWithoutLock(id: operation.entityID) != nil { throw SyncError.namespaceConflict }
                    if operation.entityKind == .pinboard, try pinboardsWithoutLock().contains(where: { $0.id == operation.entityID }) { throw SyncError.namespaceConflict }
                }
            }
            try applyRemoteBatch(accountID: state.descriptor.namespace, changes: changes, nextCursor: nextCursor)
        }
    }

    /// A rejected edit is durable, but is removed from the queue and cannot become a future causal parent.
    public func rejectPendingSharedEdits(boardID: UUID, accountID: String, reason: String, clearCachedContent: Bool = false) throws {
        try synchronized {
            let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
            suppressSyncCapture = true
            defer { suppressSyncCapture = false }
            try transaction(allowReclamation: true) {
                let query = try prepare("SELECT payload FROM sync_outbox WHERE account_id = ? ORDER BY rowid")
                try bind(state.descriptor.namespace, at: 1, to: query)
                let operations: [SyncOperation]
                do { operations = try syncReadOperations(query) } catch { sqlite3_finalize(query); throw error }
                sqlite3_finalize(query)
                for operation in operations {
                    let draft = FailedSharedDraft(operation: operation, reason: String(reason.prefix(1_000)), failedAt: Date())
                    let statement = try prepare("INSERT OR IGNORE INTO shared_failed_drafts(operation_id, namespace, account_id, payload) VALUES (?, ?, ?, ?)")
                    defer { sqlite3_finalize(statement) }
                    try bind(operation.operationID.uuidString, at: 1, to: statement)
                    try bind(state.descriptor.namespace, at: 2, to: statement)
                    try bind(accountID, at: 3, to: statement)
                    try bind(try JSONEncoder().encode(draft), at: 4, to: statement)
                    try stepToCompletion(statement)
                }
                try syncExecute("DELETE FROM owned_sync_transfers WHERE direction='upload' AND operation_id IN (SELECT operation_id FROM sync_outbox WHERE account_id=?)", [state.descriptor.namespace])
                try syncExecute("DELETE FROM sync_outbox WHERE account_id = ?", [state.descriptor.namespace])
                if !operations.isEmpty || clearCachedContent {
                    // Rebuild accepted content locally so a downgrade remains readable even while offline.
                    let personalPosition = try syncScalar("SELECT CAST(position AS TEXT) FROM pinboard_local_order WHERE board_id = ?", [boardID.uuidString])
                    try syncExecute("DELETE FROM owned_sync_transfers WHERE direction='download' AND operation_id IN (SELECT operation_id FROM sync_inbox WHERE account_id=?)", [state.descriptor.namespace])
                    for table in ["sync_inbox", "sync_heads", "sync_content_heads", "sync_order_heads", "sync_log", "sync_tombstones", "sync_cursors"] {
                        try syncExecute("DELETE FROM \(table) WHERE account_id = ?", [state.descriptor.namespace])
                    }
                    try syncExecute("DELETE FROM clipboard_records WHERE id IN (SELECT entity_id FROM sync_namespaces WHERE entity_kind = 'clipboard' AND account_id = ?)", [state.descriptor.namespace])
                    try syncExecute("DELETE FROM pinboards WHERE id IN (SELECT entity_id FROM sync_namespaces WHERE entity_kind = 'pinboard' AND account_id = ?)", [state.descriptor.namespace])
                    if clearCachedContent {
                        try syncExecute("DELETE FROM shared_accepted_operations WHERE namespace = ?", [state.descriptor.namespace])
                    } else {
                        try syncExecute("INSERT OR IGNORE INTO sync_inbox(operation_id, account_id, payload) SELECT operation_id, namespace, payload FROM shared_accepted_operations WHERE namespace = ?", [state.descriptor.namespace])
                        try drainSyncInbox(accountID: state.descriptor.namespace)
                        // Only accepted operations created locally have an ownership snapshot.
                        // Rebuilding a cache must not erase that proof or infer it from remote URLs.
                        let accepted = try prepare("SELECT payload FROM shared_accepted_operations WHERE namespace = ? ORDER BY rowid")
                        defer { sqlite3_finalize(accepted) }
                        try bind(state.descriptor.namespace, at: 1, to: accepted)
                        for operation in try syncReadOperations(accepted) {
                            guard operation.ownedFiles == nil, let original = operation.record,
                                  let current = try itemWithoutLock(id: original.id) else { continue }
                            let prior = try rebasingOwnedFileOperationRecordWithoutLock(operationID: operation.operationID, record: original)
                            if current.parts == original.parts || current.parts == prior.parts {
                                var rebound = current
                                rebound.parts = prior.parts
                                if rebound.parts != current.parts { try replaceContents(rebound) }
                                try restoreOwnedFileOperationBindingsWithoutLock(operationID: operation.operationID, record: rebound)
                            }
                        }
                        if let personalPosition, try pinboardsWithoutLock().contains(where: { $0.id == boardID }) {
                            try syncExecute("INSERT INTO pinboard_local_order(board_id, position) VALUES (?, ?)", [boardID.uuidString, personalPosition])
                        }
                    }
                }
            }
        }
    }

    public func failedSharedDrafts(boardID: UUID, accountID: String) throws -> [FailedSharedDraft] {
        try synchronized {
            let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
            let statement = try prepare("SELECT payload FROM shared_failed_drafts WHERE namespace = ? AND account_id = ? ORDER BY rowid DESC")
            defer { sqlite3_finalize(statement) }
            try bind(state.descriptor.namespace, at: 1, to: statement); try bind(accountID, at: 2, to: statement)
            var drafts: [FailedSharedDraft] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return drafts }
                try check(status, allowingRow: true)
                guard let data = dataColumn(statement, 0) else { throw SyncError.invalidOperation }
                drafts.append(try JSONDecoder().decode(FailedSharedDraft.self, from: data))
            }
        }
    }

    /// Recover a rejected item as a new local history item; it is never automatically resent to the shared board.
    @discardableResult
    public func recoverFailedSharedDraft(operationID: UUID, boardID: UUID, accountID: String) throws -> ClipboardRecord {
        try synchronized {
            try transaction {
                let state = try requireSharedBoard(boardID: boardID, accountID: accountID)
                let statement = try prepare("SELECT payload FROM shared_failed_drafts WHERE operation_id = ? AND namespace = ? AND account_id = ?")
                defer { sqlite3_finalize(statement) }
                try bind(operationID.uuidString, at: 1, to: statement)
                try bind(state.descriptor.namespace, at: 2, to: statement)
                try bind(accountID, at: 3, to: statement)
                let status = sqlite3_step(statement)
                guard status != SQLITE_DONE else { throw HistoryStoreError.recordNotFound }
                try check(status, allowingRow: true)
                guard let data = dataColumn(statement, 0),
                      var record = try JSONDecoder().decode(FailedSharedDraft.self, from: data).operation.record else { throw HistoryStoreError.recordNotFound }
                let draftOperation = try JSONDecoder().decode(FailedSharedDraft.self, from: data).operation
                if draftOperation.ownedFiles != nil {
                    guard let local = try materializedOwnedOperation(draftOperation)?.record else { throw HistoryStoreError.corruptOwnedFile }
                    record = local
                } else { record = try rebasingOwnedFileOperationRecordWithoutLock(operationID: operationID, record: record) }
                record.id = UUID(); record.pinboardID = nil; record.pinboardOrder = nil; record.isInHistory = true; record.revision = 1
                try markSyncLocalOnly(kind: .clipboard, id: record.id)
                try insert(record)
                try syncExecute("INSERT INTO owned_sync_local_recovery(record_id) VALUES (?)", [record.id.uuidString])
                try restoreOwnedFileOperationBindingsWithoutLock(operationID: operationID, record: record)
                return record
            }
        }
    }

    @discardableResult
    public func copyBoardToLocal(boardID: UUID, nameSuffix: String = L10n.text(" (本地副本)")) throws -> Pinboard {
        try synchronized {
            try transaction {
                guard var board = try pinboardsWithoutLock().first(where: { $0.id == boardID }) else { throw HistoryStoreError.pinboardNotFound }
                let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records WHERE pinboard_id = ? ORDER BY local_history_order")
                defer { sqlite3_finalize(statement) }
                try bind(boardID.uuidString, at: 1, to: statement)
                let contents = try readRecords(statement)
                board.id = UUID(); board.name = String(board.name.prefix(150)) + String(nameSuffix.prefix(40))
                try savePinboard(board, replace: false)
                for var record in contents {
                    let originalID = record.id
                    record.pinboardOrderIdentity = record.pinboardOrderIdentity ?? record.id
                    record.id = UUID(); record.pinboardID = board.id; record.isInHistory = false; record.revision = 1
                    try insert(record)
                    try copyOwnedFileBindingsWithoutLock(from: originalID, to: record)
                }
                return board
            }
        }
    }

    func createSharingSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS shared_configuration(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), account_id TEXT, generation INTEGER NOT NULL DEFAULT 0);
            INSERT OR IGNORE INTO shared_configuration(singleton) VALUES(1);
            CREATE TABLE IF NOT EXISTS shared_boards(board_id TEXT PRIMARY KEY, namespace TEXT NOT NULL UNIQUE, account_id TEXT NOT NULL, descriptor BLOB NOT NULL, access TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_failed_drafts(operation_id TEXT PRIMARY KEY, namespace TEXT NOT NULL, account_id TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS shared_accepted_operations(operation_id TEXT PRIMARY KEY, namespace TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS shared_accepted_namespace ON shared_accepted_operations(namespace);
            """)
    }

    func rememberAcceptedSharedOperation(_ operation: SyncOperation) throws {
        if let namespace = try syncScalar("SELECT namespace FROM shared_accepted_operations WHERE operation_id = ?", [operation.operationID.uuidString]) {
            guard namespace == operation.accountID else { throw SyncError.namespaceConflict }
            return
        }
        let payload = try JSONEncoder().encode(operation)
        try reserveSyncPayloadWithoutLock(payload)
        let statement = try prepare("INSERT OR IGNORE INTO shared_accepted_operations(operation_id, namespace, payload) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(operation.operationID.uuidString, at: 1, to: statement)
        try bind(operation.accountID, at: 2, to: statement)
        try bind(payload, at: 3, to: statement)
        try stepToCompletion(statement)
    }

    func sharingConfigurationWithoutLock() throws -> SyncConfiguration {
        let statement = try prepare("SELECT account_id, generation FROM shared_configuration WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), allowingRow: true)
        return SyncConfiguration(accountID: textColumn(statement, 0), generation: sqlite3_column_int64(statement, 1))
    }

    func requireSharingAccount(_ accountID: String) throws {
        guard try sharingConfigurationWithoutLock().accountID == accountID else { throw SharedBoardError.accountChanged }
    }

    func requireSharedBoard(boardID: UUID, accountID: String) throws -> SharedBoardState {
        try requireSharingAccount(accountID)
        guard let state = try sharedStateForNamespace("shared:" + boardID.uuidString), state.descriptor.accountID == accountID else {
            throw SharedBoardError.notRegistered
        }
        return state
    }

    func sharedStateForNamespace(_ namespace: String) throws -> SharedBoardState? {
        let statement = try prepare("SELECT descriptor, access FROM shared_boards WHERE namespace = ?")
        defer { sqlite3_finalize(statement) }
        try bind(namespace, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        try check(status, allowingRow: true)
        return try decodeSharedState(statement)
    }

    func decodeSharedState(_ statement: OpaquePointer) throws -> SharedBoardState {
        guard let data = dataColumn(statement, 0), let access = textColumn(statement, 1).flatMap(SharedBoardAccess.init(rawValue:)) else {
            throw SyncError.invalidOperation
        }
        return SharedBoardState(descriptor: try JSONDecoder().decode(SharedBoardDescriptor.self, from: data), access: access)
    }

    func registerSharedBoardWithoutLock(_ descriptor: SharedBoardDescriptor, access: SharedBoardAccess) throws {
        guard descriptor.containerIdentifier.hasPrefix("iCloud."), !descriptor.zoneName.isEmpty,
              !descriptor.zoneOwnerName.isEmpty, !descriptor.shareRecordName.isEmpty else { throw SyncError.invalidOperation }
        if let existing = try sharedStateForNamespace(descriptor.namespace), existing.descriptor.accountID != descriptor.accountID {
            throw SharedBoardError.accountChanged
        }
        try syncExecute("INSERT INTO owned_sync_access(namespace,generation) VALUES (?,1) ON CONFLICT(namespace) DO UPDATE SET generation=generation+1", [descriptor.namespace])
        let statement = try prepare("INSERT INTO shared_boards(board_id, namespace, account_id, descriptor, access) VALUES (?, ?, ?, ?, ?) ON CONFLICT(board_id) DO UPDATE SET descriptor = excluded.descriptor, access = excluded.access")
        defer { sqlite3_finalize(statement) }
        try bind(descriptor.boardID.uuidString, at: 1, to: statement)
        try bind(descriptor.namespace, at: 2, to: statement)
        try bind(descriptor.accountID, at: 3, to: statement)
        try bind(try JSONEncoder().encode(descriptor), at: 4, to: statement)
        try bind(access.rawValue, at: 5, to: statement)
        try stepToCompletion(statement)
    }
}
