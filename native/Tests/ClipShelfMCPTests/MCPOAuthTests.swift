import Foundation
@testable import ClipShelf
import XCTest

private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class MCPOAuthTests: XCTestCase {
    private let verifier = String(repeating: "a", count: 43)
    private let redirect = "http://127.0.0.1:49123/callback"

    func testDiscoveryDCRAndAbsentConsentHandlerDenyWithoutGrant() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        let endpoint = try await server.start()
        defer { server.stop() }
        let missing = try await send(endpoint, path: "/mcp", method: "GET")
        XCTAssertEqual(missing.response.statusCode, 401)
        XCTAssertTrue(missing.response.value(forHTTPHeaderField: "WWW-Authenticate")!.contains("resource_metadata="))
        let resource = try await send(endpoint, path: "/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(resource.json?["resource"] as? String, endpoint.absoluteString)
        let metadata = try await send(endpoint, path: "/.well-known/oauth-authorization-server")
        XCTAssertEqual(metadata.json?["code_challenge_methods_supported"] as? [String], ["S256"])
        XCTAssertEqual(metadata.json?["client_id_metadata_document_supported"] as? Bool, false)
        let clientID = try await register(endpoint)
        let denied = try await authorize(endpoint, clientID: clientID)
        XCTAssertEqual(denied.response.statusCode, 302)
        let fields = try locationFields(denied.response)
        XCTAssertEqual(fields["error"], "access_denied")
        XCTAssertEqual(fields["state"], "opaque-client-state")
        XCTAssertNil(fields["code"])
        XCTAssertTrue(fixture.auth.clients.isEmpty)
    }

    func testHTTPPKCEConsentScopeRefreshRotationAndRevocation() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        var prompts = 0
        server.onAuthorizationRequest = { request in
            prompts += 1
            XCTAssertEqual(request.requestedPermissions, [.read, .write])
            XCTAssertEqual(request.redirectURI.absoluteString, self.redirect)
            return MCPOAuthApproval(permissions: [.read], scope: .init(includeHistory: true))
        }
        let endpoint = try await server.start()
        defer { server.stop() }
        let clientID = try await register(endpoint)
        let authorized = try await authorize(endpoint, clientID: clientID, overrides: ["scope": "read write"])
        let code = try XCTUnwrap(locationFields(authorized.response)["code"])
        XCTAssertTrue(fixture.auth.clients.isEmpty, "Consent alone must not expose a usable credential.")
        let redeemed = try await exchange(endpoint, clientID: clientID, code: code)
        XCTAssertEqual(redeemed.response.statusCode, 200)
        let access = try XCTUnwrap(redeemed.json?["access_token"] as? String)
        let refresh = try XCTUnwrap(redeemed.json?["refresh_token"] as? String)
        XCTAssertEqual(redeemed.json?["scope"] as? String, "read")
        XCTAssertEqual(redeemed.json?["expires_in"] as? Int, 600)
        XCTAssertEqual(prompts, 1)
        XCTAssertNil(fixture.auth.client(forBearerToken: access), "OAuth token needs its audience.")
        XCTAssertNotNil(fixture.auth.client(forBearerToken: access, resource: endpoint.absoluteString))
        let initialized = try await send(endpoint, path: "/mcp", method: "POST", json: initialize(), headers: ["Authorization": "Bearer \(access)"])
        let session = try XCTUnwrap(initialized.response.value(forHTTPHeaderField: "MCP-Session-Id"))
        let headers = ["Authorization": "Bearer \(access)", "MCP-Session-Id": session]
        _ = try await send(endpoint, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: headers)
        let write = try await send(endpoint, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "create_item", "arguments": ["text": "never written"]]], headers: headers)
        XCTAssertEqual(write.response.statusCode, 403)
        XCTAssertTrue(write.response.value(forHTTPHeaderField: "WWW-Authenticate")!.contains("insufficient_scope"))
        XCTAssertTrue(try fixture.store.load().isEmpty)
        let rotated = try await send(endpoint, path: "/oauth/token", method: "POST", form: ["grant_type": "refresh_token", "client_id": clientID, "resource": endpoint.absoluteString, "refresh_token": refresh])
        let newAccess = try XCTUnwrap(rotated.json?["access_token"] as? String)
        XCTAssertNotEqual(newAccess, access)
        XCTAssertNil(fixture.auth.client(forBearerToken: access, resource: endpoint.absoluteString))
        XCTAssertNotNil(fixture.auth.client(forBearerToken: newAccess, resource: endpoint.absoluteString))
        let replay = try await send(endpoint, path: "/oauth/token", method: "POST", form: ["grant_type": "refresh_token", "client_id": clientID, "resource": endpoint.absoluteString, "refresh_token": refresh])
        XCTAssertEqual(replay.json?["error"] as? String, "invalid_grant")
        XCTAssertNil(fixture.auth.client(forBearerToken: newAccess, resource: endpoint.absoluteString))
        let revoked = try await send(endpoint, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 3, "method": "ping"], headers: ["Authorization": "Bearer \(newAccess)", "MCP-Session-Id": session])
        XCTAssertEqual(revoked.response.statusCode, 401)
    }

    func testHTTPRejectsUnregisteredRedirectPlainPKCEDuplicateParametersAndRemoteDCR() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        var prompted = false
        server.onAuthorizationRequest = { _ in prompted = true; return nil }
        let endpoint = try await server.start()
        defer { server.stop() }
        let remote = try await send(endpoint, path: "/oauth/register", method: "POST", json: ["redirect_uris": ["https://example.com/callback"]])
        XCTAssertEqual(remote.json?["error"] as? String, "invalid_client_metadata")
        let clientID = try await register(endpoint)
        for changes in [["redirect_uri": "http://127.0.0.1:49123/wrong"], ["code_challenge_method": "plain"], ["resource": "http://127.0.0.1:1/mcp"], ["scope": "read admin"]] {
            let result = try await authorize(endpoint, clientID: clientID, overrides: changes)
            XCTAssertEqual(result.response.statusCode, 400)
            XCTAssertNil(result.response.value(forHTTPHeaderField: "Location"))
        }
        let duplicate = try await send(endpoint, path: "/oauth/authorize?client_id=one&client_id=two")
        XCTAssertEqual(duplicate.response.statusCode, 400)
        let hostile = try await send(endpoint, path: "/oauth/register", method: "POST", json: ["redirect_uris": [redirect]], headers: ["Origin": "https://attacker.invalid"])
        XCTAssertEqual(hostile.response.statusCode, 403)
        XCTAssertFalse(prompted)
        XCTAssertTrue(fixture.auth.clients.isEmpty)
    }

    func testCodeIsSingleUseAndBoundToVerifierClientRedirectAndResource() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        server.onAuthorizationRequest = { _ in MCPOAuthApproval(permissions: [.read], scope: .init(includeHistory: true)) }
        let endpoint = try await server.start()
        defer { server.stop() }
        let clientID = try await register(endpoint)
        for overrides in [["code_verifier": String(repeating: "b", count: 43)], ["client_id": "another"], ["redirect_uri": "http://127.0.0.1:49124/callback"]] {
            let authorized = try await authorize(endpoint, clientID: clientID)
            let code = try XCTUnwrap(locationFields(authorized.response)["code"])
            let wrong = try await exchange(endpoint, clientID: clientID, code: code, overrides: overrides)
            XCTAssertEqual(wrong.json?["error"] as? String, "invalid_grant")
            let retry = try await exchange(endpoint, clientID: clientID, code: code)
            XCTAssertEqual(retry.json?["error"] as? String, "invalid_grant")
        }
        let authorized = try await authorize(endpoint, clientID: clientID)
        let code = try XCTUnwrap(locationFields(authorized.response)["code"])
        let wrongResource = try await exchange(endpoint, clientID: clientID, code: code, overrides: ["resource": "http://127.0.0.1:2/mcp"])
        XCTAssertEqual(wrongResource.response.statusCode, 400)
        let valid = try await exchange(endpoint, clientID: clientID, code: code)
        XCTAssertEqual(valid.response.statusCode, 200)
        let repeated = try await exchange(endpoint, clientID: clientID, code: code)
        XCTAssertEqual(repeated.json?["error"] as? String, "invalid_grant")
        XCTAssertEqual(fixture.auth.clients.count, 1)
    }

    func testOAuthExpiryPersistenceScopeNarrowingAndExplicitRevoke() async throws {
        let persistence = MemoryMCPCredentials()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = try MCPAuthorizationStore(persistence: persistence, now: { now })
        let resource = "http://127.0.0.1:12345/mcp"
        let issued = try auth.authorizeOAuthClient(name: "Synthetic", permissions: [.read, .write], scope: .init(includeHistory: true), oauthClientID: "local-client", resource: resource)
        XCTAssertNotNil(try MCPAuthorizationStore(persistence: persistence, now: { now }).client(forBearerToken: issued.accessToken, resource: resource))
        now.addTimeInterval(601)
        XCTAssertNil(auth.client(forBearerToken: issued.accessToken, resource: resource))
        XCTAssertNil(auth.client(id: issued.client.id))
        XCTAssertThrowsError(try auth.refreshOAuthClient(token: issued.refreshToken, oauthClientID: "other-client", resource: resource))
        XCTAssertThrowsError(try auth.refreshOAuthClient(token: issued.refreshToken, oauthClientID: "local-client", resource: resource, permissions: [.read, .delete]))
        let refreshed = try auth.refreshOAuthClient(token: issued.refreshToken, oauthClientID: "local-client", resource: resource, permissions: [.read])
        XCTAssertEqual(refreshed.client.permissions, [.read])
        try auth.revokeOAuthToken(refreshed.refreshToken, oauthClientID: "other-client")
        XCTAssertNotNil(auth.client(forBearerToken: refreshed.accessToken, resource: resource))
        try auth.revokeOAuthToken(refreshed.refreshToken, oauthClientID: "local-client")
        XCTAssertNil(auth.client(forBearerToken: refreshed.accessToken, resource: resource))
        XCTAssertThrowsError(try auth.refreshOAuthClient(token: refreshed.refreshToken, oauthClientID: "local-client", resource: resource))
        let expiry = try auth.authorizeOAuthClient(name: "Expiry", permissions: [.read], scope: .all, oauthClientID: "local-client", resource: resource)
        now.addTimeInterval(604_801)
        XCTAssertThrowsError(try auth.refreshOAuthClient(token: expiry.refreshToken, oauthClientID: "local-client", resource: resource))
    }

    func testCoordinatorCodeExpiryLateApprovalAndResetAreFailClosed() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        var now = Date()
        let coordinator = MCPOAuthCoordinator(authorizationStore: fixture.auth, now: { now })
        let endpoint = URL(string: "http://127.0.0.1:12345/mcp")!
        let registration = await coordinator.handle(MCPHTTPRequest(method: "POST", path: "/oauth/register", headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: ["redirect_uris": [redirect]])), endpoint: endpoint)
        let clientID = try XCTUnwrap((try JSONSerialization.jsonObject(with: registration.body) as? [String: Any])?["client_id"] as? String)
        coordinator.onAuthorizationRequest = { _ in MCPOAuthApproval(permissions: [.read], scope: .all) }
        let query = encoded(authorizationFields(endpoint, clientID: clientID))
        let approved = await coordinator.handle(MCPHTTPRequest(method: "GET", path: "/oauth/authorize?" + query, headers: [:], body: Data()), endpoint: endpoint)
        let code = try XCTUnwrap(URLComponents(string: approved.headers["Location"]!)?.queryItems?.first(where: { $0.name == "code" })?.value)
        now.addTimeInterval(61)
        let form = encoded(["grant_type": "authorization_code", "client_id": clientID, "code": code, "redirect_uri": redirect, "resource": endpoint.absoluteString, "code_verifier": verifier])
        let expired = await coordinator.handle(MCPHTTPRequest(method: "POST", path: "/oauth/token", headers: ["content-type": "application/x-www-form-urlencoded"], body: Data(form.utf8)), endpoint: endpoint)
        XCTAssertEqual(expired.status, 400)
        coordinator.onAuthorizationRequest = { _ in now.addTimeInterval(181); return MCPOAuthApproval(permissions: [.read], scope: .all) }
        let late = await coordinator.handle(MCPHTTPRequest(method: "GET", path: "/oauth/authorize?" + query, headers: [:], body: Data()), endpoint: endpoint)
        XCTAssertTrue(late.headers["Location"]!.contains("access_denied"))
        coordinator.onAuthorizationRequest = { _ in coordinator.reset(); return MCPOAuthApproval(permissions: [.read], scope: .all) }
        let reset = await coordinator.handle(MCPHTTPRequest(method: "GET", path: "/oauth/authorize?" + query, headers: [:], body: Data()), endpoint: endpoint)
        XCTAssertTrue(reset.headers["Location"]!.contains("access_denied"))
        XCTAssertTrue(fixture.auth.clients.isEmpty)
    }

    func testNativeApprovalCannotEscalateRequestedPermissionsOrSelectEmptyScope() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        let endpoint = try await server.start()
        defer { server.stop() }
        let clientID = try await register(endpoint)
        for approval in [MCPOAuthApproval(permissions: [.read, .delete], scope: .all), MCPOAuthApproval(permissions: [.read], scope: .init())] {
            server.onAuthorizationRequest = { _ in approval }
            let result = try await authorize(endpoint, clientID: clientID)
            XCTAssertEqual(try locationFields(result.response)["error"], "access_denied")
        }
        XCTAssertTrue(fixture.auth.clients.isEmpty)
    }

    func testRevocationEndpointUnknownTokenAndCrossClientAreNonOracles() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        let endpoint = try await server.start()
        defer { server.stop() }
        let tokens = try fixture.auth.authorizeOAuthClient(name: "Synthetic", permissions: [.read], scope: .all, oauthClientID: "client", resource: endpoint.absoluteString)
        let wrong = try await send(endpoint, path: "/oauth/revoke", method: "POST", form: ["client_id": "wrong", "token": tokens.refreshToken])
        XCTAssertEqual(wrong.response.statusCode, 200)
        XCTAssertNotNil(fixture.auth.client(forBearerToken: tokens.accessToken, resource: endpoint.absoluteString))
        let revoked = try await send(endpoint, path: "/oauth/revoke", method: "POST", form: ["client_id": "client", "token": tokens.accessToken])
        XCTAssertEqual(revoked.response.statusCode, 200)
        XCTAssertNil(fixture.auth.client(forBearerToken: tokens.accessToken, resource: endpoint.absoluteString))
        let unknown = try await send(endpoint, path: "/oauth/revoke", method: "POST", form: ["client_id": "client", "token": "unknown"])
        XCTAssertEqual(unknown.response.statusCode, 200)
    }

    private func register(_ endpoint: URL) async throws -> String {
        let result = try await send(endpoint, path: "/oauth/register", method: "POST", json: ["client_name": "Synthetic OAuth client", "redirect_uris": [redirect], "token_endpoint_auth_method": "none"])
        XCTAssertEqual(result.response.statusCode, 201)
        return try XCTUnwrap(result.json?["client_id"] as? String)
    }
    private func authorizationFields(_ endpoint: URL, clientID: String) -> [String: String] {
        ["response_type": "code", "client_id": clientID, "redirect_uri": redirect, "resource": endpoint.absoluteString,
         "state": "opaque-client-state", "code_challenge": MCPOAuthCoordinator.challenge(for: verifier), "code_challenge_method": "S256", "scope": "read"]
    }
    private func authorize(_ endpoint: URL, clientID: String, overrides: [String: String] = [:]) async throws -> Reply {
        try await send(endpoint, path: "/oauth/authorize?" + encoded(authorizationFields(endpoint, clientID: clientID).merging(overrides) { _, new in new }))
    }
    private func exchange(_ endpoint: URL, clientID: String, code: String, overrides: [String: String] = [:]) async throws -> Reply {
        try await send(endpoint, path: "/oauth/token", method: "POST", form: ["grant_type": "authorization_code", "client_id": clientID, "code": code, "redirect_uri": redirect, "resource": endpoint.absoluteString, "code_verifier": verifier].merging(overrides) { _, new in new })
    }
    private func locationFields(_ response: HTTPURLResponse) throws -> [String: String] {
        let url = try XCTUnwrap(response.value(forHTTPHeaderField: "Location"))
        return Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(string: url)?.queryItems).map { ($0.name, $0.value ?? "") })
    }
    private func encoded(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted(by: { $0.key < $1.key }).map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    }
    private func initialize() -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "oauth-test", "version": "1"]]]
    }
    private typealias Reply = (response: HTTPURLResponse, json: [String: Any]?)
    private func send(_ endpoint: URL, path: String, method: String = "GET", json: [String: Any]? = nil,
                      form: [String: String]? = nil, headers: [String: String] = [:]) async throws -> Reply {
        let origin = "http://127.0.0.1:\(endpoint.port!)"
        var request = URLRequest(url: URL(string: origin + path)!)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let form { request.httpBody = Data(encoded(form).utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: OAuthNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }
}
