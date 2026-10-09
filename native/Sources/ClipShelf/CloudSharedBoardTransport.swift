import ClipShelfLocalization
import AppKit
import ClipShelfCore
import CloudKit
import Foundation

/// Each board has an independent zone and operation namespace. Construction is entirely local;
/// CloudKit is contacted only after an explicit sharing action and a signing/configuration check.
actor CloudSharedBoardTransport: SharedBoardLifecycleTransport, SharedBoardOwnedFileTransport {
    static let recordType = "ClipShelfSharedOperationV1"
    static let maximumPayloadBytes = 256 * 1_024 * 1_024
    private let configuration: CloudSyncConfiguration

    init(configuration: CloudSyncConfiguration = .from()) { self.configuration = configuration }

    func configurationStatus() -> CloudSyncAvailability {
        guard let identifier = configuration.containerIdentifier, identifier.hasPrefix("iCloud."), identifier.count > 7 else {
            return .unavailable(L10n.text("请先配置开发者自己的 CloudKit 容器，再启用共享板。"))
        }
        guard CloudSyncService.hasCloudKitEntitlement(containerIdentifier: identifier) else {
            return .unavailable(L10n.text("此构建未签署所配置容器的 CloudKit 权限，尚不能连接共享板。"))
        }
        return .disabled
    }

    func resolveAccount(expectedAccountID: String? = nil) async throws -> String {
        try await session(expectedAccountID: expectedAccountID).accountID
    }

    func access(for board: SharedBoardDescriptor) async throws -> SharedBoardAccess {
        let context = try await context(for: board)
        do { return Self.access(of: try await fetchShare(board, context: context), userRecordName: context.session.userRecordName) }
        catch {
            if Self.isRevocation(error) { return .revoked }
            throw error
        }
    }

    func push(_ operations: [SyncOperation], board: SharedBoardDescriptor) async throws -> Set<UUID> {
        guard operations.count <= 100, Set(operations.map(\.operationID)).count == operations.count else { throw SyncError.invalidOperation }
        try Self.validate(board, containerIdentifier: configuration.containerIdentifier)
        for operation in operations { try Self.validate(operation, board: board) }
        let context = try await context(for: board)
        let share: CKShare
        do { share = try await fetchShare(board, context: context) }
        catch { if Self.isRevocation(error) { throw SharedBoardError.remotePermissionDenied }; throw error }
        let role = Self.access(of: share, userRecordName: context.session.userRecordName)
        guard role.canWrite else { throw role == .revoked ? SharedBoardError.remotePermissionDenied : SharedBoardError.readOnly }
        if operations.isEmpty { return [] }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ClipShelf-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var records: [CKRecord] = [], expectedRecords: [CKRecord.ID: CKRecord] = [:]
        for operation in operations {
            try await verifyOwnedDependencies(operation, board: board, context: context)
            let data = try CloudSyncService.encodeOperation(operation)
            guard data.count <= Self.maximumPayloadBytes else { throw HistoryStoreError.valueTooLarge }
            let file = staging.appendingPathComponent(operation.operationID.uuidString + ".json")
            try data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: operation.operationID.uuidString, zoneID: context.zoneID))
            let hash = CloudSyncService.digest(data)
            record["payload"] = CKAsset(fileURL: file)
            record["sha256"] = hash as NSString
            record["namespace"] = board.namespace as NSString
            let version = try CloudOperationCodec.version(data)
            record["formatVersion"] = version as NSNumber
            if version == 2 { record["payloadByteCount"] = data.count as NSNumber }
            records.append(record); expectedRecords[record.recordID] = record
        }
        // The server remains authoritative if permissions change after fetching CKShare.
        let result = try await boardRequest(board, context: context, writing: true) {
            try await context.database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        }
        var acknowledged = Set<UUID>(), firstError: Error?
        for (id, outcome) in result.saveResults {
            guard let expected = expectedRecords[id], let operationID = UUID(uuidString: id.recordName) else { throw SyncError.invalidOperation }
            switch outcome {
            case .success(let record):
                guard CloudOperationCodec.matches(record, expected: expected) else { throw SyncError.invalidOperation }
                acknowledged.insert(operationID)
            case .failure(let error):
                if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }
                if let cloud = error as? CKError, cloud.code == .serverRecordChanged,
                   let record = cloud.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                   CloudOperationCodec.matches(record, expected: expected) {
                    acknowledged.insert(operationID)
                } else { firstError = firstError ?? error }
            }
        }
        if acknowledged.isEmpty, let firstError { throw firstError }
        return acknowledged
    }

    func pull(board: SharedBoardDescriptor, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        try Self.validate(board, containerIdentifier: configuration.containerIdentifier)
        let token = try Self.decodeCursor(cursor, board: board)
        return try await pull(board: board, token: token, limit: limit, mayResetExpiredToken: token != nil)
    }

    private func pull(board: SharedBoardDescriptor, token: CKServerChangeToken?, limit: Int, mayResetExpiredToken: Bool) async throws -> SyncChangeBatch {
        let context = try await context(for: board)
        do {
            let share = try await fetchShare(board, context: context)
            guard Self.access(of: share, userRecordName: context.session.userRecordName) != .revoked else { throw SharedBoardError.revoked }
        } catch { if Self.isRevocation(error) { throw SharedBoardError.revoked }; throw error }
        let result: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
        do {
            result = try await boardRequest(board, context: context, writing: false) {
                try await context.database.recordZoneChanges(inZoneWith: context.zoneID, since: token, desiredKeys: CloudOperationCodec.metadataKeys + CloudOwnedBlobCodec.metadataKeys, resultsLimit: max(1, min(100, limit)))
            }
        } catch let error as CKError where error.code == .changeTokenExpired && mayResetExpiredToken {
            // Applied IDs and tombstones persist locally, so a full immutable-log replay is safe.
            return try await pull(board: board, token: nil, limit: limit, mayResetExpiredToken: false)
        } catch { if Self.isRevocation(error) { throw SharedBoardError.revoked }; throw error }
        if result.deletions.contains(where: { $0.recordID.zoneID == context.zoneID && $0.recordID.recordName == board.shareRecordName }) { throw SharedBoardError.revoked }
        let scope = blobScope(board: board, context: context)
        for deletion in result.deletions {
            guard CloudOwnedBlobCodec.isBlobDeletion(id: deletion.recordID, type: deletion.recordType, scope: scope) else {
                throw SyncError.unavailable(L10n.text("共享板的云端操作日志不完整。已停止同步并保留本地内容。"))
            }
        }
        var operations: [SyncOperation] = []
        for (id, modification) in result.modificationResultsByID {
            let metadata: CKRecord
            do { metadata = try modification.get().record }
            catch { if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }; throw error }
            guard metadata.recordID == id, id.zoneID == context.zoneID else { throw SyncError.invalidOperation }
            if id.recordName == board.shareRecordName {
                guard metadata is CKShare else { throw SyncError.invalidOperation }
                continue
            }
            if metadata.recordType == CloudOwnedBlobCodec.recordType {
                try CloudOwnedBlobCodec.validateMetadata(metadata, scope: scope)
                continue
            }
            guard metadata.recordType == Self.recordType else { throw SyncError.invalidOperation }
            let operation = try await boardRequest(board, context: context, writing: false) {
                let records = try await context.database.records(for: [id], desiredKeys: CloudOperationCodec.metadataKeys + ["payload"])
                guard let result = records[id] else { throw SyncError.invalidOperation }
                let record = try result.get()
                guard CloudOperationCodec.matches(record, expected: metadata) else { throw SyncError.invalidOperation }
                return try Self.decodeOperation(record, board: board)
            }
            operations.append(operation)
        }
        return SyncChangeBatch(operations: operations, cursor: try Self.encodeCursor(result.changeToken, board: board), hasMore: result.moreComing)
    }

    func ownedFileScope(board: SharedBoardDescriptor) async throws -> SyncOwnedFileScope {
        let context = try await context(for: board)
        return ownedScope(board: board, context: context)
    }
    private func ownedScope(board: SharedBoardDescriptor, context: Context) -> SyncOwnedFileScope {
        SyncOwnedFileScope(accountID: context.session.accountID, containerIdentifier: context.session.identifier,
                           database: context.isOwnerDatabase ? .privateDatabase : .sharedDatabase,
                           zoneOwnerName: board.zoneOwnerName, zoneName: board.zoneName, namespace: board.namespace)
    }
    private func blobScope(board: SharedBoardDescriptor, context: Context) -> CloudOwnedBlobScope {
        CloudOwnedBlobScope(containerIdentifier: context.session.identifier, namespace: board.namespace, zoneID: context.zoneID, shared: true)
    }
    private func boardRequest<T>(_ board: SharedBoardDescriptor, context: Context, writing: Bool,
                                 _ operation: () async throws -> T) async throws -> T {
        let share: CKShare
        do { share = try await fetchShare(board, context: context) }
        catch { if Self.isRevocation(error) { throw SharedBoardError.revoked }; throw error }
        let access = Self.access(of: share, userRecordName: context.session.userRecordName)
        guard access != .revoked else { throw SharedBoardError.revoked }
        guard !writing || access.canWrite else { throw SharedBoardError.readOnly }
        return try await request(context.session, operation)
    }
    func uploadOwnedFile(_ upload: PreparedSyncOwnedUpload, board: SharedBoardDescriptor) async throws {
        let context = try await context(for: board)
        guard upload.scope == ownedScope(board: board, context: context) else { throw SyncError.namespaceConflict }
        try upload.file.validate()
        let scope = blobScope(board: board, context: context)
        let id = CloudOwnedBlobCodec.recordID(digest: upload.file.digest, scope: scope)
        let found = try await boardRequest(board, context: context, writing: true) {
            try await context.database.records(for: [id], desiredKeys: CloudOwnedBlobCodec.metadataKeys)
        }
        guard let result = found[id] else { throw SyncError.invalidOperation }
        switch result {
        case .success(let record):
            guard CloudOwnedBlobCodec.matches(record, digest: upload.file.digest, byteCount: upload.file.byteCount, scope: scope) else { throw SyncError.invalidOperation }
            return
        case .failure(let error):
            if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }
            guard (error as? CKError)?.code == .unknownItem else { throw error }
        }
        let staging = try CloudAssetStaging()
        let record = try CloudOwnedBlobCodec.encode(file: upload.fileURL, digest: upload.file.digest, byteCount: upload.file.byteCount, scope: scope, staging: staging)
        let saved = try await boardRequest(board, context: context, writing: true) {
            try await context.database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        }
        guard let outcome = saved.saveResults[id] else { throw SyncError.invalidOperation }
        let acknowledged: CKRecord
        do { acknowledged = try outcome.get() }
        catch {
            if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }
            guard let cloud = error as? CKError, cloud.code == .serverRecordChanged,
                  let server = cloud.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else { throw error }
            acknowledged = server
        }
        guard CloudOwnedBlobCodec.matches(acknowledged, digest: upload.file.digest, byteCount: upload.file.byteCount, scope: scope) else { throw SyncError.invalidOperation }
        withExtendedLifetime(staging) {}
    }
    func downloadOwnedFile(_ request: SyncOwnedDownloadRequest, board: SharedBoardDescriptor) async throws -> SyncOwnedFileStaging {
        let context = try await context(for: board)
        guard request.scope == ownedScope(board: board, context: context) else { throw SyncError.namespaceConflict }
        try request.file.validate()
        let scope = blobScope(board: board, context: context)
        let id = CloudOwnedBlobCodec.recordID(digest: request.file.digest, scope: scope)
        return try await boardRequest(board, context: context, writing: false) {
            let records = try await context.database.records(for: [id], desiredKeys: CloudOwnedBlobCodec.metadataKeys + CloudOwnedBlobCodec.assetKeys)
            guard let response = records[id] else { throw SyncError.invalidOperation }
            let temporary = try CloudAssetStaging()
            let file = try CloudOwnedBlobCodec.decode(try response.get(), digest: request.file.digest, byteCount: request.file.byteCount, scope: scope, staging: temporary)
            return try SyncOwnedFileStaging.copy(from: file, descriptor: request.file)
        }
    }
    private func verifyOwnedDependencies(_ operation: SyncOperation, board: SharedBoardDescriptor, context: Context) async throws {
        guard let manifest = operation.ownedFiles else { return }
        guard let record = operation.record else { throw SyncError.invalidOperation }
        try manifest.validate(record: record)
        let scope = blobScope(board: board, context: context)
        var checked = Set<String>()
        for file in manifest.files where checked.insert(file.digest).inserted {
            let id = CloudOwnedBlobCodec.recordID(digest: file.digest, scope: scope)
            let results = try await boardRequest(board, context: context, writing: true) {
                try await context.database.records(for: [id], desiredKeys: CloudOwnedBlobCodec.metadataKeys)
            }
            guard let outcome = results[id] else { throw SyncError.invalidOperation }
            let blob: CKRecord
            do { blob = try outcome.get() }
            catch { if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }; throw error }
            guard CloudOwnedBlobCodec.matches(blob, digest: file.digest, byteCount: file.byteCount, scope: scope) else { throw SyncError.invalidOperation }
        }
    }

    /// Creates only a dedicated shared-copy zone; never shares a user's private history zone.
    func createShare(boardID: UUID, title: String, allowEditing: Bool = false, expectedAccountID: String) async throws -> SharedBoardDescriptor {
        let session = try await session(expectedAccountID: expectedAccountID)
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName(boardID), ownerName: CKCurrentUserDefaultName)
        let database = session.container.privateCloudDatabase
        _ = try await request(session) { try await database.save(CKRecordZone(zoneID: zoneID)) }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let share: CKShare
        do {
            guard let existing = try await request(session, { try await database.record(for: shareID) }) as? CKShare else { throw SyncError.invalidOperation }
            // A retry must not silently broaden an already-created share's permissions.
            share = existing
        } catch let error as CKError where error.code == .unknownItem {
            let pending = CKShare(recordZoneID: zoneID)
            pending[CKShare.SystemFieldKey.title] = String(title.prefix(200)) as NSString
            pending.publicPermission = allowEditing ? .readWrite : .readOnly
            guard let saved = try await request(session, { try await database.save(pending) }) as? CKShare else { throw SyncError.invalidOperation }
            share = saved
        }
        guard Self.access(of: share, userRecordName: session.userRecordName) == .owner else { throw SharedBoardError.remotePermissionDenied }
        return Self.descriptor(boardID: boardID, session: session, share: share)
    }

    func acceptShare(url: URL, expectedAccountID: String) async throws -> SharedBoardDescriptor {
        guard Self.isShareURL(url) else { throw SyncError.unavailable(L10n.text("请输入有效的 iCloud 共享链接。")) }
        let session = try await session(expectedAccountID: expectedAccountID)
        let metadata = try await request(session) { try await session.container.shareMetadata(for: url) }
        guard metadata.containerIdentifier == configuration.containerIdentifier,
              metadata.hierarchicalRootRecordID == nil,
              let boardID = Self.boardID(zoneName: metadata.share.recordID.zoneID.zoneName) else { throw SyncError.invalidOperation }
        let proposed = Self.descriptor(boardID: boardID, session: session, share: metadata.share)
        try Self.validate(proposed, containerIdentifier: configuration.containerIdentifier)
        let result = try await request(session) { try await session.container.accept([metadata]) }
        guard let acceptance = result[metadata] else { throw SyncError.invalidOperation }
        let share: CKShare
        do { share = try acceptance.get() }
        catch { if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }; throw error }
        let descriptor = Self.descriptor(boardID: boardID, session: session, share: share)
        try Self.validate(descriptor, containerIdentifier: configuration.containerIdentifier)
        guard descriptor.boardID == proposed.boardID, descriptor.zoneOwnerName == proposed.zoneOwnerName else { throw SyncError.invalidOperation }
        return descriptor
    }

    func stopSharing(_ board: SharedBoardDescriptor) async throws {
        let context = try await context(for: board)
        let share = try await fetchShare(board, context: context)
        guard context.isOwnerDatabase, Self.access(of: share, userRecordName: context.session.userRecordName) == .owner else { throw SharedBoardError.remotePermissionDenied }
        _ = try await request(context.session) { try await context.database.deleteRecord(withID: share.recordID) }
    }

    func leave(_ board: SharedBoardDescriptor) async throws {
        let context = try await context(for: board)
        guard !context.isOwnerDatabase else { throw SyncError.unavailable(L10n.text("共享板拥有者需要使用“停止共享”。")) }
        let share = try await fetchShare(board, context: context)
        guard Self.access(of: share, userRecordName: context.session.userRecordName) != .owner else { throw SharedBoardError.remotePermissionDenied }
        // CloudKit interprets this delete in sharedCloudDatabase as removing only this participant.
        _ = try await request(context.session) { try await context.database.deleteRecord(withID: share.recordID) }
    }

    func updateLinkPermission(board: SharedBoardDescriptor, allowEditing: Bool) async throws {
        let context = try await context(for: board)
        let share = try await fetchShare(board, context: context)
        guard context.isOwnerDatabase, Self.access(of: share, userRecordName: context.session.userRecordName) == .owner else { throw SharedBoardError.remotePermissionDenied }
        share.publicPermission = allowEditing ? .readWrite : .readOnly
        let result = try await request(context.session) {
            try await context.database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        }
        guard let outcome = result.saveResults[share.recordID] else { throw SyncError.invalidOperation }
        do { _ = try outcome.get() }
        catch { if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }; throw error }
    }

    fileprivate func sharingSnapshot(for board: SharedBoardDescriptor) async throws -> CloudSharingSnapshot {
        let context = try await context(for: board)
        let share = try await fetchShare(board, context: context)
        guard context.isOwnerDatabase, Self.access(of: share, userRecordName: context.session.userRecordName) == .owner else {
            throw SharedBoardError.remotePermissionDenied
        }
        // These fresh objects are handed to one main-actor presenter and never retained by this actor.
        return CloudSharingSnapshot(share: share, container: context.session.container)
    }

    private struct Session {
        let container: CKContainer
        let identifier: String
        let accountID: String
        let userRecordName: String
    }
    private struct Context {
        let session: Session
        let database: CKDatabase
        let zoneID: CKRecordZone.ID
        let isOwnerDatabase: Bool
    }

    private func session(expectedAccountID: String?) async throws -> Session {
        if case .unavailable(let reason) = configurationStatus() { throw SyncError.unavailable(reason) }
        guard let identifier = configuration.containerIdentifier else { throw SyncError.disabled }
        // Do not move container construction above the signing check: an unsigned process can abort here.
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw SyncError.unavailable(L10n.text("iCloud 账号当前不可用。")) }
        let user = try await container.userRecordID()
        let account = identifier + ":" + user.recordName
        if let expectedAccountID, account != expectedAccountID { throw SharedBoardError.accountChanged }
        let session = Session(container: container, identifier: identifier, accountID: account, userRecordName: user.recordName)
        try await verifyAccount(session)
        return session
    }

    private func context(for board: SharedBoardDescriptor) async throws -> Context {
        try Self.validate(board, containerIdentifier: configuration.containerIdentifier)
        let session = try await session(expectedAccountID: board.accountID)
        let owner = board.zoneOwnerName == CKCurrentUserDefaultName || board.zoneOwnerName == session.userRecordName
        return Context(session: session, database: owner ? session.container.privateCloudDatabase : session.container.sharedCloudDatabase,
                       zoneID: CKRecordZone.ID(zoneName: board.zoneName, ownerName: board.zoneOwnerName), isOwnerDatabase: owner)
    }

    private func verifyAccount(_ session: Session) async throws {
        guard try await session.container.accountStatus() == .available,
              try await session.container.userRecordID().recordName == session.userRecordName else { throw SharedBoardError.accountChanged }
    }

    private func request<T>(_ session: Session, _ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await verifyAccount(session)
        let outcome: Result<T, Error>
        do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
        try await verifyAccount(session)
        do { return try outcome.get() }
        catch { if Self.isPermissionDenied(error) { throw SharedBoardError.remotePermissionDenied }; throw error }
    }

    private func fetchShare(_ board: SharedBoardDescriptor, context: Context) async throws -> CKShare {
        let id = CKRecord.ID(recordName: board.shareRecordName, zoneID: context.zoneID)
        guard let share = try await request(context.session, { try await context.database.record(for: id) }) as? CKShare,
              share.recordID == id else { throw SyncError.invalidOperation }
        return share
    }

    private static func descriptor(boardID: UUID, session: Session, share: CKShare) -> SharedBoardDescriptor {
        SharedBoardDescriptor(boardID: boardID, accountID: session.accountID, containerIdentifier: session.identifier,
                              zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName,
                              shareRecordName: share.recordID.recordName, shareURL: share.url)
    }

    static func zoneName(_ boardID: UUID) -> String { "ClipShelfShared_" + boardID.uuidString }
    static func boardID(zoneName: String) -> UUID? {
        let prefix = "ClipShelfShared_"
        guard zoneName.hasPrefix(prefix), let id = UUID(uuidString: String(zoneName.dropFirst(prefix.count))), Self.zoneName(id) == zoneName else { return nil }
        return id
    }
    static func validate(_ board: SharedBoardDescriptor, containerIdentifier: String?) throws {
        guard let containerIdentifier, containerIdentifier.hasPrefix("iCloud."), containerIdentifier.count > 7,
              board.containerIdentifier == containerIdentifier,
              board.accountID.hasPrefix(containerIdentifier + ":"), board.accountID.count > containerIdentifier.count + 1,
              board.zoneName == zoneName(board.boardID), !board.zoneOwnerName.isEmpty,
              board.zoneOwnerName.utf8.count <= 255, board.shareRecordName == CKRecordNameZoneWideShare else { throw SyncError.namespaceConflict }
    }
    static func validate(_ operation: SyncOperation, board: SharedBoardDescriptor) throws {
        guard operation.accountID == board.namespace, operation.baseRevision >= 0, operation.baseRevision < Int.max - 1,
              operation.revision == operation.baseRevision + 1,
              (operation.baseOperationID == nil) == (operation.baseRevision == 0), operation.createdAt.timeIntervalSince1970.isFinite else { throw SyncError.invalidOperation }
        if operation.entityKind == .pinboard, operation.entityID != board.boardID { throw SyncError.namespaceConflict }
        if operation.action == .delete {
            guard operation.record == nil, operation.pinboard == nil else { throw SyncError.invalidOperation }
        } else if operation.entityKind == .clipboard {
            guard let record = operation.record, record.id == operation.entityID, record.pinboardID == board.boardID,
                  operation.pinboard == nil else { throw SyncError.namespaceConflict }
        } else {
            guard let pinboard = operation.pinboard, pinboard.id == board.boardID, operation.record == nil else { throw SyncError.namespaceConflict }
        }
    }

    static func access(role: CKShare.ParticipantRole, permission: CKShare.ParticipantPermission,
                       acceptance: CKShare.ParticipantAcceptanceStatus) -> SharedBoardAccess {
        if role == .owner { return .owner }
        guard acceptance == .accepted, role == .privateUser || role == .publicUser else { return .revoked }
        switch permission {
        case .readWrite: return .readWrite
        case .readOnly: return .readOnly
        default: return .revoked
        }
    }
    private static func access(of share: CKShare, userRecordName: String) -> SharedBoardAccess {
        if let participant = share.currentUserParticipant {
            return access(role: participant.role, permission: participant.permission, acceptance: participant.acceptanceStatus)
        }
        // Owners may not appear as currentUserParticipant in a just-saved share response.
        if share.owner.userIdentity.userRecordID?.recordName == userRecordName { return .owner }
        return .revoked
    }
    static func isPermissionDenied(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return (error as? SharedBoardError) == .remotePermissionDenied }
        if error.code == .permissionFailure { return true }
        return error.partialErrorsByItemID?.values.contains(where: isPermissionDenied) ?? false
    }
    private static func isRevocation(_ error: Error) -> Bool {
        if let shared = error as? SharedBoardError { return shared == .revoked || shared == .remotePermissionDenied }
        guard let cloud = error as? CKError else { return false }
        return cloud.code == .unknownItem || cloud.code == .zoneNotFound || cloud.code == .userDeletedZone || isPermissionDenied(error)
    }
    static func isShareURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return host == "icloud.com" || host.hasSuffix(".icloud.com")
    }
    static func matches(_ record: CKRecord, id: CKRecord.ID, namespace: String, digest: String, version: Int = 1) -> Bool {
        record.recordID == id && record.recordType == recordType && record["namespace"] as? String == namespace
            && record["sha256"] as? String == digest && CloudOwnedBlobCodec.exactInteger(record["formatVersion"]) == version
            && (version == 1 || version == 2) && record["account"] == nil
    }
    static func decodeOperation(_ record: CKRecord, board: SharedBoardDescriptor) throws -> SyncOperation {
        let operation = try CloudOperationCodec.decode(record, type: recordType, namespace: board.namespace, shared: true,
                                                       zone: CKRecordZone.ID(zoneName: board.zoneName, ownerName: board.zoneOwnerName))
        try validate(operation, board: board)
        return operation
    }

    struct CursorEnvelope: Codable, Equatable {
        let version: Int
        let board: SharedBoardDescriptor
        let token: Data
    }
    static func encodeCursor(_ token: CKServerChangeToken, board: SharedBoardDescriptor) throws -> Data {
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        return try encodeCursorData(data, board: board)
    }
    static func encodeCursorData(_ token: Data, board: SharedBoardDescriptor) throws -> Data {
        guard !token.isEmpty, token.count <= 1_024 * 1_024 else { throw SyncError.invalidCursor }
        return try JSONEncoder().encode(CursorEnvelope(version: 1, board: board, token: token))
    }
    static func decodeCursorData(_ cursor: Data, board: SharedBoardDescriptor) throws -> Data {
        guard cursor.count <= 2 * 1_024 * 1_024 else { throw SyncError.invalidCursor }
        let envelope: CursorEnvelope
        do { envelope = try JSONDecoder().decode(CursorEnvelope.self, from: cursor) } catch { throw SyncError.invalidCursor }
        // Share URLs can rotate; the binding is the account, namespace, container and zone/share IDs.
        let bound = envelope.board
        guard envelope.version == 1, bound.boardID == board.boardID, bound.accountID == board.accountID,
              bound.containerIdentifier == board.containerIdentifier, bound.zoneName == board.zoneName,
              bound.zoneOwnerName == board.zoneOwnerName, bound.shareRecordName == board.shareRecordName,
              !envelope.token.isEmpty, envelope.token.count <= 1_024 * 1_024 else { throw SyncError.invalidCursor }
        return envelope.token
    }
    static func decodeCursor(_ cursor: Data?, board: SharedBoardDescriptor) throws -> CKServerChangeToken? {
        guard let cursor else { return nil }
        let data = try decodeCursorData(cursor, board: board)
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else { throw SyncError.invalidCursor }
            return token
        } catch { throw SyncError.invalidCursor }
    }
}

