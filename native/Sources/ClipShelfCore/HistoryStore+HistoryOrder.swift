import CSQLite
import Foundation

extension HistoryStore {
    // This is local arrival order, independent of copiedAt, SQLite rowid, and sync revisions.
    // Keeping it on the record lets first-page reads use an index without a full-history join/sort.
    // Deletion never rewinds the counter. An Undo may put a replacement ID into its old vacant slot.
    private static let historyOrderInsertTrigger = """
        CREATE TRIGGER history_order_insert AFTER INSERT ON clipboard_records BEGIN
            SELECT CASE WHEN (SELECT count(*) FROM history_order_state) != 1
                OR (SELECT last_position FROM history_order_state WHERE singleton = 1) IS NULL
                OR typeof((SELECT last_position FROM history_order_state WHERE singleton = 1)) != 'integer'
                OR (SELECT last_position FROM history_order_state WHERE singleton = 1) < coalesce((SELECT max(local_history_order) FROM clipboard_records), 0)
                OR (SELECT last_position FROM history_order_state WHERE singleton = 1) >= 9223372036854775807
                THEN RAISE(ABORT, 'Invalid local history order counter') END;
            UPDATE history_order_state SET last_position = last_position + 1 WHERE singleton = 1;
            UPDATE clipboard_records SET local_history_order = (SELECT last_position FROM history_order_state WHERE singleton = 1) WHERE id = NEW.id;
        END
        """

    private static let historyOrderUpdateTrigger = """
        CREATE TRIGGER history_order_update BEFORE UPDATE OF local_history_order ON clipboard_records
        WHEN NEW.local_history_order IS NULL OR typeof(NEW.local_history_order) != 'integer'
            OR NEW.local_history_order <= 0
            OR NEW.local_history_order > (SELECT last_position FROM history_order_state WHERE singleton = 1)
        BEGIN SELECT RAISE(ABORT, 'Invalid local history order'); END
        """

    func initializeLocalHistoryOrder(previousVersion: Int) throws {
        if previousVersion < 14 {
            let info = try prepare("PRAGMA table_info(clipboard_records)")
            var hasOrder = false, hasPinboardIdentity = false
            while true {
                let status = sqlite3_step(info)
                if status == SQLITE_DONE { break }
                do { try check(status, allowingRow: true) }
                catch { sqlite3_finalize(info); throw error }
                if textColumn(info, 1) == "local_history_order" { hasOrder = true }
                if textColumn(info, 1) == "pinboard_order_identity" { hasPinboardIdentity = true }
            }
            sqlite3_finalize(info)
            if !hasOrder {
                // The whole installation and version stamp share the migration writer transaction.
                // Preserve existing sync dirty sets and cleanup confirmation tokens: this changes
                // only a local index, not clipboard contents or their causal revision.
                let updateTriggerNames = ["history_cleanup_update", "sync_clipboard_update", "content_quota_clipboard_records_update"]
                var suspended: [String] = []
                for name in updateTriggerNames {
                    if let sql = try syncScalar("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'clipboard_records' AND name = ?", [name]) {
                        suspended.append(sql)
                        try execute("DROP TRIGGER \(name)")
                    }
                }
                let count = try syncScalar("SELECT count(*) FROM clipboard_records", []).flatMap(Int64.init) ?? 0
                let bytes = try HistoryWriteBudget.adding(262_144,
                    HistoryWriteBudget.adding(existingDatabaseRewriteBytesWithoutLock(), HistoryWriteBudget.multiplying(count, by: 256)))
                try writeBudget?.reserveDatabase(bytes: bytes, destination: databaseURL)
                if !hasPinboardIdentity { try execute("ALTER TABLE clipboard_records ADD COLUMN pinboard_order_identity TEXT") }
                try execute("""
                    ALTER TABLE clipboard_records ADD COLUMN local_history_order INTEGER
                        CHECK(local_history_order IS NULL OR (typeof(local_history_order) = 'integer' AND local_history_order > 0));
                    CREATE TABLE history_order_state(singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                        last_position INTEGER NOT NULL CHECK(typeof(last_position) = 'integer' AND last_position >= 0));
                    WITH positions AS (SELECT id, row_number() OVER (ORDER BY rowid) AS position FROM clipboard_records)
                    UPDATE clipboard_records SET local_history_order = (SELECT position FROM positions WHERE positions.id = clipboard_records.id);
                    INSERT INTO history_order_state(singleton, last_position) SELECT 1, coalesce(max(local_history_order), 0) FROM clipboard_records;
                    CREATE UNIQUE INDEX clipboard_local_history_order ON clipboard_records(local_history_order);
                    """)
                for sql in suspended { try execute(sql) }
                try execute(Self.historyOrderInsertTrigger)
                try execute(Self.historyOrderUpdateTrigger)
            } else if !hasPinboardIdentity {
                try execute("ALTER TABLE clipboard_records ADD COLUMN pinboard_order_identity TEXT")
            }
            // A pre-version-stamp fixture or a concurrent opener may already have the schema.
            // Validate it, never reset its counter or overwrite existing Undo-restored positions.
        }
        try requireLocalHistoryOrderSchema()
    }

