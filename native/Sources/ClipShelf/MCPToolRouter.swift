import ClipShelfCore
import Foundation

/// ClipShelf's own 11-tool schema. Tool names match the public Paste capability
/// inventory; argument compatibility with Paste's private app is not implied.
@MainActor
final class MCPToolRouter {
    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let store: HistoryStore
    private let authorizationStore: MCPAuthorizationStore
    var onDataChanged: (() -> Void)?

    init(store: HistoryStore, authorizationStore: MCPAuthorizationStore) {
        self.store = store
        self.authorizationStore = authorizationStore
    }

    func listTools(clientID: UUID) throws -> [[String: Any]] {
        let client = try authorized(clientID, permission: .read)
        return Self.definitions.filter { definition in
            guard let name = definition["name"] as? String else { return false }
            if name == "create_pinboard", !client.scope.allPinboards { return false }
            return client.permissions.contains(Self.permission(for: name))
        }
    }

    func call(name: String, arguments: [String: Any], clientID: UUID) throws -> [String: Any] {
        guard Self.toolNames.contains(name) else { throw ToolError(message: "Unknown tool.") }
        let client = try authorized(clientID, permission: Self.permission(for: name))
        let allowed = Self.argumentNames[name] ?? []
        guard Set(arguments.keys).isSubset(of: allowed) else { throw ToolError(message: "Unexpected argument.") }
        var result: [String: Any]

        switch name {
        case "search":
            return try search(arguments, client: client)
        case "read_item":
            let item = try visibleItem(try uuid(arguments, "id"), client: client)
            return itemJSON(item, detailed: true)
        case "create_item":
            let text = try string(arguments, "text", maximumBytes: 32_768)
            let title = try optionalString(arguments, "title", maximumBytes: 256)
            let boardID = try optionalUUID(arguments, "pinboardId")
            try requireDestination(boardID, client: client)
            let record = ClipboardRecord(text: text, sourceApp: "MCP: \(client.name)",
                                         renamedTitle: title, pinboardID: boardID,
                                         isInHistory: client.scope.includeHistory)
            let created = try store.create(record)
            result = ["id": created.id.uuidString, "revision": created.revision]
        case "update_item":
            let id = try uuid(arguments, "id")
            let metadata = try visibleItem(id, client: client)
            let expected = try integer(arguments, "expectedRevision", range: 1...Int.max)
            guard expected == metadata.revision else { throw ToolError(message: "Revision conflict. Read the item again before updating.") }
            guard arguments["text"] != nil || arguments["title"] != nil else { throw ToolError(message: "Provide text or title to update.") }
            guard var item = try store.item(id: id) else { throw ToolError(message: "Item not found or outside the authorized scope.") }
            if arguments["text"] != nil {
                guard [.text, .link, .color].contains(metadata.kind) else { throw ToolError(message: "Text replacement is only supported for text, link, and color items.") }
                item.text = try string(arguments, "text", maximumBytes: 32_768)
                item.rtf = nil
                item.html = nil
                item.parts = []
                item.ocrText = nil
            }
            if arguments["title"] != nil { item.renamedTitle = try string(arguments, "title", maximumBytes: 256, allowEmpty: true) }
            item.revision = expected
            let updated = try store.update(record: item)
            result = ["id": updated.id.uuidString, "revision": updated.revision]
        case "delete_item":
            let id = try uuid(arguments, "id")
            _ = try visibleItem(id, client: client)
            try store.delete(id: id)
            result = ["deleted": true, "id": id.uuidString]
        case "list_pinboards":
            let (offset, limit) = try pagination(arguments)
            let boards = try store.pinboards().filter { client.scope.permits(boardID: $0.id) }
            result = ["pinboards": boards.dropFirst(offset).prefix(limit).map(boardJSON)]
            if offset + limit < boards.count { result["nextCursor"] = cursor(offset + limit) }
            return result
        case "create_pinboard":
            guard client.scope.allPinboards else { throw ToolError(message: "Creating a pinboard requires access to all pinboards.") }
            let name = try string(arguments, "name", maximumBytes: 128)
            let color = try optionalString(arguments, "color", maximumBytes: 7) ?? "#4F7CFF"
            let board = try store.createPinboard(name: name, color: color)
            result = boardJSON(board)
        case "rename_pinboard":
            var board = try visibleBoard(try uuid(arguments, "id"), client: client)
            board.name = try string(arguments, "name", maximumBytes: 128)
            try store.updatePinboard(board)
            result = boardJSON(board)
        case "delete_pinboard":
            let board = try visibleBoard(try uuid(arguments, "id"), client: client)
            let deleteItems = try boolean(arguments, "deleteItems", fallback: false)
            guard deleteItems || client.scope.includeHistory else {
                throw ToolError(message: "Keeping items outside the board requires access to unpinned history; otherwise explicitly choose deleteItems.")
            }
            try store.deletePinboard(id: board.id, deleteItems: deleteItems)
            result = ["deleted": true, "id": board.id.uuidString, "deletedItems": deleteItems]
        case "add_item_to_pinboard":
            let id = try uuid(arguments, "itemId")
            _ = try visibleItem(id, client: client)
            let board = try visibleBoard(try uuid(arguments, "pinboardId"), client: client)
            try store.move(recordID: id, to: board.id)
            result = ["id": id.uuidString, "pinboardId": board.id.uuidString]
        case "remove_item_from_pinboard":
            let id = try uuid(arguments, "itemId")
            _ = try visibleItem(id, client: client)
            guard client.scope.includeHistory else { throw ToolError(message: "Removing an item from a pinboard requires access to unpinned history.") }
            try store.move(recordID: id, to: nil)
            result = ["id": id.uuidString, "pinboardId": NSNull()]
        default:
            throw ToolError(message: "Unknown tool.")
        }
        onDataChanged?()
        return result
    }

