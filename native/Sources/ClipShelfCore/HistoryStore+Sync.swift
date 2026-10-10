import CSQLite
import Foundation

extension HistoryStore {
    public func syncConfiguration() throws -> SyncConfiguration {
        try synchronized { try syncConfigurationWithoutLock() }
    }

    /// Existing account-owned entities are never reassigned when the account changes.
    public func configureSync(accountID: String?, includeLocalData: Bool = false) throws {
        if let accountID { guard !accountID.isEmpty, !accountID.hasPrefix("shared:"), accountID.utf8.count <= 512 else { throw SyncError.invalidOperation } }
        try synchronized {
            try transaction {
                try syncExecute("UPDATE sync_configuration SET account_id = ?, generation = generation + 1 WHERE singleton = 1", [accountID])
                if accountID != nil, includeLocalData {
                    // This flag represents an explicit upload choice, not ordinary enable/restart.
                    try execute("DELETE FROM sync_local_only WHERE entity_kind != 'clipboard' OR entity_id NOT IN (SELECT record_id FROM owned_sync_local_recovery)")
                    for (table, kind) in [("pinboards", "pinboard"), ("clipboard_records", "clipboard")] {
                        try execute("""
                            INSERT INTO sync_dirty (entity_kind, entity_id, action)
                            SELECT '\(kind)', id, 'upsert' FROM \(table)
                            WHERE NOT EXISTS (SELECT 1 FROM sync_namespaces WHERE entity_kind = '\(kind)' AND entity_id = \(table).id)
                            ON CONFLICT(entity_kind, entity_id) DO UPDATE SET action = 'upsert'
                            """)
                    }
                }
            }
        }
    }

    public func pendingSyncOperations(accountID: String, limit: Int = 100, excluding: Set<UUID> = []) throws -> [SyncOperation] {
        try synchronized {
            try requireSyncAccount(accountID)
            let exclusions = excluding.map { "'" + $0.uuidString + "'" }.joined(separator: ",")
            let statement = try prepare("SELECT payload FROM sync_outbox WHERE account_id = ?" + (excluding.isEmpty ? "" : " AND operation_id NOT IN (" + exclusions + ")") + " ORDER BY rowid LIMIT ?")
            defer { sqlite3_finalize(statement) }
            try bind(accountID, at: 1, to: statement)
            try check(sqlite3_bind_int64(statement, 2, Int64(clamping: max(0, min(limit, 1_000)))))
            return try syncReadOperations(statement)
        }
    }

    public func acknowledgeSyncOperations(accountID: String, operationIDs: Set<UUID>) throws {
        try synchronized {
            try transaction {
                try requireSyncAccount(accountID)
                for id in operationIDs {
                    try syncExecute("DELETE FROM sync_outbox WHERE account_id = ? AND operation_id = ?", [accountID, id.uuidString])
                }
            }
        }
    }

