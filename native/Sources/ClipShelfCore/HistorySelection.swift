import Foundation

/// A frozen selection refers to a particular version, never just a reusable item identifier.
public struct ClipboardSelectionReference: Hashable, Sendable {
    public let id: UUID
    public let revision: Int
    public init(id: UUID, revision: Int) { self.id = id; self.revision = revision }
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
    let storeIdentity: UUID
    let references: [ClipboardSelectionReference]
    let syncConfiguration: SyncConfiguration
    let sharingConfiguration: SyncConfiguration
    let consumption: HistorySelectionUndoConsumption
    let ownedFileBindings: [OwnedFileBinding]
    let ownedAssetLease: OwnedAssetLease?
}

/// Captures the original content in the same transaction as a successful edit.
public struct HistorySelectionEditUndo: Sendable {
    public var committedReference: ClipboardSelectionReference { expected }
    public let original: ClipboardRecord
    let expected: ClipboardSelectionReference
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
    let storeIdentity: UUID
    let before: [ClipboardSelectionReference]
    let after: [ClipboardSelectionReference]
}

struct HistorySelectionPlacement: Sendable, Equatable {
    let id: UUID
    let boardID: UUID?
    let rank: Int64?
    let isInHistory: Bool
}
