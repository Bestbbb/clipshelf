import ClipShelfCore
@testable import ClipShelf
import XCTest

@MainActor
final class MemoryMCPCredentials: MCPAuthorizationPersistence {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

@MainActor
final class MCPTestFixture {
    let directory: URL
    let store: HistoryStore
    let persistence = MemoryMCPCredentials()
    let auth: MCPAuthorizationStore
    let router: MCPToolRouter

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipShelfMCPTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try HistoryStore(databaseURL: directory.appendingPathComponent("test.sqlite3"))
        auth = try MCPAuthorizationStore(persistence: persistence)
        router = MCPToolRouter(store: store, authorizationStore: auth)
    }

    func authorize(_ permissions: Set<MCPAuthorizationStore.Permission> = [.read, .write, .delete],
                   scope: MCPAuthorizationStore.AccessScope = .all) throws -> MCPAuthorizationStore.IssuedClient {
        try auth.authorizeClient(name: "Synthetic test client", permissions: permissions, scope: scope)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class MCPAuthorizationAndRouterTests: XCTestCase {
    func testAuthorizationPersistenceAndRevocation() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let issued = try fixture.authorize()
        XCTAssertEqual(issued.token.utf8.count, 46)
        XCTAssertEqual(fixture.auth.client(forBearerToken: issued.token)?.id, issued.client.id)
        XCTAssertNil(fixture.auth.client(forBearerToken: String(repeating: "x", count: 46)))
        let reopened = try MCPAuthorizationStore(persistence: fixture.persistence)
        XCTAssertEqual(reopened.client(forBearerToken: issued.token)?.id, issued.client.id)
        try fixture.auth.revoke(id: issued.client.id)
        XCTAssertNil(fixture.auth.client(forBearerToken: issued.token))
        XCTAssertNil(try MCPAuthorizationStore(persistence: fixture.persistence).client(forBearerToken: issued.token))
        XCTAssertThrowsError(try fixture.router.listTools(clientID: issued.client.id))
    }

    func testAllElevenToolRoutesWithIndependentCreatesAndRevisionCheck() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let issued = try fixture.authorize()
        let clientID = issued.client.id
        let definitions = try fixture.router.listTools(clientID: clientID)
        XCTAssertEqual(Set(definitions.compactMap { $0["name"] as? String }), MCPToolRouter.toolNames)
        XCTAssertEqual(definitions.count, 11)
        let board = try fixture.router.call(name: "create_pinboard", arguments: ["name": "Board A"], clientID: clientID)
        let boardID = try XCTUnwrap(board["id"] as? String)
        let created = try fixture.router.call(name: "create_item", arguments: ["text": "Synthetic clipboard entry"], clientID: clientID)
        let itemID = try XCTUnwrap(created["id"] as? String)
        let duplicate = try fixture.router.call(name: "create_item", arguments: ["text": "Synthetic clipboard entry"], clientID: clientID)
        XCTAssertNotEqual(itemID, duplicate["id"] as? String)
        let search = try fixture.router.call(name: "search", arguments: ["query": "Synthetic"], clientID: clientID)
        XCTAssertEqual((search["items"] as? [[String: Any]])?.count, 2)
        let read = try fixture.router.call(name: "read_item", arguments: ["id": itemID], clientID: clientID)
        let revision = try XCTUnwrap(read["revision"] as? Int)
        let update = try fixture.router.call(name: "update_item", arguments: ["id": itemID, "expectedRevision": revision, "text": "Updated"], clientID: clientID)
        XCTAssertEqual(update["revision"] as? Int, revision + 1)
        XCTAssertThrowsError(try fixture.router.call(name: "update_item", arguments: ["id": itemID, "expectedRevision": revision, "text": "Stale"], clientID: clientID))
        _ = try fixture.router.call(name: "add_item_to_pinboard", arguments: ["itemId": itemID, "pinboardId": boardID], clientID: clientID)
        _ = try fixture.router.call(name: "rename_pinboard", arguments: ["id": boardID, "name": "Renamed"], clientID: clientID)
        let listed = try fixture.router.call(name: "list_pinboards", arguments: [:], clientID: clientID)
        XCTAssertEqual((listed["pinboards"] as? [[String: Any]])?.first?["name"] as? String, "Renamed")
        _ = try fixture.router.call(name: "remove_item_from_pinboard", arguments: ["itemId": itemID], clientID: clientID)
        _ = try fixture.router.call(name: "delete_item", arguments: ["id": itemID], clientID: clientID)
        _ = try fixture.router.call(name: "delete_pinboard", arguments: ["id": boardID, "deleteItems": true], clientID: clientID)
        XCTAssertNil(try fixture.store.item(id: XCTUnwrap(UUID(uuidString: itemID))))
        XCTAssertTrue(try fixture.store.pinboards().isEmpty)
    }

