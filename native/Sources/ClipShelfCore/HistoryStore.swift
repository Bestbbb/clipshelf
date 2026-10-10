import ClipShelfLocalization
import CSQLite
import Foundation

public enum HistoryStoreError: Error, LocalizedError {
    case invalidDatabaseURL
    case unsupportedSchemaVersion(Int)
    case invalidTimestamp
    case invalidStoredRecord
    case valueTooLarge
    case corruptAttachment
    case invalidOwnedFile
    case corruptOwnedFile
    case recordNotFound
    case pinboardNotFound
    case invalidPinboard
    case invalidPinboardOrder
    case invalidPinboardItemOrder
    case staleRevision
    case invalidSelection
    case invalidPageRequest
    case selectionPayloadTooLarge
    case invalidBackup
    case backupExists
    case syncedProfileRequiresLocalMerge
    case database(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL: return L10n.text("History requires a local file URL.")
        case .unsupportedSchemaVersion(let version): return L10n.text("History uses an unsupported schema version (\(version)).")
        case .invalidTimestamp: return L10n.text("The clipboard capture time is invalid.")
        case .invalidStoredRecord: return L10n.text("A history record could not be decoded.")
        case .valueTooLarge: return L10n.text("The clipboard representation is too large to store.")
        case .corruptAttachment: return L10n.text("A clipboard attachment is missing or failed its integrity check.")
        case .invalidOwnedFile: return L10n.text("托管文件的名称、内容或归属无效，未保存任何部分内容。")
        case .corruptOwnedFile: return L10n.text("托管文件原件缺失、被修改或包含不安全路径，未继续操作。")
        case .recordNotFound: return L10n.text("This clipboard item no longer exists.")
        case .pinboardNotFound: return L10n.text("This pinboard no longer exists.")
        case .invalidPinboard: return L10n.text("A pinboard needs a name and a six-digit color.")
        case .invalidPinboardOrder: return L10n.text("The new order must contain every current pinboard exactly once. Reload the pinboards and try again.")
        case .invalidPinboardItemOrder: return L10n.text("分组内容或排序位置已改变。请重新加载；分页重排应使用移动条目操作，不能以部分列表覆盖整个分组。")
        case .invalidSelection: return L10n.text("选择列表无效，或已撤销的操作不属于当前资料库。请重新选择。")
        case .invalidPageRequest: return L10n.text("首尾定位不能同时指定分页偏移或条目锚点，请重新加载列表。")
        case .selectionPayloadTooLarge: return L10n.text("选中内容超过本次读取的容量限制，未执行任何输出。请减少选中内容后重试。")
        case .staleRevision: return L10n.text("This item changed while it was being edited. Reload it before saving.")
        case .invalidBackup: return L10n.text("This backup is damaged, too large, or uses an unsupported format.")
        case .backupExists: return L10n.text("A file already exists at the backup destination.")
        case .syncedProfileRequiresLocalMerge: return L10n.text("此资料库曾与同步账号或共享板关联，不能用备份整体替换。请选择合并，备份会导入为独立本地副本；恢复不会删除云端内容。")
        case .database(let code, let message): return L10n.text("History database error \(code): \(message)")
        }
    }
}

/// A serialized SQLite connection. Public methods may be called from any thread.
public final class HistoryStore: @unchecked Sendable {
    public let databaseURL: URL
    let database: OpaquePointer
    private let lock = NSLock()
    let selectionStoreIdentity = UUID()
    var syncSchemaReady = false
    var trigramSearchAvailable = false
    let recordsLocalOrigin: Bool
    var suppressSyncCapture = false
    var sourceMetadataCache: MetadataCacheEntry<[String: String]>?
    var deviceMetadataCache: MetadataCacheEntry<[ClipboardOriginDevice]>?
    public let spaceCoordinator: StorageSpaceCoordinator
    var writeBudget: HistoryWriteBudget?
    let representations: RepresentationStorage
    let ownedFileStorage: OwnedFileStorage
    var newOwnedFileDirectories: [UUID]?
    var newRepresentationFiles: [NewRepresentationFile]?
    var representationWriteSession: RepresentationWriteSession?
    var ownedFilesSchemaReady = false
    var contentQuotaSchemaReady = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let columns = "id, text, source_app, source_bundle_id, copied_at, rtf, html, parts, renamed_title, ocr_text, pinboard_id, is_in_history, revision, content_kind, pinboard_order, origin_device_id, origin_device_name, origin_device_conflict, local_history_order, pinboard_order_identity"
    private static let metadataColumns = "id, text, source_app, source_bundle_id, copied_at, NULL, NULL, parts, renamed_title, ocr_text, pinboard_id, is_in_history, revision, content_kind, pinboard_order, origin_device_id, origin_device_name, origin_device_conflict, local_history_order, pinboard_order_identity"

    public convenience init(databaseURL: URL, recordsLocalOrigin: Bool = false,
                            spaceCoordinator: StorageSpaceCoordinator? = nil) throws {
        try self.init(databaseURL: databaseURL, recordsLocalOrigin: recordsLocalOrigin,
                      spaceCoordinator: spaceCoordinator, configureConnection: nil)
    }

    /// Connection-local instrumentation can observe initialization without a process-global hook.
    /// Throwing after all properties are initialized follows the same deinit/close path as migration.
    init(databaseURL: URL, recordsLocalOrigin: Bool = false,
         spaceCoordinator: StorageSpaceCoordinator? = nil,
         configureConnection: ((OpaquePointer) throws -> Void)?) throws {
        guard databaseURL.isFileURL, !databaseURL.path.utf8.contains(0) else {
            throw HistoryStoreError.invalidDatabaseURL
        }
        self.databaseURL = databaseURL
        self.recordsLocalOrigin = recordsLocalOrigin
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let coordinator = try spaceCoordinator ?? StorageSpaceCoordinator(
            directory: databaseURL.deletingLastPathComponent().appendingPathComponent(".storage-reservations", isDirectory: true))
        self.spaceCoordinator = coordinator
        representations = try RepresentationStorage(databaseURL: databaseURL, spaceCoordinator: coordinator)
        ownedFileStorage = try OwnedFileStorage(databaseURL: databaseURL, spaceCoordinator: coordinator)
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("Unable to open database.")
            if let connection { sqlite3_close_v2(connection) }
            throw HistoryStoreError.database(code: status, message: message)
        }
        database = connection
        // All stored properties are initialized here; deinit also closes the connection
        // if any remaining initialization step throws.
        sqlite3_extended_result_codes(database, 1)
        try check(sqlite3_busy_timeout(database, 5_000))
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA secure_delete = ON")
        try configureConnection?(database)
        try migrate()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    deinit { sqlite3_close_v2(database) }

