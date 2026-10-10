import CSQLite
import Foundation

extension HistoryStore {
    public func prepareHistoryCleanup(before cutoff: Date? = nil) throws -> HistoryCleanupPlan {
        if let cutoff, !cutoff.timeIntervalSinceReferenceDate.isFinite { throw HistoryStoreError.invalidTimestamp }
        return try synchronized { try selectionReadTransaction { try prepareHistoryCleanupWithoutLock(before: cutoff) } }
    }

    public func commitHistoryCleanup(_ plan: HistoryCleanupPlan) throws -> HistoryCleanupResult {
        try synchronized {
            guard plan.storeIdentity == selectionStoreIdentity, !plan.capability.consumed else { throw HistoryCleanupError.invalidPlan }
            let result = try transaction(allowReclamation: true) { try commitHistoryCleanupWithoutLock(plan) }
            plan.capability.consumed = true
            return result
        }
    }

    /// Existing one-step clear/prune APIs prepare and execute under the same writer lock.
    func cleanupHistoryWithoutLock(before cutoff: Date?) throws -> HistoryCleanupResult {
        try commitHistoryCleanupWithoutLock(prepareHistoryCleanupWithoutLock(before: cutoff))
    }

    private func prepareHistoryCleanupWithoutLock(before cutoff: Date?) throws -> HistoryCleanupPlan {
        let sync = try syncConfigurationWithoutLock(), sharing = try sharingConfigurationWithoutLock()
        let rows = try cleanupRows(before: cutoff)
        var candidates: [HistoryCleanupCandidate] = [], excluded = 0
        var permissions = CleanupPermissions()
        for row in rows {
            if let value = try cleanupCandidate(row, sync: sync, sharing: sharing, permissions: &permissions) { candidates.append(value) }
            else { excluded += 1 }
        }
        let pinned = candidates.filter { $0.boardID != nil }.count
        let summary = HistoryCleanupSummary(deletedCount: candidates.count - pinned, preservedPinnedCount: pinned,
            privateSyncCount: candidates.filter { $0.impact == .privateSync }.count,
            sharedSyncCount: candidates.filter { $0.impact == .sharedSync }.count, excludedCount: excluded)
        return HistoryCleanupPlan(summary: summary, storeIdentity: selectionStoreIdentity,
            syncConfiguration: sync, sharingConfiguration: sharing, candidates: candidates)
    }

    private func commitHistoryCleanupWithoutLock(_ plan: HistoryCleanupPlan) throws -> HistoryCleanupResult {
        guard plan.storeIdentity == selectionStoreIdentity, !plan.capability.consumed else { throw HistoryCleanupError.invalidPlan }
        try requireIntegrationConfigurations(sync: plan.syncConfiguration, sharing: plan.sharingConfiguration)
        var current: [UUID: CleanupRow] = [:]
        let ids = plan.candidates.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 500) {
            for row in try cleanupRows(ids: Array(ids[start..<min(start + 500, ids.count)])) { current[row.id] = row }
        }
        var permissions = CleanupPermissions()
        // Validate the whole set before the first UPDATE/DELETE, including mutations
        // that preserve revision, namespaces that changed without touching a row,
        // and shared permissions that changed without switching accounts.
        for candidate in plan.candidates {
            guard let row = current[candidate.id],
                  let value = try cleanupCandidate(row, sync: plan.syncConfiguration, sharing: plan.sharingConfiguration,
                                                   permissions: &permissions), value == candidate else {
                throw HistoryCleanupError.changed
            }
        }
        let deletion = try prepare("DELETE FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(deletion) }
        let preservation = try prepare("UPDATE clipboard_records SET is_in_history = 0, revision = revision + 1 WHERE id = ?")
        defer { sqlite3_finalize(preservation) }
        var deleted: [UUID] = [], preserved: [ClipboardSelectionReference] = []
        for candidate in plan.candidates {
            let statement = candidate.boardID == nil ? deletion : preservation
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(candidate.id.uuidString, at: 1, to: statement); try stepToCompletion(statement)
            if candidate.boardID == nil { deleted.append(candidate.id) }
            else { preserved.append(.init(id: candidate.id, revision: candidate.revision + 1)) }
        }
        // Never run removeUnretainedRows(): it could delete rows outside this confirmation.
        return HistoryCleanupResult(summary: plan.summary, deletedIDs: deleted, preservedReferences: preserved)
    }

    private struct CleanupRow {
        let id: UUID, revision: Int, boardID: UUID?, boardExists: Bool, inHistory: Bool
        let mutationToken: Data
        let recordNamespace: String?, boardNamespace: String?
        let recordLocalOnly: Bool, boardLocalOnly: Bool
    }