    func testReadOnlyAndScopedHistoryCannotBypassBoardAccess() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let allowed = try fixture.store.createPinboard(name: "Allowed")
        let forbidden = try fixture.store.createPinboard(name: "Forbidden")
        let plain = try fixture.store.create(ClipboardRecord(text: "public fixture"))
        let allowedItem = try fixture.store.create(ClipboardRecord(text: "allowed fixture", pinboardID: allowed.id))
        let hidden = try fixture.store.create(ClipboardRecord(text: "hidden fixture", pinboardID: forbidden.id, isInHistory: true))
        let issued = try fixture.authorize([.read], scope: .init(includeHistory: true, pinboardIDs: [allowed.id]))
        let definitions = try fixture.router.listTools(clientID: issued.client.id)
        XCTAssertEqual(Set(definitions.compactMap { $0["name"] as? String }), ["search", "read_item", "list_pinboards"])
        XCTAssertThrowsError(try fixture.router.call(name: "create_item", arguments: ["text": "blocked"], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "delete_item", arguments: ["id": plain.id.uuidString], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "read_item", arguments: ["id": hidden.id.uuidString], clientID: issued.client.id))
        let results = try fixture.router.call(name: "search", arguments: ["query": "fixture"], clientID: issued.client.id)
        let IDs = Set((results["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        XCTAssertEqual(IDs, [plain.id.uuidString, allowedItem.id.uuidString])
        try fixture.auth.updateClient(id: issued.client.id, permissions: [.read], scope: .init(pinboardIDs: [allowed.id]))
        XCTAssertThrowsError(try fixture.router.call(name: "read_item", arguments: ["id": plain.id.uuidString], clientID: issued.client.id))
    }

    func testMutationsCannotMoveItemsOutsideScopeAndCreateDoesNotMergeHiddenRecord() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let allowed = try fixture.store.createPinboard(name: "Allowed")
        let hidden = try fixture.store.createPinboard(name: "Hidden")
        let issued = try fixture.authorize([.read, .write, .delete], scope: .init(pinboardIDs: [allowed.id]))
        let previous = try fixture.store.create(ClipboardRecord(text: "same", sourceApp: "MCP: \(issued.client.name)", pinboardID: hidden.id))
        let created = try fixture.router.call(name: "create_item", arguments: ["text": "same", "pinboardId": allowed.id.uuidString], clientID: issued.client.id)
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertNotEqual(id, previous.id.uuidString)
        XCTAssertEqual(try fixture.store.item(id: previous.id)?.pinboardID, hidden.id)
        XCTAssertThrowsError(try fixture.router.call(name: "add_item_to_pinboard", arguments: ["itemId": id, "pinboardId": hidden.id.uuidString], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "remove_item_from_pinboard", arguments: ["itemId": id], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "delete_pinboard", arguments: ["id": allowed.id.uuidString], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "create_pinboard", arguments: ["name": "outside"], clientID: issued.client.id))
    }

    func testPaginationAndArgumentsAreBounded() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let issued = try fixture.authorize()
        for number in 0..<7 { try fixture.store.create(ClipboardRecord(text: "page \(number)")) }
        let first = try fixture.router.call(name: "search", arguments: ["limit": 3], clientID: issued.client.id)
        let cursor = try XCTUnwrap(first["nextCursor"] as? String)
        let second = try fixture.router.call(name: "search", arguments: ["limit": 3, "cursor": cursor], clientID: issued.client.id)
        let firstIDs = Set((first["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let secondIDs = Set((second["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        XCTAssertEqual(firstIDs.count, 3)
        XCTAssertEqual(secondIDs.count, 3)
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))
        for badLimit in [0, -1, 101, true, 1.5] as [Any] {
            XCTAssertThrowsError(try fixture.router.call(name: "search", arguments: ["limit": badLimit], clientID: issued.client.id))
        }
        XCTAssertThrowsError(try fixture.router.call(name: "search", arguments: ["cursor": "invalid"], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "search", arguments: ["unexpected": "value"], clientID: issued.client.id))
        XCTAssertThrowsError(try fixture.router.call(name: "create_item", arguments: ["text": String(repeating: "a", count: 32_769)], clientID: issued.client.id))
    }

    func testReadOmitsBinaryAndBoundsText() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let issued = try fixture.authorize()
        let record = try fixture.store.create(ClipboardRecord(text: String(repeating: "中", count: 20_000), rtf: Data("RTF".utf8),
                                                              parts: [ClipboardPart(representations: [.init(typeIdentifier: "public.png", data: Data(repeating: 7, count: 65_536))])]))
        let result = try fixture.router.call(name: "read_item", arguments: ["id": record.id.uuidString], clientID: issued.client.id)
        XCTAssertLessThanOrEqual((result["text"] as? String)?.utf8.count ?? Int.max, 32_768)
        XCTAssertEqual(result["textTruncated"] as? Bool, true)
        XCTAssertEqual(result["binaryIncluded"] as? Bool, false)
        XCTAssertNil(result["rtf"])
        XCTAssertNil(result["parts"])
        XCTAssertEqual(result["representationTypes"] as? [[String]], [["public.png"]])
    }
}
