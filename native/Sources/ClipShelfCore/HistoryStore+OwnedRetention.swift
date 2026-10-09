import CSQLite
import Darwin
import Foundation

extension HistoryStore {
    func createOwnedStorageSchema(protectLegacy: Bool) throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS owned_asset_leases(id TEXT PRIMARY KEY,purpose TEXT NOT NULL,device TEXT NOT NULL,inode TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS owned_asset_lease_roots(lease_id TEXT NOT NULL REFERENCES owned_asset_leases(id) ON DELETE CASCADE,asset_id TEXT NOT NULL REFERENCES owned_file_assets(id),PRIMARY KEY(lease_id,asset_id));
            CREATE TABLE IF NOT EXISTS owned_asset_publications(id TEXT PRIMARY KEY,purpose TEXT NOT NULL,created_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS owned_asset_publication_roots(publication_id TEXT NOT NULL REFERENCES owned_asset_publications(id) ON DELETE CASCADE,asset_id TEXT NOT NULL REFERENCES owned_file_assets(id),PRIMARY KEY(publication_id,asset_id));
            CREATE TABLE IF NOT EXISTS owned_gc_journal(operation_id TEXT NOT NULL,asset_id TEXT NOT NULL,phase TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(operation_id,asset_id));
            CREATE UNIQUE INDEX IF NOT EXISTS owned_gc_journal_asset ON owned_gc_journal(asset_id);
            """)
        if protectLegacy {
            let ids = try ownedAllAssetIDs()
            if !ids.isEmpty { _ = try publishOwnedAssetsWithoutLock(ids, purpose: .legacyExternal) }
        }
    }
    func ownedAllAssetIDs() throws -> Set<UUID> {
        try ownedUUIDSet("SELECT id FROM owned_file_assets")
    }
    func ownedUUIDSet(_ sql: String, values: [String?] = []) throws -> Set<UUID> {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
        var ids = Set<UUID>()
        while true {
            let status = sqlite3_step(statement); if status == SQLITE_DONE { return ids }; try check(status, allowingRow: true)
            guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.invalidOwnedFile }
            ids.insert(id)
        }
    }
    func ownedMaintenanceDirectory(_ name: String) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw HistoryStoreError.invalidOwnedFile }
        do {
            for component in ownedFileStorage.directory.pathComponents.dropFirst() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw HistoryStoreError.invalidOwnedFile }
                Darwin.close(descriptor); descriptor = next
            }
            if mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST { throw HistoryStoreError.invalidOwnedFile }
            let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HistoryStoreError.invalidOwnedFile }
            Darwin.close(descriptor); return next
        } catch { Darwin.close(descriptor); throw error }
    }
    func retainOwnedAssetsWithoutLock(_ ids: Set<UUID>, purpose: OwnedAssetRetentionPurpose) throws -> OwnedAssetLease {
        let id = UUID()
        if ids.isEmpty { return OwnedAssetLease(id: id, storeIdentity: selectionStoreIdentity, assetIDs: [], descriptor: -1) }
        for id in ids { _ = try ownedFileAssetWithoutLock(id: id) }
        let directory = try ownedMaintenanceDirectory(".leases"); defer { Darwin.close(directory) }
        let fd = openat(directory, id.uuidString, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HistoryStoreError.invalidOwnedFile }
        var transferred = false
        defer { if !transferred { Darwin.close(fd); _ = unlinkat(directory, id.uuidString, 0) } }
        var identity = stat()
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, fstat(fd, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG, identity.st_nlink == 1 else { throw HistoryStoreError.invalidOwnedFile }
        try syncExecute("INSERT INTO owned_asset_leases(id,purpose,device,inode) VALUES (?,?,?,?)", [id.uuidString, purpose.rawValue, String(identity.st_dev), String(identity.st_ino)])
        for assetID in ids { try syncExecute("INSERT INTO owned_asset_lease_roots(lease_id,asset_id) VALUES (?,?)", [id.uuidString, assetID.uuidString]) }
        transferred = true
        return OwnedAssetLease(id: id, storeIdentity: selectionStoreIdentity, assetIDs: ids, descriptor: fd)
    }
    func capturedOwnedIDsWithoutLock(_ records: [ClipboardRecord]) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for record in records {
            for representation in record.parts.flatMap(\.representations) where ClipboardFileAccess.isFileURLType(representation.typeIdentifier) {
                guard let url = ClipboardFileAccess.url(from: representation.data) else { continue }
                let parent = url.deletingLastPathComponent(), assetDirectory = parent.deletingLastPathComponent()
                guard parent.lastPathComponent == "files", let id = UUID(uuidString: assetDirectory.lastPathComponent) else { continue }
                let matchesCurrentRoot = assetDirectory.deletingLastPathComponent().standardizedFileURL.path == ownedFileStorage.directory.standardizedFileURL.path
                guard let registered = try syncScalar("SELECT registered_url FROM owned_file_assets WHERE id=?", [id.uuidString]),
                      let oldURL = URL(string: registered) else {
                    if matchesCurrentRoot { throw ClipboardFileRepairError.unavailableOutput }
                    continue
                }
                let asset = try ownedFileAssetWithoutLock(id: id), current = try ownedFileStorage.fileURL(asset)
                if url.path == oldURL.path || url.path == current.path { ids.insert(id) }
                else if matchesCurrentRoot { throw ClipboardFileRepairError.unavailableOutput }
            }
        }
        return ids
    }
    public func retainCapturedOwnedFiles(_ records: [ClipboardRecord], purpose: OwnedAssetRetentionPurpose) throws -> OwnedAssetLease {
        try synchronized { try transaction { try retainOwnedAssetsWithoutLock(capturedOwnedIDsWithoutLock(records), purpose: purpose) } }
    }
    public func recordRetainingCapturedOwnedFiles(_ candidate: ClipboardRecord, purpose: OwnedAssetRetentionPurpose = .stack) throws -> RetainedClipboardRecords {
        try validate(candidate)
        return try synchronized {
            try transaction {
                // Claim existing managed paths before any capture coalescing can change a row.
                let ids = try capturedOwnedIDsWithoutLock([candidate])
                let record = try recordWithoutLock(candidate)
                let lease = try retainOwnedAssetsWithoutLock(ids, purpose: purpose)
                return RetainedClipboardRecords(records: [record], lease: lease)
            }
        }
    }
    public func publishOwnedFiles(lease: OwnedAssetLease, purpose: OwnedAssetPublicationPurpose) throws -> OwnedAssetPublication {
        try synchronized {
            guard lease.storeIdentity == selectionStoreIdentity else { throw OwnedStorageError.invalidLease }
            return try transaction {
                for id in lease.assetIDs {
                    guard ownedFileStorage.projectionAvailability(try ownedFileAssetWithoutLock(id: id)) == .available else { throw ClipboardFileRepairError.unavailableOutput }
                    guard try syncScalar("SELECT asset_id FROM owned_asset_lease_roots WHERE lease_id=? AND asset_id=?", [lease.id.uuidString, id.uuidString]) != nil else { throw OwnedStorageError.invalidLease }
                }
                return try publishOwnedAssetsWithoutLock(lease.assetIDs, purpose: purpose)
            }
        }
    }
    func publishOwnedAssetsWithoutLock(_ ids: Set<UUID>, purpose: OwnedAssetPublicationPurpose) throws -> OwnedAssetPublication {
        let id = UUID(), createdAt = Date()
        if ids.isEmpty { return OwnedAssetPublication(id: id, purpose: purpose, fileURLs: [], createdAt: createdAt, storeIdentity: selectionStoreIdentity) }
        let statement = try prepare("INSERT INTO owned_asset_publications(id,purpose,created_at) VALUES (?,?,?)"); defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement); try bind(purpose.rawValue, at: 2, to: statement)
        try check(sqlite3_bind_double(statement, 3, createdAt.timeIntervalSinceReferenceDate)); try stepToCompletion(statement)
        var urls: [URL] = []
        for assetID in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            urls.append(try ownedFileURLWithoutLock(assetID: assetID))
            try syncExecute("INSERT INTO owned_asset_publication_roots(publication_id,asset_id) VALUES (?,?)", [id.uuidString, assetID.uuidString])
        }
        return OwnedAssetPublication(id: id, purpose: purpose, fileURLs: urls, createdAt: createdAt, storeIdentity: selectionStoreIdentity)
    }
    public func ownedPublications(purpose: OwnedAssetPublicationPurpose? = nil) throws -> [OwnedAssetPublication] {
        try synchronized {
            let statement = try prepare("SELECT id,purpose,created_at FROM owned_asset_publications" + (purpose == nil ? "" : " WHERE purpose=?") + " ORDER BY rowid")
            defer { sqlite3_finalize(statement) }; if let purpose { try bind(purpose.rawValue, at: 1, to: statement) }
            var result: [OwnedAssetPublication] = []
            while true {
                let status = sqlite3_step(statement); if status == SQLITE_DONE { return result }; try check(status, allowingRow: true)
                guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)), let kind = textColumn(statement, 1).flatMap(OwnedAssetPublicationPurpose.init(rawValue:)) else { throw HistoryStoreError.invalidOwnedFile }
                let ids = try ownedUUIDSet("SELECT asset_id FROM owned_asset_publication_roots WHERE publication_id=?", values: [id.uuidString])
                result.append(OwnedAssetPublication(id: id, purpose: kind, fileURLs: try ids.sorted(by: { $0.uuidString < $1.uuidString }).map { try ownedFileURLWithoutLock(assetID: $0) }, createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)), storeIdentity: selectionStoreIdentity))
            }
        }
    }
    public func releaseOwnedPublication(_ publication: OwnedAssetPublication) throws {
        try synchronized {
            guard publication.storeIdentity == selectionStoreIdentity else { throw OwnedStorageError.invalidLease }
            try transaction { try syncExecute("DELETE FROM owned_asset_publications WHERE id=? AND purpose=?", [publication.id.uuidString, publication.purpose.rawValue]) }
        }
    }
    public func clearLegacyOwnedPublications(expectedIDs: Set<UUID>) throws {
        try synchronized {
            try transaction {
                let current = try ownedUUIDSet("SELECT id FROM owned_asset_publications WHERE purpose='legacyExternal'")
                guard current == expectedIDs else { throw OwnedStorageError.changed }
                try execute("DELETE FROM owned_asset_publications WHERE purpose='legacyExternal'")
            }
        }
    }
    func ownedRetentionTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    /// Returns live or unverifiable lease IDs. Dead locks are only pruned under the writer lock.
    func liveOwnedLeaseIDs(prune: Bool) throws -> Set<UUID> {
        let directory = try ownedMaintenanceDirectory(".leases"); defer { Darwin.close(directory) }
        let statement = try prepare("SELECT id,device,inode FROM owned_asset_leases"); defer { sqlite3_finalize(statement) }
        var live = Set<UUID>(), stale: [UUID] = []
        while true {
            let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; try check(status, allowingRow: true)
            guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)), let device = textColumn(statement, 1), let inode = textColumn(statement, 2) else { throw HistoryStoreError.invalidOwnedFile }
            let fd = openat(directory, id.uuidString, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { live.insert(id); continue }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  String(info.st_dev) == device, String(info.st_ino) == inode else { live.insert(id); continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { stale.append(id) }
            else { live.insert(id) }
        }
        if prune {
            for id in stale { try syncExecute("DELETE FROM owned_asset_leases WHERE id=?", [id.uuidString]) }
            // Lock files are tiny identities. Retaining closed files avoids unlink/replacement races;
            // no asset is retained by a file after its lease row has been removed.
        }
        return live
    }
}
