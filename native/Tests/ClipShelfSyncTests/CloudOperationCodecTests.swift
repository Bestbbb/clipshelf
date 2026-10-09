import CloudKit
import Foundation
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class CloudOperationCodecTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "private-zone", ownerName: CKCurrentUserDefaultName)
    private let account = "iCloud.test.clipshelf:synthetic-account"
    private func operation(version: Int? = nil, owned: Bool = false) -> SyncOperation {
        let file = SyncOwnedFileDescriptor(digest: CloudSyncService.digest(Data("bytes".utf8)), byteCount: 5, filename: "sample.txt")
        var record = ClipboardRecord(text: "example")
        if owned { record.parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(SyncOwnedFileManifest.token(digest: file.digest, filename: file.filename).utf8))])] }
        let manifest = owned ? SyncOwnedFileManifest(files: [file], bindings: [SyncOwnedFileBinding(partIndex: 0, representationIndex: 0, digest: file.digest, filename: file.filename)]) : nil
        return SyncOperation(accountID: account, entityID: record.id, entityKind: .clipboard, action: .upsert, baseRevision: 0, revision: 1,
                             record: record, formatVersion: version, ownedFiles: manifest)
    }
    private func encode(_ operation: SyncOperation, outer: Int) throws -> (CKRecord, CloudAssetStaging) {
        let staging = try CloudAssetStaging(), bytes = try CloudSyncService.encodeOperation(operation)
        let file = try staging.write(bytes, name: "operation")
        let record = CKRecord(recordType: CloudSyncService.recordType, recordID: CKRecord.ID(recordName: operation.operationID.uuidString, zoneID: zone))
        record["account"] = account as NSString; record["formatVersion"] = outer as NSNumber
        if outer == 2 { record["payloadByteCount"] = bytes.count as NSNumber }
        record["sha256"] = CloudSyncService.digest(bytes) as NSString; record["payload"] = CKAsset(fileURL: file)
        return (record, staging)
    }
    func testLegacyAbsentVersionStableAndV2ManifestRoundTrip() throws {
        for input in [operation(), operation(version: 1), operation(version: 2, owned: true)] {
            let bytes = try CloudSyncService.encodeOperation(input), version = try CloudOperationCodec.version(bytes)
            XCTAssertEqual(version, input.formatVersion ?? 1)
            let (record, staging) = try encode(input, outer: version)
            let decoded = try CloudSyncService.decodeOperation(record, accountID: account, zoneID: zone)
            XCTAssertEqual(decoded, input)
            XCTAssertEqual(try CloudSyncService.encodeOperation(decoded), bytes)
            withExtendedLifetime(staging) {}
        }
    }
    func testUnknownOuterInnerAndMissingVersionForManifestReject() throws {
        for (input, outer) in [(operation(), 2), (operation(version: 3), 3), (operation(version: 2, owned: true), 1),
                               (operation(version: 2), 2), (operation(owned: true), 1), (operation(version: 1, owned: true), 1)] {
            let (record, staging) = try encode(input, outer: outer)
            XCTAssertThrowsError(try CloudSyncService.decodeOperation(record, accountID: account, zoneID: zone))
            withExtendedLifetime(staging) {}
        }
    }
    func testImmutableSuccessOrLostResponseRequiresFullIdentityEvenWithoutAssetURL() throws {
        let (expected, staging) = try encode(operation(version: 2, owned: true), outer: 2)
        func copy(id: CKRecord.ID? = nil, type: String? = nil) -> CKRecord {
            let value = CKRecord(recordType: type ?? expected.recordType, recordID: id ?? expected.recordID)
            for key in expected.allKeys() where key != "payload" { value[key] = expected[key] }
            return value
        }
        XCTAssertTrue(CloudOperationCodec.matches(copy(), expected: expected))
        for (field, wrong): (String, CKRecordValue) in [("account", "other-account" as NSString), ("sha256", "other-hash" as NSString),
                                                        ("formatVersion", 1 as NSNumber), ("payloadByteCount", 1 as NSNumber), ("namespace", "shared:wrong" as NSString)] {
            let mutated = copy(); mutated[field] = wrong
            XCTAssertFalse(CloudOperationCodec.matches(mutated, expected: expected), field)
        }
        XCTAssertFalse(CloudOperationCodec.matches(copy(type: "OtherRecord"), expected: expected))
        XCTAssertFalse(CloudOperationCodec.matches(copy(id: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone)), expected: expected))
        XCTAssertFalse(CloudOperationCodec.matches(copy(id: CKRecord.ID(recordName: expected.recordID.recordName, zoneID: CKRecordZone.ID(zoneName: "other-zone", ownerName: zone.ownerName))), expected: expected))
        withExtendedLifetime(staging) {}
    }
    func testV2PayloadLengthRequiredAndVerified() throws {
        let (record, staging) = try encode(operation(version: 2, owned: true), outer: 2)
        record["payloadByteCount"] = nil
        XCTAssertThrowsError(try CloudSyncService.decodeOperation(record, accountID: account, zoneID: zone))
        record["payloadByteCount"] = 1 as NSNumber
        XCTAssertThrowsError(try CloudSyncService.decodeOperation(record, accountID: account, zoneID: zone))
        withExtendedLifetime(staging) {}
    }
    func testOperationPayloadReadRejectsSymlinkAndDigestTampering() throws {
        let (record, staging) = try encode(operation(), outer: 1)
        let original = (record["payload"] as! CKAsset).fileURL!
        let link = staging.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        record["payload"] = CKAsset(fileURL: link)
        XCTAssertThrowsError(try CloudSyncService.decodeOperation(record, accountID: account, zoneID: zone))
        record["payload"] = CKAsset(fileURL: original)
        try Data("tampered".utf8).write(to: original)
        XCTAssertThrowsError(try CloudSyncService.decodeOperation(record, accountID: account, zoneID: zone))
    }
    func testBlobDeletionIsAuxiliaryButOperationDeletionIsNot() {
        let scope = CloudOwnedBlobScope(containerIdentifier: "iCloud.test", namespace: account, zoneID: zone, shared: false)
        let id = CloudOwnedBlobCodec.recordID(digest: String(repeating: "a", count: 64), scope: scope)
        XCTAssertTrue(CloudOwnedBlobCodec.isBlobDeletion(id: id, type: CloudOwnedBlobCodec.recordType, scope: scope))
        XCTAssertFalse(CloudOwnedBlobCodec.isBlobDeletion(id: id, type: CloudSyncService.recordType, scope: scope))
        XCTAssertFalse(CloudOwnedBlobCodec.isBlobDeletion(id: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone), type: CloudOwnedBlobCodec.recordType, scope: scope))
        XCTAssertFalse(CloudOwnedBlobCodec.isBlobDeletion(id: CKRecord.ID(recordName: id.recordName, zoneID: CKRecordZone.ID(zoneName: "other", ownerName: zone.ownerName)), type: CloudOwnedBlobCodec.recordType, scope: scope))
    }
}
