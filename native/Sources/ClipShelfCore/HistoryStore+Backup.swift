import CSQLite
import Darwin
import Foundation

/// A validated, immutable archive. Preparation has no database or filesystem side effects.
/// The source file may be removed after preparation; account generations are checked again at commit.
public struct PreparedBackupRestore: Sendable {
    fileprivate let backup: HistoryBackup
    fileprivate let mode: BackupRestoreMode
    fileprivate let storeIdentity: UUID
    fileprivate let syncConfiguration: SyncConfiguration
    fileprivate let sharingConfiguration: SyncConfiguration
}

extension HistoryStore {
    static let maximumBackupBytes = 512 * 1_024 * 1_024
    static let maximumBackupAssets = 100_000
    static let maximumBackupBindings = 1_000_000

    /// Backups contain plaintext clipboard contents. File permissions are restricted to the current user.
    public func exportBackup(to destination: URL) throws {
        try synchronized {
            try transaction { try exportBackupWithoutLock(to: destination) }
        }
    }

    /// Freezes one consistent archive for encrypted export without creating a plaintext file.
    /// The returned bytes contain clipboard contents and are never written by this method.
    public func exportBackupData() throws -> Data {
        try synchronized { try transaction { try encodedBackupWithoutLock() } }
    }

    public func prepareBackupRestore(from source: URL, mode: BackupRestoreMode) throws -> PreparedBackupRestore {
        let backup = try readBackup(source)
        return try synchronized {
            if mode == .replace, try hasSyncBoundState() { throw HistoryStoreError.syncedProfileRequiresLocalMerge }
            return PreparedBackupRestore(backup: backup, mode: mode, storeIdentity: selectionStoreIdentity,
                                         syncConfiguration: try syncConfigurationWithoutLock(),
                                         sharingConfiguration: try sharingConfigurationWithoutLock())
        }
    }

    @discardableResult
    public func restoreBackup(from source: URL, mode: BackupRestoreMode) throws -> BackupRestoreSummary {
        try restoreBackup(prepareBackupRestore(from: source, mode: mode))
    }

