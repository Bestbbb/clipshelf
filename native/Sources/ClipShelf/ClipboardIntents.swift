import AppIntents
import ClipShelfCore
import Foundation

enum ClipboardIntentError: LocalizedError {
    case unavailable, permissionRequired, invalidInput, missingBoard, inaccessibleBoard, ambiguousBoard, noMatch, unsupportedContent
    var errorDescription: String? {
        switch self {
        case .unavailable: return "ClipShelf 尚未就绪，请打开应用后重试。"
        case .permissionRequired: return "请在 ClipShelf 菜单栏开启“允许快捷指令访问”。"
        case .invalidInput: return "文本不能为空且最多 64 KB；搜索最多 512 字节，序号范围为 1–1000。"
        case .missingBoard: return "没有找到这个分组，请检查完整分组名称。"
        case .inaccessibleBoard: return "这个分组不属于当前账号、共享访问已撤销，或当前操作没有写入权限。"
        case .ambiguousBoard: return "存在同名分组，请在 ClipShelf 中修改名称后重试。"
        case .noMatch: return "没有符合条件的内容。"
        case .unsupportedContent: return "这条内容没有可输出的文字。图片可先提取文字；文件请在 ClipShelf 中操作。"
        }
    }
}

/// Shortcuts uses the same store/privacy boundary without requesting app activation.
/// Merely indexing these actions does not read clipboard history or instantiate a store.
@MainActor
final class ClipboardIntentRuntime {
    static let shared = ClipboardIntentRuntime(loadOnDemand: true)
    private let loadOnDemand: Bool
    var store: HistoryStore?
    var enabled = false
    var onDataChanged: (() -> Void)?
    init(loadOnDemand: Bool = false) { self.loadOnDemand = loadOnDemand }

    private func authorizedStore() throws -> HistoryStore {
        if loadOnDemand { enabled = UserDefaults.standard.bool(forKey: "shortcutsEnabled") }
        guard enabled else { throw ClipboardIntentError.permissionRequired }
        if store == nil, loadOnDemand {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("ClipShelf Development", isDirectory: true)
            store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
        }
        guard let store else { throw ClipboardIntentError.unavailable }
        return store
    }

    private func boardID(_ name: String?, store: HistoryStore, writing: Bool,
                         sync: SyncConfiguration, sharing: SyncConfiguration) throws -> UUID? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let named = try store.pinboards().filter { $0.name == name }
        guard !named.isEmpty else { throw ClipboardIntentError.missingBoard }
        let sharedStates = try sharing.accountID.map { try store.sharedBoards(accountID: $0) } ?? []
        let matches = try named.filter { board in
            guard let namespace = try store.pinboardNamespace(id: board.id) else { return true }
            if namespace == sync.accountID { return true }
            guard let state = sharedStates.first(where: { $0.descriptor.namespace == namespace }) else { return false }
            return writing ? state.access.canWrite : state.access != .revoked
        }
        guard !matches.isEmpty else { throw ClipboardIntentError.inaccessibleBoard }
        guard matches.count == 1 else { throw ClipboardIntentError.ambiguousBoard }
        return matches[0].id
    }

    func add(text: String, board: String?) throws -> String {
        let store = try authorizedStore()
        guard !text.isEmpty, text.utf8.count <= 65_536 else { throw ClipboardIntentError.invalidInput }
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        let record = ClipboardRecord(text: text, sourceApp: "快捷指令", sourceBundleID: "com.apple.shortcuts",
                                     pinboardID: try boardID(board, store: store, writing: true, sync: sync, sharing: sharing))
        let created = try store.create(record, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing)
        onDataChanged?()
        return created.id.uuidString
    }

    func get(query: String = "", board: String?, index: Int = 1) throws -> String {
        let store = try authorizedStore()
        guard query.utf8.count <= 512, (1...1000).contains(index) else { throw ClipboardIntentError.invalidInput }
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        let id = try boardID(board, store: store, writing: false, sync: sync, sharing: sharing)
        let matches = try store.searchIntegrationMetadata(HistoryQuery(text: query, pinboardIDs: id.map { [$0] } ?? [], limit: 1),
                                                         offset: index - 1, expectedSyncConfiguration: sync,
                                                         expectedSharingConfiguration: sharing)
        guard let match = matches.first else { throw ClipboardIntentError.noMatch }
        if match.kind == .image {
            guard let text = match.ocrText, !text.isEmpty else { throw ClipboardIntentError.unsupportedContent }
            guard text.utf8.count <= 65_536 else { throw ClipboardIntentError.invalidInput }
            return text
        }
        guard match.kind != .file else { throw ClipboardIntentError.unsupportedContent }
        let types = Set(match.representationTypes.flatMap { $0 })
        guard types.isDisjoint(with: ["com.adobe.pdf", "public.pdf"]) || types.contains("public.utf8-plain-text") else {
            throw ClipboardIntentError.unsupportedContent
        }
        guard match.text.utf8.count <= 65_536 else { throw ClipboardIntentError.invalidInput }
        return match.text
    }
}

struct AddClipboardTextIntent: AppIntent {
    static let title: LocalizedStringResource = "保存文本到 ClipShelf"
    static let description = IntentDescription("把文本或链接保存到历史或指定分组。不会改写系统剪贴板。")
    static let openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    @Parameter(title: "文本") var text: String
    @Parameter(title: "分组名称") var pinboard: String?
    static var parameterSummary: some ParameterSummary { Summary("保存 \(\.$text) 到 ClipShelf") { \.$pinboard } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try ClipboardIntentRuntime.shared.add(text: text, board: pinboard))
    }
}

struct FindClipboardTextIntent: AppIntent {
    static let title: LocalizedStringResource = "查找 ClipShelf 最近文本"
    static let description = IntentDescription("查找本地内容、当前同步账号及仍可读取的共享板，排除过往账号缓存与撤销的共享。需单独允许快捷指令访问。")
    static let openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    @Parameter(title: "搜索", default: "") var query: String
    @Parameter(title: "分组名称") var pinboard: String?
    static var parameterSummary: some ParameterSummary { Summary("从 ClipShelf 查找 \(\.$query)") { \.$pinboard } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try ClipboardIntentRuntime.shared.get(query: query, board: pinboard))
    }
}

struct GetClipboardTextAtIndexIntent: AppIntent {
    static let title: LocalizedStringResource = "获取 ClipShelf 第几条文本"
    static let description = IntentDescription("从当前授权范围内的列表取得指定序号文本，从 1 开始。仅包含本地内容、当前账号及仍可读取的共享板。")
    static let openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    @Parameter(title: "序号", default: 1) var index: Int
    @Parameter(title: "分组名称") var pinboard: String?
    static var parameterSummary: some ParameterSummary { Summary("获取 ClipShelf 第 \(\.$index) 条文本") { \.$pinboard } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try ClipboardIntentRuntime.shared.get(board: pinboard, index: index))
    }
}

struct ClipShelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindClipboardTextIntent(), phrases: ["Find recent text in \(.applicationName)"],
                    shortTitle: "查找最近文本", systemImageName: "clipboard")
    }
}