    public func syncCursor(accountID: String) throws -> Data? {
        try synchronized {
            try requireSyncAccount(accountID)
            let statement = try prepare("SELECT cursor FROM sync_cursors WHERE account_id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(accountID, at: 1, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            try check(status, allowingRow: true)
            return dataColumn(statement, 0)
        }
    }

    /// Applies remote mutations and their cursor atomically. Missing causal parents remain in a durable inbox.
    public func applyRemoteChanges(accountID: String, changes: [SyncOperation], nextCursor: Data?) throws {
        try synchronized {
            try requireSyncAccount(accountID)
            try applyRemoteBatch(accountID: accountID, changes: changes, nextCursor: nextCursor)
        }
    }

    func applyRemoteBatch(accountID: String, changes: [SyncOperation], nextCursor: Data?) throws {
        for operation in changes { try validateSyncOperation(operation, accountID: accountID) }
            suppressSyncCapture = true
            defer { suppressSyncCapture = false }
            try transaction {
                for operation in changes {
                    for table in ["sync_log", "sync_inbox", "sync_outbox"] {
                        if let existing = try syncScalar("SELECT account_id FROM \(table) WHERE operation_id=?", [operation.operationID.uuidString]), existing != accountID { throw SyncError.namespaceConflict }
                    }
                    if accountID.hasPrefix("shared:") { try rememberAcceptedSharedOperation(operation) }
                    if try syncLogContains(accountID: accountID, id: operation.operationID) { continue }
                    if try syncScalar("SELECT operation_id FROM sync_inbox WHERE operation_id = ?", [operation.operationID.uuidString]) != nil { continue }
                    let payload = try JSONEncoder().encode(operation)
                    // Missing causal parents or owned-file dependencies may leave this operation
                    // in the inbox without ever reaching record binding during this transaction.
                    try reserveSyncPayloadWithoutLock(payload)
                    let statement = try prepare("INSERT OR IGNORE INTO sync_inbox (operation_id, account_id, payload) VALUES (?, ?, ?)")
                    defer { sqlite3_finalize(statement) }
                    try bind(operation.operationID.uuidString, at: 1, to: statement)
                    try bind(accountID, at: 2, to: statement)
                    try bind(payload, at: 3, to: statement)
                    try stepToCompletion(statement)
                }
                if let scope = try ownedScopeWithoutLock(namespace: accountID) { try registerOwnedPendingDependencies(scope: scope) }
                try drainSyncInbox(accountID: accountID)
                let cursor = try prepare("INSERT INTO sync_cursors (account_id, cursor) VALUES (?, ?) ON CONFLICT(account_id) DO UPDATE SET cursor = excluded.cursor")
                defer { sqlite3_finalize(cursor) }
                try bind(accountID, at: 1, to: cursor)
                try bind(nextCursor, at: 2, to: cursor)
                try stepToCompletion(cursor)
            }
    }

    func drainSyncInbox(accountID: String) throws {
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            let statement = try prepare("SELECT payload FROM sync_inbox WHERE account_id = ? ORDER BY rowid")
            try bind(accountID, at: 1, to: statement)
            let pending: [SyncOperation]
            do { pending = try syncReadOperations(statement) }
            catch { sqlite3_finalize(statement); throw error }
            sqlite3_finalize(statement)
            for operation in pending.sorted(by: { ($0.revision, $0.operationID.uuidString) < ($1.revision, $1.operationID.uuidString) }) {
                if let parent = operation.baseOperationID,
                   !(try syncLogContains(accountID: accountID, id: parent)) { continue }
                if let record = operation.record, let boardID = record.pinboardID,
                   !(try pinboardsWithoutLock().contains { $0.id == boardID }),
                   !(try syncIsDeleted(accountID: accountID, kind: .pinboard, id: boardID)) { continue }
                guard let materialized = try materializedOwnedOperation(operation) else { continue }
                try applySyncOperation(materialized)
                try syncExecute("UPDATE owned_sync_transfers SET status='complete',error=NULL WHERE operation_id=? AND direction='download'", [operation.operationID.uuidString])
                try syncExecute("DELETE FROM sync_inbox WHERE account_id = ? AND operation_id = ?", [accountID, operation.operationID.uuidString])
                madeProgress = true
            }
        }
    }

    public func hasSyncTombstone(accountID: String, kind: SyncEntityKind, entityID: UUID) throws -> Bool {
        try synchronized { try requireSyncAccount(accountID); return try syncIsDeleted(accountID: accountID, kind: kind, id: entityID) }
    }

    public func metadataSources(cancellation: HistoryReadCancellation? = nil) throws -> [String: String] {
        try synchronizedRead(cancellation: cancellation) {
            try withReadCancellation(cancellation) {
                let stamp = try metadataCacheStamp()
                if let stamp, let cached = sourceMetadataCache, cached.stamp == stamp { return cached.value }
                let statement = try prepare("SELECT source_bundle_id, max(coalesce(source_app, source_bundle_id)) FROM clipboard_records WHERE source_bundle_id IS NOT NULL AND (is_in_history = 1 OR pinboard_id IS NOT NULL) GROUP BY source_bundle_id")
                defer { sqlite3_finalize(statement) }
                var sources: [String: String] = [:]
                while true {
                    try cancellation?.checkCancellation()
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    try check(status, allowingRow: true)
                    try cancellation?.checkCancellation()
                    if let id = textColumn(statement, 0), let name = textColumn(statement, 1) { sources[id] = name }
                }
                // A concurrent writer may have committed during aggregation. Cache only a stable snapshot.
                if let stamp, try metadataCacheStamp() == stamp {
                    try cancellation?.checkCancellation()
                    sourceMetadataCache = MetadataCacheEntry(stamp: stamp, value: sources)
                }
                return sources
            }
        }
    }

    /// Existing content keeps its original account namespace even after the user switches accounts.
    /// Nil means local/unassigned; shared namespaces use the reserved `shared:` prefix.
    public func pinboardNamespace(id: UUID) throws -> String? {
        try synchronized {
            guard try pinboardsWithoutLock().contains(where: { $0.id == id }) else { throw HistoryStoreError.pinboardNotFound }
            return try syncNamespace(kind: .pinboard, id: id)
        }
    }

