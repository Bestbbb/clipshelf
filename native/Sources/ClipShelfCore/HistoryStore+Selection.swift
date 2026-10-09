import CSQLite
import Foundation

extension HistoryStore {
    /// Captures the whole filtered, ordered result in one read snapshot. Pagination limits are ignored.
    public func selectionSnapshot(_ query: HistoryQuery, scope: HistorySelectionScope = .all) throws -> HistorySelectionSnapshot {
        try synchronized {
            try selectionReadTransaction {
                let statement = try prepareSearch(query, metadataOnly: true, offset: 0, selectionOnly: true)
                defer { sqlite3_finalize(statement) }
                var references: [ClipboardSelectionReference] = []
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    try check(status, allowingRow: true)
                    guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.invalidStoredRecord }
                    references.append(ClipboardSelectionReference(id: id, revision: Int(sqlite3_column_int64(statement, 1))))
                }
                switch scope {
                case .all: return HistorySelectionSnapshot(references: references)
                case .between(let first, let last):
                    guard let from = references.firstIndex(where: { $0.id == first.id }),
                          let through = references.firstIndex(where: { $0.id == last.id }) else { throw HistoryStoreError.recordNotFound }
                    guard references[from] == first, references[through] == last else { throw HistoryStoreError.staleRevision }
                    return HistorySelectionSnapshot(references: Array(references[min(from, through)...max(from, through)]))
                }
            }
        }
    }

    public func validateSelection(_ references: [ClipboardSelectionReference]) throws {
        try synchronized { try selectionReadTransaction { _ = try selectionItems(references) } }
    }

    /// A single snapshot validates every version and the entire byte budget before loading attachments.
    /// Returned records retain the caller's frozen order; failures never produce a partial result.
    public func resolveSelection(_ references: [ClipboardSelectionReference],
                                 maximumPayloadBytes: Int = 512 * 1_024 * 1_024) throws -> [ClipboardRecord] {
        guard maximumPayloadBytes >= 0 else { throw HistoryStoreError.invalidSelection }
        return try synchronized {
            try selectionReadTransaction {
                _ = try selectionItems(references)
                try preflightSelectionPayload(references, maximumBytes: maximumPayloadBytes)
                let statement = try prepare("SELECT \(Self.columns) FROM clipboard_records WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                var records: [ClipboardRecord] = []
                records.reserveCapacity(references.count)
                for reference in references {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try bind(reference.id.uuidString, at: 1, to: statement)
                    let status = sqlite3_step(statement)
                    guard status != SQLITE_DONE else { throw HistoryStoreError.recordNotFound }
                    try check(status, allowingRow: true)
                    records.append(try decode(statement))
                }
                return records
            }
        }
    }

    /// Validates the entire selection and all shared-board permissions before the first deletion.
    @discardableResult
    public func deleteSelection(_ references: [ClipboardSelectionReference]) throws -> HistorySelectionDeleteUndo {
        try synchronized {
            try transaction {
                let items = try selectionItems(references)
                try requireEditableSelection(items)
                let undo = HistorySelectionDeleteUndo(storeIdentity: selectionStoreIdentity, references: references,
                                                      syncConfiguration: try syncConfigurationWithoutLock(),
                                                      sharingConfiguration: try sharingConfigurationWithoutLock(),
                                                      consumption: HistorySelectionUndoConsumption())
                let statement = try prepare("DELETE FROM clipboard_records WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                for item in items {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try bind(item.id.uuidString, at: 1, to: statement)
                    try stepToCompletion(statement)
                }
                return undo
            }
        }
    }

    @discardableResult
    public func moveSelection(_ references: [ClipboardSelectionReference], to boardID: UUID?,
                              before: ClipboardSelectionReference? = nil) throws -> HistorySelectionMoveUndo {
        try synchronized {
            try transaction { try moveSelectionWithoutLock(references, to: boardID, before: before) }
        }
    }

    /// Moves the selected block past its nearest unselected neighbour in the complete board.
    /// Selection order follows the board, even when references were supplied in another order.
    @discardableResult
    public func stepSelection(_ references: [ClipboardSelectionReference], boardID: UUID,
                              forward: Bool) throws -> HistorySelectionMoveUndo {
        try synchronized {
            try transaction {
                let selected = try selectionItems(references)
                guard !selected.isEmpty, selected.allSatisfy({ $0.boardID == boardID }) else { throw HistoryStoreError.invalidSelection }
                try requireEditableOrderingBoard(boardID)
                let all = try orderedItems(boardID: boardID)
                let selectedIDs = Set(references.map(\.id))
                let indices = all.indices.filter { selectedIDs.contains(all[$0].id) }
                guard let first = indices.first, let last = indices.last else { throw HistoryStoreError.recordNotFound }
                let moving = all.filter { selectedIDs.contains($0.id) }.map(\.selectionReference)
                let anchor: ClipboardSelectionReference?
                if forward {
                    guard let neighbour = all.indices.dropFirst(last + 1).first(where: { !selectedIDs.contains(all[$0].id) }) else {
                        return try unchangedSelectionUndo(references)
                    }
                    anchor = all.dropFirst(neighbour + 1).first(where: { !selectedIDs.contains($0.id) })?.selectionReference
                } else {
                    guard let neighbour = all.indices.prefix(first).last(where: { !selectedIDs.contains(all[$0].id) }) else {
                        return try unchangedSelectionUndo(references)
                    }
                    anchor = all[neighbour].selectionReference
                }
                let undo = try moveSelectionWithoutLock(moving, to: boardID, before: anchor)
                // Preserve the caller's selection order in the public post-action version list.
                return HistorySelectionMoveUndo(references: try selectionItemsByID(references.map(\.id)).map(\.selectionReference),
                                                storeIdentity: undo.storeIdentity, placements: undo.placements, expected: undo.expected,
                                                before: undo.before, boardPlacements: undo.boardPlacements,
                                                syncConfiguration: undo.syncConfiguration, sharingConfiguration: undo.sharingConfiguration)
            }
        }
    }

    @discardableResult
    public func undoSelectionMove(_ undo: HistorySelectionMoveUndo) throws -> HistorySelectionUndoReceipt {
        guard undo.storeIdentity == selectionStoreIdentity else { throw HistoryStoreError.invalidSelection }
        return try synchronized {
            try transaction {
                try requireIntegrationConfigurations(sync: undo.syncConfiguration, sharing: undo.sharingConfiguration)
                let current = try selectionItems(undo.expected)
                try requireEditableSelection(current)
                for boardID in Set(undo.placements.compactMap(\.boardID)) { try requireEditableOrderingBoard(boardID) }
                for (boardID, expected) in undo.boardPlacements {
                    try requireEditableOrderingBoard(boardID)
                    guard try orderedItems(boardID: boardID).map(\.selectionPlacement) == expected else { throw HistoryStoreError.staleRevision }
                }
                for placement in undo.placements {
                    try writePlacement(id: placement.id, boardID: placement.boardID, rank: placement.rank)
                    let statement = try prepare("UPDATE clipboard_records SET is_in_history = ? WHERE id = ?")
                    defer { sqlite3_finalize(statement) }
                    try check(sqlite3_bind_int(statement, 1, placement.isInHistory ? 1 : 0))
                    try bind(placement.id.uuidString, at: 2, to: statement)
                    try stepToCompletion(statement)
                }
                return HistorySelectionUndoReceipt(references: try selectionItemsByID(undo.references.map(\.id)).map(\.selectionReference),
                                                   storeIdentity: selectionStoreIdentity, before: undo.before,
                                                   after: try selectionItemsByID(undo.before.map(\.id)).map(\.selectionReference))
            }
        }
    }

    /// Rebase only exact trusted revision transitions. Placement baselines are intentionally retained:
    /// unrelated board insertions or sorting must still invalidate an older undo.
    public func rebaseSelectionMoveUndo(_ older: HistorySelectionMoveUndo,
                                        after receipt: HistorySelectionUndoReceipt) throws -> HistorySelectionMoveUndo {
        guard older.storeIdentity == selectionStoreIdentity, receipt.storeIdentity == selectionStoreIdentity else {
            throw HistoryStoreError.invalidSelection
        }
        let transitions = Dictionary(uniqueKeysWithValues: zip(receipt.before, receipt.after).map { ($0, $1) })
        func rebased(_ references: [ClipboardSelectionReference]) -> [ClipboardSelectionReference] {
            references.map { transitions[$0] ?? $0 }
        }
        return HistorySelectionMoveUndo(references: rebased(older.references), storeIdentity: older.storeIdentity,
                                        placements: older.placements, expected: rebased(older.expected), before: older.before,
                                        boardPlacements: older.boardPlacements,
                                        syncConfiguration: older.syncConfiguration, sharingConfiguration: older.sharingConfiguration)
    }

    /// Restores a deleted batch without replacing any live ID or silently dropping a missing board.
    /// Cloud tombstones remain authoritative: a synced deletion cannot be undone under the same ID.
    @discardableResult
    public func restoreDeletedSelection(_ originals: [ClipboardRecord], undo: HistorySelectionDeleteUndo) throws -> HistorySelectionUndoReceipt {
        guard undo.storeIdentity == selectionStoreIdentity,
              originals.map({ ClipboardSelectionReference(id: $0.id, revision: $0.revision) }) == undo.references else {
            throw HistoryStoreError.invalidSelection
        }
        for record in originals { try validate(record) }
        return try synchronized {
            guard !undo.consumption.consumed else { throw HistoryStoreError.invalidSelection }
            let receipt = try transaction {
                try requireIntegrationConfigurations(sync: undo.syncConfiguration, sharing: undo.sharingConfiguration)
                for record in originals {
                    guard try syncScalar("SELECT id FROM clipboard_records WHERE id = ?", [record.id.uuidString]) == nil else {
                        throw HistoryStoreError.staleRevision
                    }
                    guard record.isInHistory || record.pinboardID != nil else { throw HistoryStoreError.invalidStoredRecord }
                }
                for boardID in Set(originals.compactMap(\.pinboardID)) { try requireEditableOrderingBoard(boardID) }
                var restored: [ClipboardSelectionReference] = []
                // In a history selection originals are newest-first. Reinsert in reverse so the
                // restored batch retains that relative history order; explicit pinboard ranks remain intact.
                for original in originals.reversed() {
                    var record = original; record.revision += 1
                    try insert(record)
                }
                for original in originals { restored.append(ClipboardSelectionReference(id: original.id, revision: original.revision + 1)) }
                return HistorySelectionUndoReceipt(references: restored, storeIdentity: selectionStoreIdentity,
                                                   before: undo.references, after: restored)
            }
            undo.consumption.consumed = true
            return receipt
        }
    }

    func moveSelectionWithoutLock(_ references: [ClipboardSelectionReference], to boardID: UUID?,
                                  before: ClipboardSelectionReference?) throws -> HistorySelectionMoveUndo {
        let selected = try selectionItems(references)
        guard !selected.isEmpty else { throw HistoryStoreError.invalidSelection }
        if let before { _ = try selectionItems([before]) }
        var capturedItems = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        if let boardID {
            for item in try orderedItems(boardID: boardID) { capturedItems[item.id] = item }
        }
        let captured = capturedItems.mapValues(\.selectionPlacement)
        var revisions = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0.revision) })
        if let before { revisions[before.id] = before.revision }
        try moveWithoutLock(recordIDs: references.map(\.id), to: boardID, before: before?.id, expectedRevisions: revisions)
        let after = try selectionItemsByID(Array(captured.keys))
        let changed = after.filter { captured[$0.id] != $0.selectionPlacement }
        let selectedAfter = try selectionItemsByID(references.map(\.id)).map(\.selectionReference)
        let selectedIDs = Set(references.map(\.id))
        var boards = Set(selected.compactMap(\.boardID))
        if let boardID { boards.insert(boardID) }
        var boardPlacements: [UUID: [HistorySelectionPlacement]] = [:]
        for boardID in boards { boardPlacements[boardID] = try orderedItems(boardID: boardID).map(\.selectionPlacement) }
        return HistorySelectionMoveUndo(references: selectedAfter,
                                        storeIdentity: selectionStoreIdentity,
                                        placements: changed.compactMap { captured[$0.id] },
                                        expected: selectedAfter + changed.filter { !selectedIDs.contains($0.id) }.map(\.selectionReference),
                                        before: references + changed.filter { !selectedIDs.contains($0.id) }.compactMap { capturedItems[$0.id]?.selectionReference },
                                        boardPlacements: boardPlacements,
                                        syncConfiguration: try syncConfigurationWithoutLock(), sharingConfiguration: try sharingConfigurationWithoutLock())
    }

    func unchangedSelectionUndo(_ references: [ClipboardSelectionReference]) throws -> HistorySelectionMoveUndo {
        HistorySelectionMoveUndo(references: references, storeIdentity: selectionStoreIdentity, placements: [], expected: references,
                                 before: references, boardPlacements: [:], syncConfiguration: try syncConfigurationWithoutLock(),
                                 sharingConfiguration: try sharingConfigurationWithoutLock())
    }

    func requireEditableSelection(_ items: [OrderedItem]) throws {
        for boardID in Set(items.compactMap(\.boardID)) { try requireEditableOrderingBoard(boardID) }
        for item in items {
            if let namespace = try syncNamespace(kind: .clipboard, id: item.id), let state = try sharedStateForNamespace(namespace) {
                guard try sharingConfigurationWithoutLock().accountID == state.descriptor.accountID else { throw SharedBoardError.accountChanged }
                guard state.access.canWrite else { throw state.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
            }
        }
    }

    func selectionItems(_ references: [ClipboardSelectionReference]) throws -> [OrderedItem] {
        guard references.allSatisfy({ $0.revision > 0 && $0.revision < Int.max }),
              Set(references.map(\.id)).count == references.count else { throw HistoryStoreError.invalidSelection }
        let items = try selectionItemsByID(references.map(\.id))
        guard zip(items, references).allSatisfy({ $0.revision == $1.revision }) else { throw HistoryStoreError.staleRevision }
        return items
    }

    func selectionItemsByID(_ ids: [UUID]) throws -> [OrderedItem] {
        let statement = try prepare("SELECT id, pinboard_id, pinboard_order, revision, is_in_history FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        var items: [OrderedItem] = []; items.reserveCapacity(ids.count)
        for id in ids {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(id.uuidString, at: 1, to: statement)
            let status = sqlite3_step(statement)
            guard status != SQLITE_DONE else { throw HistoryStoreError.recordNotFound }
            try check(status, allowingRow: true)
            items.append(try decodeOrderingItem(statement))
        }
        return items
    }

    func preflightSelectionPayload(_ references: [ClipboardSelectionReference], maximumBytes: Int) throws {
        let statement = try prepare("SELECT length(CAST(text AS BLOB)), coalesce(length(rtf), 0), coalesce(length(html), 0), parts FROM clipboard_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        var total = 0
        func add(_ bytes: Int) throws {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard bytes >= 0, !overflow, sum <= maximumBytes else { throw HistoryStoreError.selectionPayloadTooLarge }
            total = sum
        }
        for reference in references {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(reference.id.uuidString, at: 1, to: statement)
            try check(sqlite3_step(statement), allowingRow: true)
            for column: Int32 in 0...2 { try add(Int(sqlite3_column_int64(statement, column))) }
            if let data = dataColumn(statement, 3) {
                let parts = try JSONDecoder().decode([[StoredRepresentation]].self, from: data)
                for part in parts {
                    for representation in part {
                        guard representation.byteCount >= 0,
                              representation.byteCount <= RepresentationStorage.maximumRepresentationBytes else { throw HistoryStoreError.corruptAttachment }
                        try add(representation.byteCount)
                    }
                }
            }
        }
    }

    func selectionReadTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let result = try operation()
        try execute("COMMIT"); committed = true
        return result
    }
}

private extension HistoryStore.OrderedItem {
    var selectionReference: ClipboardSelectionReference { ClipboardSelectionReference(id: id, revision: revision) }
    var selectionPlacement: HistorySelectionPlacement { HistorySelectionPlacement(id: id, boardID: boardID, rank: rank, isInHistory: inHistory) }
}
