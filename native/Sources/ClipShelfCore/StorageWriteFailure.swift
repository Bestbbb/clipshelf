import ClipShelfLocalization
import CSQLite
import Darwin
import Foundation

public enum StorageWriteFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidRequirement
    case capacityUnavailable
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case destinationChanged
    case coordinationUnavailable
    case releasedLease
    case diskFull

    public var errorDescription: String? {
        switch self {
        case .invalidRequirement: return L10n.text("存储空间需求无效或过大，尚未开始写入。")
        case .capacityUnavailable: return L10n.text("无法确认目标卷的可用空间，尚未开始新的写入。请检查目标位置后重试。")
        case .insufficientSpace(let required, let available):
            return L10n.text("目标卷空间不足：本次及其他待完成写入需要 \(L10n.fileSize(required))，当前可用 \(L10n.fileSize(available))。请释放空间后重试。")
        case .destinationChanged: return L10n.text("写入目标或所在卷已经变化，未按旧路径继续发布。请重新选择位置后重试。")
        case .coordinationUnavailable: return L10n.text("无法验证正在使用的空间预算，未开始新的写入。现有内容继续保留，请稍后重试。")
        case .releasedLease: return L10n.text("本次空间预算已结束，不能继续使用；请重新发起操作。")
        case .diskFull: return L10n.text("写入时磁盘空间或用户磁盘额度已用尽。请释放空间后重试。")
        }
    }

    /// Normalizes actual write failures as well as preflight failures. A successful preflight
    /// cannot prevent another application or the filesystem from consuming the available space.
    public static func classify(_ error: Error) -> StorageWriteFailure? {
        classify(error, depth: 0)
    }

    private static func classify(_ error: Error, depth: Int) -> StorageWriteFailure? {
        guard depth < 16 else { return nil }
        if let failure = error as? StorageWriteFailure { return failure }
        if case HistoryStoreError.database(let code, _) = error, code & 0xff == SQLITE_FULL { return .diskFull }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain, [Int(ENOSPC), Int(EDQUOT)].contains(value.code) { return .diskFull }
        if value.domain == NSCocoaErrorDomain, value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return .diskFull }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return classify(underlying, depth: depth + 1) }
        return nil
    }
}