    @discardableResult
    public func restoreBackup(_ prepared: PreparedBackupRestore) throws -> BackupRestoreSummary {
        guard prepared.storeIdentity == selectionStoreIdentity else { throw HistoryStoreError.invalidBackup }
        let backup = prepared.backup, mode = prepared.mode
        return try synchronized {
            let oldSuppression = suppressSyncCapture
            suppressSyncCapture = true
            defer { suppressSyncCapture = oldSuppression }
            return try transaction {
                try requireIntegrationConfigurations(sync: prepared.syncConfiguration, sharing: prepared.sharingConfiguration)
                let boundProfile = try hasSyncBoundState()
                if mode == .replace, boundProfile { throw HistoryStoreError.syncedProfileRequiresLocalMerge }
                let remapIdentities = boundProfile || backup.containsSyncedContent == true
                let recovery = try recoveryURL(reason: "restore", extension: "clipshelfbackup")
                let recoveryData = try encodedBackupWithoutLock()
                try reserveBackupRestoreWithoutLock(backup, mode: mode, recoveryData: recoveryData, recoveryURL: recovery)
                try publishBackupWithoutLock(recoveryData, to: recovery)
                if mode == .replace {
                    try execute("DELETE FROM clipboard_records")
                    try execute("DELETE FROM pinboards")
                }
                let existingOrder = try orderedPinboardsWithoutLock().map(\.id)
                let existingBoards = Set(existingOrder)
                var boardCount = 0
                var boardIDs: [UUID: UUID] = [:]
                for var board in backup.pinboards {
                    let originalID = board.id
                    if remapIdentities { board.id = UUID() }
                    boardIDs[originalID] = board.id
                    if existingBoards.contains(board.id) { continue }
                    try markSyncLocalOnly(kind: .pinboard, id: board.id)
                    try savePinboard(board, replace: false)
                    boardCount += 1
                }
                if let order = backup.pinboardOrder {
                    try reorderPinboardsWithoutLock(ids: existingOrder + order.compactMap { boardIDs[$0] }.filter { !existingBoards.contains($0) })
                }
                let sourceAssets = Dictionary(uniqueKeysWithValues: (backup.ownedFiles ?? []).map { ($0.asset.id, $0) })
                let sourceBindings = Dictionary(grouping: backup.ownedFileBindings ?? [], by: \.recordID)
                var importedAssets: [UUID: OwnedFileAsset] = [:]
                var recordCount = 0
                // The archive is newest first; insert oldest first to preserve capture order.
                for var record in backup.records.reversed() {
                    let originalID = record.id
                    let bindings = sourceBindings[originalID] ?? []
                    if remapIdentities {
                        record.pinboardOrderIdentity = record.pinboardOrderIdentity ?? record.id
                        record.id = UUID()
                    }
                    record.pinboardID = record.pinboardID.flatMap { boardIDs[$0] }
                    if let current = try itemWithoutLock(id: record.id) {
                        if try matchesBackupRecord(current, incoming: record, bindings: bindings, assets: sourceAssets) { continue }
                        // Keep both versions on a merge conflict instead of silently replacing either.
                        record.pinboardOrderIdentity = record.pinboardOrderIdentity ?? record.id
                        record.id = UUID()
                    }
                    var mappedBindings: [OwnedFileBinding] = []
                    for binding in bindings {
                        let asset: OwnedFileAsset
                        if let existing = importedAssets[binding.assetID] { asset = existing }
                        else {
                            guard let original = sourceAssets[binding.assetID] else { throw HistoryStoreError.invalidBackup }
                            asset = try stageOwnedFileWithoutLock(filename: original.asset.filename, data: original.data)
                            importedAssets[binding.assetID] = asset
                        }
                        let url = try ownedFileURLWithoutLock(assetID: asset.id)
                        record.parts[binding.partIndex].representations[binding.representationIndex].data = Data(url.absoluteString.utf8)
                        mappedBindings.append(OwnedFileBinding(recordID: record.id, partIndex: binding.partIndex,
                                                              representationIndex: binding.representationIndex, assetID: asset.id))
                    }
                    try markSyncLocalOnly(kind: .clipboard, id: record.id)
                    try insert(record)
                    try setOwnedFileBindingsWithoutLock(mappedBindings, record: record)
                    recordCount += 1
                }
                return BackupRestoreSummary(importedRecords: recordCount, importedPinboards: boardCount, recoveryBackupURL: recovery,
                                            restoredAsLocalOnly: true, identitiesRemapped: remapIdentities)
            }
        }
    }

    /// Paths and asset IDs change across profiles; compare trusted slot metadata and the remaining record.
    private func matchesBackupRecord(_ current: ClipboardRecord, incoming: ClipboardRecord,
                                     bindings: [OwnedFileBinding], assets: [UUID: OwnedFileBackupAsset]) throws -> Bool {
        let currentBindings = try ownedFileBindingsWithoutLock(recordID: current.id)
        guard currentBindings.count == bindings.count else { return false }
        var lhs = current, rhs = incoming
        for binding in bindings {
            guard let local = currentBindings.first(where: {
                $0.partIndex == binding.partIndex && $0.representationIndex == binding.representationIndex
            }), let original = assets[binding.assetID], try ownedBindingMatches(local, record: current) else { return false }
            let asset = try ownedFileAssetWithoutLock(id: local.assetID)
            guard asset.filename == original.asset.filename, asset.byteCount == original.asset.byteCount,
                  asset.sha256 == original.asset.sha256 else { return false }
            // The recovery export verified each current original once before any restore writes.
            // Do not reread a large shared asset for every duplicate record in the archive.
            lhs.parts[local.partIndex].representations[local.representationIndex].data = Data()
            rhs.parts[binding.partIndex].representations[binding.representationIndex].data = Data()
        }
        return lhs == rhs
    }

