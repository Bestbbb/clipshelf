import ClipShelfLocalization
import Foundation

/// Logical saved data, not database allocation or a physical disk quota. Attachments are
/// counted once per digest; owned originals remain counted until their registration is removed.
public struct LibraryContentQuotaStatus: Equatable, Sendable {
    public let recordBytes: Int64
    public let representationBytes: Int64
    public let ownedFileBytes: Int64
    public let syncPayloadBytes: Int64
    public let usedBytes: Int64
    public let limitBytes: Int64?
    public let policyRevision: Int64

    public init(recordBytes: Int64, representationBytes: Int64, ownedFileBytes: Int64,
                syncPayloadBytes: Int64, usedBytes: Int64, limitBytes: Int64?, policyRevision: Int64) {
        self.recordBytes = recordBytes; self.representationBytes = representationBytes
        self.ownedFileBytes = ownedFileBytes; self.syncPayloadBytes = syncPayloadBytes
        self.usedBytes = usedBytes; self.limitBytes = limitBytes; self.policyRevision = policyRevision
    }

    public var exceededBytes: Int64 {
        guard let limitBytes, usedBytes > limitBytes else { return 0 }
        return usedBytes - limitBytes
    }
}

public enum ContentQuotaError: Error, Equatable, LocalizedError, Sendable {
    case exceeded(usedBytes: Int64, limitBytes: Int64)
    case measurementUnavailable
    case invalidLimit
    case stalePolicy

    public var errorDescription: String? {
        switch self {
        case .exceeded(let used, let limit):
            return L10n.text("保存数据将达到 \(L10n.fileSize(used))，超过设定上限 \(L10n.fileSize(limit))。请减少内容、清理不再需要的数据，或提高上限后重试。")
        case .measurementUnavailable:
            return L10n.text("无法可靠计量保存数据，未继续增加内容。现有数据保持不变，请检查资料库后重试。")
        case .invalidLimit:
            return L10n.text("保存数据上限必须是正整数，或选择不限制。")
        case .stalePolicy:
            return L10n.text("保存数据上限已在其他窗口或进程中更改。请重新加载后再保存。")
        }
    }
}
