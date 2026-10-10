import CSQLite
import Foundation

extension HistoryStore {
    public func contentQuotaStatus() throws -> LibraryContentQuotaStatus {
        try synchronized {
            try contentQuotaPolicyTransaction {
                try reconcileContentQuota()
                return try contentQuotaStatusWithoutLock()
            }
        }
    }

    @discardableResult
    public func setContentQuotaLimit(_ bytes: Int64?, expectedRevision: Int64) throws -> LibraryContentQuotaStatus {
        guard bytes == nil || bytes! > 0 else { throw ContentQuotaError.invalidLimit }
        return try synchronized {
            try contentQuotaPolicyTransaction {
                try reconcileContentQuota()
                let current = try contentQuotaStatusWithoutLock()
                guard current.policyRevision == expectedRevision else { throw ContentQuotaError.stalePolicy }
                let revision = try quotaAdding(current.policyRevision, 1)
                let statement = try prepare("UPDATE content_quota_policy SET limit_bytes=?, revision=? WHERE singleton=1")
                defer { sqlite3_finalize(statement) }
                if let bytes { try check(sqlite3_bind_int64(statement, 1, bytes)) }
                else { try check(sqlite3_bind_null(statement, 1)) }
                try check(sqlite3_bind_int64(statement, 2, revision))
                try stepToCompletion(statement)
                return try contentQuotaStatusWithoutLock()
            }
        }
    }