    private func cleanupRows(before cutoff: Date? = nil, ids: [UUID]? = nil) throws -> [CleanupRow] {
        // Deliberately no text/RTF/HTML/parts columns or payload decode: a corrupt or
        // missing local attachment must not prevent its record from being cleared.
        var sql = """
            SELECT r.id, r.revision, r.pinboard_id, p.id, r.is_in_history, t.token,
                   rn.account_id, bn.account_id, rl.entity_id, bl.entity_id
            FROM clipboard_records r
            LEFT JOIN pinboards p ON p.id = r.pinboard_id
            LEFT JOIN history_cleanup_tokens t ON t.record_id = r.id
            LEFT JOIN sync_namespaces rn ON rn.entity_kind = 'clipboard' AND rn.entity_id = r.id
            LEFT JOIN sync_namespaces bn ON bn.entity_kind = 'pinboard' AND bn.entity_id = r.pinboard_id
            LEFT JOIN sync_local_only rl ON rl.entity_kind = 'clipboard' AND rl.entity_id = r.id
            LEFT JOIN sync_local_only bl ON bl.entity_kind = 'pinboard' AND bl.entity_id = r.pinboard_id
            """
        if let ids { sql += " WHERE r.id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))" }
        else { sql += " WHERE r.is_in_history = 1" + (cutoff == nil ? "" : " AND r.copied_at < ?") }
        sql += " ORDER BY r.local_history_order"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let ids { for (index, id) in ids.enumerated() { try bind(id.uuidString, at: Int32(index + 1), to: statement) } }
        else if let cutoff { try check(sqlite3_bind_double(statement, 1, cutoff.timeIntervalSinceReferenceDate)) }
        var rows: [CleanupRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            try check(status, allowingRow: true)
            guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)),
                  let token = dataColumn(statement, 5), token.count == 16 else { throw HistoryCleanupError.changed }
            let revision = Int(sqlite3_column_int64(statement, 1))
            guard revision > 0, revision < Int.max else { throw HistoryStoreError.invalidStoredRecord }
            let boardString = textColumn(statement, 2), board = boardString.flatMap(UUID.init(uuidString:))
            guard boardString == nil || board != nil else { throw HistoryStoreError.invalidStoredRecord }
            rows.append(CleanupRow(id: id, revision: revision, boardID: board,
                boardExists: board == nil || textColumn(statement, 3) != nil, inHistory: sqlite3_column_int(statement, 4) != 0,
                mutationToken: token, recordNamespace: textColumn(statement, 6), boardNamespace: textColumn(statement, 7),
                recordLocalOnly: textColumn(statement, 8) != nil, boardLocalOnly: textColumn(statement, 9) != nil))
        }
    }

    private struct CleanupPermissions {
        var shared: [String: SharedBoardState] = [:]
        var notShared: Set<String> = []
    }

    private func cleanupCandidate(_ row: CleanupRow, sync: SyncConfiguration, sharing: SyncConfiguration,
                                  permissions: inout CleanupPermissions) throws -> HistoryCleanupCandidate? {
        guard row.inHistory, row.boardExists else { return nil }
        let namespaces = Set([row.recordNamespace, row.boardNamespace].compactMap { $0 })
        // Conflicting record/board ownership is never an authorized cleanup scope.
        guard namespaces.count <= 1 else { return nil }
        let localOnly = row.recordLocalOnly || row.boardLocalOnly
        guard !localOnly || namespaces.isEmpty else { return nil }
        var states: [SharedBoardState] = []
        for namespace in namespaces.sorted() {
            if permissions.shared[namespace] == nil, !permissions.notShared.contains(namespace) {
                if let state = try sharedStateForNamespace(namespace) { permissions.shared[namespace] = state }
                else { permissions.notShared.insert(namespace) }
            }
            if let state = permissions.shared[namespace] {
                guard state.descriptor.accountID == sharing.accountID, state.access.canWrite,
                      row.boardID == nil || row.boardID == state.descriptor.boardID else { return nil }
                states.append(state)
            } else {
                guard !namespace.hasPrefix("shared:"), namespace == sync.accountID else { return nil }
            }
        }
        // Mirror flushSyncDirty: local-only opts out; otherwise ownership falls
        // back from the record to its board and finally to the active account.
        let effective = localOnly ? nil : row.recordNamespace ?? row.boardNamespace ?? sync.accountID
        let impact: HistoryCleanupCandidate.Impact = effective == nil ? .local :
            (effective!.hasPrefix("shared:") ? .sharedSync : .privateSync)
        return HistoryCleanupCandidate(id: row.id, revision: row.revision, boardID: row.boardID,
            mutationToken: row.mutationToken, recordNamespace: row.recordNamespace, boardNamespace: row.boardNamespace,
            recordLocalOnly: row.recordLocalOnly, boardLocalOnly: row.boardLocalOnly, sharedStates: states, impact: impact)
    }

    /// Local schema v10. Independent of backup v3 and sync wire representations.
    func initializeHistoryCleanupTokens(previousVersion: Int) throws {
        if previousVersion >= 10 {
            // Every production record mutation maintains its token in the same SQLite transaction.
            // Missing schema is not an unfinished migration: reinstalling a lost UPDATE trigger
            // would conceal mutations for which an already-issued confirmation has no new token.
            try requireHistoryCleanupSchema()
            return
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS history_cleanup_tokens (
                record_id TEXT PRIMARY KEY REFERENCES clipboard_records(id) ON DELETE CASCADE,
                token BLOB NOT NULL CHECK(length(token) = 16));
            CREATE TRIGGER IF NOT EXISTS history_cleanup_insert AFTER INSERT ON clipboard_records BEGIN
                INSERT INTO history_cleanup_tokens(record_id, token) VALUES (NEW.id, randomblob(16))
                ON CONFLICT(record_id) DO UPDATE SET token = excluded.token;
            END;
            CREATE TRIGGER IF NOT EXISTS history_cleanup_update AFTER UPDATE ON clipboard_records BEGIN
                INSERT INTO history_cleanup_tokens(record_id, token) VALUES (NEW.id, randomblob(16))
                ON CONFLICT(record_id) DO UPDATE SET token = excluded.token;
            END;
            CREATE TRIGGER IF NOT EXISTS history_cleanup_delete AFTER DELETE ON clipboard_records BEGIN
                DELETE FROM history_cleanup_tokens WHERE record_id = OLD.id;
            END;
            """)
        try requireHistoryCleanupSchema()
        // Only pre-v10 records need a baseline. Never rotate tokens on an ordinary reopen.
        try execute("INSERT OR IGNORE INTO history_cleanup_tokens(record_id, token) SELECT id, randomblob(16) FROM clipboard_records")
    }

    private func requireHistoryCleanupSchema() throws {
        try requireStartupTable("history_cleanup_tokens", columns: [
            ("record_id", "TEXT", nil), ("token", "BLOB", true)
        ], primaryKey: ["record_id"])
        let foreignKeys = try prepare("PRAGMA foreign_key_list(history_cleanup_tokens)")
        defer { sqlite3_finalize(foreignKeys) }
        var hasCascade = false
        while true {
            let status = sqlite3_step(foreignKeys)
            if status == SQLITE_DONE { break }
            try check(status, allowingRow: true)
            if textColumn(foreignKeys, 2)?.lowercased() == "clipboard_records",
               textColumn(foreignKeys, 3)?.lowercased() == "record_id",
               textColumn(foreignKeys, 4)?.lowercased() == "id",
               textColumn(foreignKeys, 6)?.uppercased() == "CASCADE" { hasCascade = true }
        }
        guard hasCascade else { throw HistoryStoreError.invalidStoredRecord }
        for event in ["insert", "update", "delete"] {
            let name = "history_cleanup_" + event
            guard try syncScalar("SELECT tbl_name FROM sqlite_master WHERE type = 'trigger' AND name = ? COLLATE NOCASE", [name])?.lowercased() == "clipboard_records",
                  let sql = try syncScalar("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ? COLLATE NOCASE", [name]),
                  try Self.validCleanupTrigger(sql, event: event) else { throw HistoryStoreError.invalidStoredRecord }
        }
    }

    /// Check the small, known token-mutation grammar rather than comparing DDL text. Whitespace,
    /// comments, identifier quoting, case, IF NOT EXISTS and FOR EACH ROW are not semantic changes.
    /// A WHEN clause, UPDATE OF, wrong key, fixed token or empty body must not pass this check.
    private static func validCleanupTrigger(_ sql: String, event: String) throws -> Bool {
        let prefix = "CREATE TRIGGER history_cleanup_\(event) AFTER \(event) ON clipboard_records BEGIN "
        let bodies: [String]
        if event == "delete" {
            bodies = ["DELETE FROM history_cleanup_tokens WHERE record_id = OLD.id",
                      "DELETE FROM history_cleanup_tokens WHERE OLD.id = record_id"]
        } else {
            bodies = [
                "INSERT INTO history_cleanup_tokens(record_id, token) VALUES (NEW.id, randomblob(16)) ON CONFLICT(record_id) DO UPDATE SET token = excluded.token",
                "INSERT OR REPLACE INTO history_cleanup_tokens(record_id, token) VALUES (NEW.id, randomblob(16))"
            ]
        }
        let actual = try cleanupSchemaTokens(sql)
        return try bodies.contains { try cleanupSchemaTokens(prefix + $0 + "; END") == actual }
    }

    static func cleanupSchemaTokens(_ sql: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"/\*[\s\S]*?\*/|--[^\r\n]*|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[(?:[^\]]|\]\])*\]|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|[^\s]"#)
        let source = sql as NSString
        var tokens = expression.matches(in: sql, range: NSRange(location: 0, length: source.length)).compactMap { match -> String? in
            var token = source.substring(with: match.range)
            if token.hasPrefix("/*") || token.hasPrefix("--") || token == ";" { return nil }
            if let quote = token.first, ["\"", "`", "["].contains(String(quote)) {
                token = String(token.dropFirst().dropLast())
                let delimiter = quote == "[" ? "]" : String(quote)
                token = token.replacingOccurrences(of: delimiter + delimiter, with: delimiter)
            }
            return token.lowercased()
        }
        if tokens.starts(with: ["create", "trigger", "if", "not", "exists"]) { tokens.removeSubrange(2..<5) }
        if let index = tokens.indices.first(where: { index in
            index + 2 < tokens.count && Array(tokens[index...index + 2]) == ["for", "each", "row"]
        }) { tokens.removeSubrange(index..<index + 3) }
        return tokens
    }
}