    func exportBackupWithoutLock(to destination: URL) throws {
        guard destination.isFileURL, !destination.path.utf8.contains(0) else { throw HistoryStoreError.invalidDatabaseURL }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw HistoryStoreError.backupExists }
        try publishBackupWithoutLock(encodedBackupWithoutLock(), to: destination)
    }

    func encodedBackupWithoutLock() throws -> Data {
        let boards = try pinboardsWithoutLock()
        guard boards.count <= 10_000 else { throw HistoryStoreError.valueTooLarge }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Include the outer envelope's base64 expansion before loading any attachment bytes.
        try preflightBackupPayload(pinboardBytes: encoder.encode(boards).count)
        let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records ORDER BY local_history_order DESC")
        defer { sqlite3_finalize(statement) }
        let records = try readRecords(statement)
        let owned = try backupOwnedFilesWithoutLock(records: records)
        let backup = HistoryBackup(records: records, pinboards: boards,
                                   pinboardOrder: try orderedPinboardsWithoutLock().map(\.id), containsSyncedContent: try hasSyncBoundState(),
                                   ownedFiles: owned.assets, ownedFileBindings: owned.bindings)
        let payload = try encoder.encode(backup)
        let envelope = BackupEnvelope(checksum: RepresentationStorage.digest(payload), payload: payload)
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumBackupBytes else { throw HistoryStoreError.valueTooLarge }
        return data
    }

    private func publishBackupWithoutLock(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL, !destination.path.utf8.contains(0) else { throw HistoryStoreError.invalidDatabaseURL }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw HistoryStoreError.backupExists }
        let lease = try writeBudget?.isPrepaid == true ? nil : spaceCoordinator.reserve([
            .init(destination: destination, bytes: Int64(data.count))
        ])
        defer { try? lease?.release() }
        try lease?.revalidate()
        let stagingDirectory = destination.deletingLastPathComponent().appendingPathComponent(".clipshelf-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent("backup")
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        try lease?.validateDestinations()
        try writeBudget?.validateDestinations()
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    private func reserveBackupRestoreWithoutLock(_ backup: HistoryBackup, mode: BackupRestoreMode, recoveryData: Data,
                                                 recoveryURL: URL) throws {
        guard let writeBudget else { throw HistoryStoreError.invalidBackup }
        var databaseBytes: Int64 = 262_144
        if mode == .replace {
            databaseBytes = try HistoryWriteBudget.adding(databaseBytes, existingDatabaseRewriteBytesWithoutLock())
        }
        var attachmentBytes: Int64 = 0
        var digests = Set<String>()
        for record in backup.records {
            databaseBytes = try HistoryWriteBudget.adding(databaseBytes,
                HistoryWriteBudget.databaseBytes(for: record, pageAllowance: 12_288))
            for part in record.parts {
                for representation in part.representations {
                    let digest = RepresentationStorage.digest(representation.data)
                    if digests.insert(digest).inserted,
                       !FileManager.default.fileExists(atPath: try representations.url(for: digest).path) {
                        attachmentBytes = try HistoryWriteBudget.adding(attachmentBytes, Int64(representation.data.count))
                    }
                }
            }
        }
        // The recovery archive and prior library remain present throughout replacement.
        // A portable owned URL is rewritten to this profile. Reserve fresh URL metadata/blocks
        // independently of the source digest because the new path differs after import.
        for _ in backup.ownedFileBindings ?? [] {
            attachmentBytes = try HistoryWriteBudget.adding(attachmentBytes, 4_096)
        }
        var ownedBytes: Int64 = 0
        for asset in backup.ownedFiles ?? [] {
            ownedBytes = try HistoryWriteBudget.adding(ownedBytes, Int64(asset.data.count) * 2)
            databaseBytes = try HistoryWriteBudget.adding(databaseBytes, 65_536)
        }
        for board in backup.pinboards {
            databaseBytes = try HistoryWriteBudget.adding(databaseBytes,
                69_632 + Int64(board.name.utf8.count + board.color.utf8.count) * 8)
        }
        if backup.pinboardOrder != nil {
            // Merge rewrites every retained sidebar position as well as the imported positions.
            // The prepaid scope bypasses the lower-level guard, so include both sets here.
            let existingCount = mode == .merge ? try orderedPinboardsWithoutLock().count : 0
            let rewrittenCount = Int64(existingCount) + Int64(backup.pinboards.count)
            databaseBytes = try HistoryWriteBudget.adding(databaseBytes, 65_536 + rewrittenCount * 4_096)
        }
        try writeBudget.prepay([
            .init(destination: databaseURL, bytes: databaseBytes),
            .init(destination: representations.directory, bytes: attachmentBytes),
            .init(destination: ownedFileStorage.directory, bytes: ownedBytes),
            .init(destination: recoveryURL, bytes: Int64(recoveryData.count))
        ])
    }

    /// Conservative JSON size bound based on stored metadata, without reading .blob or owned payload files.
    /// This is an archive-size guard, not a process resident-memory limit.
    func preflightBackupPayload(pinboardBytes: Int, maximumArchiveBytes: Int = HistoryStore.maximumBackupBytes) throws {
        guard maximumArchiveBytes >= 4_096 else { throw HistoryStoreError.valueTooLarge }
        let limit = (maximumArchiveBytes - 4_096) / 4 * 3
        var used = 0, count = 0, bindingCount = 0, included = Set<UUID>()
        func add(_ value: Int) throws {
            guard value >= 0, value <= limit - used else { throw HistoryStoreError.valueTooLarge }
            used += value
        }
        func base64Size(_ size: Int) throws -> Int {
            guard (0...RepresentationStorage.maximumRepresentationBytes).contains(size) else { throw HistoryStoreError.valueTooLarge }
            return (size + 2) / 3 * 4
        }
        try add(pinboardBytes)
        // Sidebar UUID order has separate storage in the archive.
        let boardCount = try prepare("SELECT COUNT(*) FROM pinboards")
        defer { sqlite3_finalize(boardCount) }
        try check(sqlite3_step(boardCount), allowingRow: true)
        let numberOfBoards = Int(sqlite3_column_int64(boardCount, 0))
        guard (0...10_000).contains(numberOfBoards) else { throw HistoryStoreError.valueTooLarge }
        try add(numberOfBoards * 40)
        let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records")
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            try check(status, allowingRow: true)
            count += 1
            guard count <= 100_000, let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.valueTooLarge }
            try add(1_024)
            for column: Int32 in [1, 2, 3, 8, 9, 16] {
                if let bytes = sqlite3_column_text(statement, column) {
                    let length = Int(sqlite3_column_bytes(statement, column))
                    // ASCII control escapes can use six bytes; non-ASCII uses a conservative twofold bound.
                    for index in 0..<length {
                        let byte = bytes[index]
                        try add(byte < 32 ? 6 : (byte == 34 || byte == 92 || byte >= 128 ? 2 : 1))
                    }
                }
            }
            for column: Int32 in [5, 6] { try add(base64Size(Int(sqlite3_column_bytes(statement, column)))) }
            var storedParts: [[StoredRepresentation]] = []
            if let metadata = dataColumn(statement, 7) {
                storedParts = try JSONDecoder().decode([[StoredRepresentation]].self, from: metadata)
                guard storedParts.count <= 1_000 else { throw HistoryStoreError.valueTooLarge }
                for part in storedParts {
                    guard part.count <= 100 else { throw HistoryStoreError.valueTooLarge }
                    try add(32)
                    for representation in part {
                        guard representation.typeIdentifier.utf8.count <= 1_024 else { throw HistoryStoreError.valueTooLarge }
                        try add(128 + representation.typeIdentifier.utf8.count * 6)
                        try add(base64Size(representation.byteCount))
                    }
                }
            }
            for binding in try ownedFileBindingsWithoutLock(recordID: id) {
                bindingCount += 1
                guard bindingCount <= Self.maximumBackupBindings else { throw HistoryStoreError.valueTooLarge }
                try add(256)
                guard storedParts.indices.contains(binding.partIndex),
                      storedParts[binding.partIndex].indices.contains(binding.representationIndex) else { throw HistoryStoreError.invalidOwnedFile }
                let slot = storedParts[binding.partIndex][binding.representationIndex]
                guard slot.typeIdentifier == "public.file-url" else { throw HistoryStoreError.invalidOwnedFile }
                // A physical database snapshot can move to a longer root; decode rebases every owned URL.
                let currentLength = try ownedFileURLWithoutLock(assetID: binding.assetID).absoluteString.utf8.count
                try add(max(0, try base64Size(currentLength) - base64Size(slot.byteCount)))
                if included.insert(binding.assetID).inserted {
                    guard included.count <= Self.maximumBackupAssets else { throw HistoryStoreError.valueTooLarge }
                    let asset = try ownedFileAssetWithoutLock(id: binding.assetID)
                    try OwnedFileStorage.validateFilename(asset.filename)
                    try add(512 + asset.filename.utf8.count * 6)
                    try add(base64Size(asset.byteCount))
                }
            }
        }
    }

    func readBackup(_ source: URL) throws -> HistoryBackup {
        guard source.isFileURL, !source.path.contains("\0") else { throw HistoryStoreError.invalidBackup }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HistoryStoreError.invalidBackup }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Self.maximumBackupBytes else { throw HistoryStoreError.invalidBackup }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1_024 * 1_024, Self.maximumBackupBytes - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= Self.maximumBackupBytes - data.count else { throw HistoryStoreError.invalidBackup }
            data.append(chunk)
        }
        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        guard envelope.formatVersion == 1, envelope.checksum == RepresentationStorage.digest(envelope.payload) else { throw HistoryStoreError.invalidBackup }
        let backup = try JSONDecoder().decode(HistoryBackup.self, from: envelope.payload)
        guard [2, 3].contains(backup.schemaVersion), backup.records.count <= 100_000, backup.pinboards.count <= 10_000,
              Set(backup.records.map(\.id)).count == backup.records.count,
              Set(backup.pinboards.map(\.id)).count == backup.pinboards.count else { throw HistoryStoreError.invalidBackup }
        let boards = Set(backup.pinboards.map(\.id))
        if let order = backup.pinboardOrder {
            guard Set(order) == boards, order.count == boards.count else { throw HistoryStoreError.invalidBackup }
        }
        for board in backup.pinboards { try validate(board) }
        for record in backup.records {
            try validate(record)
            if let board = record.pinboardID, !boards.contains(board) { throw HistoryStoreError.invalidBackup }
            guard record.isInHistory || record.pinboardID != nil else { throw HistoryStoreError.invalidBackup }
        }
        try validateOwnedBackup(backup)
        return backup
    }

    private func validateOwnedBackup(_ backup: HistoryBackup) throws {
        if backup.schemaVersion == 2 {
            guard backup.ownedFiles == nil, backup.ownedFileBindings == nil else { throw HistoryStoreError.invalidBackup }
            return
        }
        let assets = backup.ownedFiles ?? [], bindings = backup.ownedFileBindings ?? []
        guard assets.count <= Self.maximumBackupAssets, bindings.count <= Self.maximumBackupBindings,
              Set(assets.map { $0.asset.id }).count == assets.count else { throw HistoryStoreError.invalidBackup }
        let assetIDs = Set(assets.map { $0.asset.id })
        for entry in assets {
            try OwnedFileStorage.validateFilename(entry.asset.filename)
            guard (0...OwnedFileStorage.maximumBytes).contains(entry.asset.byteCount), entry.data.count == entry.asset.byteCount,
                  RepresentationStorage.digest(entry.data) == entry.asset.sha256 else { throw HistoryStoreError.invalidBackup }
        }
        let records = Dictionary(uniqueKeysWithValues: backup.records.map { ($0.id, $0) })
        var slots = Set<String>(), used = Set<UUID>()
        for binding in bindings {
            guard assetIDs.contains(binding.assetID), let record = records[binding.recordID],
                  record.parts.indices.contains(binding.partIndex),
                  record.parts[binding.partIndex].representations.indices.contains(binding.representationIndex),
                  slots.insert("\(binding.recordID):\(binding.partIndex):\(binding.representationIndex)").inserted else { throw HistoryStoreError.invalidBackup }
            let representation = record.parts[binding.partIndex].representations[binding.representationIndex]
            guard representation.typeIdentifier == "public.file-url",
                  let string = String(data: representation.data, encoding: .utf8), !string.contains("\0"),
                  let url = URL(string: string), url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
                  url.query == nil, url.fragment == nil,
                  url.host == nil || url.host == "" || url.host == "localhost" else { throw HistoryStoreError.invalidBackup }
            // This path is only a syntactic part of the old record. It is never dereferenced.
            used.insert(binding.assetID)
        }
        guard used == assetIDs else { throw HistoryStoreError.invalidBackup }
    }
}