    /// Most recently captured first, even when the wall clock moves backwards.
    public func load(limit: Int = 500) throws -> [ClipboardRecord] {
        guard limit > 0 else { return [] }
        return try synchronized {
            let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records WHERE is_in_history = 1 ORDER BY local_history_order DESC LIMIT ?")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_int64(statement, 1, Int64(clamping: limit)))
            var records: [ClipboardRecord] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return records }
                try check(status, allowingRow: true)
                records.append(try decode(statement))
            }
        }
    }

    /// Stores a capture, coalescing only the immediately preceding identical capture.
    @discardableResult
    public func record(_ candidate: ClipboardRecord) throws -> ClipboardRecord {
        try validate(candidate)
        return try synchronized {
            try transaction { try recordWithoutLock(candidate) }
        }
    }

    func recordWithoutLock(_ candidate: ClipboardRecord) throws -> ClipboardRecord {
        let latest = try latestRecord()
        var stored = try assigningLocalOrigin(candidate, preserveOrigin: false)
        stored.isInHistory = true
        if let latest, latest.hasSameContents(as: stored), latest.originDeviceID == stored.originDeviceID,
           latest.originDeviceConflict == stored.originDeviceConflict, try canCoalesceSyncItem(id: latest.id) {
            stored = latest
            stored.copiedAt = candidate.copiedAt
            stored.isInHistory = true
            stored.revision += 1
            try reserveRecordWriteWithoutLock(stored)
            let statement = try prepare("UPDATE clipboard_records SET copied_at = ?, is_in_history = 1, revision = revision + 1 WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_double(statement, 1, candidate.copiedAt.timeIntervalSinceReferenceDate))
            try bind(latest.id.uuidString, at: 2, to: statement)
            try stepToCompletion(statement)
        } else {
            stored = try assigningNewPinboardOrder(stored)
            try insert(stored)
        }
        return stored
    }

    public func delete(id: UUID) throws {
        try synchronized {
            try transaction(allowReclamation: true) {
                let statement = try prepare("DELETE FROM clipboard_records WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                try bind(id.uuidString, at: 1, to: statement)
                try stepToCompletion(statement)
            }
        }
    }

    public func clear() throws {
        try synchronized { try transaction(allowReclamation: true) { try execute("DELETE FROM clipboard_records") } }
    }

    /// Explicit creation never coalesces with a prior capture (used by editing and scoped integrations).
    @discardableResult
    public func create(_ record: ClipboardRecord, preserveOrigin: Bool = false) throws -> ClipboardRecord {
        try validate(record)
        guard record.isInHistory || record.pinboardID != nil else { throw HistoryStoreError.invalidStoredRecord }
        return try synchronized {
            try transaction {
                let stored = try assigningNewPinboardOrder(assigningLocalOrigin(record, preserveOrigin: preserveOrigin))
                try insert(stored)
                return stored
            }
        }
    }

    /// External integrations bind consent to both account generations, including an A→B→A switch.
    @discardableResult
    public func create(_ record: ClipboardRecord, expectedSyncConfiguration: SyncConfiguration,
                       expectedSharingConfiguration: SyncConfiguration, preserveOrigin: Bool = false) throws -> ClipboardRecord {
        try validate(record)
        guard record.isInHistory || record.pinboardID != nil else { throw HistoryStoreError.invalidStoredRecord }
        return try synchronized {
            try transaction {
                try requireIntegrationConfigurations(sync: expectedSyncConfiguration, sharing: expectedSharingConfiguration)
                if let boardID = record.pinboardID, let namespace = try syncNamespace(kind: .pinboard, id: boardID) {
                    if let shared = try sharedStateForNamespace(namespace) {
                        guard shared.descriptor.accountID == expectedSharingConfiguration.accountID else { throw SyncError.accountChanged }
                        guard shared.access.canWrite else { throw shared.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
                    } else {
                        guard namespace == expectedSyncConfiguration.accountID else { throw SyncError.namespaceConflict }
                    }
                }
                let stored = try assigningNewPinboardOrder(assigningLocalOrigin(record, preserveOrigin: preserveOrigin))
                try insert(stored)
                return stored
            }
        }
    }

    public func item(id: UUID) throws -> ClipboardRecord? {
        try synchronized { try itemWithoutLock(id: id) }
    }

    public func itemMetadata(id: UUID) throws -> ClipboardRecordMetadata? {
        try synchronized {
            let statement = try prepare("SELECT \(Self.metadataColumns) FROM clipboard_records WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, at: 1, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            try check(status, allowingRow: true)
            return try decodeMetadata(statement)
        }
    }

    public func searchMetadata(_ query: HistoryQuery, offset: Int = 0) throws -> [ClipboardRecordMetadata] {
        guard query.limit > 0 else { return [] }
        return try synchronized {
            let statement = try prepareSearch(query, metadataOnly: true, offset: offset)
            defer { sqlite3_finalize(statement) }
            var records: [ClipboardRecordMetadata] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return records }
                try check(status, allowingRow: true)
                records.append(try decodeMetadata(statement))
            }
        }
    }

    /// Zero-based position in the complete filtered result, independent of the page limit.
    /// The database reads only IDs and sort/filter columns, never representation files.
    public func metadataOffset(of recordID: UUID, query: HistoryQuery) throws -> Int? {
        try synchronized {
            let statement = try prepareSearch(query, metadataOnly: true, offset: 0, offsetFor: recordID)
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            try check(status, allowingRow: true)
            try requireHistoryOrderColumn(statement, at: 1)
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Integrations can read local content, the active private account, and currently accessible shared boards.
    /// Filtering occurs before pagination; previous account caches and revoked shares are excluded.
    public func searchIntegrationMetadata(_ query: HistoryQuery, offset: Int = 0,
                                          expectedSyncConfiguration: SyncConfiguration,
                                          expectedSharingConfiguration: SyncConfiguration) throws -> [ClipboardRecordMetadata] {
        try synchronized {
            try transaction {
                try requireIntegrationConfigurations(sync: expectedSyncConfiguration, sharing: expectedSharingConfiguration)
                guard query.limit > 0 else { return [] }
                let statement = try prepareSearch(query, metadataOnly: true, offset: offset,
                                                  integrationScope: (expectedSyncConfiguration, expectedSharingConfiguration))
                defer { sqlite3_finalize(statement) }
                var records: [ClipboardRecordMetadata] = []
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { return records }
                    try check(status, allowingRow: true)
                    records.append(try decodeMetadata(statement))
                }
            }
        }
    }

    func requireIntegrationConfigurations(sync: SyncConfiguration, sharing: SyncConfiguration) throws {
        guard try syncConfigurationWithoutLock() == sync, try sharingConfigurationWithoutLock() == sharing else { throw SyncError.accountChanged }
    }

    /// Filters metadata before loading representation files. Query text is literal, including SQL punctuation.
    public func search(_ query: HistoryQuery) throws -> [ClipboardRecord] {
        guard query.limit > 0 else { return [] }
        return try synchronized {
            let statement = try prepareSearch(query, metadataOnly: false, offset: 0)
            defer { sqlite3_finalize(statement) }
            return try readRecords(statement)
        }
    }

    func prepareSearch(_ query: HistoryQuery, metadataOnly: Bool, offset: Int,
                       integrationScope: (SyncConfiguration, SyncConfiguration)? = nil, offsetFor recordID: UUID? = nil,
                       countOnly: Bool = false, selectionOnly: Bool = false) throws -> OpaquePointer {
            var clauses = [query.includePinned ? "(is_in_history = 1 OR pinboard_id IS NOT NULL)" : "is_in_history = 1"]
            var strings: [String] = []
            if !query.text.isEmpty {
                if trigramSearchAvailable, let candidate = Self.trigramCandidateExpression(query.text) {
                    clauses.append("rowid IN (SELECT rowid FROM clipboard_search WHERE clipboard_search MATCH ?)")
                    strings.append(candidate)
                }
                clauses.append("instr(\(Self.searchableTextSQL()), lower(?)) > 0")
                strings.append(query.text)
            }
            switch query.deviceFilter {
            case .all: break
            case .device(let id): clauses.append("origin_device_id = ? AND origin_device_conflict = 0"); strings.append(id.uuidString)
            case .unknown: clauses.append("(origin_device_id IS NULL OR origin_device_conflict = 1)")
            }
            if let kind = query.kind { clauses.append("content_kind = ?"); strings.append(kind.rawValue) }
            if let source = query.sourceBundleID { clauses.append("source_bundle_id = ?"); strings.append(source) }
            if !query.pinboardIDs.isEmpty {
                clauses.append("pinboard_id IN (\(Array(repeating: "?", count: query.pinboardIDs.count).joined(separator: ",")))")
                strings.append(contentsOf: query.pinboardIDs.map(\.uuidString).sorted())
            }
            if let (sync, sharing) = integrationScope {
                let namespace = "coalesce((SELECT account_id FROM sync_namespaces WHERE entity_kind = 'clipboard' AND entity_id = clipboard_records.id), (SELECT account_id FROM sync_namespaces WHERE entity_kind = 'pinboard' AND entity_id = clipboard_records.pinboard_id))"
                var allowed = ["\(namespace) IS NULL"]
                if let account = sync.accountID { allowed.append("\(namespace) = ?"); strings.append(account) }
                if let account = sharing.accountID {
                    allowed.append("\(namespace) IN (SELECT namespace FROM shared_boards WHERE account_id = ? AND access IN ('owner', 'readWrite', 'readOnly'))")
                    strings.append(account)
                }
                clauses.append("(\(allowed.joined(separator: " OR ")))")
            }
            var dates: [Date] = []
            if let date = query.copiedAfter { clauses.append("copied_at >= ?"); dates.append(date) }
            if let date = query.copiedBefore { clauses.append("copied_at <= ?"); dates.append(date) }
            guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw HistoryStoreError.invalidTimestamp }
            if query.sortOrder == .pinboard, query.pinboardIDs.count != 1 { throw HistoryStoreError.invalidPinboardItemOrder }
            let ordering = query.sortOrder == .pinboard ? Self.pinboardOrderingSQL : "local_history_order DESC"
            let sql: String
            if countOnly {
                sql = "SELECT count(*) FROM clipboard_records WHERE \(clauses.joined(separator: " AND "))"
            } else if selectionOnly {
                sql = "SELECT id, revision, local_history_order FROM clipboard_records WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(ordering)"
            } else if recordID != nil {
                sql = "SELECT position, local_history_order FROM (SELECT id, local_history_order, row_number() OVER (ORDER BY \(ordering)) - 1 AS position FROM clipboard_records WHERE \(clauses.joined(separator: " AND "))) WHERE id = ?"
            } else {
                sql = "SELECT \(metadataOnly ? Self.metadataColumns : Self.columns) FROM clipboard_records WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(ordering) LIMIT ? OFFSET ?"
            }
            let statement = try prepare(sql)
            var success = false
            defer { if !success { sqlite3_finalize(statement) } }
            var index: Int32 = 1
            for value in strings { try bind(value, at: index, to: statement); index += 1 }
            for date in dates { try check(sqlite3_bind_double(statement, index, date.timeIntervalSinceReferenceDate)); index += 1 }
            if countOnly || selectionOnly { /* Unbounded projections use only the shared filter bindings. */ }
            else if let recordID { try bind(recordID.uuidString, at: index, to: statement) }
            else {
                try check(sqlite3_bind_int64(statement, index, Int64(clamping: query.limit)))
                try check(sqlite3_bind_int64(statement, index + 1, Int64(clamping: max(0, offset))))
            }
            success = true
            return statement
    }

    /// Optimistic revision checking prevents an editor from overwriting a concurrent change.
    @discardableResult
    public func update(record: ClipboardRecord, expectedSyncConfiguration: SyncConfiguration? = nil,
                       expectedSharingConfiguration: SyncConfiguration? = nil) throws -> ClipboardRecord {
        try validate(record)
        return try synchronized {
            try transaction {
                if let expectedSyncConfiguration {
                    guard try syncConfigurationWithoutLock() == expectedSyncConfiguration else { throw SyncError.accountChanged }
                }
                if let expectedSharingConfiguration {
                    guard try sharingConfigurationWithoutLock() == expectedSharingConfiguration else { throw SyncError.accountChanged }
                }
                guard let current = try itemWithoutLock(id: record.id) else { throw HistoryStoreError.recordNotFound }
                return try updateWithoutLock(record: record, current: current)
            }
        }
    }

    func updateWithoutLock(record: ClipboardRecord, current: ClipboardRecord, preserveOCR: Bool = false) throws -> ClipboardRecord {
        guard current.id == record.id, current.revision == record.revision else { throw HistoryStoreError.staleRevision }
        var next = record
        next.revision = current.revision + 1
        next.originDeviceID = current.originDeviceID
        next.originDeviceName = current.originDeviceName
        next.originDeviceConflict = current.originDeviceConflict
        // Stable rank-tie identity belongs to ordering, not to an editable content snapshot.
        // Preserve it even when an older caller omits the field or moves the item to another board.
        next.pinboardOrderIdentity = current.pinboardOrderIdentity
        if next.pinboardID == current.pinboardID {
            next.pinboardOrder = current.pinboardOrder
        } else {
            next.pinboardOrder = nil
            next = try assigningNewPinboardOrder(next)
        }
        if !preserveOCR, !current.hasSameContents(as: record), current.ocrText == record.ocrText { next.ocrText = nil }
        try replaceContents(next)
        return next
    }

    public func pinboards(cancellation: HistoryReadCancellation? = nil) throws -> [Pinboard] {
        try synchronizedRead(cancellation: cancellation) {
            try withReadCancellation(cancellation) { try orderedPinboardsWithoutLock(cancellation: cancellation) }
        }
    }

    func orderedPinboardsWithoutLock(cancellation: HistoryReadCancellation? = nil) throws -> [Pinboard] {
        let boards = try pinboardsWithoutLock(cancellation: cancellation)
        let statement = try prepare("SELECT board_id, position FROM pinboard_local_order")
        defer { sqlite3_finalize(statement) }
        var positions: [UUID: Int] = [:]
        while true {
            try cancellation?.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            try check(status, allowingRow: true)
            guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.invalidStoredRecord }
            positions[id] = Int(sqlite3_column_int64(statement, 1))
        }
        return try boards.enumerated().sorted { lhs, rhs in
            try cancellation?.checkCancellation()
            return (positions[lhs.element.id] ?? Int.max, lhs.offset) < (positions[rhs.element.id] ?? Int.max, rhs.offset)
        }.map(\.element)
    }

    /// Personal sidebar order is atomic and does not mutate a shared board or require write permission.
    /// The complete ID list prevents a stale UI from silently dropping newly received boards.
    /// An expected order additionally rejects a concurrent reorder of the same board set.
    @discardableResult
    public func reorderPinboards(ids: [UUID], expectedOrder: [UUID]? = nil) throws -> [Pinboard] {
        try synchronized {
            try transaction {
                if let expectedOrder, try orderedPinboardsWithoutLock().map(\.id) != expectedOrder {
                    throw HistoryStoreError.invalidPinboardOrder
                }
                try reorderPinboardsWithoutLock(ids: ids)
                return try orderedPinboardsWithoutLock()
            }
        }
    }

    func reorderPinboardsWithoutLock(ids: [UUID]) throws {
        let current = Set(try pinboardsWithoutLock().map(\.id))
        guard Set(ids) == current, ids.count == current.count else { throw HistoryStoreError.invalidPinboardOrder }
        try reserveMetadataWriteWithoutLock(rows: Int64(current.count))
        try execute("DELETE FROM pinboard_local_order")
        let statement = try prepare("INSERT INTO pinboard_local_order(board_id, position) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        for (position, id) in ids.enumerated() {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(id.uuidString, at: 1, to: statement)
            try check(sqlite3_bind_int64(statement, 2, Int64(position)))
            try stepToCompletion(statement)
        }
    }

    @discardableResult
    public func createPinboard(name: String, color: String = "#4F7CFF") throws -> Pinboard {
        try synchronized {
            try transaction {
                let order = (try pinboardsWithoutLock().map(\.sortOrder).max() ?? -1) + 1
                let board = Pinboard(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color, sortOrder: order)
                try validate(board)
                try savePinboard(board, replace: false)
                return board
            }
        }
    }

    public func updatePinboard(_ board: Pinboard) throws {
        try validate(board)
        try synchronized {
            try transaction {
                guard try pinboardsWithoutLock().contains(where: { $0.id == board.id }) else { throw HistoryStoreError.pinboardNotFound }
                try savePinboard(board, replace: true)
            }
        }
    }

    /// The caller must choose whether removing a board also removes its items from history.
    public func deletePinboard(id: UUID, deleteItems: Bool = false) throws {
        try synchronized {
            try transaction(allowReclamation: true) {
                if deleteItems {
                    let items = try prepare("DELETE FROM clipboard_records WHERE pinboard_id = ?")
                    defer { sqlite3_finalize(items) }
                    try bind(id.uuidString, at: 1, to: items)
                    try stepToCompletion(items)
                } else {
                    let items = try prepare("UPDATE clipboard_records SET revision = revision + 1, is_in_history = 1, pinboard_order = NULL WHERE pinboard_id = ?")
                    defer { sqlite3_finalize(items) }
                    try bind(id.uuidString, at: 1, to: items)
                    try stepToCompletion(items)
                }
                let statement = try prepare("DELETE FROM pinboards WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                try bind(id.uuidString, at: 1, to: statement)
                try stepToCompletion(statement)
                try removeUnretainedRows()
            }
        }
    }

    public func move(recordID: UUID, to pinboardID: UUID?) throws {
        try move(recordIDs: [recordID], to: pinboardID)
    }

    public func clearHistory() throws {
        try synchronized {
            _ = try transaction(allowReclamation: true) { try cleanupHistoryWithoutLock(before: nil) }
        }
    }

    public func countHistory(before cutoff: Date) throws -> Int {
        guard cutoff.timeIntervalSinceReferenceDate.isFinite else { throw HistoryStoreError.invalidTimestamp }
        return try synchronized { try countHistoryWithoutLock(before: cutoff) }
    }

    @discardableResult
    public func prune(before cutoff: Date) throws -> Int {
        guard cutoff.timeIntervalSinceReferenceDate.isFinite else { throw HistoryStoreError.invalidTimestamp }
        return try synchronized {
            try transaction(allowReclamation: true) { try cleanupHistoryWithoutLock(before: cutoff).summary.affectedCount }
        }
    }

    /// Reclaims unreferenced attachment files under a database write lock.
    /// Run after mutation batches on a background queue, not while rendering the panel.
    @discardableResult
    public func compactAttachments() throws -> Int {
        try synchronized {
            try transaction {
                if representationWriteSession == nil { representationWriteSession = try representations.beginWriteSession() }
                let statement = try prepare("SELECT parts FROM clipboard_records WHERE parts IS NOT NULL")
                defer { sqlite3_finalize(statement) }
                var referenced = Set<String>()
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    try check(status, allowingRow: true)
                    if let data = dataColumn(statement, 0) {
                        let parts = try JSONDecoder().decode([[StoredRepresentation]].self, from: data)
                        referenced.formUnion(parts.flatMap { $0.map(\.digest) })
                    }
                }
                var count = 0
                for file in try FileManager.default.contentsOfDirectory(at: representations.directory, includingPropertiesForKeys: nil) {
                    let digest = file.deletingPathExtension().lastPathComponent
                    if file.pathExtension == "blob", !referenced.contains(digest) {
                        // Only generated digest filenames are eligible; never follow an archive path.
                        _ = try representations.url(for: digest)
                        try FileManager.default.removeItem(at: file)
                        count += 1
                    }
                }
                return count
            }
        }
    }

    func validate(_ record: ClipboardRecord) throws {
        guard record.copiedAt.timeIntervalSinceReferenceDate.isFinite else { throw HistoryStoreError.invalidTimestamp }
        if let rank = record.pinboardOrder {
            guard record.pinboardID != nil, Self.minimumPinboardRank...Self.maximumPinboardRank ~= rank else { throw HistoryStoreError.invalidStoredRecord }
        }
        guard (record.originDeviceID != nil || record.originDeviceName == nil),
              !record.originDeviceConflict || (record.originDeviceID == nil && record.originDeviceName == nil),
              (record.originDeviceName?.utf8.count ?? 0) <= 512 else { throw HistoryStoreError.invalidStoredRecord }
        guard record.revision > 0, record.revision < Int.max,
              record.text.utf8.count <= RepresentationStorage.maximumRepresentationBytes,
              (record.rtf?.count ?? 0) <= RepresentationStorage.maximumRepresentationBytes,
              (record.html?.count ?? 0) <= RepresentationStorage.maximumRepresentationBytes,
              record.parts.count <= 1_000 else { throw HistoryStoreError.valueTooLarge }
        for part in record.parts {
            guard part.representations.count <= 100,
                  Set(part.representations.map(\.typeIdentifier)).count == part.representations.count else {
                throw HistoryStoreError.invalidStoredRecord
            }
            for representation in part.representations {
                guard !representation.typeIdentifier.isEmpty, representation.typeIdentifier.count <= 1_024,
                      representation.data.count <= RepresentationStorage.maximumRepresentationBytes else {
                    throw HistoryStoreError.valueTooLarge
                }
            }
        }
    }

    func validate(_ board: Pinboard) throws {
        let name = board.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, board.color.hasPrefix("#"), board.color.count == 7,
              board.color.dropFirst().allSatisfy(\.isHexDigit) else { throw HistoryStoreError.invalidPinboard }
    }

    func insert(_ record: ClipboardRecord, historyOrder: Int64? = nil) throws {
        try validate(record)
        if let historyOrder { try validateRestoredHistoryOrderWithoutLock(historyOrder) }
        let statement = try prepare("INSERT INTO clipboard_records (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)")
        defer { sqlite3_finalize(statement) }
        try bindRecord(record, to: statement)
        try stepToCompletion(statement)
        if let historyOrder { try restoreHistoryOrderWithoutLock(id: record.id, order: historyOrder) }
    }

    func bindRecord(_ record: ClipboardRecord, to statement: OpaquePointer) throws {
        try reserveRecordWriteWithoutLock(record)
        try bind(record.id.uuidString, at: 1, to: statement)
        try bind(record.text, at: 2, to: statement)
        try bind(record.sourceApp, at: 3, to: statement)
        try bind(record.sourceBundleID, at: 4, to: statement)
        try check(sqlite3_bind_double(statement, 5, record.copiedAt.timeIntervalSinceReferenceDate))
        try bind(record.rtf, at: 6, to: statement)
        try bind(record.html, at: 7, to: statement)
        if representationWriteSession == nil { representationWriteSession = try representations.beginWriteSession() }
        try bind(try representations.encode(record.parts, budget: writeBudget, session: representationWriteSession,
                                           didCreate: { self.newRepresentationFiles?.append($0) }), at: 8, to: statement)
        try bind(record.renamedTitle, at: 9, to: statement)
        try bind(record.ocrText, at: 10, to: statement)
        try bind(record.pinboardID?.uuidString, at: 11, to: statement)
        try check(sqlite3_bind_int(statement, 12, record.isInHistory ? 1 : 0))
        try check(sqlite3_bind_int64(statement, 13, Int64(record.revision)))
        try bind(record.kind.rawValue, at: 14, to: statement)
        if let order = record.pinboardOrder { try check(sqlite3_bind_int64(statement, 15, order)) }
        else { try check(sqlite3_bind_null(statement, 15)) }
        try bind(record.originDeviceID?.uuidString, at: 16, to: statement)
        try bind(record.originDeviceName, at: 17, to: statement)
        try check(sqlite3_bind_int(statement, 18, record.originDeviceConflict ? 1 : 0))
        try bind(record.pinboardOrderIdentity?.uuidString, at: 19, to: statement)
    }

    func replaceContents(_ record: ClipboardRecord) throws {
        try reserveExistingRecordRewriteWithoutLock(id: record.id)
        // Numbered parameters match insert, so the two encoding paths cannot drift.
        let statement = try prepare("""
            UPDATE clipboard_records SET text = ?2, source_app = ?3, source_bundle_id = ?4,
            copied_at = ?5, rtf = ?6, html = ?7, parts = ?8, renamed_title = ?9,
            ocr_text = ?10, pinboard_id = ?11, is_in_history = ?12, revision = ?13,
            content_kind = ?14, pinboard_order = ?15, origin_device_id = ?16,
            origin_device_name = ?17, origin_device_conflict = ?18, pinboard_order_identity = ?19 WHERE id = ?1
            """)
        defer { sqlite3_finalize(statement) }
        try bindRecord(record, to: statement)
        try stepToCompletion(statement)
        try retainMatchingOwnedFileBindingsWithoutLock(record)
    }

    func itemWithoutLock(id: UUID) throws -> ClipboardRecord? {
        let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        try check(status, allowingRow: true)
        return try decode(statement)
    }

    func readRecords(_ statement: OpaquePointer) throws -> [ClipboardRecord] {
        var records: [ClipboardRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            try check(status, allowingRow: true)
            records.append(try decode(statement))
        }
    }

    func pinboardsWithoutLock(cancellation: HistoryReadCancellation? = nil) throws -> [Pinboard] {
        let statement = try prepare("SELECT id, name, color, sort_order FROM pinboards ORDER BY sort_order, rowid")
        defer { sqlite3_finalize(statement) }
        var boards: [Pinboard] = []
        while true {
            try cancellation?.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return boards }
            try check(status, allowingRow: true)
            guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)),
                  let name = textColumn(statement, 1), let color = textColumn(statement, 2) else { throw HistoryStoreError.invalidStoredRecord }
            boards.append(Pinboard(id: id, name: name, color: color, sortOrder: Int(sqlite3_column_int64(statement, 3))))
        }
    }

    func savePinboard(_ board: Pinboard, replace: Bool) throws {
        try reserveMetadataWriteWithoutLock(payloadBytes: Int64(board.name.utf8.count + board.color.utf8.count))
        let sql = replace ? "UPDATE pinboards SET name = ?2, color = ?3, sort_order = ?4 WHERE id = ?1" :
            "INSERT INTO pinboards (id, name, color, sort_order) VALUES (?, ?, ?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(board.id.uuidString, at: 1, to: statement)
        try bind(board.name, at: 2, to: statement)
        try bind(board.color, at: 3, to: statement)
        try check(sqlite3_bind_int64(statement, 4, Int64(clamping: board.sortOrder)))
        try stepToCompletion(statement)
    }

    func createPinboardTable() throws {
        try execute("CREATE TABLE pinboards (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, sort_order INTEGER NOT NULL)")
    }

    func removeUnretainedRows() throws {
        try execute("DELETE FROM clipboard_records WHERE is_in_history = 0 AND pinboard_id IS NULL")
    }

    func countHistoryWithoutLock(before cutoff: Date) throws -> Int {
        let statement = try prepare("SELECT count(*) FROM clipboard_records WHERE is_in_history = 1 AND copied_at < ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, cutoff.timeIntervalSinceReferenceDate))
        try check(sqlite3_step(statement), allowingRow: true)
        return Int(sqlite3_column_int64(statement, 0))
    }

    func recoveryURL(reason: String, extension suffix: String) throws -> URL {
        let directory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("pre-\(reason)-\(UUID().uuidString).\(suffix)")
    }

    /// SQLite's backup API copies a consistent snapshot, including uncheckpointed WAL pages.
    func recoveryDatabaseBackup(reason: String) throws {
        let destination = try recoveryURL(reason: reason, extension: "sqlite3")
        // Block other writers and attachment compaction while a separate read connection
        // snapshots committed SQLite pages and their immutable attachment files.
        try execute("BEGIN IMMEDIATE")
        defer { try? execute("ROLLBACK") }
        let lease = try spaceCoordinator.reserve([
            .init(destination: destination, bytes: try physicalRecoveryBackupBytesWithoutLock())
        ])
        defer { try? lease.release() }
        try lease.revalidate()
        var source: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source else { if let source { sqlite3_close_v2(source) }; throw HistoryStoreError.invalidBackup }
        defer { sqlite3_close_v2(source) }
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let target else { if let target { sqlite3_close_v2(target) }; throw HistoryStoreError.invalidBackup }
        defer { sqlite3_close_v2(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw HistoryStoreError.invalidBackup }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            let error = HistoryStoreError.database(code: step == SQLITE_DONE ? finish : step,
                                                    message: String(cString: sqlite3_errmsg(target)))
            throw StorageWriteFailure.classify(error) ?? HistoryStoreError.invalidBackup
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let attachmentDestination = destination.deletingPathExtension().appendingPathExtension("attachments")
        try FileManager.default.copyItem(at: representations.directory, to: attachmentDestination)
        try lease.validateDestinations()
    }

    func migrate() throws {
        func schemaVersion() throws -> Int {
            let versionStatement = try prepare("PRAGMA user_version")
            defer { sqlite3_finalize(versionStatement) }
            try check(sqlite3_step(versionStatement), allowingRow: true)
            return Int(sqlite3_column_int(versionStatement, 0))
        }
        let observedVersion = try schemaVersion()
        if (1...13).contains(observedVersion) { try recoveryDatabaseBackup(reason: "migration-v\(observedVersion)") }
        suppressSyncCapture = true
        defer { suppressSyncCapture = false }
        try transaction {
            // A different connection may have finished initialization or migration while this
            // connection made its recovery backup or waited for BEGIN IMMEDIATE's writer lock.
            let version = try schemaVersion()
            switch version {
            case 0:
                try createPinboardTable()
                try execute("""
                    CREATE TABLE clipboard_records (
                        id TEXT NOT NULL UNIQUE,
                        text TEXT NOT NULL,
                        source_app TEXT,
                        source_bundle_id TEXT,
                        copied_at REAL NOT NULL,
                        rtf BLOB,
                        html BLOB,
                        parts BLOB,
                        renamed_title TEXT,
                        ocr_text TEXT,
                        pinboard_id TEXT REFERENCES pinboards(id) ON DELETE SET NULL,
                        is_in_history INTEGER NOT NULL DEFAULT 1,
                        revision INTEGER NOT NULL DEFAULT 1,
                        content_kind TEXT NOT NULL DEFAULT 'text'
                    )
                    """)
                try execute("PRAGMA user_version = 2")
            case 1:
                try createPinboardTable()
                for column in ["parts BLOB", "renamed_title TEXT", "ocr_text TEXT", "pinboard_id TEXT REFERENCES pinboards(id) ON DELETE SET NULL", "is_in_history INTEGER NOT NULL DEFAULT 1", "revision INTEGER NOT NULL DEFAULT 1", "content_kind TEXT NOT NULL DEFAULT 'text'"] {
                    try execute("ALTER TABLE clipboard_records ADD COLUMN \(column)")
                }
                let kinds = try prepare("SELECT id, text FROM clipboard_records")
                defer { sqlite3_finalize(kinds) }
                var migratedKinds: [(String, String)] = []
                while true {
                    let status = sqlite3_step(kinds)
                    if status == SQLITE_DONE { break }
                    try check(status, allowingRow: true)
                    if let id = textColumn(kinds, 0), let text = textColumn(kinds, 1) {
                        migratedKinds.append((id, ClipboardRecord(text: text).kind.rawValue))
                    }
                }
                for (id, kind) in migratedKinds {
                    let update = try prepare("UPDATE clipboard_records SET content_kind = ? WHERE id = ?")
                    defer { sqlite3_finalize(update) }
                    try bind(kind, at: 1, to: update)
                    try bind(id, at: 2, to: update)
                    try stepToCompletion(update)
                }
                try execute("PRAGMA user_version = 2")
            case 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14: break
            default: throw HistoryStoreError.unsupportedSchemaVersion(version)
            }
            try initializeLocalHistoryOrder(previousVersion: version)
            try execute("CREATE TABLE IF NOT EXISTS pinboard_order_backfill(board_id TEXT PRIMARY KEY REFERENCES pinboards(id) ON DELETE CASCADE)")
            if version < 7 {
                let columns = try prepare("PRAGMA table_info(clipboard_records)")
                var hasOrder = false
                while sqlite3_step(columns) == SQLITE_ROW { if textColumn(columns, 1) == "pinboard_order" { hasOrder = true } }
                sqlite3_finalize(columns)
                if !hasOrder { try execute("ALTER TABLE clipboard_records ADD COLUMN pinboard_order INTEGER") }
                try execute("INSERT OR IGNORE INTO pinboard_order_backfill(board_id) SELECT DISTINCT pinboard_id FROM clipboard_records WHERE pinboard_id IS NOT NULL AND pinboard_order IS NULL")
                for board in try pinboardsWithoutLock() { try normalizePinboardOrdering(boardID: board.id, incrementRevision: false) }
            }
            try initializeOriginSchema()
            let validation = try prepare("SELECT \(Self.columns) FROM clipboard_records LIMIT 0")
            sqlite3_finalize(validation)
            try execute("CREATE INDEX IF NOT EXISTS clipboard_pinboard ON clipboard_records(pinboard_id)")
            try execute("CREATE INDEX IF NOT EXISTS clipboard_date ON clipboard_records(copied_at)")
            try execute("CREATE INDEX IF NOT EXISTS clipboard_pinboard_order ON clipboard_records(pinboard_id, pinboard_order, id)")
            try createSyncSchema(previousVersion: version)
            try createSharingSchema()
            try createOwnedFilesSchema()
            try execute("CREATE TABLE IF NOT EXISTS pinboard_local_order(board_id TEXT PRIMARY KEY REFERENCES pinboards(id) ON DELETE CASCADE, position INTEGER NOT NULL)")
            try initializeSearchIndex()
            try initializeHistoryCleanupTokens(previousVersion: version)
            try createOwnedSyncSchema(markLegacy: version < 11)
            try createOwnedStorageSchema(protectLegacy: version > 0 && version < 12)
            try initializeContentQuotaSchema(previousVersion: version)
            try execute("PRAGMA user_version = 14")
            syncSchemaReady = true
        }
    }

    /// Validate only schema metadata, not every stored row, on a normal connection open.
    /// Backfill completion is recorded by user_version in the same transaction as installation.
    /// A nil nullability requirement accepts either declaration (for SQLite's legacy TEXT PK).
    func requireStartupTable(_ table: String,
                             columns: [(name: String, type: String, notNull: Bool?)],
                             primaryKey: [String]) throws {
        guard try syncScalar("SELECT type FROM sqlite_master WHERE name = ? COLLATE NOCASE", [table]) == "table" else {
            throw HistoryStoreError.invalidStoredRecord
        }
        // All names here are fixed source-code identifiers, never user-controlled SQL.
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var found: [String: (type: String, notNull: Bool, key: Int)] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            try check(status, allowingRow: true)
            guard let name = textColumn(statement, 1), let type = textColumn(statement, 2) else {
                throw HistoryStoreError.invalidStoredRecord
            }
            found[name.lowercased()] = (type.uppercased(), sqlite3_column_int(statement, 3) != 0,
                                       Int(sqlite3_column_int(statement, 5)))
        }
        for column in columns {
            guard let actual = found[column.name], actual.type == column.type,
                  column.notNull == nil || column.notNull == actual.notNull else { throw HistoryStoreError.invalidStoredRecord }
        }
        let keys = found.filter { $0.value.key > 0 }.sorted { $0.value.key < $1.value.key }.map(\.key)
        guard keys == primaryKey else { throw HistoryStoreError.invalidStoredRecord }
    }

    func latestRecord() throws -> ClipboardRecord? {
        let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records ORDER BY local_history_order DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        try check(status, allowingRow: true)
        return try decode(statement)
    }

    func decode(_ statement: OpaquePointer) throws -> ClipboardRecord {
        try requireHistoryOrderColumn(statement, at: 18)
        guard let idString = textColumn(statement, 0), let id = UUID(uuidString: idString),
              let text = textColumn(statement, 1) else {
            throw HistoryStoreError.invalidStoredRecord
        }
        let record = ClipboardRecord(
            id: id, text: text,
            sourceApp: textColumn(statement, 2), sourceBundleID: textColumn(statement, 3),
            copiedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
            rtf: dataColumn(statement, 5), html: dataColumn(statement, 6),
            parts: try representations.decode(dataColumn(statement, 7)),
            renamedTitle: textColumn(statement, 8), ocrText: textColumn(statement, 9),
            pinboardID: textColumn(statement, 10).flatMap(UUID.init(uuidString:)),
            isInHistory: sqlite3_column_int(statement, 11) != 0,
            revision: Int(sqlite3_column_int64(statement, 12)),
            pinboardOrder: sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 14),
            originDeviceID: textColumn(statement, 15).flatMap(UUID.init(uuidString:)),
            originDeviceName: textColumn(statement, 16), originDeviceConflict: sqlite3_column_int(statement, 17) != 0,
            pinboardOrderIdentity: try decodePinboardOrderIdentity(statement, at: 19)
        )
        return ownedFilesSchemaReady ? try rebasingOwnedFileURLsWithoutLock(record) : record
    }

    func decodeMetadata(_ statement: OpaquePointer) throws -> ClipboardRecordMetadata {
        try requireHistoryOrderColumn(statement, at: 18)
        _ = try decodePinboardOrderIdentity(statement, at: 19)
        guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)),
              let text = textColumn(statement, 1),
              let rawKind = textColumn(statement, 13), let kind = ClipboardContentKind(rawValue: rawKind) else {
            throw HistoryStoreError.invalidStoredRecord
        }
        let parts = try dataColumn(statement, 7).map { try JSONDecoder().decode([[StoredRepresentation]].self, from: $0) } ?? []
        return ClipboardRecordMetadata(
            id: id, text: text, sourceApp: textColumn(statement, 2), sourceBundleID: textColumn(statement, 3),
            copiedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
            renamedTitle: textColumn(statement, 8), ocrText: textColumn(statement, 9),
            pinboardID: textColumn(statement, 10).flatMap(UUID.init(uuidString:)),
            pinboardOrder: sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 14),
            isInHistory: sqlite3_column_int(statement, 11) != 0, revision: Int(sqlite3_column_int64(statement, 12)),
            kind: kind, representationTypes: parts.map { $0.map(\.typeIdentifier) },
            originDeviceID: textColumn(statement, 15).flatMap(UUID.init(uuidString:)),
            originDeviceName: textColumn(statement, 16), originDeviceConflict: sqlite3_column_int(statement, 17) != 0
        )
    }

    func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    func dataColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: length)
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else { try check(sqlite3_bind_null(statement, index)); return }
        guard value.utf8.count <= Int(Int32.max) else { throw HistoryStoreError.valueTooLarge }
        try value.withCString { pointer in
            try check(sqlite3_bind_text(statement, index, pointer, Int32(value.utf8.count), Self.transient))
        }
    }

    func bind(_ value: Data?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else { try check(sqlite3_bind_null(statement, index)); return }
        guard value.count <= Int(Int32.max) else { throw HistoryStoreError.valueTooLarge }
        if value.isEmpty { try check(sqlite3_bind_zeroblob(statement, index, 0)); return }
        try value.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient))
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        guard let statement else { throw HistoryStoreError.invalidStoredRecord }
        return statement
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    func stepToCompletion(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { try check(status); return }
    }

    func check(_ status: Int32, allowingRow: Bool = false) throws {
        guard status == SQLITE_OK || (allowingRow && status == SQLITE_ROW) else {
            let error = HistoryStoreError.database(code: status, message: String(cString: sqlite3_errmsg(database)))
            throw StorageWriteFailure.classify(error) ?? error
        }
    }

    func transaction<T>(allowReclamation: Bool = false, _ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        var committed = false
        newOwnedFileDirectories = []
        newRepresentationFiles = []
        let budget = HistoryWriteBudget(coordinator: spaceCoordinator, allowReclamation: allowReclamation)
        writeBudget = budget
        defer {
            if !committed {
                // Retain the writer lock during cleanup, including failures in outbox flush/COMMIT.
                for id in newOwnedFileDirectories ?? [] { ownedFileStorage.removeNew(id) }
                for file in newRepresentationFiles ?? [] { file.removeIfUnchanged() }
                try? execute("ROLLBACK")
            }
            newOwnedFileDirectories = nil
            newRepresentationFiles = nil
            representationWriteSession = nil
            writeBudget = nil
            budget.release()
        }
        do {
            let previousQuota = contentQuotaSchemaReady ? try contentQuotaStatusWithoutLock() : nil
            let result = try operation()
            if syncSchemaReady { try flushSyncDirty() }
            try finishContentQuota(previous: previousQuota, allowReclamation: allowReclamation)
            try budget.validateDestinations()
            try execute("COMMIT")
            committed = true
            return result
        } catch {
            throw StorageWriteFailure.classify(error) ?? error
        }
    }

    func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    /// Waiting readers may retire without waiting for a different operation to release the
    /// connection. Cancellation never reaches into that operation or its SQLite transaction.
    func synchronizedRead<T>(cancellation: HistoryReadCancellation?, _ operation: () throws -> T) throws -> T {
        guard let cancellation else { return try synchronized(operation) }
        try cancellation.checkCancellation()
        while !lock.lock(before: Date().addingTimeInterval(0.025)) {
            try cancellation.checkCancellation()
        }
        defer { lock.unlock() }
        try cancellation.checkCancellation()
        return try operation()
    }
}
