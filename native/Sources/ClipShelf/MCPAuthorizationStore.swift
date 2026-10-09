import CryptoKit
import Foundation
import Security

@MainActor
protocol MCPAuthorizationPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Production credentials live only in the user's local, non-synchronizing Keychain.
@MainActor
final class MCPKeychainPersistence: MCPAuthorizationPersistence {
    private let service: String
    init(service: String = "app.clipshelf.mcp.authorizations") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "client-grants-v1",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MCPAuthorizationStore.AuthorizationError.keychain(status)
        }
        return data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(request as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MCPAuthorizationStore.AuthorizationError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw MCPAuthorizationStore.AuthorizationError.keychain(status)
        }
    }
}

@MainActor
final class MCPAuthorizationStore {
    enum Permission: String, Codable, CaseIterable, Sendable { case read, write, delete }

    struct AccessScope: Codable, Equatable, Sendable {
        /// Applies to unpinned history only. A pinned record always needs board access.
        var includeHistory: Bool
        var allPinboards: Bool
        var pinboardIDs: Set<UUID>

        init(includeHistory: Bool = false, allPinboards: Bool = false, pinboardIDs: Set<UUID> = []) {
            self.includeHistory = includeHistory
            self.allPinboards = allPinboards
            self.pinboardIDs = pinboardIDs
        }

        static let all = AccessScope(includeHistory: true, allPinboards: true)

        func permits(boardID: UUID) -> Bool { allPinboards || pinboardIDs.contains(boardID) }
        func permits(pinboardID: UUID?, isInHistory: Bool) -> Bool {
            if let pinboardID { return permits(boardID: pinboardID) }
            return includeHistory && isInHistory
        }
    }