    private func search(_ arguments: [String: Any], client: MCPAuthorizationStore.Client) throws -> [String: Any] {
        let text = try optionalString(arguments, "query", maximumBytes: 512) ?? ""
        let (offset, limit) = try pagination(arguments)
        let requestedBoard = try optionalUUID(arguments, "pinboardId")
        if let requestedBoard { _ = try visibleBoard(requestedBoard, client: client) }
        let kindString = try optionalString(arguments, "kind", maximumBytes: 16)
        let kind = kindString.flatMap(ClipboardContentKind.init(rawValue:))
        if kindString != nil && kind == nil { throw ToolError(message: "Invalid content kind.") }
        let boardIDs: Set<UUID>
        if let requestedBoard { boardIDs = [requestedBoard] }
        else if !client.scope.includeHistory && !client.scope.allPinboards { boardIDs = client.scope.pinboardIDs }
        else { boardIDs = [] }

        var position = offset
        var remainingScan = 1_000
        var items: [[String: Any]] = []
        var hasMore = false
        while remainingScan > 0, position < 1_000_000 {
            let batchLimit = min(100, remainingScan)
            let query = HistoryQuery(text: text, kind: kind, pinboardIDs: boardIDs, limit: batchLimit)
            let batch = try store.searchMetadata(query, offset: position)
            if batch.isEmpty { break }
            for item in batch {
                if client.scope.permits(pinboardID: item.pinboardID, isInHistory: item.isInHistory) {
                    if items.count == limit {
                        hasMore = true
                        break
                    }
                    items.append(itemJSON(item, detailed: false))
                }
                position += 1
                remainingScan -= 1
            }
            if hasMore || batch.count < batchLimit { break }
            if remainingScan == 0 { hasMore = true }
        }
        var result: [String: Any] = ["items": items]
        if hasMore, position < 1_000_000 { result["nextCursor"] = cursor(position) }
        return result
    }

    private func authorized(_ clientID: UUID, permission: MCPAuthorizationStore.Permission) throws -> MCPAuthorizationStore.Client {
        guard let client = authorizationStore.client(id: clientID), client.permissions.contains(permission) else {
            throw ToolError(message: "This client is not authorized for the requested operation.")
        }
        return client
    }

