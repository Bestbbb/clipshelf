import CSQLite
import Foundation

/// A transaction owns these cooperative reservations while SQLite and file rollback are still
/// possible. This is a conservative preflight, not a physical reservation of filesystem blocks.
/// The caller already holds the SQLite writer lock; the coordinator never acquires that lock.
final class HistoryWriteBudget {
    let coordinator: StorageSpaceCoordinator
    private var lease: StorageSpaceLease?
    private(set) var isPrepaid = false
    private let allowReclamation: Bool

    init(coordinator: StorageSpaceCoordinator, allowReclamation: Bool = false) {
        self.coordinator = coordinator
        self.allowReclamation = allowReclamation
    }
    deinit { release() }

    func prepay(_ requirements: [StorageSpaceRequirement]) throws {
        precondition(lease == nil && !isPrepaid)
        let lease = try coordinator.reserve(requirements)
        do { try lease.revalidate() } catch { try? lease.release(); throw error }
        self.lease = lease
        isPrepaid = true
    }

    func reserveDatabase(bytes: Int64, destination: URL) throws {
        guard !isPrepaid, !allowReclamation else { return }
        let requirements = [StorageSpaceRequirement(destination: destination, bytes: bytes)]
        if let lease {
            // Atomically extend one live reservation; do not accumulate one descriptor per
            // row in an otherwise unbounded batch or release protection before COMMIT.
            try lease.addRequirements(requirements)
        } else {
            let lease = try coordinator.reserve(requirements)
            do { try lease.revalidate() } catch { try? lease.release(); throw error }
            self.lease = lease
        }
    }

    func validateDestinations() throws {
        try lease?.validateDestinations()
    }

    func release() {
        // A cleanup error after COMMIT must never turn a committed save into a failed capture.
        let previous = lease
        lease = nil
        try? previous?.release()
    }

    /// New database pages, WAL and FTS terms. Sync payloads are budgeted after encoding,
    /// at their actual outbox/inbox insertion point, including ordering-only operations.
    /// Never subtract an old row: rollback and WAL checkpointing can keep both versions alive.
    static func databaseBytes(for record: ClipboardRecord, pageAllowance: Int64 = 262_144) throws -> Int64 {
        var inline: Int64 = 0
        for value in [record.text, record.sourceApp, record.sourceBundleID, record.renamedTitle,
                      record.ocrText, record.originDeviceName].compactMap({ $0 }) {
            inline = try adding(inline, Int64(value.utf8.count))
        }
        inline = try adding(inline, Int64(record.rtf?.count ?? 0))
        inline = try adding(inline, Int64(record.html?.count ?? 0))
        for part in record.parts {
            inline = try adding(inline, 128)
            for representation in part.representations {
                inline = try adding(inline, Int64(representation.typeIdentifier.utf8.count) + 256)
            }
        }
        // FTS and B-tree splits vary with prior state, so leave a fixed page allowance plus
        // room for the original row, its WAL and both text indexes. Real disk errors still win.
        return try adding(pageAllowance, multiplying(inline, by: 8))
    }

    static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw HistoryStoreError.valueTooLarge }
        return value
    }

    static func multiplying(_ value: Int64, by count: Int64) throws -> Int64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: count)
        guard value >= 0, count >= 0, !overflow else { throw HistoryStoreError.valueTooLarge }
        return result
    }
}

extension HistoryStore {
    func reserveRecordWriteWithoutLock(_ record: ClipboardRecord) throws {
        try writeBudget?.reserveDatabase(bytes: HistoryWriteBudget.databaseBytes(for: record), destination: databaseURL)
    }

    func reserveMetadataWriteWithoutLock(rows: Int64 = 1, payloadBytes: Int64 = 0) throws {
        let bytes = try HistoryWriteBudget.adding(65_536,
            HistoryWriteBudget.adding(HistoryWriteBudget.multiplying(rows, by: 4_096),
                                     HistoryWriteBudget.multiplying(payloadBytes, by: 8)))
        try writeBudget?.reserveDatabase(bytes: bytes, destination: databaseURL)
    }

    func reserveSyncPayloadWithoutLock(_ payload: Data) throws {
        try reserveSyncPayloadWithoutLock(byteCount: Int64(payload.count))
    }

    func reserveSyncPayloadWithoutLock(byteCount: Int64, retiringByteCount: Int64 = 0) throws {
        let fresh = try HistoryWriteBudget.multiplying(byteCount, by: 3)
        // A copy followed by secure_delete must retain both versions and rewrite old pages.
        // Retiring bytes add to the write peak; they are never a credit against free space.
        let retiring = try HistoryWriteBudget.multiplying(retiringByteCount, by: 2)
        let bytes = try HistoryWriteBudget.adding(131_072, HistoryWriteBudget.adding(fresh, retiring))
        try writeBudget?.reserveDatabase(bytes: bytes, destination: databaseURL)
    }

    /// secure_delete and UPDATE can rewrite the old overflow pages even when the new row
    /// is tiny. Measure inline bytes in SQLite without loading or decoding attachment files.
    func reserveExistingRecordRewriteWithoutLock(id: UUID) throws {
        guard let writeBudget, !writeBudget.isPrepaid else { return }
        let columns = ["text", "source_app", "source_bundle_id", "rtf", "html", "parts",
                       "renamed_title", "ocr_text", "origin_device_name"]
        let lengths = columns.map { "COALESCE(length(CAST(\($0) AS BLOB)), 0)" }.joined(separator: " + ")
        let statement = try prepare("SELECT " + lengths + " FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        guard status != SQLITE_DONE else { return }
        try check(status, allowingRow: true)
        let bytes = try HistoryWriteBudget.adding(65_536,
            HistoryWriteBudget.multiplying(sqlite3_column_int64(statement, 0), by: 8))
        try writeBudget.reserveDatabase(bytes: bytes, destination: databaseURL)
    }

    func databasePageValueWithoutLock(_ name: String) throws -> Int64 {
        precondition(name == "page_count" || name == "page_size")
        let statement = try prepare("PRAGMA " + name)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), allowingRow: true)
        return sqlite3_column_int64(statement, 0)
    }

    /// Reserve an additional rewrite of the existing database and a complete WAL pass.
    /// The old database is still on disk; its bytes are never credited as available space.
    func existingDatabaseRewriteBytesWithoutLock() throws -> Int64 {
        let pages = try databasePageValueWithoutLock("page_count")
        let pageSize = try databasePageValueWithoutLock("page_size")
        let frames = try HistoryWriteBudget.multiplying(pages, by: HistoryWriteBudget.adding(pageSize, 24))
        let database = try HistoryWriteBudget.multiplying(pages, by: pageSize)
        return try HistoryWriteBudget.adding(32, HistoryWriteBudget.adding(database, frames))
    }
}

extension HistoryStore {
    /// SQLite's logical page count includes committed pages that only exist in the WAL.
    /// File enumeration is confined to our attachment tree and never follows external references.
    func physicalRecoveryBackupBytesWithoutLock() throws -> Int64 {
        var total = try HistoryWriteBudget.multiplying(databasePageValueWithoutLock("page_count"),
                                                      by: databasePageValueWithoutLock("page_size"))
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: representations.directory,
            includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw HistoryStoreError.corruptAttachment }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink == false else { throw HistoryStoreError.corruptAttachment }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw HistoryStoreError.corruptAttachment
            }
            total = try HistoryWriteBudget.adding(total, Int64(size))
        }
        if let enumerationError { throw enumerationError }
        return total
    }
}
