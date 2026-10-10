import Foundation
import UniformTypeIdentifiers

extension HistoryStore {
    /// Metadata, access, aggregate size, original bytes and account generations share one read snapshot.
    public func prepareEdit(_ reference: ClipboardSelectionReference) throws -> ClipboardEditSnapshot {
        try synchronized {
            try ownedRetentionTransaction {
                let items = try selectionItems([reference])
                let sync = try syncConfigurationWithoutLock(), sharing = try sharingConfigurationWithoutLock()
                try requireEditSnapshotAccess(items, sync: sync, sharing: sharing)
                try preflightSelectionPayload([reference], maximumBytes: 512 * 1_024 * 1_024)
                guard let original = try itemWithoutLock(id: reference.id) else { throw HistoryStoreError.recordNotFound }
                return ClipboardEditSnapshot(record: original, syncConfiguration: sync,
                                             sharingConfiguration: sharing, storeIdentity: selectionStoreIdentity,
                                             ownedAssetLease: try retainOwnedAssetsWithoutLock(capturedOwnedIDsWithoutLock([original]), purpose: .edit))
            }
        }
    }

    /// A text-object edit cannot change any other part, including the image from which existing
    /// OCR was derived. Reuse the complete snapshot commit and its account/access/quota checks.
    public func commitPartEdit(_ edit: ClipboardPartEdit, snapshot: ClipboardEditSnapshot) throws -> HistorySelectionEditUndo {
        let edited = try edit.applying(to: snapshot.record)
        let preservedOCR: ClipboardImageOCR?
        if let text = snapshot.record.ocrText,
           let image = snapshot.record.parts.lazy.flatMap(\.representations).first(where: {
               UTType($0.typeIdentifier)?.conforms(to: .image) == true
           }) {
            preservedOCR = ClipboardImageOCR(text: text, sourceImageDigest: RepresentationStorage.digest(image.data))
        } else { preservedOCR = nil }
        return try commitEdit(edited, snapshot: snapshot, recomputedOCR: preservedOCR)
    }

    /// No stale editor can save under another store, revision, or account-configuration generation.
    /// The original and its Undo capability are captured in the same atomic write as the edit.
    public func commitEdit(_ edited: ClipboardRecord, snapshot: ClipboardEditSnapshot,
                           recomputedOCR: ClipboardImageOCR? = nil) throws -> HistorySelectionEditUndo {
        try synchronized {
            try transaction {
                guard snapshot.storeIdentity == selectionStoreIdentity, edited.id == snapshot.record.id else {
                    throw HistoryStoreError.invalidSelection
                }
                guard edited.revision == snapshot.record.revision else { throw HistoryStoreError.staleRevision }
                try requireIntegrationConfigurations(sync: snapshot.syncConfiguration, sharing: snapshot.sharingConfiguration)
                let items = try selectionItems([.init(id: snapshot.record.id, revision: snapshot.record.revision)])
                try requireEditSnapshotAccess(items, sync: snapshot.syncConfiguration, sharing: snapshot.sharingConfiguration)
                try preflightSelectionPayload([.init(id: snapshot.record.id, revision: snapshot.record.revision)],
                                              maximumBytes: 512 * 1_024 * 1_024)
                // Restore/import can replace bytes while retaining an ID and revision.
                guard let current = try itemWithoutLock(id: snapshot.record.id), current == snapshot.record else {
                    throw HistoryStoreError.staleRevision
                }
                try validate(edited)
                if let recomputedOCR {
                    guard edited.ocrText == recomputedOCR.text,
                          let image = edited.parts.lazy.flatMap(\.representations).first(where: {
                              UTType($0.typeIdentifier)?.conforms(to: .image) == true
                          }), RepresentationStorage.digest(image.data) == recomputedOCR.sourceImageDigest else {
                        throw HistoryStoreError.invalidStoredRecord
                    }
                }
                return try editSelectionRecordWithoutLock(edited, validatedCurrent: current, preserveOCR: recomputedOCR != nil)
            }
        }
    }

    private func requireEditSnapshotAccess(_ items: [OrderedItem], sync: SyncConfiguration,
                                           sharing: SyncConfiguration) throws {
        try requireEditableSelection(items)
        for item in items {
            let namespaces = try [syncNamespace(kind: .clipboard, id: item.id),
                                  item.boardID.flatMap { try syncNamespace(kind: .pinboard, id: $0) }].compactMap { $0 }
            for namespace in Set(namespaces) {
                if let state = try sharedStateForNamespace(namespace) {
                    guard state.descriptor.accountID == sharing.accountID else { throw SharedBoardError.accountChanged }
                    guard state.access.canWrite else { throw state.access == .revoked ? SharedBoardError.revoked : SharedBoardError.readOnly }
                } else {
                    guard !namespace.hasPrefix("shared:"), namespace == sync.accountID else { throw SyncError.namespaceConflict }
                }
            }
        }
    }
}