    private func visibleItem(_ id: UUID, client: MCPAuthorizationStore.Client) throws -> ClipboardRecordMetadata {
        guard let item = try store.itemMetadata(id: id),
              client.scope.permits(pinboardID: item.pinboardID, isInHistory: item.isInHistory) else {
            throw ToolError(message: "Item not found or outside the authorized scope.")
        }
        return item
    }

    private func visibleBoard(_ id: UUID, client: MCPAuthorizationStore.Client) throws -> Pinboard {
        guard client.scope.permits(boardID: id), let board = try store.pinboards().first(where: { $0.id == id }) else {
            throw ToolError(message: "Pinboard not found or outside the authorized scope.")
        }
        return board
    }

    private func requireDestination(_ boardID: UUID?, client: MCPAuthorizationStore.Client) throws {
        if let boardID { _ = try visibleBoard(boardID, client: client) }
        else if !client.scope.includeHistory { throw ToolError(message: "Choose an authorized pinboard for this item.") }
    }

    private func itemJSON(_ item: ClipboardRecordMetadata, detailed: Bool) -> [String: Any] {
        let byteLimit = detailed ? 32_768 : 512
        var result: [String: Any] = [
            "id": item.id.uuidString, "title": Self.truncate(item.title, bytes: 512),
            "kind": item.kind.rawValue, "text": Self.truncate(item.text, bytes: byteLimit),
            "textTruncated": item.text.utf8.count > byteLimit,
            "copiedAt": ISO8601DateFormatter().string(from: item.copiedAt), "revision": item.revision,
            "pinboardId": item.pinboardID?.uuidString as Any? ?? NSNull(),
        ]
        if let source = item.sourceApp { result["sourceApp"] = Self.truncate(source, bytes: 256) }
        if detailed {
            result["representationTypes"] = item.representationTypes.prefix(32).map { $0.prefix(32).map { Self.truncate($0, bytes: 128) } }
            result["binaryIncluded"] = false
            if let ocr = item.ocrText {
                result["ocrText"] = Self.truncate(ocr, bytes: 8_192)
                result["ocrTextTruncated"] = ocr.utf8.count > 8_192
            }
        }
        return result
    }

    private func boardJSON(_ board: Pinboard) -> [String: Any] {
        ["id": board.id.uuidString, "name": Self.truncate(board.name, bytes: 256), "color": board.color, "sortOrder": board.sortOrder]
    }