/// A one-way handoff, scoped to this file. CKShare is mutable, so neither the transport nor any
/// other client retains this freshly fetched instance after the main-actor presenter receives it.
fileprivate struct CloudSharingSnapshot: @unchecked Sendable {
    let share: CKShare
    let container: CKContainer
}

/// Apple's share manager handles individual participants, private invitations and link permissions.
/// It is presented only after the user clicks a management action. It never sends an invitation
/// automatically; users choose their recipients and confirm any changes in the system interface.
@MainActor
final class CloudSharedBoardSharingPresenter: NSObject, NSCloudSharingServiceDelegate {
    var onChange: ((SharedBoardDescriptor) -> Void)?
    var onStopSharing: ((SharedBoardDescriptor) -> Void)?
    var onError: ((Error) -> Void)?
    private let transport: CloudSharedBoardTransport
    private var service: NSSharingService?
    private var board: SharedBoardDescriptor?
    private weak var anchor: NSView?
    private var preparing = false
    private var stoppedSharing = false

    init(transport: CloudSharedBoardTransport) { self.transport = transport }

    func present(board: SharedBoardDescriptor, relativeTo view: NSView) async throws {
        guard service == nil, !preparing else { throw SyncError.unavailable(L10n.text("共享成员管理窗口已经打开。")) }
        guard view.window?.isVisible == true else { throw SyncError.unavailable(L10n.text("请先打开共享设置窗口。")) }
        preparing = true
        defer { preparing = false }
        let snapshot = try await transport.sharingSnapshot(for: board)
        try Task.checkCancellation()
        guard view.window?.isVisible == true else { throw CancellationError() }
        let provider = NSItemProvider()
        provider.registerCloudKitShare(snapshot.share, container: snapshot.container)
        guard let service = NSSharingService(named: .cloudSharing), service.canPerform(withItems: [provider]) else {
            throw SyncError.unavailable(L10n.text("当前系统无法显示 iCloud 共享成员管理。"))
        }
        self.board = board
        self.anchor = view
        self.stoppedSharing = false
        self.service = service
        service.delegate = self
        service.perform(withItems: [provider])
    }

    func anchoringView(for sharingService: NSSharingService, showRelativeTo positioningRect: UnsafeMutablePointer<NSRect>,
                       preferredEdge: UnsafeMutablePointer<NSRectEdge>) -> NSView? {
        guard let anchor, anchor.window?.isVisible == true else { return nil }
        positioningRect.pointee = anchor.bounds
        preferredEdge.pointee = .maxY
        return anchor
    }

    nonisolated func options(for cloudKitSharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPublic, .allowPrivate, .allowReadOnly, .allowReadWrite]
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        let id = ObjectIdentifier(sharingService)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.service.map(ObjectIdentifier.init) == id, let board = self.board else { return }
            self.onChange?(board)
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        let id = ObjectIdentifier(sharingService)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.service.map(ObjectIdentifier.init) == id, let board = self.board else { return }
            self.stoppedSharing = true
            self.onStopSharing?(board)
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
        let id = ObjectIdentifier(sharingService)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.service.map(ObjectIdentifier.init) == id else { return }
            let current = self.board, stopped = self.stoppedSharing
            self.service = nil; self.board = nil; self.anchor = nil
            if let error { self.onError?(error) }
            else if let current, !stopped { self.onChange?(current) }
        }
    }
}
