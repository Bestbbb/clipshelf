import CSQLite
import Foundation

extension HistoryStore {
    func createOwnedSyncSchema(markLegacy: Bool) throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS owned_sync_operation_proofs(operation_id TEXT PRIMARY KEY, namespace TEXT NOT NULL, entity_id TEXT NOT NULL, manifest BLOB NOT NULL, scope_key TEXT);
            CREATE TABLE IF NOT EXISTS owned_sync_scopes(namespace TEXT PRIMARY KEY, scope BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS owned_sync_access(namespace TEXT PRIMARY KEY, generation INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS owned_sync_assets(scope_key TEXT NOT NULL, digest TEXT NOT NULL, filename TEXT NOT NULL, descriptor BLOB NOT NULL, asset_id TEXT NOT NULL REFERENCES owned_file_assets(id), PRIMARY KEY(scope_key,digest,filename));
            CREATE TABLE IF NOT EXISTS owned_sync_transfers(scope_key TEXT NOT NULL, operation_id TEXT NOT NULL, entity_id TEXT NOT NULL, scope BLOB NOT NULL, descriptor BLOB NOT NULL, digest TEXT NOT NULL, filename TEXT NOT NULL, direction TEXT NOT NULL, status TEXT NOT NULL, error TEXT, PRIMARY KEY(scope_key,operation_id,digest,filename,direction));
            CREATE TABLE IF NOT EXISTS owned_sync_backfill(record_id TEXT PRIMARY KEY REFERENCES clipboard_records(id) ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS owned_sync_local_recovery(record_id TEXT PRIMARY KEY REFERENCES clipboard_records(id) ON DELETE CASCADE);
            """)
        if markLegacy {
            try execute("INSERT OR IGNORE INTO owned_sync_backfill(record_id) SELECT DISTINCT record_id FROM owned_file_bindings")
        }
    }

    public func makeSyncTransferContext(scope: SyncOwnedFileScope) throws -> SyncTransferContext {
        try synchronized {
            try transaction {
                for value in [scope.accountID, scope.containerIdentifier, scope.zoneName, scope.zoneOwnerName, scope.namespace] {
                    guard !value.isEmpty, value.utf8.count <= 1_024 else { throw SyncError.invalidOperation }
                }
                let board: SharedBoardDescriptor?
                let configuration: SyncConfiguration
                if scope.namespace.hasPrefix("shared:") {
                    guard let state = try sharedStateForNamespace(scope.namespace), state.descriptor.accountID == scope.accountID,
                          state.descriptor.containerIdentifier == scope.containerIdentifier, state.descriptor.zoneName == scope.zoneName,
                          state.descriptor.zoneOwnerName == scope.zoneOwnerName else { throw SyncError.namespaceConflict }
                    guard state.access != .revoked else { throw SharedBoardError.revoked }
                    guard scope.database == (state.access == .owner ? .privateDatabase : .sharedDatabase) else { throw SyncError.namespaceConflict }
                    configuration = try sharingConfigurationWithoutLock(); board = state.descriptor
                } else {
                    guard scope.namespace == scope.accountID, scope.database == .privateDatabase else { throw SyncError.namespaceConflict }
                    configuration = try syncConfigurationWithoutLock(); board = nil
                }
                guard configuration.accountID == scope.accountID else { throw SyncError.accountChanged }
                let context = SyncTransferContext(scope: scope, storeIdentity: selectionStoreIdentity, configuration: configuration,
                                                  board: board, accessGeneration: try ownedAccessGeneration(scope.namespace))
                let statement = try prepare("INSERT INTO owned_sync_scopes(namespace,scope) VALUES (?,?) ON CONFLICT(namespace) DO UPDATE SET scope=excluded.scope")
                defer { sqlite3_finalize(statement) }
                try bind(scope.namespace, at: 1, to: statement); try bind(try JSONEncoder().encode(scope), at: 2, to: statement); try stepToCompletion(statement)
                try publishOwnedSyncBackfillWithoutLock()
                try registerOwnedPendingDependencies(scope: scope)
                return context
            }
        }
    }

    func ownedAccessGeneration(_ namespace: String) throws -> Int64 {
        Int64(try syncScalar("SELECT CAST(generation AS TEXT) FROM owned_sync_access WHERE namespace=?", [namespace]) ?? "0") ?? 0
    }
    func requireOwnedContext(_ context: SyncTransferContext, writing: Bool = false) throws {
        guard context.storeIdentity == selectionStoreIdentity else { throw SyncError.invalidOperation }
        let current = try context.board == nil ? syncConfigurationWithoutLock() : sharingConfigurationWithoutLock()
        guard current == context.configuration, current.accountID == context.scope.accountID else { throw SyncError.accountChanged }
        if let board = context.board {
            guard let state = try sharedStateForNamespace(board.namespace), state.descriptor == board,
                  try ownedAccessGeneration(board.namespace) == context.accessGeneration else { throw SyncError.accountChanged }
            guard state.access != .revoked else { throw SharedBoardError.revoked }
            if writing, !state.access.canWrite { throw SharedBoardError.readOnly }
        }
        guard try ownedScopeWithoutLock(namespace: context.scope.namespace) == context.scope else { throw SyncError.accountChanged }
    }
    public func validateSyncTransferContext(_ context: SyncTransferContext, writing: Bool = false) throws {
        try synchronized { try requireOwnedContext(context, writing: writing) }
    }
    func ownedScopeWithoutLock(namespace: String) throws -> SyncOwnedFileScope? {
        let statement = try prepare("SELECT scope FROM owned_sync_scopes WHERE namespace=?")
        defer { sqlite3_finalize(statement) }; try bind(namespace, at: 1, to: statement)
        let result = sqlite3_step(statement); if result == SQLITE_DONE { return nil }; try check(result, allowingRow: true)
        guard let data = dataColumn(statement, 0) else { throw SyncError.invalidOperation }
        return try JSONDecoder().decode(SyncOwnedFileScope.self, from: data)
    }
    func ownedScopeKey(_ scope: SyncOwnedFileScope) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return RepresentationStorage.digest(try encoder.encode(scope))
    }

    /// The immutable operation owns its binding snapshot, independent of later edits or projections.
    public func prepareSyncOwnedUpload(operationID: UUID, file: SyncOwnedFileDescriptor, context: SyncTransferContext) throws -> PreparedSyncOwnedUpload {
        try synchronized {
            try requireOwnedContext(context, writing: true)
            let operation = try ownedOutboxOperation(operationID, namespace: context.scope.namespace)
            guard let manifest = operation.ownedFiles, manifest.files.contains(file), let record = operation.record else { throw SyncError.invalidOperation }
            let bindings = try ownedFileOperationBindingsWithoutLock(operationID: operationID, recordID: record.id)
            guard let portable = manifest.bindings.first(where: { $0.digest == file.digest && $0.filename == file.filename }),
                  let binding = bindings.first(where: { $0.partIndex == portable.partIndex && $0.representationIndex == portable.representationIndex }) else { throw HistoryStoreError.invalidOwnedFile }
            let asset = try ownedFileAssetWithoutLock(id: binding.assetID)
            guard asset.sha256 == file.digest, asset.byteCount == file.byteCount, asset.filename == file.filename else { throw HistoryStoreError.invalidOwnedFile }
            let staging = try SyncOwnedFileStaging.create(data: ownedFileStorage.read(asset), descriptor: file)
            try transaction { try writeOwnedTransfer(operation, file: file, scope: context.scope, direction: .upload, status: .pending) }
            return PreparedSyncOwnedUpload(operationID: operationID, scope: context.scope, file: file, staging: staging)
        }
    }
    public func recordSyncOwnedUpload(operationID: UUID, file: SyncOwnedFileDescriptor, context: SyncTransferContext, error: String? = nil) throws {
        try synchronized {
            try requireOwnedContext(context, writing: true)
            let operation = try ownedOutboxOperation(operationID, namespace: context.scope.namespace)
            guard operation.ownedFiles?.files.contains(file) == true else { throw SyncError.invalidOperation }
            try transaction { try writeOwnedTransfer(operation, file: file, scope: context.scope, direction: .upload, status: error == nil ? .complete : .failed, error: error) }
        }
    }
    public func syncOwnedUploadIsComplete(operationID: UUID, file: SyncOwnedFileDescriptor, context: SyncTransferContext) throws -> Bool {
        try synchronized {
            try requireOwnedContext(context, writing: true)
            return try syncScalar("SELECT status FROM owned_sync_transfers WHERE scope_key=? AND operation_id=? AND digest=? AND filename=? AND direction='upload'", [ownedScopeKey(context.scope), operationID.uuidString, file.digest, file.filename]) == "complete"
        }
    }
    func ownedOutboxOperation(_ id: UUID, namespace: String) throws -> SyncOperation {
        let statement = try prepare("SELECT payload FROM sync_outbox WHERE operation_id=? AND account_id=?")
        defer { sqlite3_finalize(statement) }; try bind(id.uuidString, at: 1, to: statement); try bind(namespace, at: 2, to: statement)
        let result = sqlite3_step(statement); guard result != SQLITE_DONE else { throw SyncError.invalidOperation }; try check(result, allowingRow: true)
        guard let data = dataColumn(statement, 0) else { throw SyncError.invalidOperation }; return try JSONDecoder().decode(SyncOperation.self, from: data)
    }
    func writeOwnedTransfer(_ operation: SyncOperation, file: SyncOwnedFileDescriptor, scope: SyncOwnedFileScope,
                            direction: SyncOwnedTransferDirection, status: SyncOwnedTransferStatus, error: String? = nil) throws {
        let statement = try prepare("""
            INSERT INTO owned_sync_transfers(scope_key,operation_id,entity_id,scope,descriptor,digest,filename,direction,status,error) VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(scope_key,operation_id,digest,filename,direction) DO UPDATE SET status=excluded.status,error=excluded.error
            """)
        defer { sqlite3_finalize(statement) }
        try bind(try ownedScopeKey(scope), at: 1, to: statement); try bind(operation.operationID.uuidString, at: 2, to: statement); try bind(operation.entityID.uuidString, at: 3, to: statement)
        try bind(try JSONEncoder().encode(scope), at: 4, to: statement); try bind(try JSONEncoder().encode(file), at: 5, to: statement)
        try bind(file.digest, at: 6, to: statement); try bind(file.filename, at: 7, to: statement); try bind(direction.rawValue, at: 8, to: statement)
        try bind(status.rawValue, at: 9, to: statement); try bind(error.map { String($0.prefix(1_000)) }, at: 10, to: statement); try stepToCompletion(statement)
    }
    public func pendingSyncOwnedDownloads(context: SyncTransferContext, limit: Int = 100, excluding: Set<String> = []) throws -> [SyncOwnedDownloadRequest] {
        try synchronized {
            try requireOwnedContext(context)
            return try transaction {
                let statement = try prepare("SELECT payload FROM sync_inbox WHERE account_id=? ORDER BY rowid")
                defer { sqlite3_finalize(statement) }; try bind(context.scope.namespace, at: 1, to: statement)
                var requests: [SyncOwnedDownloadRequest] = []
                for operation in try syncReadOperations(statement) {
                    for file in operation.ownedFiles?.files ?? [] {
                        if excluding.contains(operation.operationID.uuidString + ":" + file.digest + ":" + file.filename) { continue }
                        if try ownedCachedAsset(file, scope: context.scope) != nil { continue }
                        if requests.count >= max(0, min(limit, 1_000)) { return requests }
                        let prior = try syncScalar("SELECT status FROM owned_sync_transfers WHERE scope_key=? AND operation_id=? AND digest=? AND filename=? AND direction='download'", [ownedScopeKey(context.scope), operation.operationID.uuidString, file.digest, file.filename])
                        if prior == nil { try writeOwnedTransfer(operation, file: file, scope: context.scope, direction: .download, status: .pending) }
                        requests.append(SyncOwnedDownloadRequest(operationID: operation.operationID, scope: context.scope, file: file, context: context))
                    }
                }
                return requests
            }
        }
    }
    public func acceptSyncOwnedDownload(_ request: SyncOwnedDownloadRequest, stagedFileURL: URL, context: SyncTransferContext) throws {
        try synchronized {
            try requireOwnedContext(context)
            guard request.context.storeIdentity == context.storeIdentity, request.context.configuration == context.configuration,
                  request.context.accessGeneration == context.accessGeneration, request.scope == context.scope else { throw SyncError.accountChanged }
            let data = try SyncOwnedFileStaging.readVerified(fileURL: stagedFileURL, descriptor: request.file)
            let old = suppressSyncCapture; suppressSyncCapture = true; defer { suppressSyncCapture = old }
            try transaction {
                if try syncLogContains(accountID: context.scope.namespace, id: request.operationID) { return }
                let operation = try ownedInboxOperation(request.operationID, namespace: context.scope.namespace)
                guard operation.ownedFiles?.files.contains(request.file) == true else { throw SyncError.invalidOperation }
                if try ownedCachedAsset(request.file, scope: context.scope) == nil {
                    let asset = try stageOwnedFileWithoutLock(filename: request.file.filename, data: data)
                    let statement = try prepare("INSERT OR REPLACE INTO owned_sync_assets(scope_key,digest,filename,descriptor,asset_id) VALUES (?,?,?,?,?)")
                    defer { sqlite3_finalize(statement) }
                    try bind(try ownedScopeKey(context.scope), at: 1, to: statement); try bind(request.file.digest, at: 2, to: statement); try bind(request.file.filename, at: 3, to: statement)
                    try bind(try JSONEncoder().encode(request.file), at: 4, to: statement); try bind(asset.id.uuidString, at: 5, to: statement); try stepToCompletion(statement)
                }
                try writeOwnedTransfer(operation, file: request.file, scope: context.scope, direction: .download, status: .complete)
                try drainSyncInbox(accountID: context.scope.namespace)
            }
        }
    }
    public func failSyncOwnedDownload(_ request: SyncOwnedDownloadRequest, context: SyncTransferContext, error: String) throws {
        try synchronized {
            try requireOwnedContext(context)
            guard request.context.configuration == context.configuration, request.context.storeIdentity == context.storeIdentity,
                  request.context.accessGeneration == context.accessGeneration, request.scope == context.scope else { throw SyncError.accountChanged }
            try transaction {
                if try syncLogContains(accountID: context.scope.namespace, id: request.operationID) { return }
                let operation = try ownedInboxOperation(request.operationID, namespace: context.scope.namespace)
                try writeOwnedTransfer(operation, file: request.file, scope: context.scope, direction: .download, status: .failed, error: error)
            }
        }
    }
    func ownedInboxOperation(_ id: UUID, namespace: String) throws -> SyncOperation {
        let statement = try prepare("SELECT payload FROM sync_inbox WHERE operation_id=? AND account_id=?")
        defer { sqlite3_finalize(statement) }; try bind(id.uuidString, at: 1, to: statement); try bind(namespace, at: 2, to: statement)
        let result = sqlite3_step(statement); guard result != SQLITE_DONE else { throw SyncError.invalidOperation }; try check(result, allowingRow: true)
        guard let data = dataColumn(statement, 0) else { throw SyncError.invalidOperation }; return try JSONDecoder().decode(SyncOperation.self, from: data)
    }
    func ownedCachedAsset(_ file: SyncOwnedFileDescriptor, scope: SyncOwnedFileScope) throws -> OwnedFileAsset? {
        guard let id = try syncScalar("SELECT asset_id FROM owned_sync_assets WHERE scope_key=? AND digest=? AND filename=?", [ownedScopeKey(scope), file.digest, file.filename]).flatMap(UUID.init(uuidString:)) else { return nil }
        let asset = try ownedFileAssetWithoutLock(id: id)
        guard asset.sha256 == file.digest, asset.byteCount == file.byteCount, asset.filename == file.filename else { throw SyncError.invalidOperation }
        do { _ = try ownedFileStorage.read(asset) } catch { return nil }
        return asset
    }
    public func syncOwnedTransferStates(context: SyncTransferContext) throws -> [SyncOwnedTransferState] {
        try synchronized { try requireOwnedContext(context); return try ownedTransferStatesWithoutLock(scopeKey: ownedScopeKey(context.scope)) }
    }
    public func syncOwnedTransferStates() throws -> [SyncOwnedTransferState] {
        try synchronized {
            let sync = try syncConfigurationWithoutLock(), sharing = try sharingConfigurationWithoutLock()
            return try ownedTransferStatesWithoutLock(scopeKey: nil).filter { state in
                if state.scope.namespace.hasPrefix("shared:") {
                    guard state.scope.accountID == sharing.accountID,
                          let board = try sharedStateForNamespace(state.scope.namespace), board.access != .revoked,
                          board.descriptor.accountID == sharing.accountID else { return false }
                    return board.descriptor.zoneName == state.scope.zoneName && board.descriptor.zoneOwnerName == state.scope.zoneOwnerName && board.descriptor.containerIdentifier == state.scope.containerIdentifier
                }
                return state.scope.accountID == sync.accountID
            }
        }
    }
    func ownedTransferStatesWithoutLock(scopeKey: String?) throws -> [SyncOwnedTransferState] {
        let statement = try prepare("SELECT operation_id,entity_id,scope,descriptor,direction,status,error FROM owned_sync_transfers" + (scopeKey == nil ? "" : " WHERE scope_key=?") + " ORDER BY rowid")
        defer { sqlite3_finalize(statement) }; if let scopeKey { try bind(scopeKey, at: 1, to: statement) }
        var states: [SyncOwnedTransferState] = []
        while true {
            let result = sqlite3_step(statement); if result == SQLITE_DONE { return states }; try check(result, allowingRow: true)
            guard let operationID = textColumn(statement, 0).flatMap(UUID.init(uuidString:)), let entityID = textColumn(statement, 1).flatMap(UUID.init(uuidString:)),
                  let scope = dataColumn(statement, 2), let file = dataColumn(statement, 3),
                  let direction = textColumn(statement, 4).flatMap(SyncOwnedTransferDirection.init(rawValue:)), let status = textColumn(statement, 5).flatMap(SyncOwnedTransferStatus.init(rawValue:)) else { throw SyncError.invalidOperation }
            states.append(SyncOwnedTransferState(operationID: operationID, entityID: entityID, scope: try JSONDecoder().decode(SyncOwnedFileScope.self, from: scope), file: try JSONDecoder().decode(SyncOwnedFileDescriptor.self, from: file), direction: direction, status: status, error: textColumn(statement, 6)))
        }
    }

    func portableOwnedOperation(_ operation: SyncOperation) throws -> SyncOperation {
        guard let original = operation.record else { return operation }
        let bindings = try ownedFileBindingsWithoutLock(recordID: original.id)
        guard !bindings.isEmpty else { return operation }
        var record = original, files: [SyncOwnedFileDescriptor] = [], portable: [SyncOwnedFileBinding] = [], snapshots: [OwnedFileBinding] = []
        record.parts = []
        for (originalIndex, part) in original.parts.enumerated() {
            let matches = bindings.filter { $0.partIndex == originalIndex }
            if matches.isEmpty { record.parts.append(part); continue }
            let boundSlots = Set(matches.map(\.representationIndex))
            let ownedURLs = Set(matches.map { original.parts[$0.partIndex].representations[$0.representationIndex].data })
            let externalReferences = part.representations.enumerated().filter { !boundSlots.contains($0.offset) && $0.element.typeIdentifier == "public.file-url" && !ownedURLs.contains($0.element.data) }.map(\.element)
            var included = Set<UUID>()
            for binding in matches {
                guard try ownedBindingMatches(binding, record: original) else { throw HistoryStoreError.invalidOwnedFile }
                if !included.insert(binding.assetID).inserted { continue }
                let asset = try ownedFileAssetWithoutLock(id: binding.assetID)
                let file = SyncOwnedFileDescriptor(digest: asset.sha256, byteCount: asset.byteCount, filename: asset.filename)
                if !files.contains(file) { files.append(file) }
                let index = record.parts.count
                record.parts.append(ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(SyncOwnedFileManifest.token(digest: asset.sha256, filename: asset.filename).utf8))]))
                portable.append(SyncOwnedFileBinding(partIndex: index, representationIndex: 0, digest: asset.sha256, filename: asset.filename))
                snapshots.append(OwnedFileBinding(recordID: original.id, partIndex: index, representationIndex: 0, assetID: asset.id))
            }
            for external in externalReferences { record.parts.append(ClipboardPart(representations: [external])) }
        }
        let manifest = SyncOwnedFileManifest(files: files, bindings: portable)
        try manifest.validate(record: record)
        try storeOwnedOperationBindings(operationID: operation.operationID, bindings: snapshots)
        try storeOwnedOperationProof(operation, manifest: manifest, scope: nil)
        return operation.replacing(record: record, ownedFiles: manifest, formatVersion: 2)
    }
    func storeOwnedOperationBindings(operationID: UUID, bindings: [OwnedFileBinding]) throws {
        let statement = try prepare("INSERT OR REPLACE INTO owned_file_operation_bindings(operation_id,bindings) VALUES (?,?)")
        defer { sqlite3_finalize(statement) }; try bind(operationID.uuidString, at: 1, to: statement); try bind(try JSONEncoder().encode(bindings), at: 2, to: statement); try stepToCompletion(statement)
    }
    func materializedOwnedOperation(_ operation: SyncOperation) throws -> SyncOperation? {
        guard let manifest = operation.ownedFiles, var record = operation.record else { return operation }
        let existing = try ownedFileOperationBindingsWithoutLock(operationID: operation.operationID, recordID: record.id)
        if !existing.isEmpty { try requireOwnedOperationProof(operation, manifest: manifest) }
        var local: [OwnedFileBinding] = []
        for portable in manifest.bindings {
            guard let file = manifest.files.first(where: { $0.digest == portable.digest && $0.filename == portable.filename }) else { throw SyncError.invalidOperation }
            let asset: OwnedFileAsset
            if let known = existing.first(where: { $0.partIndex == portable.partIndex && $0.representationIndex == portable.representationIndex }) {
                asset = try ownedFileAssetWithoutLock(id: known.assetID)
                guard asset.sha256 == file.digest, asset.byteCount == file.byteCount, asset.filename == file.filename else { throw SyncError.invalidOperation }
                _ = try ownedFileStorage.read(asset)
            } else {
                guard let scope = try ownedScopeWithoutLock(namespace: operation.accountID), let cached = try ownedCachedAsset(file, scope: scope) else { return nil }
                asset = cached
            }
            record.parts[portable.partIndex].representations[0].data = Data(try ownedFileStorage.fileURL(asset).absoluteString.utf8)
            local.append(OwnedFileBinding(recordID: record.id, partIndex: portable.partIndex, representationIndex: 0, assetID: asset.id))
        }
        try storeOwnedOperationBindings(operationID: operation.operationID, bindings: local)
        if existing.isEmpty { try storeOwnedOperationProof(operation, manifest: manifest, scope: ownedScopeWithoutLock(namespace: operation.accountID)) }
        return operation.replacing(record: record, ownedFiles: manifest, formatVersion: 2)
    }
    func storeOwnedOperationProof(_ operation: SyncOperation, manifest: SyncOwnedFileManifest, scope: SyncOwnedFileScope?) throws {
        let statement = try prepare("INSERT OR REPLACE INTO owned_sync_operation_proofs(operation_id,namespace,entity_id,manifest,scope_key) VALUES (?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(operation.operationID.uuidString, at: 1, to: statement); try bind(operation.accountID, at: 2, to: statement)
        try bind(operation.entityID.uuidString, at: 3, to: statement); try bind(try JSONEncoder().encode(manifest), at: 4, to: statement)
        try bind(try scope.map(ownedScopeKey), at: 5, to: statement); try stepToCompletion(statement)
    }
    func requireOwnedOperationProof(_ operation: SyncOperation, manifest: SyncOwnedFileManifest) throws {
        let statement = try prepare("SELECT namespace,entity_id,manifest,scope_key FROM owned_sync_operation_proofs WHERE operation_id=?")
        defer { sqlite3_finalize(statement) }; try bind(operation.operationID.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement); guard result != SQLITE_DONE else { throw SyncError.invalidOperation }; try check(result, allowingRow: true)
        guard textColumn(statement, 0) == operation.accountID, textColumn(statement, 1) == operation.entityID.uuidString,
              let data = dataColumn(statement, 2), try JSONDecoder().decode(SyncOwnedFileManifest.self, from: data) == manifest else { throw SyncError.namespaceConflict }
        if let key = textColumn(statement, 3) {
            guard let scope = try ownedScopeWithoutLock(namespace: operation.accountID), try ownedScopeKey(scope) == key else { throw SyncError.namespaceConflict }
        }
    }
    func registerOwnedPendingDependencies(scope: SyncOwnedFileScope) throws {
        for (table, direction) in [("sync_outbox", SyncOwnedTransferDirection.upload), ("sync_inbox", .download)] {
            let query = try prepare("SELECT payload FROM \(table) WHERE account_id=? ORDER BY rowid")
            defer { sqlite3_finalize(query) }; try bind(scope.namespace, at: 1, to: query)
            for operation in try syncReadOperations(query) {
                for file in operation.ownedFiles?.files ?? [] {
                    let exists = try syncScalar("SELECT status FROM owned_sync_transfers WHERE scope_key=? AND operation_id=? AND digest=? AND filename=? AND direction=?", [ownedScopeKey(scope), operation.operationID.uuidString, file.digest, file.filename, direction.rawValue])
                    if exists == nil { try writeOwnedTransfer(operation, file: file, scope: scope, direction: direction, status: .pending) }
                }
            }
        }
    }
    public func hasPendingOwnedFileOperations(namespace: String) throws -> Bool {
        try synchronized {
            if namespace.hasPrefix("shared:") {
                guard let state = try sharedStateForNamespace(namespace), try sharingConfigurationWithoutLock().accountID == state.descriptor.accountID else { throw SyncError.accountChanged }
            } else { try requireSyncAccount(namespace) }
            for table in ["sync_inbox", "sync_outbox"] {
                let statement = try prepare("SELECT payload FROM \(table) WHERE account_id=?")
                defer { sqlite3_finalize(statement) }; try bind(namespace, at: 1, to: statement)
                if try syncReadOperations(statement).contains(where: { $0.ownedFiles != nil }) { return true }
            }
            return false
        }
    }
    func publishOwnedSyncBackfillWithoutLock() throws {
        let statement = try prepare("SELECT record_id FROM owned_sync_backfill ORDER BY rowid")
        defer { sqlite3_finalize(statement) }; var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) { ids.append(id) } }
        for id in ids {
            guard let namespace = try syncNamespace(kind: .clipboard, id: id), try !isSyncLocalOnly(kind: .clipboard, id: id) else { continue }
            if namespace.hasPrefix("shared:") {
                guard let state = try sharedStateForNamespace(namespace), state.access.canWrite,
                      try sharingConfigurationWithoutLock().accountID == state.descriptor.accountID else { continue }
            } else { guard try syncConfigurationWithoutLock().accountID == namespace else { continue } }
            guard let record = try itemWithoutLock(id: id), try !ownedFileBindingsWithoutLock(recordID: id).isEmpty else { continue }
            let head = try syncHead(accountID: namespace, kind: .clipboard, id: id)
            let operation = SyncOperation(accountID: namespace, entityID: id, entityKind: .clipboard, action: .upsert,
                                          baseRevision: head?.revision ?? 0, revision: (head?.revision ?? 0) + 1,
                                          baseOperationID: head?.id, record: record)
            try enqueueSyncOperation(operation)
            try syncExecute("DELETE FROM owned_sync_backfill WHERE record_id=?", [id.uuidString])
        }
    }
}

extension SyncOperation {
    func replacing(record: ClipboardRecord, ownedFiles: SyncOwnedFileManifest?, formatVersion: Int?) -> SyncOperation {
        SyncOperation(operationID: operationID, accountID: accountID, entityID: entityID, entityKind: entityKind, action: action,
                      baseRevision: baseRevision, revision: revision, baseOperationID: baseOperationID, createdAt: createdAt,
                      record: record, pinboard: pinboard, orderingOnly: orderingOnly, formatVersion: formatVersion, ownedFiles: ownedFiles)
    }
}
