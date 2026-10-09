import Foundation

extension HistoryStore {
    /// Payload resolution for clipboard output only. Ordinary references retain their normal symlink
    /// semantics; registered projections must be safe regular files in the no-follow owned tree.
    /// Preview/repair/delete continue to use resolveSelection, which permits unavailable references.
    public func resolveSelectionForOutput(_ references: [ClipboardSelectionReference],
                                          maximumPayloadBytes: Int = 512 * 1_024 * 1_024,
                                          expectedSyncConfiguration: SyncConfiguration? = nil,
                                          expectedSharingConfiguration: SyncConfiguration? = nil) throws -> [ClipboardRecord] {
        guard maximumPayloadBytes >= 0 else { throw HistoryStoreError.invalidSelection }
        return try synchronized {
            try selectionReadTransaction {
                let sync = try syncConfigurationWithoutLock(), sharing = try sharingConfigurationWithoutLock()
                if let expectedSyncConfiguration, expectedSyncConfiguration != sync { throw SyncError.accountChanged }
                if let expectedSharingConfiguration, expectedSharingConfiguration != sharing { throw SyncError.accountChanged }
                let records = try resolveSelectionWithoutLock(references, maximumPayloadBytes: maximumPayloadBytes)
                for record in records {
                    _ = try requireFileRepairAccess(record, sync: sync, sharing: sharing, write: false)
                    for binding in try ownedFileBindingsWithoutLock(recordID: record.id) {
                        guard try ownedBindingMatches(binding, record: record),
                              ownedFileStorage.projectionAvailability(try ownedFileAssetWithoutLock(id: binding.assetID)) == .available else {
                            throw ClipboardFileRepairError.unavailableOutput
                        }
                    }
                }
                return records
            }
        }
    }

    /// Stack keeps each capture occurrence even after its history row is coalesced or deleted.
    /// Matching a URL here grants no ownership: it only applies the registered asset's stricter
    /// output checks to that immutable capture snapshot. Registry assets outlive history bindings.
    public func validateCapturedFileOutput(_ records: [ClipboardRecord]) throws {
        try synchronized {
            try selectionReadTransaction {
                for record in records {
                    for representation in record.parts.flatMap(\.representations)
                    where ClipboardFileAccess.isFileURLType(representation.typeIdentifier) {
                        guard let url = ClipboardFileAccess.url(from: representation.data) else { continue }
                        let files = url.deletingLastPathComponent()
                        guard files.lastPathComponent == "files",
                              let assetID = UUID(uuidString: files.deletingLastPathComponent().lastPathComponent),
                              let registered = try syncScalar("SELECT registered_url FROM owned_file_assets WHERE id = ?", [assetID.uuidString]),
                              let registeredURL = ClipboardFileAccess.url(from: Data(registered.utf8)) else { continue }
                        let asset = try ownedFileAssetWithoutLock(id: assetID), current = try ownedFileStorage.fileURL(asset)
                        guard url.path == registeredURL.path || url.path == current.path else { continue }
                        guard url.path == current.path, ownedFileStorage.projectionAvailability(asset) == .available else {
                            throw ClipboardFileRepairError.unavailableOutput
                        }
                    }
                }
            }
        }
    }

    public func fileRepairSnapshot(_ reference: ClipboardSelectionReference) throws -> ClipboardFileRepairSnapshot {
        try synchronized {
            try selectionReadTransaction {
                _ = try selectionItems([reference])
                try preflightSelectionPayload([reference], maximumBytes: 512 * 1_024 * 1_024)
                guard let record = try itemWithoutLock(id: reference.id) else { throw HistoryStoreError.recordNotFound }
                let sync = try syncConfigurationWithoutLock(), sharing = try sharingConfigurationWithoutLock()
                let readOnly = try requireFileRepairAccess(record, sync: sync, sharing: sharing, write: false)
                let bindings = try ownedFileBindingsWithoutLock(recordID: record.id)
                var files: [ClipboardFileReference] = []
                for (partIndex, part) in record.parts.enumerated() {
                    for (representationIndex, representation) in part.representations.enumerated()
                    where ClipboardFileAccess.isFileURLType(representation.typeIdentifier) {
                        let url = ClipboardFileAccess.url(from: representation.data)
                        let binding = bindings.first { $0.partIndex == partIndex && $0.representationIndex == representationIndex }
                        let status: ClipboardFileAvailability
                        if let binding {
                            guard try ownedBindingMatches(binding, record: record) else { throw HistoryStoreError.invalidOwnedFile }
                            status = ownedFileStorage.projectionAvailability(try ownedFileAssetWithoutLock(id: binding.assetID))
                        } else { status = url.map(ClipboardFileAccess.availability(of:)) ?? .invalidURL }
                        files.append(.init(partIndex: partIndex, representationIndex: representationIndex,
                                           rawURL: representation.data, url: url, status: status, isOwned: binding != nil))
                    }
                }
                return ClipboardFileRepairSnapshot(record: record, files: files, syncConfiguration: sync,
                                                    sharingConfiguration: sharing, isReadOnly: readOnly,
                                                    storeIdentity: selectionStoreIdentity)
            }
        }
    }

