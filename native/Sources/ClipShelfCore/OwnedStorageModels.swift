import Darwin
import Foundation

public enum OwnedAssetRetentionPurpose: String, Codable, Sendable { case undo, stack, edit, preview, output }
public enum OwnedAssetPublicationPurpose: String, Codable, Sendable { case clipboard, drag, sharing, externalOpen, legacyExternal }

/// The kernel lock, not a timeout, proves that this retention is still alive.
/// Copies share one object. Deinitialization never takes the store or SQLite lock.
public final class OwnedAssetLease: @unchecked Sendable {
    let id: UUID
    let storeIdentity: UUID
    let assetIDs: Set<UUID>
    private let descriptor: Int32
    init(id: UUID, storeIdentity: UUID, assetIDs: Set<UUID>, descriptor: Int32) {
        self.id = id; self.storeIdentity = storeIdentity; self.assetIDs = assetIDs; self.descriptor = descriptor
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
public struct RetainedClipboardRecords: Sendable {
    public let records: [ClipboardRecord]
    public let lease: OwnedAssetLease
}
public struct OwnedAssetPublication: Sendable, Identifiable {
    public let id: UUID
    public let purpose: OwnedAssetPublicationPurpose
    public let fileURLs: [URL]
    public let createdAt: Date
    let storeIdentity: UUID
}
public struct OwnedStorageUsage: Sendable, Equatable {
    public let assetCount: Int
    public let totalLogicalBytes: Int64
    public let totalAllocatedBytes: Int64
    public let reclaimableAssetCount: Int
    public let reclaimableLogicalBytes: Int64
    public let protectedAssetCount: Int
    public let unverifiedAssetCount: Int
    public let pendingReclamationCount: Int
    public let legacyProtectedAssetCount: Int
    public let measurementComplete: Bool
    public init(assetCount: Int, totalLogicalBytes: Int64, totalAllocatedBytes: Int64,
                reclaimableAssetCount: Int, reclaimableLogicalBytes: Int64, protectedAssetCount: Int,
                unverifiedAssetCount: Int, pendingReclamationCount: Int, legacyProtectedAssetCount: Int = 0, measurementComplete: Bool = true) {
        self.assetCount = assetCount; self.totalLogicalBytes = totalLogicalBytes; self.totalAllocatedBytes = totalAllocatedBytes
        self.reclaimableAssetCount = reclaimableAssetCount; self.reclaimableLogicalBytes = reclaimableLogicalBytes
        self.protectedAssetCount = protectedAssetCount; self.unverifiedAssetCount = unverifiedAssetCount
        self.pendingReclamationCount = pendingReclamationCount
        self.legacyProtectedAssetCount = legacyProtectedAssetCount
        self.measurementComplete = measurementComplete
    }
}
public struct OwnedStorageCleanupPlan: Sendable {
    public let usage: OwnedStorageUsage
    public var candidateCount: Int { candidates.count }
    public var candidateLogicalBytes: Int64 { candidates.reduce(0) { $0 + $1.logicalBytes } }
    let storeIdentity: UUID
    let syncConfiguration: SyncConfiguration
    let sharingConfiguration: SyncConfiguration
    let candidates: [OwnedFileReclamationCandidate]
    let capability = OwnedStorageCleanupCapability()
}
final class OwnedStorageCleanupCapability: @unchecked Sendable { var consumed = false }
public struct OwnedStorageCleanupResult: Sendable, Equatable {
    public let removedAssetCount: Int
    public let removedFileCount: Int
    public let removedLogicalBytes: Int64
    public let remainingPendingCount: Int
    public init(removedAssetCount: Int, removedFileCount: Int, removedLogicalBytes: Int64, remainingPendingCount: Int) {
        self.removedAssetCount = removedAssetCount; self.removedFileCount = removedFileCount
        self.removedLogicalBytes = removedLogicalBytes; self.remainingPendingCount = remainingPendingCount
    }
}
public enum OwnedStorageError: Error, LocalizedError {
    case changed, invalidLease, incompleteRecovery
    public var errorDescription: String? {
        switch self {
        case .changed: return "文件、保留依赖或账号已变化，未按旧确认继续清理，请重新检查范围。"
        case .invalidLease: return "文件保留凭证已失效，未继续输出或清理。"
        case .incompleteRecovery: return "部分文件仍在安全恢复区，未删除不确定内容；请重试完成清理。"
        }
    }
}
