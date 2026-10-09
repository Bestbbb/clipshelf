import Foundation
import ClipShelfCore

struct HistoryFilterOptions: Equatable {
    var pinboards: [Pinboard]
    var sources: [String: String]
    var devices: [UUID: String]
    var localDeviceID: UUID?

    init(pinboards: [Pinboard], sources: [String: String], devices: [UUID: String], localDeviceID: UUID?) {
        self.pinboards = pinboards; self.sources = sources
        self.devices = devices; self.localDeviceID = localDeviceID
    }
}

/// A value copy of a query. Nothing reaches the panel until the user applies it.
struct HistoryFilterDraft {
    var query: HistoryQuery

    init(query: HistoryQuery) { self.query = query }

    mutating func clearFilters() {
        query.kind = nil; query.sourceBundleID = nil; query.deviceFilter = .all
        query.copiedAfter = nil; query.copiedBefore = nil; query.pinboardIDs = []
    }

    func validate(availablePinboardIDs: Set<UUID>) throws {
        let dates = [query.copiedAfter, query.copiedBefore].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw ValidationError.invalidDate }
        if let start = query.copiedAfter, let end = query.copiedBefore, start > end { throw ValidationError.reversedDates }
        let missing = query.pinboardIDs.subtracting(availablePinboardIDs)
        guard missing.isEmpty else { throw ValidationError.unavailablePinboards(missing.count) }
        if query.sortOrder == .pinboard, query.pinboardIDs.count != 1 { throw ValidationError.manualOrderRequiresOneBoard }
    }

    func availabilityNotice(options: HistoryFilterOptions) -> String? {
        var messages: [String] = []
        if let source = query.sourceBundleID, options.sources[source] == nil { messages.append("所选来源 App 暂不可用；保留该条件，结果可能为空。") }
        if case .device(let id) = query.deviceFilter, id != options.localDeviceID, options.devices[id] == nil {
            messages.append("所选设备暂不可用；保留该条件，结果可能为空。")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalidDate, reversedDates, unavailablePinboards(Int), manualOrderRequiresOneBoard
        var errorDescription: String? {
            switch self {
            case .invalidDate: return "日期无效，请重新选择。"
            case .reversedDates: return "开始时间不能晚于结束时间。"
            case .unavailablePinboards(let count): return "有 \(count) 个已选分组已不可用，请取消勾选后再应用。"
            case .manualOrderRequiresOneBoard: return "分组内手动顺序需要且仅需要一个分组；请选择单个分组，或改为“最近复制”。"
            }
        }
    }
}