    /// Policy and status never publish sync operations or change integration configuration.
    /// The SQLite writer lock makes reconciliation and compare-and-set atomic across stores.
    private func contentQuotaPolicyTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }

    /// Called only while holding the SQLite writer transaction, after all source tables exist.
    func initializeContentQuotaSchema(previousVersion: Int) throws {
        let existing = try syncScalar("SELECT name FROM sqlite_master WHERE type='table' AND name='content_quota_policy'", []) != nil
        guard existing || previousVersion < 13 else { throw ContentQuotaError.measurementUnavailable }
        if !existing {
            try execute("""
                CREATE TABLE content_quota_policy(singleton INTEGER PRIMARY KEY CHECK(singleton=1), limit_bytes INTEGER CHECK(limit_bytes>0), revision INTEGER NOT NULL CHECK(revision>=0));
                INSERT INTO content_quota_policy VALUES(1,NULL,0);
                CREATE TABLE content_quota_totals(singleton INTEGER PRIMARY KEY CHECK(singleton=1), record_bytes INTEGER NOT NULL CHECK(record_bytes>=0), representation_bytes INTEGER NOT NULL CHECK(representation_bytes>=0), owned_file_bytes INTEGER NOT NULL CHECK(owned_file_bytes>=0), sync_payload_bytes INTEGER NOT NULL CHECK(sync_payload_bytes>=0));
                INSERT INTO content_quota_totals VALUES(1,0,0,0,0);
                CREATE TABLE content_quota_items(kind TEXT NOT NULL, id TEXT NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>=0), PRIMARY KEY(kind,id));
                CREATE TABLE content_quota_representations(record_id TEXT NOT NULL, digest TEXT NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>=0), PRIMARY KEY(record_id,digest));
                CREATE INDEX content_quota_representation_digest ON content_quota_representations(digest);
                CREATE TABLE content_quota_dirty(kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(kind,id));
                """)
        }
        for (table, columns) in [
            ("content_quota_policy", "singleton,limit_bytes,revision"),
            ("content_quota_totals", "singleton,record_bytes,representation_bytes,owned_file_bytes,sync_payload_bytes"),
            ("content_quota_items", "kind,id,bytes"),
            ("content_quota_representations", "record_id,digest,bytes"),
            ("content_quota_dirty", "kind,id")
        ] {
            guard try syncScalar("SELECT type FROM sqlite_master WHERE name=?", [table]) == "table" else { throw ContentQuotaError.measurementUnavailable }
            let validation = try prepare("SELECT \(columns) FROM \(table) LIMIT 0")
            sqlite3_finalize(validation)
        }
        for (table, id, kind) in Self.quotaSources {
            // IDs deliberately have no foreign key: a delete must retain the old ledger entry
            // until reconciliation. UPDATE marks both IDs, including a changed primary key.
            // Explicit UPSERT is also required during foreign-key actions. Reinstall owned
            // triggers so reopening an existing v13 library receives the current definition.
            try execute("""
                DROP TRIGGER IF EXISTS content_quota_\(table)_insert;
                DROP TRIGGER IF EXISTS content_quota_\(table)_delete;
                DROP TRIGGER IF EXISTS content_quota_\(table)_update;
                CREATE TRIGGER IF NOT EXISTS content_quota_\(table)_insert AFTER INSERT ON \(table) BEGIN
                    INSERT INTO content_quota_dirty VALUES('\(kind)',NEW.\(id)) ON CONFLICT(kind,id) DO NOTHING; END;
                CREATE TRIGGER IF NOT EXISTS content_quota_\(table)_delete AFTER DELETE ON \(table) BEGIN
                    INSERT INTO content_quota_dirty VALUES('\(kind)',OLD.\(id)) ON CONFLICT(kind,id) DO NOTHING; END;
                CREATE TRIGGER IF NOT EXISTS content_quota_\(table)_update AFTER UPDATE ON \(table) BEGIN
                    INSERT INTO content_quota_dirty VALUES('\(kind)',OLD.\(id)) ON CONFLICT(kind,id) DO NOTHING;
                    INSERT INTO content_quota_dirty VALUES('\(kind)',NEW.\(id)) ON CONFLICT(kind,id) DO NOTHING; END;
                """)
            if !existing {
                try execute("INSERT INTO content_quota_dirty SELECT '\(kind)',\(id) FROM \(table)")
            }
        }
        // Missing/corrupt prior ledger state is an error, never a new zero baseline.
        _ = try contentQuotaStatusWithoutLock()
        try reconcileContentQuota()
        contentQuotaSchemaReady = true
    }

    private static let quotaSources: [(String, String, String)] = [
        ("clipboard_records", "id", "record"), ("owned_file_assets", "id", "owned"),
        ("sync_inbox", "operation_id", "sync_inbox"), ("sync_outbox", "operation_id", "sync_outbox"),
        ("shared_accepted_operations", "operation_id", "shared_accepted_operations"),
        ("shared_failed_drafts", "operation_id", "shared_failed_drafts")
    ]

    func contentQuotaStatusWithoutLock() throws -> LibraryContentQuotaStatus {
        let statement = try prepare("SELECT t.record_bytes,t.representation_bytes,t.owned_file_bytes,t.sync_payload_bytes,p.limit_bytes,p.revision FROM content_quota_totals t JOIN content_quota_policy p ON p.singleton=t.singleton WHERE t.singleton=1")
        defer { sqlite3_finalize(statement) }
        guard try quotaRow(statement) else { throw ContentQuotaError.measurementUnavailable }
        let values = try (0..<4).map { try quotaInteger(statement, Int32($0)) }
        let used = try values.reduce(Int64(0)) { try quotaAdding($0, $1) }
        let limit: Int64? = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : try quotaInteger(statement, 4)
        guard limit == nil || limit! > 0 else { throw ContentQuotaError.measurementUnavailable }
        let revision = try quotaInteger(statement, 5)
        return LibraryContentQuotaStatus(recordBytes: values[0], representationBytes: values[1], ownedFileBytes: values[2], syncPayloadBytes: values[3], usedBytes: used, limitBytes: limit, policyRevision: revision)
    }

    func finishContentQuota(previous: LibraryContentQuotaStatus?, allowReclamation: Bool) throws {
        guard contentQuotaSchemaReady else { return }
        try reconcileContentQuota()
        let current = try contentQuotaStatusWithoutLock()
        if !allowReclamation, let previous, let limit = current.limitBytes,
           current.usedBytes > limit, current.usedBytes > previous.usedBytes {
            throw ContentQuotaError.exceeded(usedBytes: current.usedBytes, limitBytes: limit)
        }
    }

    /// Work is proportional to changed rows and their representations, not library history.
    /// Only the initial migration scans all counted sources. All arithmetic stays in Int64;
    /// SQLite's promotion of overflowing sums to REAL must never silently lower the total.
    func reconcileContentQuota() throws {
        var totals = try contentQuotaStatusWithoutLock()
        let dirty = try prepare("SELECT kind,id FROM content_quota_dirty ORDER BY kind,id")
        var changed: [(String, String)] = []
        defer { sqlite3_finalize(dirty) }
        while try quotaRow(dirty) {
            guard let kind = textColumn(dirty, 0), let id = textColumn(dirty, 1), !id.isEmpty,
                  Self.quotaSources.contains(where: { $0.2 == kind }) else { throw ContentQuotaError.measurementUnavailable }
            changed.append((kind, id))
        }
        for (kind, id) in changed {
            let old = try quotaItem(kind: kind, id: id)
            let measured: Int64?
            var representationBytes = totals.representationBytes
            if kind == "record" {
                let record = try measureQuotaRecord(id: id)
                measured = record?.0
                representationBytes = try reconcileQuotaRepresentations(recordID: id, desired: record?.1 ?? [:], total: representationBytes)
            } else if kind == "owned" {
                measured = try measureQuotaOwned(id: id)
            } else {
                let statement = try prepare("SELECT typeof(payload),length(payload) FROM \(kind) WHERE operation_id=?")
                defer { sqlite3_finalize(statement) }
                try bind(id, at: 1, to: statement)
                if try quotaRow(statement) {
                    guard textColumn(statement, 0) == "blob" else { throw ContentQuotaError.measurementUnavailable }
                    measured = try quotaInteger(statement, 1)
                } else { measured = nil }
            }
            let new = measured ?? 0 // Absence was confirmed by SQLITE_DONE, not a failed read.
            var recordBytes = totals.recordBytes, ownedBytes = totals.ownedFileBytes, payloadBytes = totals.syncPayloadBytes
            if kind == "record" { recordBytes = try quotaReplacing(recordBytes, old: old, new: new) }
            else if kind == "owned" { ownedBytes = try quotaReplacing(ownedBytes, old: old, new: new) }
            else { payloadBytes = try quotaReplacing(payloadBytes, old: old, new: new) }
            if let measured {
                let statement = try prepare("INSERT INTO content_quota_items VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET bytes=excluded.bytes")
                defer { sqlite3_finalize(statement) }
                try bind(kind, at: 1, to: statement); try bind(id, at: 2, to: statement)
                try check(sqlite3_bind_int64(statement, 3, measured)); try stepToCompletion(statement)
            } else { try syncExecute("DELETE FROM content_quota_items WHERE kind=? AND id=?", [kind, id]) }
            let used = try [recordBytes, representationBytes, ownedBytes, payloadBytes].reduce(Int64(0)) { try quotaAdding($0, $1) }
            totals = LibraryContentQuotaStatus(recordBytes: recordBytes, representationBytes: representationBytes, ownedFileBytes: ownedBytes, syncPayloadBytes: payloadBytes, usedBytes: used, limitBytes: totals.limitBytes, policyRevision: totals.policyRevision)
            try syncExecute("DELETE FROM content_quota_dirty WHERE kind=? AND id=?", [kind, id])
        }
        if !changed.isEmpty {
            let statement = try prepare("UPDATE content_quota_totals SET record_bytes=?,representation_bytes=?,owned_file_bytes=?,sync_payload_bytes=? WHERE singleton=1")
            defer { sqlite3_finalize(statement) }
            for (index, value) in [totals.recordBytes, totals.representationBytes, totals.ownedFileBytes, totals.syncPayloadBytes].enumerated() {
                try check(sqlite3_bind_int64(statement, Int32(index + 1), value))
            }
            try stepToCompletion(statement)
        }
    }

    private func measureQuotaRecord(id: String) throws -> (Int64, [String: Int64])? {
        let statement = try prepare("SELECT text,source_app,source_bundle_id,rtf,html,parts,renamed_title,ocr_text,origin_device_name FROM clipboard_records WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        guard try quotaRow(statement) else { return nil }
        var bytes: Int64 = 0
        for column in Int32(0)..<9 {
            let type = sqlite3_column_type(statement, column)
            guard type == SQLITE_NULL || type == SQLITE_TEXT || type == SQLITE_BLOB,
                  column != 0 || type == SQLITE_TEXT else { throw ContentQuotaError.measurementUnavailable }
            // sqlite3_column_bytes counts the full UTF-8 buffer, including embedded NULs.
            let count = sqlite3_column_bytes(statement, column)
            guard count >= 0 else { throw ContentQuotaError.measurementUnavailable }
            bytes = try quotaAdding(bytes, Int64(count))
        }
        var attachments: [String: Int64] = [:]
        if sqlite3_column_type(statement, 5) != SQLITE_NULL {
            guard let data = dataColumn(statement, 5), let parts = try? JSONDecoder().decode([[StoredRepresentation]].self, from: data) else { throw ContentQuotaError.measurementUnavailable }
            for representation in parts.joined() {
                guard !representation.typeIdentifier.isEmpty, representation.byteCount >= 0,
                      representation.byteCount <= RepresentationStorage.maximumRepresentationBytes,
                      representation.digest.count == 64,
                      representation.digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ContentQuotaError.measurementUnavailable }
                let count = Int64(representation.byteCount)
                if let prior = attachments[representation.digest], prior != count { throw ContentQuotaError.measurementUnavailable }
                attachments[representation.digest] = count
            }
        }
        return (bytes, attachments)
    }

    private func measureQuotaOwned(id: String) throws -> Int64? {
        let statement = try prepare("SELECT metadata FROM owned_file_assets WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        guard try quotaRow(statement) else { return nil }
        guard let data = dataColumn(statement, 0), let asset = try? JSONDecoder().decode(OwnedFileAsset.self, from: data),
              asset.id.uuidString == id, asset.byteCount >= 0, asset.byteCount <= OwnedFileStorage.maximumBytes,
              asset.sha256.count == 64, asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              (try? OwnedFileStorage.validateFilename(asset.filename)) != nil else { throw ContentQuotaError.measurementUnavailable }
        return Int64(asset.byteCount)
    }

    private func reconcileQuotaRepresentations(recordID: String, desired: [String: Int64], total: Int64) throws -> Int64 {
        let statement = try prepare("SELECT digest,bytes FROM content_quota_representations WHERE record_id=?")
        defer { sqlite3_finalize(statement) }
        try bind(recordID, at: 1, to: statement)
        var old: [String: Int64] = [:]
        while try quotaRow(statement) {
            guard let digest = textColumn(statement, 0) else { throw ContentQuotaError.measurementUnavailable }
            old[digest] = try quotaInteger(statement, 1)
        }
        var result = total
        for (digest, bytes) in old where desired[digest] == nil {
            try syncExecute("DELETE FROM content_quota_representations WHERE record_id=? AND digest=?", [recordID, digest])
            if try quotaDigestBytes(digest) == nil { result = try quotaReplacing(result, old: bytes, new: 0) }
        }
        for (digest, bytes) in desired {
            if let prior = old[digest] {
                guard prior == bytes else { throw ContentQuotaError.measurementUnavailable }
                continue
            }
            if let prior = try quotaDigestBytes(digest) {
                guard prior == bytes else { throw ContentQuotaError.measurementUnavailable }
            } else { result = try quotaAdding(result, bytes) }
            let insert = try prepare("INSERT INTO content_quota_representations VALUES(?,?,?)")
            defer { sqlite3_finalize(insert) }
            try bind(recordID, at: 1, to: insert); try bind(digest, at: 2, to: insert)
            try check(sqlite3_bind_int64(insert, 3, bytes)); try stepToCompletion(insert)
        }
        return result
    }

    private func quotaDigestBytes(_ digest: String) throws -> Int64? {
        let statement = try prepare("SELECT bytes FROM content_quota_representations WHERE digest=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(digest, at: 1, to: statement)
        return try quotaRow(statement) ? quotaInteger(statement, 0) : nil
    }

    private func quotaItem(kind: String, id: String) throws -> Int64 {
        let statement = try prepare("SELECT bytes FROM content_quota_items WHERE kind=? AND id=?")
        defer { sqlite3_finalize(statement) }
        try bind(kind, at: 1, to: statement); try bind(id, at: 2, to: statement)
        return try quotaRow(statement) ? quotaInteger(statement, 0) : 0
    }

    private func quotaRow(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        try check(status, allowingRow: true)
        return true
    }

    private func quotaInteger(_ statement: OpaquePointer, _ column: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw ContentQuotaError.measurementUnavailable }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0 else { throw ContentQuotaError.measurementUnavailable }
        return value
    }

    private func quotaAdding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw ContentQuotaError.measurementUnavailable }
        return sum
    }

    private func quotaReplacing(_ total: Int64, old: Int64, new: Int64) throws -> Int64 {
        guard old >= 0, total >= old else { throw ContentQuotaError.measurementUnavailable }
        return try quotaAdding(total - old, new)
    }
}