    private func requireLocalHistoryOrderSchema() throws {
        try requireStartupTable("clipboard_records", columns: [
            ("local_history_order", "INTEGER", false), ("pinboard_order_identity", "TEXT", false)
        ], primaryKey: [])
        try requireStartupTable("history_order_state", columns: [
            ("singleton", "INTEGER", false), ("last_position", "INTEGER", true)
        ], primaryKey: ["singleton"])
        let indexes = try prepare("PRAGMA index_list(clipboard_records)")
        var foundIndex = false
        while true {
            let status = sqlite3_step(indexes)
            if status == SQLITE_DONE { break }
            do { try check(status, allowingRow: true) }
            catch { sqlite3_finalize(indexes); throw error }
            if textColumn(indexes, 1) == "clipboard_local_history_order" {
                foundIndex = sqlite3_column_int(indexes, 2) == 1 && sqlite3_column_int(indexes, 4) == 0
            }
        }
        sqlite3_finalize(indexes)
        guard foundIndex else { throw HistoryStoreError.invalidStoredRecord }
        let index = try prepare("PRAGMA index_info(clipboard_local_history_order)")
        defer { sqlite3_finalize(index) }
        guard sqlite3_step(index) == SQLITE_ROW, textColumn(index, 2) == "local_history_order",
              sqlite3_step(index) == SQLITE_DONE else { throw HistoryStoreError.invalidStoredRecord }
        for (name, expected) in [("history_order_insert", Self.historyOrderInsertTrigger),
                                 ("history_order_update", Self.historyOrderUpdateTrigger)] {
            guard let sql = try syncScalar("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'clipboard_records' AND name = ?", [name]),
                  try Self.cleanupSchemaTokens(sql) == Self.cleanupSchemaTokens(expected) else {
                throw HistoryStoreError.invalidStoredRecord
            }
        }
        let counter = try historyOrderCounterWithoutLock()
        // MAX uses the unique index; ordinary startup never scans/backfills clipboard rows.
        let maximum = try prepare("SELECT max(local_history_order) FROM clipboard_records")
        defer { sqlite3_finalize(maximum) }
        try check(sqlite3_step(maximum), allowingRow: true)
        if sqlite3_column_type(maximum, 0) != SQLITE_NULL {
            try requireHistoryOrderColumn(maximum, at: 0)
            guard counter >= sqlite3_column_int64(maximum, 0) else { throw HistoryStoreError.invalidStoredRecord }
        }
    }

    private func historyOrderCounterWithoutLock() throws -> Int64 {
        let statement = try prepare("SELECT singleton, last_position FROM history_order_state")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER, sqlite3_column_int64(statement, 0) == 1,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER else { throw HistoryStoreError.invalidStoredRecord }
        let value = sqlite3_column_int64(statement, 1)
        guard value >= 0, sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.invalidStoredRecord }
        return value
    }

    func requireHistoryOrderColumn(_ statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_column_count(statement) > index, sqlite3_column_type(statement, index) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, index) > 0 else { throw HistoryStoreError.invalidStoredRecord }
    }

    func decodePinboardOrderIdentity(_ statement: OpaquePointer, at index: Int32) throws -> UUID? {
        guard sqlite3_column_count(statement) > index else { throw HistoryStoreError.invalidStoredRecord }
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let raw = textColumn(statement, index), let value = UUID(uuidString: raw) else {
            throw HistoryStoreError.invalidStoredRecord
        }
        return value
    }

    func historyOrderWithoutLock(id: UUID) throws -> Int64 {
        let statement = try prepare("SELECT local_history_order FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        guard status != SQLITE_DONE else { throw HistoryStoreError.recordNotFound }
        try check(status, allowingRow: true)
        try requireHistoryOrderColumn(statement, at: 0)
        return sqlite3_column_int64(statement, 0)
    }

    func validateRestoredHistoryOrderWithoutLock(_ order: Int64) throws {
        guard order > 0, order <= (try historyOrderCounterWithoutLock()) else { throw HistoryStoreError.invalidStoredRecord }
    }

    func restoreHistoryOrderWithoutLock(id: UUID, order: Int64) throws {
        try validateRestoredHistoryOrderWithoutLock(order)
        let statement = try prepare("UPDATE clipboard_records SET local_history_order = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, order))
        try bind(id.uuidString, at: 2, to: statement)
        try stepToCompletion(statement)
        guard sqlite3_changes(database) == 1 else { throw HistoryStoreError.recordNotFound }
    }
}
