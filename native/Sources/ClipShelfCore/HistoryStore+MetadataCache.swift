import CSQLite
import Foundation

struct MetadataCacheStamp: Equatable {
    let localChanges: Int64
    let externalDataVersion: Int64
}

struct MetadataCacheEntry<Value> {
    let stamp: MetadataCacheStamp
    let value: Value
}

extension HistoryStore {
    /// total_changes covers this connection; data_version covers committed writes from other
    /// connections. Inside a transaction neither cached reads nor cache publication are allowed.
    func metadataCacheStamp() throws -> MetadataCacheStamp? {
        guard sqlite3_get_autocommit(database) != 0 else { return nil }
        let statement = try prepare("PRAGMA data_version")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), allowingRow: true)
        return MetadataCacheStamp(localChanges: sqlite3_total_changes64(database),
                                  externalDataVersion: sqlite3_column_int64(statement, 0))
    }
}