    private func pagination(_ arguments: [String: Any]) throws -> (Int, Int) {
        let limit = try integer(arguments, "limit", range: 1...100, fallback: 20)
        guard let raw = arguments["cursor"] else { return (0, limit) }
        guard let encoded = raw as? String, encoded.utf8.count <= 64,
              let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8),
              value.hasPrefix("offset:"), let offset = Int(value.dropFirst(7)), (0..<1_000_000).contains(offset) else {
            throw ToolError(message: "Invalid cursor.")
        }
        return (offset, limit)
    }

    private func cursor(_ offset: Int) -> String { Data("offset:\(offset)".utf8).base64EncodedString() }
    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let value = args[key] as? String, let id = UUID(uuidString: value) else { throw ToolError(message: "\(key) must be a UUID.") }
        return id
    }
    private func optionalUUID(_ args: [String: Any], _ key: String) throws -> UUID? {
        guard args[key] != nil else { return nil }
        return try uuid(args, key)
    }
    private func string(_ args: [String: Any], _ key: String, maximumBytes: Int, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String, value.utf8.count <= maximumBytes,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError(message: "\(key) must be a string within \(maximumBytes) UTF-8 bytes.")
        }
        return value
    }
    private func optionalString(_ args: [String: Any], _ key: String, maximumBytes: Int) throws -> String? {
        guard args[key] != nil else { return nil }
        return try string(args, key, maximumBytes: maximumBytes, allowEmpty: true)
    }
    private func integer(_ args: [String: Any], _ key: String, range: ClosedRange<Int>, fallback: Int? = nil) throws -> Int {
        if args[key] == nil, let fallback { return fallback }
        guard let value = args[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue >= Double(range.lowerBound), value.doubleValue < Double(Int.max),
              let number = Int(exactly: value.int64Value), range.contains(number) else {
            throw ToolError(message: "\(key) must be an integer in the allowed range.")
        }
        return number
    }
    private func boolean(_ args: [String: Any], _ key: String, fallback: Bool) throws -> Bool {
        guard let value = args[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ToolError(message: "\(key) must be a boolean.") }
        return number.boolValue
    }
    private static func truncate(_ string: String, bytes: Int) -> String {
        var prefix = Array(string.utf8.prefix(bytes))
        while !prefix.isEmpty {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            prefix.removeLast()
        }
        return ""
    }

    static let toolNames: Set<String> = Set(argumentNames.keys)
    private static let argumentNames: [String: Set<String>] = [
        "search": ["query", "kind", "pinboardId", "limit", "cursor"], "read_item": ["id"],
        "create_item": ["text", "title", "pinboardId"], "update_item": ["id", "expectedRevision", "text", "title"],
        "delete_item": ["id"], "list_pinboards": ["limit", "cursor"], "create_pinboard": ["name", "color"],
        "rename_pinboard": ["id", "name"], "delete_pinboard": ["id", "deleteItems"],
        "add_item_to_pinboard": ["itemId", "pinboardId"], "remove_item_from_pinboard": ["itemId"],
    ]
    private static func permission(for name: String) -> MCPAuthorizationStore.Permission {
        if ["search", "read_item", "list_pinboards"].contains(name) { return .read }
        if ["delete_item", "delete_pinboard"].contains(name) { return .delete }
        return .write
    }

    private static var definitions: [[String: Any]] {
        let id: [String: Any] = ["type": "string", "format": "uuid"]
        let text: [String: Any] = ["type": "string", "maxLength": 32_768]
        let title: [String: Any] = ["type": "string", "maxLength": 256]
        let page: [String: Any] = ["limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20], "cursor": ["type": "string", "maxLength": 64]]
        func definition(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": permission(for: name) == .read,
                             "destructiveHint": permission(for: name) == .delete, "openWorldHint": false]]
        }
        return [
            definition("search", "Search authorized clipboard metadata. No binary payloads. Cursors are bounded live offsets, not snapshots.", page.merging(["query": ["type": "string", "maxLength": 512], "kind": ["type": "string", "enum": ClipboardContentKind.allCases.map(\.rawValue)], "pinboardId": id]) { _, new in new }),
            definition("read_item", "Read one authorized item with bounded text and representation type metadata, without binary data.", ["id": id], ["id"]),
            definition("create_item", "Create an independent plain-text item in authorized history or a pinboard.", ["text": text, "title": title, "pinboardId": id], ["text"]),
            definition("update_item", "Update title or plain text using the current revision. Replacing text removes old rich formatting.", ["id": id, "expectedRevision": ["type": "integer", "minimum": 1], "text": text, "title": title], ["id", "expectedRevision"]),
            definition("delete_item", "Permanently delete an authorized item.", ["id": id], ["id"]),
            definition("list_pinboards", "List authorized pinboards.", page),
            definition("create_pinboard", "Create a pinboard; requires write permission and all-pinboards scope.", ["name": title, "color": ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"]], ["name"]),
            definition("rename_pinboard", "Rename an authorized pinboard.", ["id": id, "name": title], ["id", "name"]),
            definition("delete_pinboard", "Delete a pinboard. By default keep items in unpinned history; deleteItems=true permanently deletes them.", ["id": id, "deleteItems": ["type": "boolean", "default": false]], ["id"]),
            definition("add_item_to_pinboard", "Move an authorized item into an authorized pinboard; an item belongs to one pinboard.", ["itemId": id, "pinboardId": id], ["itemId", "pinboardId"]),
            definition("remove_item_from_pinboard", "Unpin an authorized item into unpinned history, requiring history access.", ["itemId": id], ["itemId"]),
        ]
    }
}
