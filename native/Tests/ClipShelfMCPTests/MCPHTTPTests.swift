@testable import ClipShelf
import XCTest

@MainActor
final class MCPHTTPTests: XCTestCase {
    func testParserRejectsSmugglingAndBodyBoundaryViolations() async throws {
        let invalid = [
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 0\r\n\r\nextra",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 65537\r\n\r\n",
            "POST http://evil.example/mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 0\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n",
        ]
        for input in invalid { XCTAssertThrowsError(try MCPHTTPRequestParser.parse(Data(input.utf8))) }
        let incomplete = Data("POST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\nab".utf8)
        XCTAssertNil(try MCPHTTPRequestParser.parse(incomplete))
    }

    func testListenerBindsLoopbackAndRequiresAuthorizationHostAndOrigin() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        XCTAssertFalse(server.isRunning)
        let url = try await server.start()
        defer { server.stop() }
        XCTAssertEqual(url.host, "127.0.0.1")
        let issued = try fixture.authorize()
        let unauthorized = try await request(url, token: nil, body: initialize())
        XCTAssertEqual(unauthorized.response.statusCode, 401)
        let hostileOrigin = try await request(url, token: issued.token, body: initialize(), headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(hostileOrigin.response.statusCode, 403)
        let hostileHost = try await request(url, token: issued.token, body: initialize(), headers: ["Host": "evil.example"])
        XCTAssertEqual(hostileHost.response.statusCode, 403)
        let malformed = try await request(url, token: issued.token, rawBody: Data("{not json".utf8))
        XCTAssertEqual(malformed.response.statusCode, 400)
        let badAccept = try await request(url, token: issued.token, body: initialize(), headers: ["Accept": ";"])
        XCTAssertEqual(badAccept.response.statusCode, 400)
        let get = try await request(url, token: issued.token, method: "GET")
        XCTAssertEqual(get.response.statusCode, 405)
    }

    func testRealHTTPLifecycleToolCallAndRevocationOfExistingSession() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        let url = try await server.start()
        defer { server.stop() }
        let issued = try fixture.authorize([.read])
        let initialized = try await request(url, token: issued.token, body: initialize(version: "future-version"))
        XCTAssertEqual(initialized.response.statusCode, 200)
        let session = try XCTUnwrap(initialized.response.value(forHTTPHeaderField: "MCP-Session-Id"))
        let result = try XCTUnwrap(initialized.json?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        let headers = ["MCP-Session-Id": session, "MCP-Protocol-Version": "2025-11-25"]
        let beforeReady = try await request(url, token: issued.token, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: headers)
        XCTAssertNotNil(beforeReady.json?["error"])
        let ready = try await request(url, token: issued.token, body: ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: headers)
        XCTAssertEqual(ready.response.statusCode, 202)
        let listed = try await request(url, token: issued.token, body: ["jsonrpc": "2.0", "id": 3, "method": "tools/list"], headers: headers)
        let listResult = try XCTUnwrap(listed.json?["result"] as? [String: Any])
        XCTAssertEqual((listResult["tools"] as? [[String: Any]])?.count, 3)
        let write = try await request(url, token: issued.token, body: ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "create_item", "arguments": ["text": "must not write"]]], headers: headers)
        XCTAssertEqual((write.json?["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(try fixture.store.load().isEmpty)
        let badVersion = try await request(url, token: issued.token, body: ["jsonrpc": "2.0", "id": 5, "method": "ping"], headers: ["MCP-Session-Id": session, "MCP-Protocol-Version": "2024-11-05"])
        XCTAssertEqual(badVersion.response.statusCode, 400)
        try fixture.auth.revoke(id: issued.client.id)
        let revoked = try await request(url, token: issued.token, body: ["jsonrpc": "2.0", "id": 6, "method": "ping"], headers: headers)
        XCTAssertEqual(revoked.response.statusCode, 401)
    }

    private func initialize(version: String = "2025-11-25") -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]
    }

    private func request(_ url: URL, token: String?, body: [String: Any]? = nil,
                         rawBody: Data? = nil, headers: [String: String] = [:], method: String = "POST") async throws -> (response: HTTPURLResponse, json: [String: Any]?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        else if let rawBody { request.httpBody = rawBody }
        else if method == "POST" { request.httpBody = Data() }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }
}
