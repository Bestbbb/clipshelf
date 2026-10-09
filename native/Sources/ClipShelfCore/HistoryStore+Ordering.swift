import CSQLite
import Foundation

extension HistoryStore {
    static let minimumPinboardRank = Int64.min / 4
    static let maximumPinboardRank = Int64.max / 4
    static let pinboardRankSpacing: Int64 = 1_048_576
    static let pinboardOrderingSQL = "pinboard_order IS NULL ASC, pinboard_order ASC, CASE WHEN pinboard_order IS NULL THEN rowid END DESC, id ASC"

    struct OrderedItem {
        let id: UUID
        let boardID: UUID?
        let rank: Int64?
        let revision: Int
        let inHistory: Bool
    }

    /// Moves only the supplied IDs. Unloaded items remain in the board and retain relative order.
    /// `before: nil` means the end of the complete board, not the end of a loaded page.
    /// Pass revisions captured when dragging began for the moved items and anchor.
    public func move(recordIDs: [UUID], to pinboardID: UUID?, before beforeID: UUID? = nil,
                     expectedRevisions: [UUID: Int] = [:]) throws {
        try synchronized {
            try transaction {
                try moveWithoutLock(recordIDs: recordIDs, to: pinboardID, before: beforeID, expectedRevisions: expectedRevisions)
            }
        }
    }

    func moveWithoutLock(recordIDs: [UUID], to pinboardID: UUID?, before beforeID: UUID? = nil,
                         expectedRevisions: [UUID: Int] = [:]) throws {
        guard !recordIDs.isEmpty, Set(recordIDs).count == recordIDs.count,
              beforeID.map({ !recordIDs.contains($0) }) ?? true,
              pinboardID != nil || beforeID == nil else { throw HistoryStoreError.invalidPinboardItemOrder }
        try checkOrderingRevisions(expectedRevisions)
        let moving = try recordIDs.map { try orderingItem(id: $0) }
        for board in Set(moving.compactMap(\.boardID)) { try requireEditableOrderingBoard(board) }
        guard let boardID = pinboardID else {
            for item in moving where item.boardID != nil || item.rank != nil || !item.inHistory {
                try writePlacement(id: item.id, boardID: nil, rank: nil)
            }
            return
        }
        try requireEditableOrderingBoard(boardID)
        let all = try orderedItems(boardID: boardID)
        let movingIDs = Set(recordIDs)
        let remaining = all.filter { !movingIDs.contains($0.id) }
        let insertion: Int
        if let beforeID {
            guard let index = remaining.firstIndex(where: { $0.id == beforeID }) else { throw HistoryStoreError.invalidPinboardItemOrder }
            insertion = index
        } else { insertion = remaining.count }
        var desired = remaining
        desired.insert(contentsOf: moving, at: insertion)
        if desired.map(\.id) == all.map(\.id), all.allSatisfy({ $0.rank != nil }) { return }
        let left = insertion > 0 ? remaining[insertion - 1].rank : nil
        let right = insertion < remaining.count ? remaining[insertion].rank : nil
        if remaining.allSatisfy({ $0.rank != nil }),
           let ranks = Self.ranksBetween(left: left, right: right, count: moving.count) {
            for (item, rank) in zip(moving, ranks) where item.boardID != boardID || item.rank != rank {
                try writePlacement(id: item.id, boardID: boardID, rank: rank)
            }
        } else {
            // Rank gaps can be exhausted after repeated insertions; rebalance in this same transaction.
            try writeBalancedOrder(desired, boardID: boardID)
        }
    }

    /// This API requires the complete current set. Paginated UIs must use `move(recordIDs:to:before:)`.
    public func reorderPinboardItems(boardID: UUID, orderedIDs: [UUID], expectedRevisions: [UUID: Int] = [:]) throws {
        try synchronized {
            try transaction {
                try requireEditableOrderingBoard(boardID)
                try checkOrderingRevisions(expectedRevisions)
                let current = try orderedItems(boardID: boardID)
                guard orderedIDs.count == current.count, Set(orderedIDs) == Set(current.map(\.id)) else {
                    throw HistoryStoreError.invalidPinboardItemOrder
                }
                if orderedIDs == current.map(\.id), current.allSatisfy({ $0.rank != nil }) { return }
                let values = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
                try writeBalancedOrder(orderedIDs.compactMap { values[$0] }, boardID: boardID)
            }
        }
    }

