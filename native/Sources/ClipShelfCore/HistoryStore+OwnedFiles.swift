import CSQLite
import Foundation

extension HistoryStore {
    public func ownedFileBindings(recordID: UUID) throws -> [OwnedFileBinding] {
        try synchronized { try ownedFileBindingsWithoutLock(recordID: recordID) }
    }

    @discardableResult
    public func create(_ record: ClipboardRecord, ownedFiles: [OwnedFileImport],
                       expectedSyncConfiguration: SyncConfiguration, expectedSharingConfiguration: SyncConfiguration,
                       preserveOrigin: Bool = false) throws -> ClipboardRecord {
        try validate(record)
        guard record.isInHistory || record.pinboardID != nil else { throw HistoryStoreError.invalidStoredRecord }
        return try synchronized {
            try transaction {
                try requireIntegrationConfigurations(sync: expectedSyncConfiguration, sharing: expectedSharingConfiguration)
                try requireOwnedFileAccount(record, sync: expectedSyncConfiguration, sharing: expectedSharingConfiguration)
                var stored = try assigningNewPinboardOrder(assigningLocalOrigin(record, preserveOrigin: preserveOrigin))
                let bindings = try importingOwnedFiles(ownedFiles, into: &stored)
                try insert(stored)
                try setOwnedFileBindingsWithoutLock(bindings, record: stored)
                return stored
            }
        }
    }

    /// Local adoption requires the caller's receipt proof, exact record revision and both account generations.
    /// It does not announce a local path rewrite as a new cloud edit.
    @discardableResult
    public func registerOwnedFiles(recordID: UUID, expectedRevision: Int, ownedFiles: [OwnedFileImport],
                                   expectedSyncConfiguration: SyncConfiguration,
                                   expectedSharingConfiguration: SyncConfiguration) throws -> ClipboardRecord {
        try synchronized {
            let oldSuppression = suppressSyncCapture
            suppressSyncCapture = true
            defer { suppressSyncCapture = oldSuppression }
            return try transaction {
                try requireIntegrationConfigurations(sync: expectedSyncConfiguration, sharing: expectedSharingConfiguration)
                guard var current = try itemWithoutLock(id: recordID) else { throw HistoryStoreError.recordNotFound }
                guard current.revision == expectedRevision else { throw HistoryStoreError.staleRevision }
                try requireOwnedFileAccount(current, sync: expectedSyncConfiguration, sharing: expectedSharingConfiguration)
                let previous = try ownedFileBindingsWithoutLock(recordID: recordID)
                let requested = Set(ownedFiles.map { "\($0.partIndex):\($0.representationIndex)" })
                guard previous.allSatisfy({ !requested.contains("\($0.partIndex):\($0.representationIndex)") }) else { throw HistoryStoreError.invalidOwnedFile }
                let imported = try importingOwnedFiles(ownedFiles, into: &current)
                current.revision += 1
                try validate(current)
                try replaceContents(current)
                try setOwnedFileBindingsWithoutLock(previous + imported, record: current)
                try syncExecute("INSERT OR IGNORE INTO owned_sync_backfill(record_id) VALUES (?)", [current.id.uuidString])
                try publishOwnedSyncBackfillWithoutLock()
                return current
            }
        }
    }

