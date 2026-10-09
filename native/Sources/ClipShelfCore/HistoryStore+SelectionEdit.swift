import Foundation

extension HistoryStore {
    /// Reads the original, checks its exact revision, and saves the edit in one transaction.
    /// The undo original follows the same 512 MiB raw-content budget as selection payloads.
    public func editSelectionRecord(_ record: ClipboardRecord) throws -> HistorySelectionEditUndo {
        try validate(record)
        return try synchronized {
            try transaction {
                let reference = ClipboardSelectionReference(id: record.id, revision: record.revision)
                let items = try selectionItems([reference])
                try requireEditableSelection(items)
                try preflightSelectionPayload([reference], maximumBytes: 512 * 1_024 * 1_024)
                guard let original = try itemWithoutLock(id: record.id) else { throw HistoryStoreError.recordNotFound }
                let sync = try syncConfigurationWithoutLock(), sharing = try sharingConfigurationWithoutLock()
                let bindings = try ownedFileBindingsWithoutLock(recordID: record.id)
                let updated = try updateWithoutLock(record: record, current: original)
                return HistorySelectionEditUndo(original: original,
                                                expected: ClipboardSelectionReference(id: updated.id, revision: updated.revision),
                                                storeIdentity: selectionStoreIdentity,
                                                syncConfiguration: sync, sharingConfiguration: sharing, ownedFileBindings: bindings)
            }
        }
    }

    @discardableResult
    public func undoSelectionEdit(_ undo: HistorySelectionEditUndo) throws -> HistorySelectionUndoReceipt {
        guard undo.storeIdentity == selectionStoreIdentity else { throw HistoryStoreError.invalidSelection }
        return try synchronized {
            try transaction {
                try requireIntegrationConfigurations(sync: undo.syncConfiguration, sharing: undo.sharingConfiguration)
                let items = try selectionItems([undo.expected])
                try requireEditableSelection(items)
                guard let current = try itemWithoutLock(id: undo.expected.id) else { throw HistoryStoreError.recordNotFound }
                var original = undo.original
                original.revision = undo.expected.revision
                let restored = try updateWithoutLock(record: original, current: current)
                try setOwnedFileBindingsWithoutLock(undo.ownedFileBindings, record: restored)
                let reference = ClipboardSelectionReference(id: restored.id, revision: restored.revision)
                return HistorySelectionUndoReceipt(references: [reference], storeIdentity: selectionStoreIdentity,
                                                   before: [ClipboardSelectionReference(id: undo.original.id, revision: undo.original.revision)],
                                                   after: [reference])
            }
        }
    }

    public func rebaseSelectionEditUndo(_ undo: HistorySelectionEditUndo,
                                        after receipt: HistorySelectionUndoReceipt) throws -> HistorySelectionEditUndo {
        guard undo.storeIdentity == selectionStoreIdentity, receipt.storeIdentity == selectionStoreIdentity else {
            throw HistoryStoreError.invalidSelection
        }
        let index = receipt.before.firstIndex(of: undo.expected)
        return HistorySelectionEditUndo(original: undo.original,
                                        expected: index.map { receipt.after[$0] } ?? undo.expected,
                                        storeIdentity: undo.storeIdentity,
                                        syncConfiguration: undo.syncConfiguration, sharingConfiguration: undo.sharingConfiguration,
                                        ownedFileBindings: undo.ownedFileBindings)
    }
}
