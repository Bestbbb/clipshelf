import ClipShelfCore
import Foundation

/// Fixed synthetic fixtures for inspecting bounded pages and source filters.
/// The caller must opt into the isolated validation profile before populating.
enum SearchValidationFixtures {
    static func populate(_ store: HistoryStore) throws {
        let epoch = Date()
        let board = try store.createPinboard(name: "验收 · 深页", color: "#6C63A8")
        let remoteID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        _ = try store.create(ClipboardRecord(text: "TARGET-DEEP-HISTORY · 位于历史末尾的合成条目",
            sourceApp: "验收夹具", copiedAt: epoch.addingTimeInterval(-1_000)))
        for index in 0..<900 {
            var record = ClipboardRecord(
                text: index == 800 ? "TARGET-DEEP-BOARD · 分组第 401 条合成内容" : String(format: "合成历史 %03d · search fixture", index),
                sourceApp: index.isMultiple(of: 2) ? "验收编辑器" : "验收笔记",
                copiedAt: epoch.addingTimeInterval(Double(index - 900)),
                pinboardID: index.isMultiple(of: 2) ? board.id : nil)
            if index % 3 == 1 {
                record.originDeviceID = remoteID
                record.originDeviceName = "Mac"
            }
            // The third group models legacy records with no source evidence.
            _ = try store.create(record, preserveOrigin: index % 3 != 0)
        }
    }
}