    private func requireOwnedFileAccount(_ record: ClipboardRecord, sync: SyncConfiguration, sharing: SyncConfiguration) throws {
        let namespaces = try [syncNamespace(kind: .clipboard, id: record.id),
                              record.pinboardID.flatMap { try syncNamespace(kind: .pinboard, id: $0) }].compactMap { $0 }
        for namespace in namespaces {
            if let state = try sharedStateForNamespace(namespace) {
                guard state.descriptor.accountID == sharing.accountID else { throw SyncError.accountChanged }
                guard state.access.canWrite else { throw state.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
            } else if namespace != sync.accountID { throw SyncError.namespaceConflict }
        }
    }

    private func importingOwnedFiles(_ files: [OwnedFileImport], into record: inout ClipboardRecord) throws -> [OwnedFileBinding] {
        var slots = Set<String>(), total = 0
        for file in files {
            guard slots.insert("\(file.partIndex):\(file.representationIndex)").inserted,
                  record.parts.indices.contains(file.partIndex),
                  record.parts[file.partIndex].representations.indices.contains(file.representationIndex),
                  record.parts[file.partIndex].representations[file.representationIndex].typeIdentifier == "public.file-url",
                  file.data.count <= OwnedFileStorage.maximumBytes - total else { throw HistoryStoreError.invalidOwnedFile }
            total += file.data.count
            try OwnedFileStorage.validateFilename(file.filename)
        }
        return try files.map { file in
            let asset = try stageOwnedFileWithoutLock(filename: file.filename, data: file.data)
            record.parts[file.partIndex].representations[file.representationIndex].data = Data(try ownedFileStorage.fileURL(asset).absoluteString.utf8)
            return OwnedFileBinding(recordID: record.id, partIndex: file.partIndex,
                                    representationIndex: file.representationIndex, assetID: asset.id)
        }
    }

    func createOwnedFilesSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS owned_file_assets(id TEXT PRIMARY KEY, metadata BLOB NOT NULL, registered_url TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS owned_file_bindings(
                record_id TEXT NOT NULL REFERENCES clipboard_records(id) ON DELETE CASCADE,
                part_index INTEGER NOT NULL CHECK(part_index >= 0),
                representation_index INTEGER NOT NULL CHECK(representation_index >= 0),
                asset_id TEXT NOT NULL REFERENCES owned_file_assets(id),
                PRIMARY KEY(record_id, part_index, representation_index));
            CREATE TABLE IF NOT EXISTS owned_file_operation_bindings(operation_id TEXT PRIMARY KEY, bindings BLOB NOT NULL);
            """)
        ownedFilesSchemaReady = true
    }

    func stageOwnedFileWithoutLock(filename: String, data: Data) throws -> OwnedFileAsset {
        guard newOwnedFileDirectories != nil else { throw HistoryStoreError.invalidOwnedFile }
        try OwnedFileStorage.validateFilename(filename)
        guard data.count <= OwnedFileStorage.maximumBytes else { throw HistoryStoreError.valueTooLarge }
        let asset = OwnedFileAsset(id: UUID(), filename: filename, byteCount: data.count, sha256: RepresentationStorage.digest(data))
        try ownedFileStorage.create(asset, data: data) { newOwnedFileDirectories?.append(asset.id) }
        let statement = try prepare("INSERT INTO owned_file_assets(id, metadata, registered_url) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(asset.id.uuidString, at: 1, to: statement)
        try bind(try JSONEncoder().encode(asset), at: 2, to: statement)
        try bind(try ownedFileStorage.fileURL(asset).absoluteString, at: 3, to: statement)
        try stepToCompletion(statement)
        return asset
    }

    func ownedFileAssetWithoutLock(id: UUID) throws -> OwnedFileAsset {
        let statement = try prepare("SELECT metadata FROM owned_file_assets WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        guard status != SQLITE_DONE else { throw HistoryStoreError.invalidOwnedFile }
        try check(status, allowingRow: true)
        guard let data = dataColumn(statement, 0) else { throw HistoryStoreError.invalidOwnedFile }
        let asset = try JSONDecoder().decode(OwnedFileAsset.self, from: data)
        guard asset.id == id else { throw HistoryStoreError.invalidOwnedFile }
        return asset
    }

    func ownedFileURLWithoutLock(assetID: UUID) throws -> URL {
        try ownedFileStorage.fileURL(ownedFileAssetWithoutLock(id: assetID))
    }

    /// A physical SQLite+attachments snapshot may move as a unit. The binding and its locally
    /// registered URL are authority; an arbitrary URL cannot be adopted by this read projection.
    func rebasingOwnedFileURLsWithoutLock(_ record: ClipboardRecord) throws -> ClipboardRecord {
        try rebasingOwnedFileURLsWithoutLock(record, bindings: ownedFileBindingsWithoutLock(recordID: record.id))
    }

    private func rebasingOwnedFileURLsWithoutLock(_ record: ClipboardRecord, bindings: [OwnedFileBinding]) throws -> ClipboardRecord {
        var result = record
        for binding in bindings {
            guard result.parts.indices.contains(binding.partIndex),
                  result.parts[binding.partIndex].representations.indices.contains(binding.representationIndex) else { throw HistoryStoreError.invalidOwnedFile }
            let slot = result.parts[binding.partIndex].representations[binding.representationIndex]
            let current = try ownedFileURLWithoutLock(assetID: binding.assetID).absoluteString
            let original = try syncScalar("SELECT registered_url FROM owned_file_assets WHERE id = ?", [binding.assetID.uuidString])
            guard slot.typeIdentifier == "public.file-url", let value = String(data: slot.data, encoding: .utf8),
                  value == current || value == original else { throw HistoryStoreError.invalidOwnedFile }
            result.parts[binding.partIndex].representations[binding.representationIndex].data = Data(current.utf8)
        }
        return result
    }

    func ownedFileBindingsWithoutLock(recordID: UUID) throws -> [OwnedFileBinding] {
        let statement = try prepare("SELECT part_index, representation_index, asset_id FROM owned_file_bindings WHERE record_id = ? ORDER BY part_index, representation_index")
        defer { sqlite3_finalize(statement) }
        try bind(recordID.uuidString, at: 1, to: statement)
        var bindings: [OwnedFileBinding] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return bindings }
            try check(status, allowingRow: true)
            guard let id = textColumn(statement, 2).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.invalidOwnedFile }
            bindings.append(OwnedFileBinding(recordID: recordID, partIndex: Int(sqlite3_column_int64(statement, 0)),
                                             representationIndex: Int(sqlite3_column_int64(statement, 1)), assetID: id))
        }
    }

    func ownedBindingMatches(_ binding: OwnedFileBinding, record: ClipboardRecord) throws -> Bool {
        guard record.id == binding.recordID, record.parts.indices.contains(binding.partIndex),
              record.parts[binding.partIndex].representations.indices.contains(binding.representationIndex) else { return false }
        let representation = record.parts[binding.partIndex].representations[binding.representationIndex]
        let expected = Data(try ownedFileURLWithoutLock(assetID: binding.assetID).absoluteString.utf8)
        return representation.typeIdentifier == "public.file-url"
            && representation.data == expected
    }

    func setOwnedFileBindingsWithoutLock(_ bindings: [OwnedFileBinding], record: ClipboardRecord) throws {
        var slots = Set<String>()
        for binding in bindings {
            guard slots.insert("\(binding.partIndex):\(binding.representationIndex)").inserted,
                  try ownedBindingMatches(binding, record: record) else { throw HistoryStoreError.invalidOwnedFile }
        }
        let removal = try prepare("DELETE FROM owned_file_bindings WHERE record_id = ?")
        defer { sqlite3_finalize(removal) }
        try bind(record.id.uuidString, at: 1, to: removal); try stepToCompletion(removal)
        let statement = try prepare("INSERT INTO owned_file_bindings(record_id,part_index,representation_index,asset_id) VALUES (?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        for binding in bindings {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(record.id.uuidString, at: 1, to: statement)
            try check(sqlite3_bind_int64(statement, 2, Int64(binding.partIndex)))
            try check(sqlite3_bind_int64(statement, 3, Int64(binding.representationIndex)))
            try bind(binding.assetID.uuidString, at: 4, to: statement); try stepToCompletion(statement)
        }
    }

    func retainMatchingOwnedFileBindingsWithoutLock(_ record: ClipboardRecord) throws {
        let kept = try ownedFileBindingsWithoutLock(recordID: record.id).filter { try ownedBindingMatches($0, record: record) }
        try setOwnedFileBindingsWithoutLock(kept, record: record)
    }

    func copyOwnedFileBindingsWithoutLock(from originalID: UUID, to record: ClipboardRecord) throws {
        let bindings = try ownedFileBindingsWithoutLock(recordID: originalID).map {
            OwnedFileBinding(recordID: record.id, partIndex: $0.partIndex, representationIndex: $0.representationIndex, assetID: $0.assetID)
        }
        try setOwnedFileBindingsWithoutLock(bindings, record: record)
    }

    /// Local outbox creation is the only writer. Remote operation JSON cannot assert ownership.
    func snapshotOwnedFileBindingsWithoutLock(operationID: UUID, record: ClipboardRecord) throws {
        let bindings = try ownedFileBindingsWithoutLock(recordID: record.id)
        guard !bindings.isEmpty else { return }
        for binding in bindings { guard try ownedBindingMatches(binding, record: record) else { throw HistoryStoreError.invalidOwnedFile } }
        let statement = try prepare("INSERT OR IGNORE INTO owned_file_operation_bindings(operation_id, bindings) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(operationID.uuidString, at: 1, to: statement)
        try bind(try JSONEncoder().encode(bindings), at: 2, to: statement)
        try stepToCompletion(statement)
    }

    func restoreOwnedFileOperationBindingsWithoutLock(operationID: UUID, record: ClipboardRecord) throws {
        let bindings = try ownedFileOperationBindingsWithoutLock(operationID: operationID, recordID: record.id)
        if !bindings.isEmpty { try setOwnedFileBindingsWithoutLock(bindings, record: record) }
    }

    func rebasingOwnedFileOperationRecordWithoutLock(operationID: UUID, record: ClipboardRecord) throws -> ClipboardRecord {
        let bindings = try ownedFileOperationBindingsWithoutLock(operationID: operationID, recordID: record.id)
        return try rebasingOwnedFileURLsWithoutLock(record, bindings: bindings)
    }

    func ownedFileOperationBindingsWithoutLock(operationID: UUID, recordID: UUID) throws -> [OwnedFileBinding] {
        let statement = try prepare("SELECT bindings FROM owned_file_operation_bindings WHERE operation_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(operationID.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return [] }
        try check(status, allowingRow: true)
        guard let data = dataColumn(statement, 0) else { throw HistoryStoreError.invalidOwnedFile }
        return try JSONDecoder().decode([OwnedFileBinding].self, from: data).map {
            OwnedFileBinding(recordID: recordID, partIndex: $0.partIndex, representationIndex: $0.representationIndex, assetID: $0.assetID)
        }
    }

    func backupOwnedFilesWithoutLock(records: [ClipboardRecord]) throws -> (assets: [OwnedFileBackupAsset], bindings: [OwnedFileBinding]) {
        var bindings: [OwnedFileBinding] = [], assets: [OwnedFileBackupAsset] = [], included = Set<UUID>()
        for record in records {
            for binding in try ownedFileBindingsWithoutLock(recordID: record.id) {
                guard try ownedBindingMatches(binding, record: record) else { throw HistoryStoreError.invalidOwnedFile }
                bindings.append(binding)
                if included.insert(binding.assetID).inserted {
                    let asset = try ownedFileAssetWithoutLock(id: binding.assetID)
                    assets.append(OwnedFileBackupAsset(asset: asset, data: try ownedFileStorage.read(asset)))
                }
            }
        }
        return (assets, bindings)
    }
}
