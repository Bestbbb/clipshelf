import Foundation

public struct HistoryCleanupSummary: Equatable, Sendable {
    public let deletedCount: Int
    public let preservedPinnedCount: Int
    /// These are disjoint subsets of affectedCount, not additional records.
    public let privateSyncCount: Int
    public let sharedSyncCount: Int
    public let excludedCount: Int
    public var affectedCount: Int { deletedCount + preservedPinnedCount }

    public init(deletedCount: Int, preservedPinnedCount: Int, privateSyncCount: Int,
                sharedSyncCount: Int, excludedCount: Int) {
        self.deletedCount = deletedCount; self.preservedPinnedCount = preservedPinnedCount
        self.privateSyncCount = privateSyncCount; self.sharedSyncCount = sharedSyncCount
        self.excludedCount = excludedCount
    }
}

/// A metadata-only, one-use confirmation bound to a live store and account generations.
/// Only the store can construct a plan; new matching rows never expand its frozen scope.
public struct HistoryCleanupPlan: Sendable {
    public let summary: HistoryCleanupSummary
    let storeIdentity: UUID
    let syncConfiguration: SyncConfiguration
    let sharingConfiguration: SyncConfiguration
    let candidates: [HistoryCleanupCandidate]
    let capability = HistoryCleanupCapability()
}

public struct HistoryCleanupResult: Sendable {
    public let summary: HistoryCleanupSummary
    public let deletedIDs: [UUID]
    public let preservedReferences: [ClipboardSelectionReference]
    public init(summary: HistoryCleanupSummary, deletedIDs: [UUID], preservedReferences: [ClipboardSelectionReference]) {
        self.summary = summary; self.deletedIDs = deletedIDs; self.preservedReferences = preservedReferences
    }
}

public enum HistoryCleanupError: Error, LocalizedError {
    case invalidPlan, changed
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "这次清理确认已使用或不属于当前资料库，请重新确认。"
        case .changed: return "待清理条目、所属账号或权限已变化，未清理任何内容，请重新确认范围。"
        }
    }
}

// Mutable only while the owning HistoryStore's lock is held. Copies of a plan
// share this capability, including empty plans; failed transactions do not consume it.
final class HistoryCleanupCapability: @unchecked Sendable { var consumed = false }

struct HistoryCleanupCandidate: Equatable, Sendable {
    let id: UUID
    let revision: Int
    let boardID: UUID?
    let mutationToken: Data
    let recordNamespace: String?
    let boardNamespace: String?
    let recordLocalOnly: Bool
    let boardLocalOnly: Bool
    let sharedStates: [SharedBoardState]
    let impact: Impact
    enum Impact: Equatable, Sendable { case local, privateSync, sharedSync }
}
