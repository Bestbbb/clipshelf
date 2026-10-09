import CryptoKit
import Foundation

struct MCPOAuthAuthorizationRequest: Sendable {
    let id: UUID
    let clientID: String
    /// Unverified, client-supplied display name; never present it as a verified identity.
    let clientName: String
    let redirectURI: URL
    let resource: URL
    let requestedPermissions: Set<MCPAuthorizationStore.Permission>
    let expiresAt: Date
}

struct MCPOAuthApproval: Sendable {
    let permissions: Set<MCPAuthorizationStore.Permission>
    let scope: MCPAuthorizationStore.AccessScope
}

struct MCPOAuthResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

/// Local native-client OAuth profile. HTTP loopback authorization endpoints are an
/// explicit compatibility limitation: MCP's HTTPS-AS requirement is not claimed.
@MainActor
final class MCPOAuthCoordinator {
    var onAuthorizationRequest: ((MCPOAuthAuthorizationRequest) async -> MCPOAuthApproval?)?
    private let authorizations: MCPAuthorizationStore
    private let now: () -> Date
    private var registrations: [String: Registration] = [:]
    private var codes: [String: Code] = [:]
    private var approvals: [UUID: PendingApproval] = [:]
    private var generation = UUID()

    private struct Registration {
        let id: String
        let name: String
        let redirectURIs: [String]
        let createdAt: Date
    }
    private struct Code {
        let registration: Registration
        let redirectURI: String
        let resource: String
        let challenge: String
        let approval: MCPOAuthApproval
        let expiresAt: Date
    }
    private struct PendingApproval {
        let continuation: CheckedContinuation<MCPOAuthApproval?, Never>
        let handler: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    private struct OAuthError: Error {
        let code: String
        let description: String
        var status = 400
    }

    init(authorizationStore: MCPAuthorizationStore, now: @escaping () -> Date = Date.init) {
        authorizations = authorizationStore
        self.now = now
    }

    func reset() {
        generation = UUID()
        codes.removeAll()
        registrations.removeAll()
        for id in Array(approvals.keys) { completeApproval(id, approval: nil) }
    }

    func handle(_ request: MCPHTTPRequest, endpoint: URL) async -> MCPOAuthResponse {
        let origin = "http://127.0.0.1:\(endpoint.port!)"
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        do {
            switch (request.method, path) {
            case ("GET", "/.well-known/oauth-protected-resource"), ("GET", "/.well-known/oauth-protected-resource/mcp"):
                guard !request.path.contains("?") else { throw invalidRequest() }
                return json(200, ["resource": endpoint.absoluteString, "authorization_servers": [origin],
                                  "scopes_supported": ["read"], "bearer_methods_supported": ["header"]])
            case ("GET", "/.well-known/oauth-authorization-server"):
                guard !request.path.contains("?") else { throw invalidRequest() }
                return json(200, ["issuer": origin, "authorization_endpoint": origin + "/oauth/authorize",
                                  "token_endpoint": origin + "/oauth/token", "registration_endpoint": origin + "/oauth/register",
                                  "revocation_endpoint": origin + "/oauth/revoke", "response_types_supported": ["code"],
                                  "grant_types_supported": ["authorization_code", "refresh_token"],
                                  "token_endpoint_auth_methods_supported": ["none"],
                                  "revocation_endpoint_auth_methods_supported": ["none"],
                                  "code_challenge_methods_supported": ["S256"], "scopes_supported": ["read", "write", "delete"],
                                  "authorization_response_iss_parameter_supported": true,
                                  "client_id_metadata_document_supported": false])
            case ("POST", "/oauth/register"):
                try requireContentType(request, "application/json")
                guard !request.path.contains("?"), let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw invalidRequest() }
                return try register(body)
            case ("GET", "/oauth/authorize"):
                let query = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                guard query.count == 2 else { throw invalidRequest() }
                return try await authorize(Self.decodeForm(String(query[1])), endpoint: endpoint)
            case ("POST", "/oauth/token"):
                return try token(parameters(request), endpoint: endpoint)
            case ("POST", "/oauth/revoke"):
                let form = try parameters(request)
                guard let clientID = form["client_id"], let token = form["token"], token.utf8.count <= 128 else { throw invalidRequest() }
                try authorizations.revokeOAuthToken(token, oauthClientID: clientID)
                return MCPOAuthResponse(status: 200)
            default:
                return json(404, ["error": "invalid_request", "error_description": "Unknown OAuth endpoint or method."])
            }
        } catch let error as OAuthError {
            return json(error.status, ["error": error.code, "error_description": error.description])
        } catch {
            return json(400, ["error": "invalid_grant", "error_description": "The authorization could not be completed."])
        }
    }

