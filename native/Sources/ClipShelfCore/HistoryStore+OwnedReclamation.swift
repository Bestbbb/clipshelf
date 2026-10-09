import CSQLite
import Foundation

extension HistoryStore {
    /// A plain copied URL never grants ownership, but it must keep an already registered
    /// asset alive while a history record still refers to that exact local file.
    func ownedAssetIDsReferencedByRecordMetadata(recordIDs: Set<UUID>? = nil) throws -> Set<UUID> {
        let assets = try ownedAllAssetIDs()
        var urls: [String: Set<UUID>] = [:]
        for id in assets {
            let current = try ownedFileURLWithoutLock(assetID: id).absoluteString
            let original = try syncScalar("SELECT registered_url FROM owned_file_assets WHERE id=?", [id.uuidString])
            for url in [current, original].compactMap({ $0 }) { urls[RepresentationStorage.digest(Data(url.utf8)), default: []].insert(id) }
        }
        let statement = try prepare("SELECT id,parts FROM clipboard_records WHERE parts IS NOT NULL"); defer { sqlite3_finalize(statement) }
        var referenced = Set<UUID>()
        while true {
            let status = sqlite3_step(statement); if status == SQLITE_DONE { return referenced }; try check(status, allowingRow: true)
            guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)), let data = dataColumn(statement, 1) else { throw HistoryStoreError.invalidStoredRecord }
            if let recordIDs, !recordIDs.contains(id) { continue }
            for part in try JSONDecoder().decode([[StoredRepresentation]].self, from: data) {
                for representation in part where ClipboardFileAccess.isFileURLType(representation.typeIdentifier) {
                    if let exact = urls[representation.digest] { referenced.formUnion(exact); continue }
                    // Equivalent file URLs can have different percent-encoding. Only read URL
                    // representations here, never an external referenced file or full image payload.
                    guard representation.byteCount <= 64 * 1_024 else { throw HistoryStoreError.invalidOwnedFile }
                    let url = try representations.url(for: representation.digest)
                    let descriptor = SyncOwnedFileDescriptor(digest: representation.digest, byteCount: representation.byteCount, filename: url.lastPathComponent)
                    let value = try SyncOwnedFileStaging.readVerified(fileURL: url, descriptor: descriptor)
                    referenced.formUnion(try capturedOwnedIDsWithoutLock([ClipboardRecord(text: "", parts: [.init(representations: [.init(typeIdentifier: representation.typeIdentifier, data: value)])])]))
                }
            }
        }
    }
    func ownedPersistentOperationIDs() throws -> Set<UUID> {
        var ids = Set<UUID>()
        for table in ["sync_outbox", "sync_inbox", "shared_accepted_operations", "shared_failed_drafts"] {
            ids.formUnion(try ownedUUIDSet("SELECT operation_id FROM \(table)"))
        }
        return ids
    }
    func ownedReachableAssets(pruneDeadLeases: Bool) throws -> Set<UUID> {
        var roots = try ownedUUIDSet("SELECT asset_id FROM owned_file_bindings")
        roots.formUnion(try ownedAssetIDsReferencedByRecordMetadata())
        roots.formUnion(try ownedUUIDSet("SELECT asset_id FROM owned_asset_publication_roots"))
        for lease in try liveOwnedLeaseIDs(prune: pruneDeadLeases) {
            roots.formUnion(try ownedUUIDSet("SELECT asset_id FROM owned_asset_lease_roots WHERE lease_id=?", values: [lease.uuidString]))
        }
        let liveOperations = try ownedPersistentOperationIDs()
        let snapshots = try prepare("SELECT operation_id,bindings FROM owned_file_operation_bindings"); defer { sqlite3_finalize(snapshots) }
        while true {
            let status = sqlite3_step(snapshots); if status == SQLITE_DONE { break }; try check(status, allowingRow: true)
            guard let id = textColumn(snapshots, 0).flatMap(UUID.init(uuidString:)), let data = dataColumn(snapshots, 1) else { throw HistoryStoreError.invalidOwnedFile }
            if liveOperations.contains(id) { roots.formUnion(try JSONDecoder().decode([OwnedFileBinding].self, from: data).map(\.assetID)) }
        }
        // Partial verified downloads have cache mappings before operation bindings exist.
        let inbox = try prepare("SELECT payload FROM sync_inbox"); defer { sqlite3_finalize(inbox) }
        for operation in try syncReadOperations(inbox) {
            guard let scope = try ownedScopeWithoutLock(namespace: operation.accountID) else { continue }
            for file in operation.ownedFiles?.files ?? [] {
                if let id = try syncScalar("SELECT asset_id FROM owned_sync_assets WHERE scope_key=? AND digest=? AND filename=?", [ownedScopeKey(scope), file.digest, file.filename]).flatMap(UUID.init(uuidString:)) { roots.insert(id) }
            }
        }
        return roots
    }
    func ownedCleanupSnapshot() throws -> (OwnedStorageUsage, [OwnedFileReclamationCandidate]) {
        let ids = try ownedAllAssetIDs(), roots = try ownedReachableAssets(pruneDeadLeases: false)
        var candidates: [OwnedFileReclamationCandidate] = [], unverified = 0
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where !roots.contains(id) {
            do {
                if let candidate = try ownedFileStorage.prepareReclamation(ownedFileAssetWithoutLock(id: id)) { candidates.append(candidate) }
                else { unverified += 1 }
            } catch { unverified += 1 }
        }
        let measure = try ownedFileStorage.ownedStorageMeasurement(registeredAssetIDs: ids)
        let legacy = try ownedUUIDSet("SELECT asset_id FROM owned_asset_publication_roots JOIN owned_asset_publications ON id=publication_id WHERE purpose='legacyExternal'")
        let pending = Int(try syncScalar("SELECT CAST(COUNT(*) AS TEXT) FROM owned_gc_journal", []) ?? "0") ?? 0
        let usage = OwnedStorageUsage(assetCount: ids.count + measure.unregisteredDirectoryIDs.count,
                                      totalLogicalBytes: measure.logicalBytes, totalAllocatedBytes: measure.allocatedBytes,
                                      reclaimableAssetCount: candidates.count, reclaimableLogicalBytes: candidates.reduce(0) { $0 + $1.logicalBytes },
                                      protectedAssetCount: roots.intersection(ids).count,
                                      unverifiedAssetCount: unverified + measure.unknownEntryCount + measure.skippedEntryCount,
                                      pendingReclamationCount: pending, legacyProtectedAssetCount: legacy.count, measurementComplete: measure.isComplete)
        return (usage, candidates)
    }
    public func ownedStorageUsage() throws -> OwnedStorageUsage {
        try synchronized { try ownedRetentionTransaction { try ownedCleanupSnapshot().0 } }
    }
    public func prepareOwnedStorageCleanup() throws -> OwnedStorageCleanupPlan {
        try synchronized {
            try ownedRetentionTransaction {
                let (usage, candidates) = try ownedCleanupSnapshot()
                return OwnedStorageCleanupPlan(usage: usage, storeIdentity: selectionStoreIdentity,
                                               syncConfiguration: try syncConfigurationWithoutLock(), sharingConfiguration: try sharingConfigurationWithoutLock(), candidates: candidates)
            }
        }
    }
    func writeOwnedGCJournal(_ token: QuarantinedOwnedFile, phase: String) throws {
        let statement = try prepare("INSERT INTO owned_gc_journal(operation_id,asset_id,phase,payload) VALUES (?,?,?,?) ON CONFLICT(operation_id,asset_id) DO UPDATE SET phase=excluded.phase,payload=excluded.payload")
        defer { sqlite3_finalize(statement) }; try bind(token.operationID.uuidString, at: 1, to: statement); try bind(token.candidate.assetID.uuidString, at: 2, to: statement)
        try bind(phase, at: 3, to: statement); try bind(try JSONEncoder().encode(token), at: 4, to: statement); try stepToCompletion(statement)
    }
    public func commitOwnedStorageCleanup(_ plan: OwnedStorageCleanupPlan) throws -> OwnedStorageCleanupResult {
        try synchronized {
            guard plan.storeIdentity == selectionStoreIdentity, !plan.capability.consumed else { throw OwnedStorageError.changed }
            let operationID = UUID()
            let tokens = plan.candidates.map { ownedFileStorage.preparedQuarantine(candidate: $0, operationID: operationID) }
            // This intent is durable before the first filesystem rename. Crashing before the
            // later metadata commit therefore leaves enough evidence to put every asset back.
            try ownedRetentionTransaction {
                try validateOwnedCleanupPlan(plan)
                for token in tokens {
                    // A prior intent owns this asset until it is recovered or completed.
                    // BEGIN IMMEDIATE serializes this check with every other writer.
                    guard try syncScalar("SELECT operation_id FROM owned_gc_journal WHERE asset_id=?", [token.candidate.assetID.uuidString]) == nil else { throw OwnedStorageError.changed }
                    try writeOwnedGCJournal(token, phase: "planned")
                }
            }
            do {
                try ownedRetentionTransaction {
                    try validateOwnedCleanupPlan(plan)
                    // Another connection may have recovered/cancelled our planned intent in
                    // the gap between transactions. Never rename without durable matching intent.
                    for token in tokens { try requireOwnedGCIntent(token) }
                    _ = try liveOwnedLeaseIDs(prune: true)
                    let liveOperations = try ownedPersistentOperationIDs()
                    let allOperations = try ownedUUIDSet("SELECT operation_id FROM owned_file_operation_bindings")
                    for id in allOperations.subtracting(liveOperations) {
                        try syncExecute("DELETE FROM owned_file_operation_bindings WHERE operation_id=?", [id.uuidString])
                        try syncExecute("DELETE FROM owned_sync_operation_proofs WHERE operation_id=?", [id.uuidString])
                    }
                    for token in tokens {
                        _ = try ownedFileStorage.quarantine(token.candidate, operationID: operationID)
                        try syncExecute("DELETE FROM owned_sync_assets WHERE asset_id=?", [token.candidate.assetID.uuidString])
                        try syncExecute("DELETE FROM owned_file_assets WHERE id=?", [token.candidate.assetID.uuidString])
                        try writeOwnedGCJournal(token, phase: "quarantined")
                    }
                }
            } catch {
                // A failure before COMMIT is reversible. Keep any journal whose safe restore
                // fails so startup can try again; never mask the original error with deletion.
                _ = try? resumeOwnedStorageCleanupWithoutLock(onlyOperation: operationID)
                throw error
            }
            plan.capability.consumed = true
            return try resumeOwnedStorageCleanupWithoutLock(onlyOperation: operationID)
        }
    }
    func requireOwnedGCIntent(_ token: QuarantinedOwnedFile) throws {
        let statement = try prepare("SELECT phase,payload FROM owned_gc_journal WHERE operation_id=? AND asset_id=?")
        defer { sqlite3_finalize(statement) }; try bind(token.operationID.uuidString, at: 1, to: statement); try bind(token.candidate.assetID.uuidString, at: 2, to: statement)
        let status = sqlite3_step(statement)
        guard status != SQLITE_DONE else { throw OwnedStorageError.changed }; try check(status, allowingRow: true)
        guard textColumn(statement, 0) == "planned", let data = dataColumn(statement, 1),
              try JSONDecoder().decode(QuarantinedOwnedFile.self, from: data) == token else { throw OwnedStorageError.changed }
    }
    func validateOwnedCleanupPlan(_ plan: OwnedStorageCleanupPlan) throws {
        guard try syncConfigurationWithoutLock() == plan.syncConfiguration,
              try sharingConfigurationWithoutLock() == plan.sharingConfiguration else { throw OwnedStorageError.changed }
        let roots = try ownedReachableAssets(pruneDeadLeases: false)
        for candidate in plan.candidates {
            guard !roots.contains(candidate.assetID),
                  try ownedFileAssetWithoutLock(id: candidate.assetID) == candidate.asset,
                  try ownedFileStorage.prepareReclamation(candidate.asset) == candidate else { throw OwnedStorageError.changed }
        }
    }
    public func resumeOwnedStorageCleanup() throws -> OwnedStorageCleanupResult {
        try synchronized { try resumeOwnedStorageCleanupWithoutLock(onlyOperation: nil) }
    }
    func resumeOwnedStorageCleanupWithoutLock(onlyOperation: UUID?) throws -> OwnedStorageCleanupResult {
        let statement = try prepare("SELECT phase,payload FROM owned_gc_journal" + (onlyOperation == nil ? "" : " WHERE operation_id=?") + " ORDER BY rowid")
        if let onlyOperation { try bind(onlyOperation.uuidString, at: 1, to: statement) }
        var pending: [(String, QuarantinedOwnedFile)] = []
        do {
            while true {
                let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; try check(status, allowingRow: true)
                guard let phase = textColumn(statement, 0), let data = dataColumn(statement, 1) else { throw OwnedStorageError.incompleteRecovery }
                pending.append((phase, try JSONDecoder().decode(QuarantinedOwnedFile.self, from: data)))
            }
        } catch { sqlite3_finalize(statement); throw error }
        sqlite3_finalize(statement)
        var assets = 0, files = 0, bytes: Int64 = 0
        for (phase, token) in pending {
            do {
                let completedAsset = try ownedRetentionTransaction {
                    guard let currentPhase = try syncScalar("SELECT phase FROM owned_gc_journal WHERE operation_id=? AND asset_id=?", [token.operationID.uuidString, token.candidate.assetID.uuidString]) else { return false }
                    guard currentPhase == phase else { throw OwnedStorageError.changed }
                    if phase == "planned" {
                        guard try ownedFileAssetWithoutLock(id: token.candidate.assetID) == token.candidate.asset else { throw OwnedStorageError.incompleteRecovery }
                        try ownedFileStorage.restore(token)
                        try syncExecute("DELETE FROM owned_gc_journal WHERE operation_id=? AND asset_id=?", [token.operationID.uuidString, token.candidate.assetID.uuidString])
                    } else if phase == "quarantined" {
                        guard try syncScalar("SELECT id FROM owned_file_assets WHERE id=?", [token.candidate.assetID.uuidString]) == nil else { throw OwnedStorageError.incompleteRecovery }
                        let result = try ownedFileStorage.removeQuarantined(token)
                        files += result.removedFileCount; bytes += result.removedLogicalBytes
                        if result.complete {
                            try syncExecute("DELETE FROM owned_gc_journal WHERE operation_id=? AND asset_id=?", [token.operationID.uuidString, token.candidate.assetID.uuidString])
                            return true
                        }
                    } else { throw OwnedStorageError.incompleteRecovery }
                    return false
                }
                // Physical unlink counts above survive a failed SQL commit. Count a group
                // only after its durable journal completion, so retries cannot count it twice.
                if completedAsset { assets += 1 }
            } catch { /* Keep durable evidence and continue independent safe recovery entries. */ }
        }
        let remaining = Int(try syncScalar("SELECT CAST(COUNT(*) AS TEXT) FROM owned_gc_journal", []) ?? "0") ?? 0
        return OwnedStorageCleanupResult(removedAssetCount: assets, removedFileCount: files, removedLogicalBytes: bytes, remainingPendingCount: remaining)
    }
}