    struct Client: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        var permissions: Set<Permission>
        var scope: AccessScope
        let createdAt: Date
        var lastUsedAt: Date?
    }

    struct IssuedClient {
        let client: Client
        /// Returned once for explicit presentation. Never put this in history or logs.
        let token: String
    }

    struct OAuthTokens {
        let client: Client
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    enum AuthorizationError: LocalizedError {
        case invalidGrant, tooManyClients, unknownClient, corruptedStorage, randomFailure, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidGrant: return "请填写客户端名称，并明确选择读取权限和访问范围。"
            case .tooManyClients: return "MCP 客户端数量已达上限，请先撤销不用的客户端。"
            case .unknownClient: return "找不到该 MCP 客户端授权。"
            case .corruptedStorage: return "MCP 授权记录无法读取，服务保持关闭。"
            case .randomFailure: return "无法生成安全的 MCP 凭证。"
            case .keychain(let status): return "无法访问 MCP 钥匙串记录（\(status)）。"
            }
        }
    }

    private struct Credential: Codable {
        var client: Client
        var token: String
        // Optional fields preserve existing static-token Keychain records.
        var expiresAt: Date?
        var resource: String?
        var oauthClientID: String?
        var refreshToken: String?
        var refreshExpiresAt: Date?
        var consumedRefreshDigests: [String]?
    }
    private let persistence: any MCPAuthorizationPersistence
    private var credentials: [Credential]
    private let now: () -> Date
    var onChange: (() -> Void)?
    var clients: [Client] { credentials.map(\.client).sorted { $0.createdAt < $1.createdAt } }

    convenience init() throws { try self.init(persistence: MCPKeychainPersistence()) }

    init(persistence: any MCPAuthorizationPersistence, now: @escaping () -> Date = Date.init) throws {
        self.persistence = persistence
        self.now = now
        if let data = try persistence.load() {
            guard data.count <= 1_048_576,
                  let decoded = try? JSONDecoder().decode([Credential].self, from: data),
                  decoded.count <= 128,
                  Set(decoded.map(\.client.id)).count == decoded.count,
                  decoded.allSatisfy({ $0.token.hasPrefix("cs_") && $0.token.utf8.count == 46 }) else {
                throw AuthorizationError.corruptedStorage
            }
            credentials = decoded
        } else {
            credentials = []
        }
    }

    func authorizeClient(name: String, permissions: Set<Permission>, scope: AccessScope) throws -> IssuedClient {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(name: trimmed, permissions: permissions, scope: scope)
        guard credentials.count < 128 else { throw AuthorizationError.tooManyClients }
        let token = try Self.randomToken(prefix: "cs_")
        let client = Client(id: UUID(), name: trimmed, permissions: permissions, scope: scope,
                            createdAt: now(), lastUsedAt: nil)
        try persist(credentials + [Credential(client: client, token: token)])
        return IssuedClient(client: client, token: token)
    }

    func updateClient(id: UUID, permissions: Set<Permission>, scope: AccessScope) throws {
        guard let index = credentials.firstIndex(where: { $0.client.id == id }) else { throw AuthorizationError.unknownClient }
        try validate(name: credentials[index].client.name, permissions: permissions, scope: scope)
        var next = credentials
        next[index].client.permissions = permissions
        next[index].client.scope = scope
        try persist(next)
    }

    func revoke(id: UUID) throws {
        guard credentials.contains(where: { $0.client.id == id }) else { return }
        try persist(credentials.filter { $0.client.id != id })
    }

    func client(id: UUID) -> Client? {
        credentials.first { $0.client.id == id && ($0.expiresAt == nil || $0.expiresAt! > now()) }?.client
    }

    func client(forBearerToken token: String, resource: String? = nil) -> Client? {
        guard token.utf8.count == 46, token.hasPrefix("cs_") else { return nil }
        let digest = Array(SHA256.hash(data: Data(token.utf8)))
        var matchedIndex: Int?
        for (index, credential) in credentials.enumerated() {
            let stored = Array(SHA256.hash(data: Data(credential.token.utf8)))
            var difference: UInt8 = 0
            for offset in digest.indices { difference |= digest[offset] ^ stored[offset] }
            if difference == 0 { matchedIndex = index }
        }
        guard let matchedIndex else { return nil }
        let credential = credentials[matchedIndex]
        guard credential.expiresAt == nil || credential.expiresAt! > now(),
              credential.resource == nil || credential.resource == resource else { return nil }
        credentials[matchedIndex].client.lastUsedAt = now()
        return credentials[matchedIndex].client
    }

    func isOAuthClient(id: UUID) -> Bool { credentials.first { $0.client.id == id }?.oauthClientID != nil }

    /// Called only after explicit native consent and successful one-use PKCE redemption.
    func authorizeOAuthClient(name: String, permissions: Set<Permission>, scope: AccessScope,
                              oauthClientID: String, resource: String) throws -> OAuthTokens {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(name: trimmed, permissions: permissions, scope: scope)
        guard credentials.count < 128 else { throw AuthorizationError.tooManyClients }
        let client = Client(id: UUID(), name: trimmed, permissions: permissions, scope: scope,
                            createdAt: now(), lastUsedAt: nil)
        let access = try Self.randomToken(prefix: "cs_")
        let refresh = try Self.randomToken(prefix: "csr_")
        let credential = Credential(client: client, token: access, expiresAt: now().addingTimeInterval(600),
                                    resource: resource, oauthClientID: oauthClientID, refreshToken: refresh,
                                    refreshExpiresAt: now().addingTimeInterval(604_800), consumedRefreshDigests: [])
        try persist(credentials + [credential])
        return OAuthTokens(client: client, accessToken: access, refreshToken: refresh, expiresIn: 600)
    }

    func refreshOAuthClient(token: String, oauthClientID: String, resource: String,
                            permissions: Set<Permission>? = nil) throws -> OAuthTokens {
        let digest = Self.tokenDigest(token)
        // A replay revokes the complete grant family, including its current access token.
        if let replay = credentials.first(where: {
            $0.oauthClientID == oauthClientID && $0.resource == resource && ($0.consumedRefreshDigests ?? []).contains(digest)
        }) {
            try revoke(id: replay.client.id)
            throw AuthorizationError.invalidGrant
        }
        guard let index = credentials.firstIndex(where: {
            $0.oauthClientID == oauthClientID && $0.resource == resource &&
            $0.refreshToken.map { Self.constantTimeEqual($0, token) } == true
        }), let expiry = credentials[index].refreshExpiresAt, expiry > now() else { throw AuthorizationError.invalidGrant }
        var next = credentials
        if let permissions {
            guard permissions.contains(.read), permissions.isSubset(of: next[index].client.permissions) else { throw AuthorizationError.invalidGrant }
            next[index].client.permissions = permissions
        }
        // Bound replay records and require fresh consent when the family reaches the limit.
        guard (next[index].consumedRefreshDigests ?? []).count < 1_024 else {
            try revoke(id: next[index].client.id)
            throw AuthorizationError.invalidGrant
        }
        next[index].consumedRefreshDigests = (next[index].consumedRefreshDigests ?? []) + [digest]
        next[index].token = try Self.randomToken(prefix: "cs_")
        next[index].refreshToken = try Self.randomToken(prefix: "csr_")
        next[index].expiresAt = now().addingTimeInterval(600)
        try persist(next)
        return OAuthTokens(client: next[index].client, accessToken: next[index].token,
                           refreshToken: next[index].refreshToken!, expiresIn: 600)
    }

    func revokeOAuthToken(_ token: String, oauthClientID: String) throws {
        let digest = Self.tokenDigest(token)
        guard let credential = credentials.first(where: {
            $0.oauthClientID == oauthClientID && (Self.constantTimeEqual($0.token, token) ||
                $0.refreshToken.map { Self.constantTimeEqual($0, token) } == true ||
                ($0.consumedRefreshDigests ?? []).contains(digest))
        }) else { return } // RFC 7009 deliberately gives no token-existence oracle.
        try revoke(id: credential.client.id)
    }

    static func randomToken(prefix: String = "") throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthorizationError.randomFailure }
        return prefix + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func tokenDigest(_ token: String) -> String { Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString() }
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(SHA256.hash(data: Data(lhs.utf8))), right = Array(SHA256.hash(data: Data(rhs.utf8)))
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func validate(name: String, permissions: Set<Permission>, scope: AccessScope) throws {
        guard !name.isEmpty, name.utf8.count <= 128, permissions.contains(.read),
              scope.pinboardIDs.count <= 128,
              scope.includeHistory || scope.allPinboards || !scope.pinboardIDs.isEmpty else {
            throw AuthorizationError.invalidGrant
        }
    }

    private func persist(_ next: [Credential]) throws {
        let data = try JSONEncoder().encode(next)
        guard data.count <= 1_048_576 else { throw AuthorizationError.tooManyClients }
        try persistence.save(data)
        credentials = next
        onChange?()
    }
}