    private func register(_ body: [String: Any]) throws -> MCPOAuthResponse {
        registrations = registrations.filter { now().timeIntervalSince($0.value.createdAt) < 86_400 }
        guard registrations.count < 128 else { throw OAuthError(code: "temporarily_unavailable", description: "Registration limit reached.", status: 429) }
        let name = (body["client_name"] as? String ?? "Local OAuth client").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let redirects = body["redirect_uris"] as? [String], !redirects.isEmpty, redirects.count <= 5,
              redirects.allSatisfy(Self.isLoopbackRedirect),
              body["token_endpoint_auth_method"] == nil || body["token_endpoint_auth_method"] as? String == "none",
              body["response_types"] == nil || body["response_types"] as? [String] == ["code"],
              body["grant_types"] == nil || (body["grant_types"] as? [String]).map({ !$0.isEmpty && Set($0).isSubset(of: ["authorization_code", "refresh_token"]) && $0.contains("authorization_code") }) == true else {
            throw OAuthError(code: "invalid_client_metadata", description: "Only public native clients with HTTP loopback callbacks and authorization-code PKCE are supported.")
        }
        let id = try MCPAuthorizationStore.randomToken(prefix: "csc_")
        registrations[id] = Registration(id: id, name: name, redirectURIs: redirects, createdAt: now())
        return json(201, ["client_id": id, "client_id_issued_at": Int(now().timeIntervalSince1970), "client_name": name,
                          "redirect_uris": redirects, "token_endpoint_auth_method": "none",
                          "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]])
    }

    private func authorize(_ form: [String: String], endpoint: URL) async throws -> MCPOAuthResponse {
        guard let clientID = form["client_id"], let registration = registrations[clientID],
              now().timeIntervalSince(registration.createdAt) < 86_400,
              let redirect = form["redirect_uri"], Self.isLoopbackRedirect(redirect),
              registration.redirectURIs.contains(where: { Self.matchLoopbackRedirect($0, redirect) }) else {
            // Never redirect an invalid client/redirect pair.
            throw OAuthError(code: "invalid_request", description: "Unknown client or unregistered redirect URI.")
        }
        guard form["response_type"] == "code", form["resource"] == endpoint.absoluteString,
              let state = form["state"], !state.isEmpty, state.utf8.count <= 512,
              form["code_challenge_method"] == "S256", let challenge = form["code_challenge"],
              challenge.utf8.count == 43, challenge.allSatisfy({ Self.base64URL.contains($0) }) else { throw invalidRequest() }
        let permissions = try parsePermissions(form["scope"] ?? "read")
        codes = codes.filter { $0.value.expiresAt > now() }
        guard codes.count < 128, approvals.isEmpty else {
            throw OAuthError(code: "temporarily_unavailable", description: "Another authorization is pending. Try again after it finishes.", status: 429)
        }
        let request = MCPOAuthAuthorizationRequest(id: UUID(), clientID: clientID, clientName: registration.name,
            redirectURI: URL(string: redirect)!, resource: endpoint, requestedPermissions: permissions, expiresAt: now().addingTimeInterval(180))
        let currentGeneration = generation
        let approval = await requestApproval(request)
        guard generation == currentGeneration, request.expiresAt > now(), !Task.isCancelled,
              let approval, approval.permissions.contains(.read), approval.permissions.isSubset(of: permissions),
              approval.scope.includeHistory || approval.scope.allPinboards || !approval.scope.pinboardIDs.isEmpty,
              approval.scope.pinboardIDs.count <= 128 else {
            return redirectResponse(redirect, fields: ["error": "access_denied", "state": state, "iss": "http://127.0.0.1:\(endpoint.port!)"])
        }
        let code = try MCPAuthorizationStore.randomToken(prefix: "csa_")
        codes[code] = Code(registration: registration, redirectURI: redirect, resource: endpoint.absoluteString,
                           challenge: challenge, approval: approval, expiresAt: now().addingTimeInterval(60))
        return redirectResponse(redirect, fields: ["code": code, "state": state, "iss": "http://127.0.0.1:\(endpoint.port!)"])
    }

    private func requestApproval(_ request: MCPOAuthAuthorizationRequest) async -> MCPOAuthApproval? {
        guard let callback = onAuthorizationRequest else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let handler = Task { @MainActor [weak self] in
                    let result = await callback(request)
                    self?.completeApproval(request.id, approval: result)
                }
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.completeApproval(request.id, approval: nil)
                }
                approvals[request.id] = PendingApproval(continuation: continuation, handler: handler, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.completeApproval(request.id, approval: nil) }
        }
    }

    private func completeApproval(_ id: UUID, approval: MCPOAuthApproval?) {
        guard let pending = approvals.removeValue(forKey: id) else { return }
        pending.handler.cancel()
        pending.timeout.cancel()
        pending.continuation.resume(returning: approval)
    }

