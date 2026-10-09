import CloudKit
import Foundation
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class CloudOwnedBlobCodecTests: XCTestCase {
    private func scope(shared: Bool = false, owner: String = CKCurrentUserDefaultName, namespace: String = "test-account") -> CloudOwnedBlobScope {
        CloudOwnedBlobScope(containerIdentifier: "iCloud.test.clipshelf", namespace: namespace,
                            zoneID: CKRecordZone.ID(zoneName: shared ? "shared-zone" : "private-zone", ownerName: owner), shared: shared)
    }
    private func encode(_ data: Data, scope: CloudOwnedBlobScope? = nil) throws -> (CKRecord, CloudAssetStaging) {
        let staging = try CloudAssetStaging()
        let original = try staging.write(data, name: "original")
        let record = try CloudOwnedBlobCodec.encode(file: original, digest: CloudSyncService.digest(data), byteCount: data.count,
                                                    scope: scope ?? self.scope(), staging: staging)
        return (record, staging)
    }
    private func metadata(_ source: CKRecord, id: CKRecord.ID? = nil, type: String? = nil) -> CKRecord {
        let result = CKRecord(recordType: type ?? source.recordType, recordID: id ?? source.recordID)
        for key in source.allKeys() where !CloudOwnedBlobCodec.assetKeys.contains(key) && key != "payload" { result[key] = source[key] }
        return result
    }
    func testEmptyAndSmallBlobsRoundTripIntoIndependentLease() throws {
        for data in [Data(), Data("独立文件 bytes 👩🏽‍💻".utf8)] {
            var upload: CloudAssetStaging?
            let record: CKRecord
            (record, upload) = try encode(data)
            let staging = try CloudAssetStaging()
            let digest = CloudSyncService.digest(data)
            let file = try CloudOwnedBlobCodec.decode(record, digest: digest, byteCount: data.count, scope: scope(), staging: staging)
            let lease = try SyncOwnedFileStaging.copy(from: file, descriptor: SyncOwnedFileDescriptor(digest: digest, byteCount: data.count, filename: "copy.txt"))
            let uploadedDirectory = upload!.directory
            upload = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: uploadedDirectory.path))
            XCTAssertEqual(try Data(contentsOf: lease.fileURL), data)
            XCTAssertNotEqual(file, lease.fileURL)
        }
    }
    func testMaximumFileUsesTwoChunksWithoutReducing64MiBBudget() throws {
        let data = Data(repeating: 0xa7, count: SyncOwnedFileLimits.maximumFileBytes)
        let (record, upload) = try encode(data)
        XCTAssertEqual((record["chunkCount"] as? NSNumber)?.intValue, 2)
        for key in CloudOwnedBlobCodec.assetKeys {
            let file = try XCTUnwrap((record[key] as? CKAsset)?.fileURL)
            XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, CloudOwnedBlobCodec.chunkBytes)
        }
        let staging = try CloudAssetStaging()
        let file = try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope(), staging: staging)
        XCTAssertEqual(try CloudSyncService.digest(CloudAssetStaging.read(file, maximum: data.count)), CloudSyncService.digest(data))
        withExtendedLifetime(upload) {}
    }
    func testMissingSecondChunkAndCorruptedChunkFail() throws {
        let data = Data(repeating: 0x41, count: CloudOwnedBlobCodec.chunkBytes + 3)
        let (record, upload) = try encode(data)
        let second = record["chunk1"]
        record["chunk1"] = nil
        XCTAssertThrowsError(try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope(), staging: CloudAssetStaging()))
        record["chunk1"] = second
        let secondFile = (second as! CKAsset).fileURL!
        try Data([0, 0, 0]).write(to: secondFile)
        XCTAssertThrowsError(try CloudOwnedBlobCodec.decode(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope(), staging: CloudAssetStaging()))
        withExtendedLifetime(upload) {}
    }
    func testBlobIdentityBindsTypeVersionLengthZoneNamespaceAndContainer() throws {
        let data = Data("same immutable bytes".utf8), digest = CloudSyncService.digest(Data("same immutable bytes".utf8))
        let (record, staging) = try encode(data)
        func matches(_ candidate: CKRecord) -> Bool { CloudOwnedBlobCodec.matches(candidate, digest: digest, byteCount: data.count, scope: scope()) }
        XCTAssertTrue(matches(record))
        for (key, wrong): (String, CKRecordValue) in [("formatVersion", 2 as NSNumber), ("byteCount", (data.count + 1) as NSNumber),
                                                     ("chunkCount", 2 as NSNumber), ("namespace", "foreign" as NSString),
                                                     ("scopeKind", "shared" as NSString), ("container", "iCloud.other" as NSString),
                                                     ("zoneName", "other" as NSString), ("sha256", String(repeating: "a", count: 64) as NSString)] {
            let copy = metadata(record); copy[key] = wrong
            XCTAssertFalse(matches(copy), key)
        }
        XCTAssertFalse(matches(metadata(record, type: "NotABlob")))
        XCTAssertFalse(matches(metadata(record, id: CKRecord.ID(recordName: record.recordID.recordName, zoneID: CKRecordZone.ID(zoneName: "private-zone", ownerName: "other-owner")))))
        XCTAssertFalse(matches(metadata(record, id: CKRecord.ID(recordName: "owned-other", zoneID: record.recordID.zoneID))))
        let fractional = metadata(record); fractional["formatVersion"] = 1.5 as NSNumber
        XCTAssertFalse(matches(fractional))
        withExtendedLifetime(staging) {}
    }
    func testRetryMetadataMayHaveNoAssetURLButDownloadRequiresAllBytes() throws {
        let data = Data([0, 1, 2]), (record, staging) = try encode(Data([0, 1, 2]))
        let serverRecord = metadata(record)
        XCTAssertTrue(CloudOwnedBlobCodec.matches(serverRecord, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope()))
        XCTAssertThrowsError(try CloudOwnedBlobCodec.decode(serverRecord, digest: CloudSyncService.digest(data), byteCount: data.count, scope: scope(), staging: CloudAssetStaging()))
        withExtendedLifetime(staging) {}
    }
    func testSharedBlobContainsNoUploadingAccountAndRejectsUnexpectedOne() throws {
        let shared = scope(shared: true, owner: "actual-zone-owner", namespace: "shared:board")
        let data = Data("shared".utf8), (record, staging) = try encode(Data("shared".utf8), scope: shared)
        XCTAssertNil(record["account"])
        XCTAssertTrue(CloudOwnedBlobCodec.matches(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: shared))
        record["account"] = "uploading-owner-account" as NSString
        XCTAssertFalse(CloudOwnedBlobCodec.matches(record, digest: CloudSyncService.digest(data), byteCount: data.count, scope: shared))
        withExtendedLifetime(staging) {}
    }
    func testSharedOwnerAliasMayChangeToRealOwnerWithoutUploaderMetadata() throws {
        let owner = scope(shared: true, owner: CKCurrentUserDefaultName, namespace: "shared:board")
        let participant = scope(shared: true, owner: "real-cloud-owner", namespace: "shared:board")
        let data = Data("shared bytes".utf8), (uploaded, staging) = try encode(Data("shared bytes".utf8), scope: owner)
        // CloudKit presents the same zone using the actual owner to an invited participant.
        let received = metadata(uploaded, id: CloudOwnedBlobCodec.recordID(digest: CloudSyncService.digest(data), scope: participant))
        for key in CloudOwnedBlobCodec.assetKeys {
            if let file = (uploaded[key] as? CKAsset)?.fileURL { received[key] = CKAsset(fileURL: file) }
        }
        let destination = try CloudAssetStaging()
        let file = try CloudOwnedBlobCodec.decode(received, digest: CloudSyncService.digest(data), byteCount: data.count, scope: participant, staging: destination)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertNil(received["account"])
        XCTAssertFalse(CloudOwnedBlobCodec.matches(received, digest: CloudSyncService.digest(data), byteCount: data.count, scope: owner))
        withExtendedLifetime(staging) {}
    }
    func testUploadRejectsWrongDigestLengthOversizeAndSymlinks() throws {
        let staging = try CloudAssetStaging(), data = Data("original".utf8)
        let original = try staging.write(data, name: "original")
        for (hash, count) in [(String(repeating: "a", count: 64), data.count), (CloudSyncService.digest(data), data.count + 1), (CloudSyncService.digest(data), CloudOwnedBlobCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try CloudOwnedBlobCodec.encode(file: original, digest: hash, byteCount: count, scope: scope(), staging: CloudAssetStaging()))
        }
        let link = staging.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try CloudAssetStaging.read(link, maximum: 100))
        let parent = try CloudAssetStaging(), directoryLink = parent.directory.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: staging.directory)
        XCTAssertThrowsError(try CloudAssetStaging.read(directoryLink.appendingPathComponent("original"), maximum: 100))
        XCTAssertThrowsError(try CloudAssetStaging.read(staging.directory, maximum: 100))
        XCTAssertThrowsError(try CloudAssetStaging.read(original, maximum: data.count - 1))
    }
    func testZoneMetadataRequestNeverIncludesAssetFields() {
        let desiredKeys = CloudOperationCodec.metadataKeys + CloudOwnedBlobCodec.metadataKeys
        XCTAssertFalse(desiredKeys.contains("payload"))
        XCTAssertTrue(Set(desiredKeys).isDisjoint(with: CloudOwnedBlobCodec.assetKeys))
    }
}