    func createSyncSchema(previousVersion: Int) throws {
        // These heads diverge after v7: a later ordering operation is not a content head.
        // Do not silently reconstruct a missing current-schema table from sync_heads.
        if previousVersion >= 7 { try requireSyncHeadSchema() }
        try execute("""
            CREATE TABLE IF NOT EXISTS sync_configuration (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), account_id TEXT, generation INTEGER NOT NULL DEFAULT 0);
            INSERT OR IGNORE INTO sync_configuration(singleton) VALUES (1);
            CREATE TABLE IF NOT EXISTS sync_namespaces (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, account_id TEXT NOT NULL, PRIMARY KEY(entity_kind, entity_id));
            CREATE TABLE IF NOT EXISTS sync_local_only (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, PRIMARY KEY(entity_kind, entity_id));
            CREATE TABLE IF NOT EXISTS sync_dirty (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, action TEXT NOT NULL, PRIMARY KEY(entity_kind, entity_id));
            CREATE TABLE IF NOT EXISTS sync_outbox (operation_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_inbox (operation_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_log (operation_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, base_operation_id TEXT, revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_order_dirty(entity_id TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS sync_content_heads(account_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, operation_id TEXT NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY(account_id, entity_kind, entity_id));
            CREATE TABLE IF NOT EXISTS sync_order_heads(account_id TEXT NOT NULL, entity_id TEXT NOT NULL, operation_id TEXT NOT NULL, board_id TEXT, PRIMARY KEY(account_id, entity_id));
            CREATE TABLE IF NOT EXISTS sync_heads (account_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, operation_id TEXT NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY(account_id, entity_kind, entity_id));
            CREATE TABLE IF NOT EXISTS sync_tombstones (account_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, operation_id TEXT NOT NULL, PRIMARY KEY(account_id, entity_kind, entity_id));
            CREATE TABLE IF NOT EXISTS sync_cursors (account_id TEXT PRIMARY KEY, cursor BLOB);
            CREATE INDEX IF NOT EXISTS sync_outbox_account ON sync_outbox(account_id);
            CREATE INDEX IF NOT EXISTS sync_inbox_account ON sync_inbox(account_id);
            """)
        if previousVersion < 7 {
            try requireSyncHeadSchema()
            try execute("""
                INSERT OR IGNORE INTO sync_content_heads SELECT * FROM sync_heads;
                INSERT OR IGNORE INTO sync_order_heads(account_id, entity_id, operation_id, board_id)
                SELECT account_id, entity_id, operation_id, pinboard_id FROM sync_heads
                JOIN clipboard_records ON clipboard_records.id = sync_heads.entity_id WHERE entity_kind = 'clipboard';
                """)
        }
        for (table, kind) in [("clipboard_records", "clipboard"), ("pinboards", "pinboard")] {
            for (event, action, row) in [("INSERT", "upsert", "NEW"), ("UPDATE", "upsert", "NEW"), ("DELETE", "delete", "OLD")] {
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS sync_\(kind)_\(event.lowercased()) AFTER \(event) ON \(table) BEGIN
                    INSERT INTO sync_dirty(entity_kind, entity_id, action) VALUES ('\(kind)', \(row).id, '\(action)')
                    ON CONFLICT(entity_kind, entity_id) DO UPDATE SET action = excluded.action;
                    END
                    """)
            }
        }
    }

    private func requireSyncHeadSchema() throws {
        for table in ["sync_heads", "sync_content_heads"] {
            try requireStartupTable(table, columns: [
                ("account_id", "TEXT", true), ("entity_kind", "TEXT", true),
                ("entity_id", "TEXT", true), ("operation_id", "TEXT", true), ("revision", "INTEGER", true)
            ], primaryKey: ["account_id", "entity_kind", "entity_id"])
        }
        try requireStartupTable("sync_order_heads", columns: [
            ("account_id", "TEXT", true), ("entity_id", "TEXT", true),
            ("operation_id", "TEXT", true), ("board_id", "TEXT", false)
        ], primaryKey: ["account_id", "entity_id"])
    }

    func syncConfigurationWithoutLock() throws -> SyncConfiguration {
        let statement = try prepare("SELECT account_id, generation FROM sync_configuration WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), allowingRow: true)
        return SyncConfiguration(accountID: textColumn(statement, 0), generation: sqlite3_column_int64(statement, 1))
    }

    func requireSyncAccount(_ accountID: String) throws {
        guard try syncConfigurationWithoutLock().accountID == accountID else { throw SyncError.accountChanged }
    }

    func syncNamespace(kind: SyncEntityKind, id: UUID) throws -> String? {
        try syncScalar("SELECT account_id FROM sync_namespaces WHERE entity_kind = ? AND entity_id = ?", [kind.rawValue, id.uuidString])
    }

    func canCoalesceSyncItem(id: UUID) throws -> Bool {
        guard syncSchemaReady else { return true }
        if try isSyncLocalOnly(kind: .clipboard, id: id) { return false }
        return try syncNamespace(kind: .clipboard, id: id) == syncConfigurationWithoutLock().accountID
    }

    func setSyncNamespace(kind: SyncEntityKind, id: UUID, accountID: String) throws {
        guard try !isSyncLocalOnly(kind: kind, id: id) else { throw SyncError.namespaceConflict }
        if let existing = try syncNamespace(kind: kind, id: id), existing != accountID { throw SyncError.namespaceConflict }
        try syncExecute("INSERT OR IGNORE INTO sync_namespaces (entity_kind, entity_id, account_id) VALUES (?, ?, ?)", [kind.rawValue, id.uuidString, accountID])
    }

    func flushSyncDirty() throws {
        if suppressSyncCapture { try execute("DELETE FROM sync_dirty; DELETE FROM sync_order_dirty"); return }
        try publishOrderingBaselinesForDirtyBoards()
        let activeAccount = try syncConfigurationWithoutLock().accountID
        let statement = try prepare("SELECT entity_kind, entity_id, action FROM sync_dirty ORDER BY CASE entity_kind WHEN 'pinboard' THEN 0 ELSE 1 END, rowid")
        var dirty: [(SyncEntityKind, UUID, SyncAction)] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            do { try check(status, allowingRow: true) } catch { sqlite3_finalize(statement); throw error }
            guard let kind = textColumn(statement, 0).flatMap(SyncEntityKind.init(rawValue:)),
                  let id = textColumn(statement, 1).flatMap(UUID.init(uuidString:)),
                  let action = textColumn(statement, 2).flatMap(SyncAction.init(rawValue:)) else {
                sqlite3_finalize(statement); throw SyncError.invalidOperation
            }
            dirty.append((kind, id, action))
        }
        sqlite3_finalize(statement)
        for (kind, id, action) in dirty {
            // Namespace decisions need only placement. Purely local moves must not decode attachments.
            let placement = kind == .clipboard && action == .upsert ? try orderingItem(id: id) : nil
            let inheritedNamespace = try placement?.boardID.flatMap { try syncNamespace(kind: .pinboard, id: $0) }
            let existingNamespace = try syncNamespace(kind: kind, id: id)
            let localOnly = try isSyncLocalOnly(kind: kind, id: id)
            let localOnlyBoard = try placement?.boardID.map { try isSyncLocalOnly(kind: .pinboard, id: $0) } ?? false
            if localOnly || localOnlyBoard {
                guard existingNamespace == nil, inheritedNamespace == nil else { throw SyncError.namespaceConflict }
                try markSyncLocalOnly(kind: kind, id: id)
                continue
            }
            guard let accountID = existingNamespace ?? inheritedNamespace ?? activeAccount else { continue }
            if let state = try sharedStateForNamespace(accountID) {
                guard try sharingConfigurationWithoutLock().accountID == state.descriptor.accountID else { throw SharedBoardError.accountChanged }
                guard state.access.canWrite else { throw state.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
                if kind == .pinboard, action == .delete, state.access != .owner { throw SharedBoardError.readOnly }
                if let placement, placement.boardID != state.descriptor.boardID { throw SyncError.namespaceConflict }
            }
            let record = kind == .clipboard && action == .upsert ? try itemWithoutLock(id: id) : nil
            try setSyncNamespace(kind: kind, id: id, accountID: accountID)
            let hasOrderMarker = try syncScalar("SELECT entity_id FROM sync_order_dirty WHERE entity_id = ?", [id.uuidString]) != nil
            var head = try syncHead(accountID: accountID, kind: kind, id: id, table: "sync_content_heads")
            if kind == .clipboard, action == .upsert, hasOrderMarker,
               let position = try syncOrderHead(accountID: accountID, id: id) {
                head = (position.id, position.revision)
            }
            let board = kind == .pinboard && action == .upsert ? try pinboardsWithoutLock().first { $0.id == id } : nil
            if let boardID = record?.pinboardID {
                if let owner = try syncNamespace(kind: .pinboard, id: boardID), owner != accountID { throw SyncError.namespaceConflict }
                if try syncNamespace(kind: .pinboard, id: boardID) == nil {
                    // Explicitly moving an item to a local board also opts that board's metadata into this account.
                    try setSyncNamespace(kind: .pinboard, id: boardID, accountID: accountID)
                    if let board = try pinboardsWithoutLock().first(where: { $0.id == boardID }) {
                        let boardOperation = SyncOperation(accountID: accountID, entityID: boardID, entityKind: .pinboard,
                                                           action: .upsert, baseRevision: 0, revision: 1, pinboard: board)
                        try enqueueSyncOperation(boardOperation)
                    }
                }
            }
            if action == .upsert, try syncIsDeleted(accountID: accountID, kind: kind, id: id) { throw SyncError.invalidOperation }
            let operation = SyncOperation(accountID: accountID, entityID: id, entityKind: kind, action: action,
                                          baseRevision: head?.revision ?? 0, revision: (head?.revision ?? 0) + 1,
                                          baseOperationID: head?.id, record: record, pinboard: board,
                                          orderingOnly: kind == .clipboard && action == .upsert && head != nil && hasOrderMarker ? true : nil)
            try enqueueSyncOperation(operation)
        }
        try execute("DELETE FROM sync_dirty; DELETE FROM sync_order_dirty")
    }

    func hasSyncBoundState() throws -> Bool {
        if try syncConfigurationWithoutLock().accountID != nil || sharingConfigurationWithoutLock().accountID != nil { return true }
        return try syncScalar("SELECT entity_id FROM sync_namespaces LIMIT 1", []) != nil
            || syncScalar("SELECT board_id FROM shared_boards LIMIT 1", []) != nil
            || syncScalar("SELECT operation_id FROM sync_outbox LIMIT 1", []) != nil
    }

    func markSyncLocalOnly(kind: SyncEntityKind, id: UUID) throws {
        guard try syncNamespace(kind: kind, id: id) == nil else { throw SyncError.namespaceConflict }
        try syncExecute("INSERT OR IGNORE INTO sync_local_only(entity_kind, entity_id) VALUES (?, ?)", [kind.rawValue, id.uuidString])
    }

    func isSyncLocalOnly(kind: SyncEntityKind, id: UUID) throws -> Bool {
        try syncScalar("SELECT entity_id FROM sync_local_only WHERE entity_kind = ? AND entity_id = ?", [kind.rawValue, id.uuidString]) != nil
    }

    func enqueueSyncOperation(_ original: SyncOperation) throws {
        let operation = try portableOwnedOperation(original)
        try validateSyncOperation(operation, accountID: operation.accountID)
        let payload = try JSONEncoder().encode(operation)
        guard payload.count <= 256 * 1_024 * 1_024 else { throw HistoryStoreError.valueTooLarge }
        // Ordering and board mutations also enqueue the complete portable record. The
        // encoded payload is the authority here, not the small visible metadata change.
        // Tombstones remain possible when reclaiming space; actual SQLite errors still roll back.
        if operation.action != .delete { try reserveSyncPayloadWithoutLock(payload) }
        let statement = try prepare("INSERT INTO sync_outbox(operation_id, account_id, payload) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(operation.operationID.uuidString, at: 1, to: statement)
        try bind(operation.accountID, at: 2, to: statement)
        try bind(payload, at: 3, to: statement)
        try stepToCompletion(statement)
        try logSyncOperation(operation)
        try setSyncHead(operation)
        if operation.orderingOnly != true { try setSyncHead(operation, table: "sync_content_heads") }
        if let record = operation.record {
            let position = try syncOrderHead(accountID: operation.accountID, id: operation.entityID)
            if operation.orderingOnly == true || position == nil || position?.boardID != record.pinboardID {
                try setSyncOrderHead(operation, boardID: record.pinboardID)
            }
        }
        if operation.action == .delete { try writeSyncTombstone(operation) }
    }

    func validateSyncOperation(_ operation: SyncOperation, accountID: String) throws {
        if let manifest = operation.ownedFiles {
            guard operation.formatVersion == 2, operation.action == .upsert, operation.entityKind == .clipboard,
                  let record = operation.record else { throw SyncError.invalidOperation }
            try manifest.validate(record: record)
        } else {
            guard operation.formatVersion == nil || operation.formatVersion == 1 else { throw SyncError.invalidOperation }
            guard !(operation.record?.parts.flatMap(\.representations).contains(where: {
                $0.typeIdentifier == "public.file-url" && String(data: $0.data, encoding: .utf8)?.hasPrefix("clipshelf-owned:") == true
            }) ?? false) else { throw SyncError.invalidOperation }
        }
        guard operation.accountID == accountID, !accountID.isEmpty,
              accountID.utf8.count <= 512, operation.baseRevision >= 0, operation.baseRevision < Int.max - 1,
              operation.revision == operation.baseRevision + 1,
              operation.revision < Int.max, operation.createdAt.timeIntervalSinceReferenceDate.isFinite,
              (operation.baseOperationID == nil) == (operation.baseRevision == 0) else { throw SyncError.invalidOperation }
        if operation.orderingOnly == true {
            guard operation.action == .upsert, operation.entityKind == .clipboard, operation.baseRevision > 0,
                  operation.record?.pinboardID != nil, operation.record?.pinboardOrder != nil else { throw SyncError.invalidOperation }
        }
        if operation.action == .delete {
            guard operation.record == nil, operation.pinboard == nil else { throw SyncError.invalidOperation }
        } else if operation.entityKind == .clipboard {
            guard let record = operation.record, record.id == operation.entityID, operation.pinboard == nil else { throw SyncError.invalidOperation }
            try validate(record)
        } else {
            guard let board = operation.pinboard, board.id == operation.entityID, operation.record == nil else { throw SyncError.invalidOperation }
            try validate(board)
        }
    }

    func applySyncOperation(_ operation: SyncOperation) throws {
        let account = operation.accountID, kind = operation.entityKind, id = operation.entityID
        if try syncLogContains(accountID: account, id: operation.operationID) { return }
        try setSyncNamespace(kind: kind, id: id, accountID: account)
        if let parent = operation.baseOperationID {
            guard try syncScalar("SELECT revision FROM sync_log WHERE operation_id = ? AND account_id = ? AND entity_kind = ? AND entity_id = ?", [parent.uuidString, account, kind.rawValue, id.uuidString]) == String(operation.baseRevision) else { throw SyncError.invalidOperation }
        }
        if let record = operation.record { try reconcileRemoteOrigin(record) }
        if operation.orderingOnly == true {
            try applyOrderingOperation(operation)
            try advanceSyncHead(operation)
            try logSyncOperation(operation)
            return
        }
        // A drag changes location, not content. Content conflict arbitration uses its own head.
        let head = try syncHead(accountID: account, kind: kind, id: id, table: "sync_content_heads")
        if operation.action == .delete {
            if let head, head.id != operation.baseOperationID,
               !(try syncIsAncestor(head.id, of: operation.baseOperationID, accountID: account)) {
                try preserveConflict(kind: kind, id: id, operationID: head.id, accountID: account)
            }
            if kind == .clipboard {
                try syncExecute("DELETE FROM clipboard_records WHERE id = ?", [id.uuidString])
            } else {
                try syncExecute("UPDATE clipboard_records SET pinboard_id = NULL, pinboard_order = NULL, is_in_history = 1, revision = revision + 1 WHERE pinboard_id = ?", [id.uuidString])
                try syncExecute("DELETE FROM pinboards WHERE id = ?", [id.uuidString])
            }
            try writeSyncTombstone(operation)
            try setSyncHead(operation, table: "sync_content_heads")
        } else if try syncIsDeleted(accountID: account, kind: kind, id: id) {
            // A concurrent edit cannot revive the deleted identity, but its content remains recoverable.
            if let head, !(try syncIsAncestor(operation.operationID, of: head.id, accountID: account)) {
                try preserveRemoteConflict(operation)
            }
        } else {
            if let head, head.id != operation.baseOperationID {
                if try syncIsAncestor(operation.operationID, of: head.id, accountID: account) {
                    // A descendant is already local; receiving its parent later must not overwrite it.
                } else if try syncIsAncestor(head.id, of: operation.baseOperationID, accountID: account) {
                    try applySyncPayload(operation)
                    try setSyncHead(operation, table: "sync_content_heads")
                } else if operation.operationID.uuidString > head.id.uuidString {
                    if try !isOrderingOnlyConflict(operation) { try preserveConflict(kind: kind, id: id, operationID: head.id, accountID: account) }
                    try applySyncPayload(operation)
                    try setSyncHead(operation, table: "sync_content_heads")
                } else {
                    if try !isOrderingOnlyConflict(operation) { try preserveRemoteConflict(operation) }
                }
            } else {
                try applySyncPayload(operation)
                try setSyncHead(operation, table: "sync_content_heads")
            }
        }
        try advanceSyncHead(operation)
        try logSyncOperation(operation)
    }

    func applySyncPayload(_ operation: SyncOperation) throws {
        if var record = operation.record {
            if let board = record.pinboardID, try syncIsDeleted(accountID: operation.accountID, kind: .pinboard, id: board) {
                record.pinboardID = nil
                record.pinboardOrder = nil
                record.isInHistory = true
            }
            if let current = try itemWithoutLock(id: record.id) {
                if operation.ownedFiles == nil, try !ownedFileBindingsWithoutLock(recordID: current.id).isEmpty {
                    // A legacy peer cannot revoke verified bytes by sending an unproven path.
                    try preserveRemoteConflict(operation)
                    return
                }
                record = resolvingOrigin(record, existing: current)
                if record.pinboardID == current.pinboardID {
                    // Full snapshots carry their author's last-known position. Position-only operations
                    // arbitrate it independently, so a concurrent text edit cannot undo a drag.
                    record.pinboardOrder = current.pinboardOrder ?? record.pinboardOrder
                } else { try setSyncOrderHead(operation, boardID: record.pinboardID) }
                if record != current { record.revision = max(record.revision, current.revision + 1) }
                try replaceContents(record)
            } else {
                try insert(record)
                try setSyncOrderHead(operation, boardID: record.pinboardID)
            }
            if operation.ownedFiles != nil { try restoreOwnedFileOperationBindingsWithoutLock(operationID: operation.operationID, record: record) }
        } else if let board = operation.pinboard {
            try savePinboard(board, replace: try pinboardsWithoutLock().contains { $0.id == board.id })
        }
    }

    func applyOrderingOperation(_ operation: SyncOperation) throws {
        guard try !syncIsDeleted(accountID: operation.accountID, kind: .clipboard, id: operation.entityID),
              let incoming = operation.record, let current = try itemWithoutLock(id: operation.entityID),
              current.pinboardID == incoming.pinboardID else { return }
        let head = try syncOrderHead(accountID: operation.accountID, id: operation.entityID)
        if let head {
            if try syncIsAncestor(operation.operationID, of: head.id, accountID: operation.accountID) { return }
            let follows = try syncIsAncestor(head.id, of: operation.baseOperationID, accountID: operation.accountID)
            if !follows, operation.operationID.uuidString < head.id.uuidString { return }
        }
        if current.pinboardOrder != incoming.pinboardOrder {
            try writePlacement(id: current.id, boardID: current.pinboardID, rank: incoming.pinboardOrder)
        }
        try setSyncOrderHead(operation, boardID: current.pinboardID)
    }

    func syncOrderHead(accountID: String, id: UUID) throws -> (id: UUID, boardID: UUID?, revision: Int)? {
        let statement = try prepare("SELECT sync_order_heads.operation_id, board_id, revision FROM sync_order_heads JOIN sync_log ON sync_log.operation_id = sync_order_heads.operation_id WHERE sync_order_heads.account_id = ? AND sync_order_heads.entity_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(accountID, at: 1, to: statement); try bind(id.uuidString, at: 2, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        try check(status, allowingRow: true)
        guard let operationID = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw SyncError.invalidOperation }
        return (operationID, textColumn(statement, 1).flatMap(UUID.init(uuidString:)), Int(sqlite3_column_int64(statement, 2)))
    }

    func setSyncOrderHead(_ operation: SyncOperation, boardID: UUID?) throws {
        try syncExecute("""
            INSERT INTO sync_order_heads(account_id, entity_id, operation_id, board_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, entity_id) DO UPDATE SET operation_id = excluded.operation_id, board_id = excluded.board_id
            """, [operation.accountID, operation.entityID.uuidString, operation.operationID.uuidString, boardID?.uuidString])
    }

    func advanceSyncHead(_ operation: SyncOperation) throws {
        let head = try syncHead(accountID: operation.accountID, kind: operation.entityKind, id: operation.entityID)
        if let head {
            if try syncIsAncestor(operation.operationID, of: head.id, accountID: operation.accountID) { return }
            let follows = try syncIsAncestor(head.id, of: operation.baseOperationID, accountID: operation.accountID)
            if operation.action != .delete, !follows, operation.operationID.uuidString < head.id.uuidString { return }
        }
        try setSyncHead(operation)
    }

    func isOrderingOnlyConflict(_ operation: SyncOperation) throws -> Bool {
        guard let incoming = operation.record, let current = try itemWithoutLock(id: incoming.id) else { return false }
        var normalizedIncoming = incoming, normalizedCurrent = current
        if let manifest = operation.ownedFiles {
            for binding in manifest.bindings { normalizedIncoming.parts[binding.partIndex].representations[0].data = Data(SyncOwnedFileManifest.token(digest: binding.digest, filename: binding.filename).utf8) }
            let temporary = SyncOperation(accountID: operation.accountID, entityID: current.id, entityKind: .clipboard, action: .upsert, baseRevision: 0, revision: 1, record: current)
            normalizedCurrent = try portableOwnedOperation(temporary).record ?? current
            try syncExecute("DELETE FROM owned_file_operation_bindings WHERE operation_id=?", [temporary.operationID.uuidString])
            try syncExecute("DELETE FROM owned_sync_operation_proofs WHERE operation_id=?", [temporary.operationID.uuidString])
        }
        return normalizedIncoming.hasSameContents(as: normalizedCurrent) && incoming.copiedAt == current.copiedAt
            && incoming.renamedTitle == current.renamedTitle && incoming.ocrText == current.ocrText
            && incoming.pinboardID == current.pinboardID && incoming.isInHistory == current.isInHistory
    }

    func preserveConflict(kind: SyncEntityKind, id: UUID, operationID: UUID, accountID: String) throws {
        if var record = try itemWithoutLock(id: id), kind == .clipboard {
            record.id = conflictID(operationID)
            record.renamedTitle = record.title + " (Conflict)"
            record.isInHistory = true
            if try itemWithoutLock(id: record.id) == nil {
                try insert(record)
                try copyOwnedFileBindingsWithoutLock(from: id, to: record)
                try setSyncNamespace(kind: .clipboard, id: record.id, accountID: accountID)
            }
        } else if kind == .pinboard, var board = try pinboardsWithoutLock().first(where: { $0.id == id }) {
            board.id = conflictID(operationID)
            board.name = String(board.name.prefix(180)) + " (Conflict)"
            if !(try pinboardsWithoutLock().contains { $0.id == board.id }) {
                try savePinboard(board, replace: false)
                try setSyncNamespace(kind: .pinboard, id: board.id, accountID: accountID)
            }
        }
    }

    func preserveRemoteConflict(_ operation: SyncOperation) throws {
        let id = conflictID(operation.operationID)
        if var record = operation.record {
            record = resolvingOrigin(record, existing: try itemWithoutLock(id: record.id))
            record.id = id
            record.renamedTitle = record.title + " (Conflict)"
            record.isInHistory = true
            if let boardID = record.pinboardID {
                let deleted = try syncIsDeleted(accountID: operation.accountID, kind: .pinboard, id: boardID)
                let exists = try syncScalar("SELECT id FROM pinboards WHERE id = ?", [boardID.uuidString]) != nil
                // The concurrent edit remains recoverable even after its whole board was deleted.
                if deleted || !exists { record.pinboardID = nil; record.pinboardOrder = nil }
            }
            if try itemWithoutLock(id: id) == nil {
                try insert(record)
                if operation.ownedFiles != nil { try restoreOwnedFileOperationBindingsWithoutLock(operationID: operation.operationID, record: record) }
                try setSyncNamespace(kind: .clipboard, id: id, accountID: operation.accountID)
            }
        } else if var board = operation.pinboard {
            board.id = id
            board.name = String(board.name.prefix(180)) + " (Conflict)"
            if !(try pinboardsWithoutLock().contains { $0.id == id }) {
                try savePinboard(board, replace: false)
                try setSyncNamespace(kind: .pinboard, id: id, accountID: operation.accountID)
            }
        }
    }

    func conflictID(_ operationID: UUID) -> UUID {
        let hash = RepresentationStorage.digest(Data(("ClipShelf conflict " + operationID.uuidString).utf8))
        let value = Array(hash.prefix(32))
        return UUID(uuidString: String(value[0..<8]) + "-" + String(value[8..<12]) + "-" + String(value[12..<16]) + "-" + String(value[16..<20]) + "-" + String(value[20..<32]))!
    }

    func syncHead(accountID: String, kind: SyncEntityKind, id: UUID, table: String = "sync_heads") throws -> (id: UUID, revision: Int)? {
        let statement = try prepare("SELECT operation_id, revision FROM \(table) WHERE account_id = ? AND entity_kind = ? AND entity_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(accountID, at: 1, to: statement); try bind(kind.rawValue, at: 2, to: statement); try bind(id.uuidString, at: 3, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        try check(status, allowingRow: true)
        guard let operationID = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw SyncError.invalidOperation }
        return (operationID, Int(sqlite3_column_int64(statement, 1)))
    }

    func setSyncHead(_ operation: SyncOperation, table: String = "sync_heads") throws {
        try syncExecute("INSERT INTO \(table)(account_id, entity_kind, entity_id, operation_id, revision) VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, entity_kind, entity_id) DO UPDATE SET operation_id = excluded.operation_id, revision = excluded.revision",
                        [operation.accountID, operation.entityKind.rawValue, operation.entityID.uuidString, operation.operationID.uuidString, String(operation.revision)])
    }

    func logSyncOperation(_ operation: SyncOperation) throws {
        try syncExecute("INSERT OR IGNORE INTO sync_log(operation_id, account_id, entity_kind, entity_id, base_operation_id, revision) VALUES (?, ?, ?, ?, ?, ?)",
                        [operation.operationID.uuidString, operation.accountID, operation.entityKind.rawValue, operation.entityID.uuidString, operation.baseOperationID?.uuidString, String(operation.revision)])
    }

    func syncLogContains(accountID: String, id: UUID) throws -> Bool {
        try syncScalar("SELECT operation_id FROM sync_log WHERE account_id = ? AND operation_id = ?", [accountID, id.uuidString]) != nil
    }

    func syncIsAncestor(_ ancestor: UUID, of descendant: UUID?, accountID: String) throws -> Bool {
        var current = descendant
        var visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted {
            if id == ancestor { return true }
            current = try syncScalar("SELECT base_operation_id FROM sync_log WHERE account_id = ? AND operation_id = ?", [accountID, id.uuidString]).flatMap(UUID.init(uuidString:))
            guard visited.count <= 100_000 else { throw SyncError.invalidOperation }
        }
        return false
    }

    func syncIsDeleted(accountID: String, kind: SyncEntityKind, id: UUID) throws -> Bool {
        try syncScalar("SELECT operation_id FROM sync_tombstones WHERE account_id = ? AND entity_kind = ? AND entity_id = ?", [accountID, kind.rawValue, id.uuidString]) != nil
    }

    func writeSyncTombstone(_ operation: SyncOperation) throws {
        try syncExecute("INSERT INTO sync_tombstones(account_id, entity_kind, entity_id, operation_id) VALUES (?, ?, ?, ?) ON CONFLICT(account_id, entity_kind, entity_id) DO UPDATE SET operation_id = excluded.operation_id",
                        [operation.accountID, operation.entityKind.rawValue, operation.entityID.uuidString, operation.operationID.uuidString])
    }

    func syncReadOperations(_ statement: OpaquePointer) throws -> [SyncOperation] {
        var operations: [SyncOperation] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return operations }
            try check(status, allowingRow: true)
            guard let data = dataColumn(statement, 0) else { throw SyncError.invalidOperation }
            operations.append(try JSONDecoder().decode(SyncOperation.self, from: data))
        }
    }

    func syncExecute(_ sql: String, _ values: [String?]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { try bind(value, at: Int32(offset + 1), to: statement) }
        try stepToCompletion(statement)
    }

    func syncScalar(_ sql: String, _ values: [String?]) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { try bind(value, at: Int32(offset + 1), to: statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        try check(status, allowingRow: true)
        return textColumn(statement, 0)
    }
}