    /// Replaces this file object, not arbitrary representations belonging to other clipboard objects.
    /// The complete original remains in the strict edit Undo token; no user file is copied or removed.
    public func relocateExternalFile(_ snapshot: ClipboardFileRepairSnapshot, file: ClipboardFileReference,
                                     to newURL: URL) throws -> HistorySelectionEditUndo {
        guard let replacement = ClipboardFileAccess.url(from: Data(newURL.absoluteString.utf8)),
              ClipboardFileAccess.availability(of: replacement) == .available else {
            throw ClipboardFileRepairError.unavailableReplacement
        }
        return try synchronized {
            try transaction {
                var record = try validateFileRepairSnapshot(snapshot, file: file, write: true)
                let bindings = try ownedFileBindingsWithoutLock(recordID: record.id)
                guard !bindings.contains(where: { $0.partIndex == file.partIndex }) else {
                    throw ClipboardFileRepairError.ownedFileRequiresProjectionRestore
                }
                let part = record.parts[file.partIndex]
                let oldURL = ClipboardFileAccess.url(from: file.rawURL)
                let aliases = part.representations.filter { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }
                guard aliases.allSatisfy({ representation in
                    if let oldURL, let url = ClipboardFileAccess.url(from: representation.data) { return url.path == oldURL.path }
                    return representation.data == file.rawURL
                }) else { throw ClipboardFileRepairError.ambiguousFileReferences }
                guard oldURL?.path != replacement.path else { throw ClipboardFileRepairError.unchangedURL }
                let oldSummary = Self.fileNameSummary(record)
                // Any fallback, image preview or opaque source format in this part describes the old
                // file. Keep only consistent file URL aliases, with the canonical type always first.
                var types = ["public.file-url"]
                for alias in aliases where !types.contains(alias.typeIdentifier) { types.append(alias.typeIdentifier) }
                record.parts[file.partIndex].representations = types.map { .init(typeIdentifier: $0, data: Data(replacement.absoluteString.utf8)) }
                record.rtf = nil; record.html = nil
                if let oldSummary, record.text == oldSummary, let summary = Self.fileNameSummary(record) { record.text = summary }
                try validate(record)
                return try editSelectionRecordWithoutLock(record)
            }
        }
    }

    /// A local maintenance operation: no history, revision, binding or cloud outbox mutation.
    /// BEGIN IMMEDIATE holds off other database writers during validation and filesystem publication.
    /// Concurrent filesystem creators are handled by no-overwrite publication, never by replacement.
    public func restoreMissingOwnedProjection(_ snapshot: ClipboardFileRepairSnapshot,
                                              file: ClipboardFileReference) throws -> OwnedFileProjectionRepairResult {
        try synchronized {
            try execute("BEGIN IMMEDIATE")
            var publication: OwnedProjectionPublication?
            do {
                let record = try validateFileRepairSnapshot(snapshot, file: file, write: false)
                guard let binding = try ownedFileBindingsWithoutLock(recordID: record.id).first(where: {
                    $0.partIndex == file.partIndex && $0.representationIndex == file.representationIndex
                }), try ownedBindingMatches(binding, record: record) else { throw HistoryStoreError.invalidOwnedFile }
                publication = try ownedFileStorage.restoreMissingProjection(ownedFileAssetWithoutLock(id: binding.assetID))
                try execute("COMMIT")
                return publication!.result
            } catch {
                publication?.rollback()
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func validateFileRepairSnapshot(_ snapshot: ClipboardFileRepairSnapshot, file: ClipboardFileReference,
                                            write: Bool) throws -> ClipboardRecord {
        guard snapshot.storeIdentity == selectionStoreIdentity, snapshot.files.contains(file) else {
            throw ClipboardFileRepairError.invalidReference
        }
        try requireIntegrationConfigurations(sync: snapshot.syncConfiguration, sharing: snapshot.sharingConfiguration)
        _ = try selectionItems([.init(id: snapshot.record.id, revision: snapshot.record.revision)])
        guard let record = try itemWithoutLock(id: snapshot.record.id) else { throw HistoryStoreError.recordNotFound }
        _ = try requireFileRepairAccess(record, sync: snapshot.syncConfiguration, sharing: snapshot.sharingConfiguration, write: write)
        guard record.parts.indices.contains(file.partIndex),
              record.parts[file.partIndex].representations.indices.contains(file.representationIndex) else {
            throw ClipboardFileRepairError.invalidReference
        }
        let representation = record.parts[file.partIndex].representations[file.representationIndex]
        guard ClipboardFileAccess.isFileURLType(representation.typeIdentifier), representation.data == file.rawURL else {
            throw ClipboardFileRepairError.invalidReference
        }
        return record
    }

    /// Local cache visibility alone is not authorization to repair an inactive account's records.
    private func requireFileRepairAccess(_ record: ClipboardRecord, sync: SyncConfiguration,
                                        sharing: SyncConfiguration, write: Bool) throws -> Bool {
        let namespaces = try [syncNamespace(kind: .clipboard, id: record.id),
                              record.pinboardID.flatMap { try syncNamespace(kind: .pinboard, id: $0) }].compactMap { $0 }
        var readOnly = false
        for namespace in namespaces {
            if let state = try sharedStateForNamespace(namespace) {
                guard state.descriptor.accountID == sharing.accountID else { throw SharedBoardError.accountChanged }
                guard state.access != .revoked else { throw SharedBoardError.revoked }
                if !state.access.canWrite {
                    readOnly = true
                    if write { throw SharedBoardError.readOnly }
                }
            } else {
                guard !namespace.hasPrefix("shared:"), namespace == sync.accountID else { throw SyncError.namespaceConflict }
            }
        }
        return readOnly
    }

    private static func fileNameSummary(_ record: ClipboardRecord) -> String? {
        let names = record.parts.compactMap { part -> String? in
            guard let representation = part.representations.first(where: { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }),
                  let url = ClipboardFileAccess.url(from: representation.data) else { return nil }
            return url.lastPathComponent
        }
        return names.isEmpty ? nil : names.joined(separator: "\n")
    }
}
