import Foundation

/// A frozen selection refers to a particular version, never just a reusable item identifier.
public struct ClipboardSelectionReference: Hashable, Sendable {
    public let id: UUID
    public let revision: Int
    // A historical version from a deleted identity is not a current version of its replacement,
    // even if their small integer revisions coincide. Only a trusted Undo receipt can reconnect it.
    let historicalIdentity: UUID?
    public init(id: UUID, revision: Int) { self.id = id; self.revision = revision; historicalIdentity = nil }
    init(id: UUID, revision: Int, historicalIdentity: UUID?) {
        self.id = id; self.revision = revision; self.historicalIdentity = historicalIdentity
    }
}

public enum HistorySelectionScope: Sendable {
    case all
    /// Both endpoints must still match the query and their captured revisions. The range is inclusive.
    case between(ClipboardSelectionReference, ClipboardSelectionReference)
}

public struct HistorySelectionSnapshot: Sendable {
    public let references: [ClipboardSelectionReference]
    public init(references: [ClipboardSelectionReference]) { self.references = references }
}

/// An in-memory, store-bound undo capability. It contains placement metadata, never clipboard payloads.
public struct HistorySelectionMoveUndo: Sendable {
    /// Updated versions of the explicitly selected items, in the caller's frozen order.
    public let references: [ClipboardSelectionReference]
    /// Every record whose version or placement the undo depends on, including unselected board neighbours.
    public var affectedRecordIDs: Set<UUID> {
        var ids = Set(references.map(\.id))
        ids.formUnion(expected.map(\.id))
        ids.formUnion(before.map(\.id))
        ids.formUnion(placements.map(\.id))
        for board in boardPlacements.values { ids.formUnion(board.map(\.id)) }
        return ids
    }
    let storeIdentity: UUID
    let placements: [HistorySelectionPlacement]
    let expected: [ClipboardSelectionReference]
    let before: [ClipboardSelectionReference]
    let boardPlacements: [UUID: [HistorySelectionPlacement]]
    let syncConfiguration: SyncConfiguration
    let sharingConfiguration: SyncConfiguration
}

/// A deletion is undoable only inside the exact private/shared account generations that authorized it.
public struct HistorySelectionDeleteUndo: Sendable {
    public var affectedRecordIDs: Set<UUID> {
        Set(references.map(\.id)).union(boardPlacements.values.flatMap { $0.map(\.id) })
    }
    let storeIdentity: UUID
    let references: [ClipboardSelectionReference]
    let syncConfiguration: SyncConfiguration
    let sharingConfiguration: SyncConfiguration
    let consumption: HistorySelectionUndoConsumption
    let ownedFileBindings: [OwnedFileBinding]
    let ownedAssetLease: OwnedAssetLease?
    let records: [UUID: HistorySelectionDeletedRecordState]
    let boardPlacements: [UUID: [HistorySelectionPlacement]]
}

/// Captures the original content in the same transaction as a successful edit.
public struct HistorySelectionEditUndo: Sendable {
    public var committedReference: ClipboardSelectionReference { expected }
    public let original: ClipboardRecord
    let originalReference: ClipboardSelectionReference
    let expected: ClipboardSelectionReference
    let expectedContentFingerprint: String
    let fingerprintIdentity: UUID
    let storeIdentity: UUID
    let syncConfiguration: SyncConfiguration
    let sharingConfiguration: SyncConfiguration
    let ownedFileBindings: [OwnedFileBinding]
    let ownedAssetLease: OwnedAssetLease?
}

/// Access is protected by the owning HistoryStore lock. Copies of a token share consumption state.
final class HistorySelectionUndoConsumption: @unchecked Sendable { var consumed = false }

/// Trusted version transitions produced only by a successfully committed undo operation.
public struct HistorySelectionUndoReceipt: Sendable {
    public let references: [ClipboardSelectionReference]
    /// A synced deletion is restored as a new entity, without resurrecting its old tombstone.
    public var identityChanges: [UUID: UUID] {
        Dictionary(uniqueKeysWithValues: zip(before, after).compactMap { old, new in
            old.id == new.id ? nil : (old.id, new.id)
        })
    }
    let storeIdentity: UUID
    let before: [ClipboardSelectionReference]
    let after: [ClipboardSelectionReference]
}

struct HistorySelectionPlacement: Sendable, Equatable {
    let id: UUID
    let boardID: UUID?
    let rank: Int64?
    let orderIdentity: UUID
    let isInHistory: Bool
}

/// Payload-independent state captured before deleting, under the owning transaction.
struct HistorySelectionDeletedRecordState: Sendable {
    let historyOrder: Int64
    let namespace: String?
    let deletionNamespace: String?
    let localOnly: Bool
    let ownedLocalRecovery: Bool
    let contentFingerprint: String
    let fingerprintIdentity: UUID
}

extension HistorySelectionUndoReceipt {
    func rebased(_ reference: ClipboardSelectionReference) -> ClipboardSelectionReference {
        if let index = before.firstIndex(of: reference) { return after[index] }
        return rebasedHistorical(reference)
    }

    func rebasedHistorical(_ reference: ClipboardSelectionReference) -> ClipboardSelectionReference {
        guard let replacement = identityChanges[reference.id] else { return reference }
        return ClipboardSelectionReference(id: replacement, revision: reference.revision,
                                           historicalIdentity: reference.historicalIdentity ?? reference.id)
    }

    func rebased(_ placement: HistorySelectionPlacement) -> HistorySelectionPlacement {
        HistorySelectionPlacement(id: identityChanges[placement.id] ?? placement.id, boardID: placement.boardID,
                                  rank: placement.rank, orderIdentity: placement.orderIdentity, isInHistory: placement.isInHistory)
    }

    func rebased(_ binding: OwnedFileBinding) -> OwnedFileBinding {
        OwnedFileBinding(recordID: identityChanges[binding.recordID] ?? binding.recordID, partIndex: binding.partIndex,
                         representationIndex: binding.representationIndex, assetID: binding.assetID)
    }
}
