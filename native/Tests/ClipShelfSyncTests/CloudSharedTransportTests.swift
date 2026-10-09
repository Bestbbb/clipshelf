import CloudKit
import Foundation
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class CloudSharedTransportTests: XCTestCase {
    private let container = "iCloud.test.clipshelf.shared"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-shared-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func board(id: UUID = UUID(), account: String? = nil, owner: String = "synthetic-owner") -> SharedBoardDescriptor {
        SharedBoardDescriptor(boardID: id, accountID: account ?? container + ":test-account", containerIdentifier: container,
                              zoneName: CloudSharedBoardTransport.zoneName(id), zoneOwnerName: owner, shareRecordName: CKRecordNameZoneWideShare)
    }
    private func operation(_ board: SharedBoardDescriptor) -> SyncOperation {
        let record = ClipboardRecord(text: "合成共享内容 👩🏽‍💻", rtf: Data([0, 1, 255]), pinboardID: board.boardID, isInHistory: false)
        return SyncOperation(accountID: board.namespace, entityID: record.id, entityKind: .clipboard,
                             action: .upsert, baseRevision: 0, revision: 1, record: record)
    }
    private func cloudRecord(_ operation: SyncOperation, board: SharedBoardDescriptor) throws -> CKRecord {
        let data = try CloudSyncService.encodeOperation(operation)
        let file = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        let zone = CKRecordZone.ID(zoneName: board.zoneName, ownerName: board.zoneOwnerName)
        let result = CKRecord(recordType: CloudSharedBoardTransport.recordType, recordID: CKRecord.ID(recordName: operation.operationID.uuidString, zoneID: zone))
        result["namespace"] = board.namespace as NSString
        result["sha256"] = CloudSyncService.digest(data) as NSString
        result["formatVersion"] = 1 as NSNumber
        result["payload"] = CKAsset(fileURL: file)
        return result
    }

    func testUnsignedContainerRejectsEveryEntryPointBeforeCloudKitConstruction() async throws {
        // This randomly named container can never be an entitlement of the test executable.
        let identifier = "iCloud.test.clipshelf." + UUID().uuidString.lowercased()
        XCTAssertFalse(CloudSyncService.hasCloudKitEntitlement(containerIdentifier: identifier))
        let transport = CloudSharedBoardTransport(configuration: CloudSyncConfiguration(containerIdentifier: identifier))
        guard case .unavailable = await transport.configurationStatus() else { return XCTFail("Unsigned container must be unavailable") }
        let id = UUID(), account = identifier + ":synthetic-account"
        let descriptor = SharedBoardDescriptor(boardID: id, accountID: account, containerIdentifier: identifier,
                                               zoneName: CloudSharedBoardTransport.zoneName(id), zoneOwnerName: CKCurrentUserDefaultName,
                                               shareRecordName: CKRecordNameZoneWideShare)
        let attempts: [() async throws -> Void] = [
            { _ = try await transport.resolveAccount(expectedAccountID: account) },
            { _ = try await transport.access(for: descriptor) },
            { _ = try await transport.push([], board: descriptor) },
            { _ = try await transport.pull(board: descriptor, after: nil, limit: 100) },
            { _ = try await transport.createShare(boardID: id, title: "Synthetic", expectedAccountID: account) },
            { _ = try await transport.acceptShare(url: URL(string: "https://www.icloud.com/share/synthetic")!, expectedAccountID: account) },
            { try await transport.stopSharing(descriptor) },
            { try await transport.leave(descriptor) },
            { try await transport.updateLinkPermission(board: descriptor, allowEditing: true) }
        ]
        for attempt in attempts {
            do { try await attempt(); XCTFail("Missing entitlement must reject the request") }
            catch SyncError.unavailable { }
            catch { XCTFail("Expected configuration gate, got \(error)") }
        }
    }

    func testMissingConfigurationRejectsAccountLookupLocally() async {
        let transport = CloudSharedBoardTransport(configuration: CloudSyncConfiguration(containerIdentifier: nil))
        guard case .unavailable = await transport.configurationStatus() else { return XCTFail("Missing configuration must be unavailable") }
        do { _ = try await transport.resolveAccount(); XCTFail("No container configured") }
        catch SyncError.unavailable { }
        catch { XCTFail("Unexpected \(error)") }
    }

    func testDescriptorCannotAddressPrivateHistoryOrAnotherContainer() throws {
        let item = board()
        XCTAssertNoThrow(try CloudSharedBoardTransport.validate(item, containerIdentifier: container))
        XCTAssertEqual(CloudSharedBoardTransport.boardID(zoneName: item.zoneName), item.boardID)
        XCTAssertNil(CloudSharedBoardTransport.boardID(zoneName: "ClipShelfPrivateV1"))
        XCTAssertThrowsError(try CloudSharedBoardTransport.validate(item, containerIdentifier: "iCloud.another.container"))
        for zone in ["ClipShelfPrivateV1", CloudSharedBoardTransport.zoneName(UUID())] {
            let wrong = SharedBoardDescriptor(boardID: item.boardID, accountID: item.accountID, containerIdentifier: container,
                                               zoneName: zone, zoneOwnerName: item.zoneOwnerName, shareRecordName: item.shareRecordName)
            XCTAssertThrowsError(try CloudSharedBoardTransport.validate(wrong, containerIdentifier: container))
        }
        let arbitraryRecord = SharedBoardDescriptor(boardID: item.boardID, accountID: item.accountID, containerIdentifier: container,
                                                    zoneName: item.zoneName, zoneOwnerName: item.zoneOwnerName, shareRecordName: UUID().uuidString)
        XCTAssertThrowsError(try CloudSharedBoardTransport.validate(arbitraryRecord, containerIdentifier: container))
    }

    func testPermissionsRequireAcceptedMembershipAndIgnoreUnknownRoles() {
        XCTAssertEqual(CloudSharedBoardTransport.access(role: .owner, permission: .readWrite, acceptance: .accepted), .owner)
        XCTAssertEqual(CloudSharedBoardTransport.access(role: .privateUser, permission: .readOnly, acceptance: .accepted), .readOnly)
        XCTAssertEqual(CloudSharedBoardTransport.access(role: .publicUser, permission: .readWrite, acceptance: .accepted), .readWrite)
        for status: CKShare.ParticipantAcceptanceStatus in [.unknown, .pending, .removed] {
            XCTAssertEqual(CloudSharedBoardTransport.access(role: .privateUser, permission: .readWrite, acceptance: status), .revoked)
        }
        XCTAssertEqual(CloudSharedBoardTransport.access(role: .unknown, permission: .readWrite, acceptance: .accepted), .revoked)
        XCTAssertEqual(CloudSharedBoardTransport.access(role: .publicUser, permission: .none, acceptance: .accepted), .revoked)
    }

    func testPermissionFailureRecognizesPerRecordPartialErrors() {
        let denied = CKError(.permissionFailure)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["operation": denied]])
        XCTAssertTrue(CloudSharedBoardTransport.isPermissionDenied(denied))
        XCTAssertTrue(CloudSharedBoardTransport.isPermissionDenied(partial))
        XCTAssertTrue(CloudSharedBoardTransport.isPermissionDenied(SharedBoardError.remotePermissionDenied))
        XCTAssertFalse(CloudSharedBoardTransport.isPermissionDenied(CKError(.networkUnavailable)))
    }

    func testSharedOperationsCannotCrossNamespacesOrBoardReferences() throws {
        let item = board(), original = operation(board())
        XCTAssertThrowsError(try CloudSharedBoardTransport.validate(original, board: item))
        let valid = operation(item)
        XCTAssertNoThrow(try CloudSharedBoardTransport.validate(valid, board: item))
        var foreign = valid.record!
        foreign.pinboardID = UUID()
        let crossed = SyncOperation(accountID: item.namespace, entityID: foreign.id, entityKind: .clipboard,
                                    action: .upsert, baseRevision: 0, revision: 1, record: foreign)
        XCTAssertThrowsError(try CloudSharedBoardTransport.validate(crossed, board: item))
        let privateOp = SyncOperation(accountID: item.accountID, entityID: valid.entityID, entityKind: .clipboard,
                                       action: .delete, baseRevision: 0, revision: 1)
        XCTAssertThrowsError(try CloudSharedBoardTransport.validate(privateOp, board: item))
        let otherBoardDeletion = SyncOperation(accountID: item.namespace, entityID: UUID(), entityKind: .pinboard,
                                                action: .delete, baseRevision: 0, revision: 1)
        XCTAssertThrowsError(try CloudSharedBoardTransport.validate(otherBoardDeletion, board: item))
    }

    func testAssetRoundTripAndDigestRejectCorruption() throws {
        let item = board(), original = operation(item)
        let record = try cloudRecord(original, board: item)
        XCTAssertEqual(try CloudSharedBoardTransport.decodeOperation(record, board: item), original)
        let file = (record["payload"] as! CKAsset).fileURL!
        try Data("corrupted".utf8).write(to: file)
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeOperation(record, board: item))
    }

    func testCloudRecordRejectsWrongRecordIdentityFormatOrNamespace() throws {
        let item = board(), original = operation(item)
        let record = try cloudRecord(original, board: item)
        record["namespace"] = board().namespace as NSString
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeOperation(record, board: item))
        record["namespace"] = item.namespace as NSString
        record["formatVersion"] = 2 as NSNumber
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeOperation(record, board: item))
        record["formatVersion"] = 1 as NSNumber
        let impostor = CKRecord(recordType: CloudSharedBoardTransport.recordType,
                                recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: record.recordID.zoneID))
        for key in record.allKeys() where key != "payload" { impostor[key] = record[key] }
        impostor["payload"] = CKAsset(fileURL: (record["payload"] as! CKAsset).fileURL!)
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeOperation(impostor, board: item))
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeOperation(record, board: board()))
    }

    func testRetryAcceptsOnlySameImmutablePayloadAndRecordIdentity() throws {
        let item = board(), original = operation(item)
        let record = try cloudRecord(original, board: item)
        let hash = CloudSyncService.digest(try CloudSyncService.encodeOperation(original))
        XCTAssertTrue(CloudSharedBoardTransport.matches(record, id: record.recordID, namespace: item.namespace, digest: hash))
        XCTAssertFalse(CloudSharedBoardTransport.matches(record, id: record.recordID, namespace: item.accountID, digest: hash))
        XCTAssertFalse(CloudSharedBoardTransport.matches(record, id: record.recordID, namespace: item.namespace, digest: "other-payload"))
        let anotherID = CKRecord.ID(recordName: UUID().uuidString, zoneID: record.recordID.zoneID)
        XCTAssertFalse(CloudSharedBoardTransport.matches(record, id: anotherID, namespace: item.namespace, digest: hash))
    }

    func testCursorBoundToAccountBoardAndZoneOwner() throws {
        let item = board(), token = Data("synthetic opaque token".utf8)
        let cursor = try CloudSharedBoardTransport.encodeCursorData(token, board: item)
        XCTAssertEqual(try CloudSharedBoardTransport.decodeCursorData(cursor, board: item), token)
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeCursorData(cursor, board: board()))
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeCursorData(cursor, board: board(id: item.boardID, account: container + ":other-account")))
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeCursorData(cursor, board: board(id: item.boardID, owner: "another-owner")))
        XCTAssertThrowsError(try CloudSharedBoardTransport.decodeCursorData(Data("not JSON".utf8), board: item))
        XCTAssertThrowsError(try CloudSharedBoardTransport.encodeCursorData(Data(repeating: 0, count: 1_024 * 1_024 + 1), board: item))
        XCTAssertNil(try CloudSharedBoardTransport.decodeCursor(nil, board: item))
    }

    func testRotatingShareURLDoesNotInvalidateZoneCursor() throws {
        let item = board(), token = Data([1, 2, 3])
        let cursor = try CloudSharedBoardTransport.encodeCursorData(token, board: item)
        let updated = SharedBoardDescriptor(boardID: item.boardID, accountID: item.accountID, containerIdentifier: container,
                                            zoneName: item.zoneName, zoneOwnerName: item.zoneOwnerName, shareRecordName: item.shareRecordName,
                                            shareURL: URL(string: "https://www.icloud.com/share/new-link"))
        XCTAssertEqual(try CloudSharedBoardTransport.decodeCursorData(cursor, board: updated), token)
    }

    func testShareURLRejectsNonCloudKitOrCredentialURLs() {
        for value in ["https://www.icloud.com/share/abc", "https://icloud.com/share/abc"] {
            XCTAssertTrue(CloudSharedBoardTransport.isShareURL(URL(string: value)!))
        }
        for value in ["file:///tmp/share", "http://www.icloud.com/share/abc", "https://icloud.com.evil.example/share/abc", "https://user:password@icloud.com/share/abc", "https://icloud.com:444/share/abc"] {
            XCTAssertFalse(CloudSharedBoardTransport.isShareURL(URL(string: value)!))
        }
    }
}
