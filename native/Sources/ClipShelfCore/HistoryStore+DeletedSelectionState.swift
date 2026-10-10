import Foundation

extension HistoryStore {
    /// The caller already bounded the complete selection's raw payload budget. Keep one decoded
    /// record at a time and retain hashes only, rather than adding another Undo payload copy.
    func captureDeletedRecordStatesWithoutLock(_ references: [ClipboardSelectionReference]) throws -> [UUID: HistorySelectionDeletedRecordState] {
        let account = try syncConfigurationWithoutLock().accountID
        var states: [UUID: HistorySelectionDeletedRecordState] = [:]
        for reference in references {
            guard let record = try itemWithoutLock(id: reference.id) else { throw HistoryStoreError.recordNotFound }
            let localOnly = try isSyncLocalOnly(kind: .clipboard, id: reference.id)
            let namespace = try syncNamespace(kind: .clipboard, id: reference.id)
            let deletionNamespace = namespace ?? (localOnly ? nil : account)
            let recovery = try syncScalar("SELECT record_id FROM owned_sync_local_recovery WHERE record_id = ?", [reference.id.uuidString]) != nil
            guard !recovery || localOnly else { throw SyncError.namespaceConflict }
            states[reference.id] = HistorySelectionDeletedRecordState(historyOrder: try historyOrderWithoutLock(id: reference.id),
                                                                     namespace: namespace, deletionNamespace: deletionNamespace, localOnly: localOnly,
                                                                     ownedLocalRecovery: recovery,
                                                                     contentFingerprint: ClipboardEditFingerprint.digest(record),
                                                                     fingerprintIdentity: record.id)
        }
        return states
    }

    func validateDeletedSelectionOriginals(_ originals: [ClipboardRecord], undo: HistorySelectionDeleteUndo) throws {
        guard undo.storeIdentity == selectionStoreIdentity,
              originals.map({ ClipboardSelectionReference(id: $0.id, revision: $0.revision) }) == undo.references else {
            throw HistoryStoreError.invalidSelection
        }
        for record in originals {
            try validate(record)
            guard let state = undo.records[record.id],
                  ClipboardEditFingerprint.digest(record, canonicalIdentity: state.fingerprintIdentity) == state.contentFingerprint else {
                throw HistoryStoreError.invalidSelection
            }
        }
    }

    func requireDeletedRecordNamespaceWithoutLock(id: UUID, state: HistorySelectionDeletedRecordState) throws {
        guard try syncNamespace(kind: .clipboard, id: id) == state.deletionNamespace,
              try isSyncLocalOnly(kind: .clipboard, id: id) == state.localOnly else { throw SyncError.namespaceConflict }
        if let namespace = state.deletionNamespace, let shared = try sharedStateForNamespace(namespace) {
            guard try sharingConfigurationWithoutLock().accountID == shared.descriptor.accountID else { throw SharedBoardError.accountChanged }
            guard shared.access.canWrite else { throw shared.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
        }
    }

    func restoreDeletedRecordNamespaceWithoutLock(record: ClipboardRecord, state: HistorySelectionDeletedRecordState) throws {
        // Enabling sync without including existing local data is not permission to upload it
        // through Undo. Its deletion may have emitted a payload-free tombstone; the restored copy
        // remains local until the user explicitly opts that data into their private account.
        if state.localOnly || (state.namespace == nil && state.deletionNamespace != nil) {
            try markSyncLocalOnly(kind: .clipboard, id: record.id)
        }
        else if let namespace = state.namespace { try setSyncNamespace(kind: .clipboard, id: record.id, accountID: namespace) }
        if state.ownedLocalRecovery {
            try syncExecute("INSERT INTO owned_sync_local_recovery(record_id) VALUES (?)", [record.id.uuidString])
        }
    }
}
