import ClipShelfCore
import CloudKit
import CryptoKit
import Foundation
import Security

struct CloudSyncConfiguration: Equatable, Sendable {
    let containerIdentifier: String?
    let zoneName: String
    init(containerIdentifier: String?, zoneName: String = "ClipShelfPrivateV1") {
        self.containerIdentifier = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.zoneName = zoneName
    }
    static func from(bundle: Bundle = .main) -> CloudSyncConfiguration {
        CloudSyncConfiguration(containerIdentifier: bundle.object(forInfoDictionaryKey: "ClipShelfCloudKitContainerIdentifier") as? String)
    }
}

enum CloudSyncAvailability: Equatable, Sendable {
    case disabled
    case available(accountID: String)
    case unavailable(String)
}

/// Private CloudKit transport. Construction does not create a container, inspect an account, or send network requests.
actor CloudSyncService: SyncOwnedFileTransport {
    private let store: HistoryStore
    private let configuration: CloudSyncConfiguration
    private var enabledAccount: String?
    private var container: CKContainer?
    private var coordinator: SyncCoordinator?
    static let recordType = "ClipShelfOperationV1"

    init(store: HistoryStore, configuration: CloudSyncConfiguration = .from()) {
        self.store = store
        self.configuration = configuration
    }

    func configurationStatus() -> CloudSyncAvailability {
        guard let identifier = configuration.containerIdentifier, !identifier.isEmpty else {
            return .unavailable("CloudKit 容器尚未配置。需要开发者配置自己的容器并签名后才能启用 iCloud 同步。")
        }
        guard identifier.hasPrefix("iCloud."), !configuration.zoneName.isEmpty else {
            return .unavailable("CloudKit 容器或记录区域配置无效。")
        }
        guard Self.hasCloudKitEntitlement(containerIdentifier: identifier) else {
            return .unavailable("此构建尚未签署所配置容器的 CloudKit 权限；本地历史仍可正常使用。")
        }
        return enabledAccount.map { .available(accountID: $0) } ?? .disabled
    }

    /// Call only in response to explicit user opt-in. Existing local history is included only when separately selected.
    func enable(includeLocalData: Bool = false, expectedAccountID: String? = nil) async throws -> String {
        if case .unavailable(let reason) = configurationStatus() { throw SyncError.unavailable(reason) }
        guard let identifier = configuration.containerIdentifier else { throw SyncError.disabled }
        let container = CKContainer(identifier: identifier)
        let account = try await resolveAccount(container)
        if let expectedAccountID, expectedAccountID != account { throw SyncError.accountChanged }
        let zone = CKRecordZone(zoneID: CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName))
        _ = try await container.privateCloudDatabase.save(zone)
        try store.configureSync(accountID: account, includeLocalData: includeLocalData)
        self.container = container
        enabledAccount = account
        coordinator = SyncCoordinator(store: store, transport: self)
        return account
    }

    func disable() throws {
        enabledAccount = nil
        coordinator = nil
        container = nil
        try store.configureSync(accountID: nil)
    }

    func synchronize() async throws -> SyncRunSummary {
        guard let enabledAccount, let coordinator else { throw SyncError.disabled }
        return try await coordinator.synchronize(accountID: enabledAccount)
    }

    func push(_ operations: [SyncOperation], accountID: String) async throws -> Set<UUID> {
        guard operations.count <= 100, Set(operations.map(\.operationID)).count == operations.count, operations.allSatisfy({ $0.accountID == accountID }) else { throw SyncError.invalidOperation }
        let container = try await checkedContainer(accountID: accountID)
        if operations.isEmpty { return [] }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ClipShelf-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
        var records: [CKRecord] = []
        var expectedRecords: [CKRecord.ID: CKRecord] = [:]
        for operation in operations {
            try await verifyOwnedDependencies(operation, accountID: accountID)
            let data = try Self.encodeOperation(operation)
            guard data.count <= 256 * 1_024 * 1_024 else { throw HistoryStoreError.valueTooLarge }
            let file = staging.appendingPathComponent(operation.operationID.uuidString + ".json")
            try data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: operation.operationID.uuidString, zoneID: zoneID))
            let digest = Self.digest(data)
            record["payload"] = CKAsset(fileURL: file)
            record["sha256"] = digest as NSString
            record["account"] = accountID as NSString
            let version = try CloudOperationCodec.version(data)
            record["formatVersion"] = version as NSNumber
            if version == 2 { record["payloadByteCount"] = data.count as NSNumber }
            expectedRecords[record.recordID] = record
            records.append(record)
        }
        let result = try await container.privateCloudDatabase.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        _ = try await checkedContainer(accountID: accountID)
        var acknowledged = Set<UUID>()
        var firstError: Error?
        for (id, outcome) in result.saveResults {
            guard let expected = expectedRecords[id], let uuid = UUID(uuidString: id.recordName) else { throw SyncError.invalidOperation }
            switch outcome {
            case .success(let record):
                guard CloudOperationCodec.matches(record, expected: expected) else { throw SyncError.invalidOperation }
                acknowledged.insert(uuid)
            case .failure(let error):
                // A retry after a lost response sees the already-created immutable record.
                if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged,
                   let server = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                   CloudOperationCodec.matches(server, expected: expected) {
                    acknowledged.insert(uuid)
                } else { firstError = firstError ?? error }
            }
        }
        if acknowledged.isEmpty, let firstError { throw firstError }
        return acknowledged
    }

    func pull(accountID: String, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        let container = try await checkedContainer(accountID: accountID)
        let token: CKServerChangeToken?
        if let cursor {
            guard cursor.count <= 1_024 * 1_024 else { throw SyncError.invalidCursor }
            token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: cursor)
            guard token != nil else { throw SyncError.invalidCursor }
        } else { token = nil }
        let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
        let result: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
        do {
            result = try await container.privateCloudDatabase.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: CloudOperationCodec.metadataKeys + CloudOwnedBlobCodec.metadataKeys, resultsLimit: max(1, min(100, limit)))
        } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
            // A full replay is safe because applied operation IDs and tombstones persist locally.
            return try await pull(accountID: accountID, after: nil, limit: limit)
        }
        _ = try await checkedContainer(accountID: accountID)
        let scope = blobScope(accountID: accountID)
        for deletion in result.deletions {
            guard CloudOwnedBlobCodec.isBlobDeletion(id: deletion.recordID, type: deletion.recordType, scope: scope) else {
                throw SyncError.unavailable("云端同步日志有缺失记录。为避免把缺失数据解释为删除，已停止并保留本地历史。")
            }
        }
        var operations: [SyncOperation] = []
        for (id, modification) in result.modificationResultsByID {
            let metadata = try modification.get().record
            guard metadata.recordID == id, id.zoneID == zoneID else { throw SyncError.invalidOperation }
            if metadata.recordType == CloudOwnedBlobCodec.recordType {
                try CloudOwnedBlobCodec.validateMetadata(metadata, scope: scope)
                continue
            }
            guard metadata.recordType == Self.recordType else { throw SyncError.invalidOperation }
            // Fetch one operation payload at a time; blob CKAssets are deliberately excluded
            // from the change feed and fetched only for durable inbox dependencies.
            let responses = try await container.privateCloudDatabase.records(for: [id], desiredKeys: CloudOperationCodec.metadataKeys + ["payload"])
            guard let response = responses[id] else { throw SyncError.invalidOperation }
            let record = try response.get()
            guard CloudOperationCodec.matches(record, expected: metadata) else { throw SyncError.invalidOperation }
            let operation = try Self.decodeOperation(record, accountID: accountID, zoneID: zoneID)
            _ = try await checkedContainer(accountID: accountID)
            operations.append(operation)
        }
        let next = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
        return SyncChangeBatch(operations: operations, cursor: next, hasMore: result.moreComing)
    }

    private func localOwnedScope(accountID: String) throws -> SyncOwnedFileScope {
        guard let identifier = configuration.containerIdentifier, enabledAccount == accountID,
              try store.syncConfiguration().accountID == accountID else { throw SyncError.accountChanged }
        return SyncOwnedFileScope(accountID: accountID, containerIdentifier: identifier, database: .privateDatabase,
                                  zoneOwnerName: CKCurrentUserDefaultName, zoneName: configuration.zoneName, namespace: accountID)
    }
    /// Local status only: settings never resolve an account or make CloudKit requests.
    func ownedFileTransferStates() throws -> [SyncOwnedTransferState] {
        guard let account = enabledAccount else { return [] }
        let scope = try localOwnedScope(accountID: account)
        return try store.syncOwnedTransferStates().filter { $0.scope == scope }
    }
    func ownedFileScope(accountID: String) async throws -> SyncOwnedFileScope {
        _ = try await checkedContainer(accountID: accountID)
        return try localOwnedScope(accountID: accountID)
    }
    private func blobScope(accountID: String) -> CloudOwnedBlobScope {
        CloudOwnedBlobScope(containerIdentifier: configuration.containerIdentifier ?? "", namespace: accountID,
                            zoneID: CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName), shared: false)
    }
    func uploadOwnedFile(_ upload: PreparedSyncOwnedUpload) async throws {
        let account = upload.scope.accountID
        let container = try await checkedContainer(accountID: account)
        guard upload.scope == (try localOwnedScope(accountID: account)) else { throw SyncError.namespaceConflict }
        try upload.file.validate()
        let scope = blobScope(accountID: account)
        let id = CloudOwnedBlobCodec.recordID(digest: upload.file.digest, scope: scope)
        let found = try await container.privateCloudDatabase.records(for: [id], desiredKeys: CloudOwnedBlobCodec.metadataKeys)
        _ = try await checkedContainer(accountID: account)
        guard let result = found[id] else { throw SyncError.invalidOperation }
        switch result {
        case .success(let record):
            guard CloudOwnedBlobCodec.matches(record, digest: upload.file.digest, byteCount: upload.file.byteCount, scope: scope) else { throw SyncError.invalidOperation }
            return
        case .failure(let error):
            guard (error as? CKError)?.code == .unknownItem else { throw error }
        }
        let staging = try CloudAssetStaging()
        let record = try CloudOwnedBlobCodec.encode(file: upload.fileURL, digest: upload.file.digest, byteCount: upload.file.byteCount, scope: scope, staging: staging)
        let saved = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        _ = try await checkedContainer(accountID: account)
        guard let outcome = saved.saveResults[id] else { throw SyncError.invalidOperation }
        let acknowledged: CKRecord
        do { acknowledged = try outcome.get() }
        catch {
            guard let cloud = error as? CKError, cloud.code == .serverRecordChanged,
                  let server = cloud.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else { throw error }
            acknowledged = server
        }
        guard CloudOwnedBlobCodec.matches(acknowledged, digest: upload.file.digest, byteCount: upload.file.byteCount, scope: scope) else { throw SyncError.invalidOperation }
        withExtendedLifetime(staging) {}
    }
    func downloadOwnedFile(_ request: SyncOwnedDownloadRequest) async throws -> SyncOwnedFileStaging {
        let account = request.scope.accountID
        let container = try await checkedContainer(accountID: account)
        guard request.scope == (try localOwnedScope(accountID: account)) else { throw SyncError.namespaceConflict }
        try request.file.validate()
        let scope = blobScope(accountID: account)
        let id = CloudOwnedBlobCodec.recordID(digest: request.file.digest, scope: scope)
        let records = try await container.privateCloudDatabase.records(for: [id], desiredKeys: CloudOwnedBlobCodec.metadataKeys + CloudOwnedBlobCodec.assetKeys)
        guard let response = records[id] else { throw SyncError.invalidOperation }
        let record = try response.get()
        // Copy before another await; CloudKit's temporary URLs must not survive the response.
        let temporary = try CloudAssetStaging()
        let file = try CloudOwnedBlobCodec.decode(record, digest: request.file.digest, byteCount: request.file.byteCount, scope: scope, staging: temporary)
        let lease = try SyncOwnedFileStaging.copy(from: file, descriptor: request.file)
        _ = try await checkedContainer(accountID: account)
        return lease
    }
    private func verifyOwnedDependencies(_ operation: SyncOperation, accountID: String) async throws {
        guard let manifest = operation.ownedFiles else { return }
        guard let record = operation.record else { throw SyncError.invalidOperation }
        try manifest.validate(record: record)
        let scope = blobScope(accountID: accountID)
        var checked = Set<String>()
        for file in manifest.files where checked.insert(file.digest).inserted {
            let container = try await checkedContainer(accountID: accountID)
            let id = CloudOwnedBlobCodec.recordID(digest: file.digest, scope: scope)
            let records = try await container.privateCloudDatabase.records(for: [id], desiredKeys: CloudOwnedBlobCodec.metadataKeys)
            _ = try await checkedContainer(accountID: accountID)
            guard let outcome = records[id], CloudOwnedBlobCodec.matches(try outcome.get(), digest: file.digest, byteCount: file.byteCount, scope: scope) else { throw SyncError.invalidOperation }
        }
    }
    static func decodeOperation(_ record: CKRecord, accountID: String, zoneID: CKRecordZone.ID) throws -> SyncOperation {
        try CloudOperationCodec.decode(record, type: recordType, namespace: accountID, shared: false, zone: zoneID)
    }

    private func checkedContainer(accountID: String) async throws -> CKContainer {
        guard enabledAccount == accountID, let container,
              try store.syncConfiguration().accountID == accountID else { throw SyncError.accountChanged }
        guard try await resolveAccount(container) == accountID else {
            try disable()
            throw SyncError.accountChanged
        }
        guard enabledAccount == accountID, try store.syncConfiguration().accountID == accountID else { throw SyncError.accountChanged }
        return container
    }

    private func resolveAccount(_ container: CKContainer) async throws -> String {
        guard try await container.accountStatus() == .available else {
            throw SyncError.unavailable("iCloud 账号当前不可用，请在系统设置中检查账号后重试。")
        }
        let user = try await container.userRecordID()
        return (configuration.containerIdentifier ?? "") + ":" + user.recordName
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encodeOperation(_ operation: SyncOperation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation)
    }

    static func hasCloudKitEntitlement(containerIdentifier: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String] else { return false }
        return containers.contains(containerIdentifier) && services.contains("CloudKit")
    }
}