    func assigningNewPinboardOrder(_ record: ClipboardRecord) throws -> ClipboardRecord {
        var result = record
        guard let boardID = record.pinboardID else { result.pinboardOrder = nil; return result }
        try requireEditableOrderingBoard(boardID)
        guard result.pinboardOrder == nil else { return result }
        try normalizePinboardOrdering(boardID: boardID)
        var items = try orderedItems(boardID: boardID)
        var ranks = Self.ranksBetween(left: items.last?.rank, right: nil, count: 1)
        if ranks == nil {
            try writeBalancedOrder(items, boardID: boardID)
            items = try orderedItems(boardID: boardID)
            ranks = Self.ranksBetween(left: items.last?.rank, right: nil, count: 1)
        }
        guard let rank = ranks?.first else { throw HistoryStoreError.invalidPinboardItemOrder }
        result.pinboardOrder = rank
        return result
    }

    func normalizePinboardOrdering(boardID: UUID, incrementRevision: Bool = true) throws {
        let items = try orderedItems(boardID: boardID)
        if items.contains(where: { $0.rank == nil }) {
            try writeBalancedOrder(items, boardID: boardID, incrementRevision: incrementRevision)
        }
    }

    /// Migration does not upload or rewrite immutable pending operations. The next authorized local
    /// board mutation publishes a new complete order baseline, including ranks of untouched items.
    func publishOrderingBaselinesForDirtyBoards() throws {
        let statement = try prepare("""
            SELECT board_id FROM pinboard_order_backfill WHERE board_id IN (
                SELECT pinboard_id FROM clipboard_records JOIN sync_dirty ON sync_dirty.entity_id = clipboard_records.id
                WHERE sync_dirty.entity_kind = 'clipboard' AND pinboard_id IS NOT NULL
                UNION SELECT entity_id FROM sync_dirty WHERE entity_kind = 'pinboard'
            )
            """)
        var boards: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            do { try check(status, allowingRow: true) } catch { sqlite3_finalize(statement); throw error }
            if let id = textColumn(statement, 0) { boards.append(id) }
        }
        sqlite3_finalize(statement)
        for board in boards {
            try syncExecute("""
                INSERT OR IGNORE INTO sync_order_dirty(entity_id)
                SELECT id FROM clipboard_records WHERE pinboard_id = ? AND NOT EXISTS
                    (SELECT 1 FROM sync_dirty WHERE entity_kind = 'clipboard' AND entity_id = clipboard_records.id)
                """, [board])
            try syncExecute("""
                INSERT INTO sync_dirty(entity_kind, entity_id, action)
                SELECT 'clipboard', id, 'upsert' FROM clipboard_records WHERE pinboard_id = ?
                ON CONFLICT(entity_kind, entity_id) DO NOTHING
                """, [board])
            try syncExecute("DELETE FROM pinboard_order_backfill WHERE board_id = ?", [board])
        }
    }

    func requireEditableOrderingBoard(_ boardID: UUID) throws {
        guard try pinboardsWithoutLock().contains(where: { $0.id == boardID }) else { throw HistoryStoreError.pinboardNotFound }
        if let namespace = try syncNamespace(kind: .pinboard, id: boardID), let state = try sharedStateForNamespace(namespace) {
            guard try sharingConfigurationWithoutLock().accountID == state.descriptor.accountID else { throw SharedBoardError.accountChanged }
            guard state.access.canWrite else { throw state.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
        }
    }

    func orderedItems(boardID: UUID) throws -> [OrderedItem] {
        let statement = try prepare("SELECT id, pinboard_id, pinboard_order, revision, is_in_history FROM clipboard_records WHERE pinboard_id = ? ORDER BY \(Self.pinboardOrderingSQL)")
        defer { sqlite3_finalize(statement) }
        try bind(boardID.uuidString, at: 1, to: statement)
        var items: [OrderedItem] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return items }
            try check(status, allowingRow: true)
            items.append(try decodeOrderingItem(statement))
        }
    }

    func orderingItem(id: UUID) throws -> OrderedItem {
        let statement = try prepare("SELECT id, pinboard_id, pinboard_order, revision, is_in_history FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        guard status != SQLITE_DONE else { throw HistoryStoreError.recordNotFound }
        try check(status, allowingRow: true)
        return try decodeOrderingItem(statement)
    }

    func decodeOrderingItem(_ statement: OpaquePointer) throws -> OrderedItem {
        guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.invalidStoredRecord }
        return OrderedItem(id: id, boardID: textColumn(statement, 1).flatMap(UUID.init(uuidString:)),
                           rank: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2),
                           revision: Int(sqlite3_column_int64(statement, 3)), inHistory: sqlite3_column_int(statement, 4) != 0)
    }

    func checkOrderingRevisions(_ expected: [UUID: Int]) throws {
        for (id, revision) in expected {
            guard try orderingItem(id: id).revision == revision else { throw HistoryStoreError.staleRevision }
        }
    }

    func writeBalancedOrder(_ items: [OrderedItem], boardID: UUID, incrementRevision: Bool = true) throws {
        guard items.count < Int(Self.maximumPinboardRank / Self.pinboardRankSpacing) else { throw HistoryStoreError.valueTooLarge }
        for (index, item) in items.enumerated() {
            let rank = Int64(index) * Self.pinboardRankSpacing
            if item.boardID != boardID || item.rank != rank {
                try writePlacement(id: item.id, boardID: boardID, rank: rank, incrementRevision: incrementRevision)
            }
        }
    }

    func writePlacement(id: UUID, boardID: UUID?, rank: Int64?, incrementRevision: Bool = true) throws {
        if syncSchemaReady, !suppressSyncCapture {
            let current = try orderingItem(id: id)
            if current.boardID == boardID, boardID != nil {
                // Preserve a prior content mutation in this transaction as a full update.
                try syncExecute("""
                    INSERT OR IGNORE INTO sync_order_dirty(entity_id)
                    SELECT ? WHERE NOT EXISTS (SELECT 1 FROM sync_dirty WHERE entity_kind = 'clipboard' AND entity_id = ?)
                    """, [id.uuidString, id.uuidString])
            } else { try syncExecute("DELETE FROM sync_order_dirty WHERE entity_id = ?", [id.uuidString]) }
        }
        let statement = try prepare("UPDATE clipboard_records SET pinboard_id = ?, pinboard_order = ?, revision = revision + ?, is_in_history = CASE WHEN ? IS NULL THEN 1 ELSE is_in_history END WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(boardID?.uuidString, at: 1, to: statement)
        if let rank { try check(sqlite3_bind_int64(statement, 2, rank)) } else { try check(sqlite3_bind_null(statement, 2)) }
        try check(sqlite3_bind_int(statement, 3, incrementRevision ? 1 : 0))
        try bind(boardID?.uuidString, at: 4, to: statement)
        try bind(id.uuidString, at: 5, to: statement)
        try stepToCompletion(statement)
    }

    static func ranksBetween(left: Int64?, right: Int64?, count: Int) -> [Int64]? {
        guard count > 0, count < Int(maximumPinboardRank / pinboardRankSpacing) else { return nil }
        let number = Int64(count)
        if right == nil {
            let start = left ?? -pinboardRankSpacing
            if start <= maximumPinboardRank - pinboardRankSpacing * number {
                return (1...count).map { start + Int64($0) * pinboardRankSpacing }
            }
        }
        if left == nil, let right, right >= minimumPinboardRank + pinboardRankSpacing * number {
            return (0..<count).map { right - Int64(count - $0) * pinboardRankSpacing }
        }
        let lower = left ?? minimumPinboardRank, upper = right ?? maximumPinboardRank
        guard upper > lower else { return nil }
        let gap = (upper - lower) / (number + 1)
        guard gap > 0 else { return nil }
        return (1...count).map { lower + Int64($0) * gap }
    }
}