    private func token(_ form: [String: String], endpoint: URL) throws -> MCPOAuthResponse {
        guard let clientID = form["client_id"], form["resource"] == endpoint.absoluteString,
              form["client_secret"] == nil else { throw invalidRequest() }
        let issued: MCPAuthorizationStore.OAuthTokens
        switch form["grant_type"] {
        case "authorization_code":
            guard let value = form["code"], value.utf8.count <= 128,
                  let code = codes.removeValue(forKey: value), code.expiresAt > now(),
                  code.registration.id == clientID, form["redirect_uri"] == code.redirectURI,
                  code.resource == endpoint.absoluteString, let verifier = form["code_verifier"],
                  (43...128).contains(verifier.utf8.count), verifier.allSatisfy({ Self.verifierCharacters.contains($0) }),
                  Self.challenge(for: verifier) == code.challenge else {
                throw OAuthError(code: "invalid_grant", description: "Authorization code is expired, consumed, or incorrectly bound.")
            }
            issued = try authorizations.authorizeOAuthClient(name: code.registration.name, permissions: code.approval.permissions,
                scope: code.approval.scope, oauthClientID: clientID, resource: code.resource)
        case "refresh_token":
            guard let refresh = form["refresh_token"], refresh.utf8.count <= 128 else { throw invalidRequest() }
            issued = try authorizations.refreshOAuthClient(token: refresh, oauthClientID: clientID,
                resource: endpoint.absoluteString, permissions: try form["scope"].map(parsePermissions))
        default:
            throw OAuthError(code: "unsupported_grant_type", description: "Use authorization_code or refresh_token.")
        }
        return json(200, ["access_token": issued.accessToken, "token_type": "Bearer", "expires_in": issued.expiresIn,
                          "refresh_token": issued.refreshToken, "scope": issued.client.permissions.map(\.rawValue).sorted().joined(separator: " ")])
    }

    private func parameters(_ request: MCPHTTPRequest) throws -> [String: String] {
        try requireContentType(request, "application/x-www-form-urlencoded")
        guard !request.path.contains("?"), request.headers["authorization"] == nil,
              let string = String(data: request.body, encoding: .utf8) else { throw invalidRequest() }
        return try Self.decodeForm(string)
    }
    private func requireContentType(_ request: MCPHTTPRequest, _ expected: String) throws {
        guard request.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.lowercased() == expected else {
            throw OAuthError(code: "invalid_request", description: "Incorrect Content-Type.", status: 415)
        }
    }
    private func parsePermissions(_ scope: String) throws -> Set<MCPAuthorizationStore.Permission> {
        let words = scope.split(separator: " ").map(String.init)
        let permissions = Set(words.compactMap(MCPAuthorizationStore.Permission.init(rawValue:)))
        guard Set(words).count == permissions.count, permissions.contains(.read) else {
            throw OAuthError(code: "invalid_scope", description: "Supported scopes are read, write and delete; read is required.")
        }
        return permissions
    }
    private static let base64URL = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let verifierCharacters = base64URL.union(Set(".~"))
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeForm(_ input: String) throws -> [String: String] {
        guard input.utf8.count <= 65_536 else { throw OAuthError(code: "invalid_request", description: "Form too large.") }
        var result: [String: String] = [:]
        for pair in input.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !name.isEmpty, name.utf8.count <= 64, value.utf8.count <= 4_096, result[name] == nil,
                  result.count < 32, !name.contains("\0"), !value.contains("\0") else {
                throw OAuthError(code: "invalid_request", description: "Invalid or duplicate form parameter.")
            }
            result[name] = value
        }
        return result
    }
    private static func isLoopbackRedirect(_ string: String) -> Bool {
        guard string.utf8.count <= 2_048, let url = URLComponents(string: string),
              url.scheme == "http", ["127.0.0.1", "[::1]", "localhost"].contains(url.host ?? ""),
              let port = url.port, (1...65_535).contains(port), url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil, !url.path.isEmpty, url.path.hasPrefix("/"),
              !string.contains("\\"), !string.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { return false }
        return true
    }
    private static func matchLoopbackRedirect(_ registered: String, _ requested: String) -> Bool {
        // RFC 8252 permits an ephemeral loopback callback port; all other URI parts match exactly.
        guard var left = URLComponents(string: registered), var right = URLComponents(string: requested) else { return false }
        left.port = nil
        right.port = nil
        return left.string == right.string
    }
    private func redirectResponse(_ redirect: String, fields: [String: String]) -> MCPOAuthResponse {
        var components = URLComponents(string: redirect)!
        components.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return MCPOAuthResponse(status: 302, headers: ["Location": components.url!.absoluteString, "Referrer-Policy": "no-referrer"])
    }
    private func invalidRequest() -> OAuthError { OAuthError(code: "invalid_request", description: "Required parameters, resource, state or S256 challenge are invalid.") }
    private func json(_ status: Int, _ body: [String: Any]) -> MCPOAuthResponse {
        MCPOAuthResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data())
    }
}
