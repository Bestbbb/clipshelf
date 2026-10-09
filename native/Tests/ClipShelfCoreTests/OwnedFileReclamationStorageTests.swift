import Darwin
import Foundation
import XCTest
@testable import ClipShelfCore

final class OwnedFileReclamationStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: OwnedFileStorage!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("clipshelf-reclamation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        storage = try OwnedFileStorage(databaseURL: directory.appendingPathComponent("history.sqlite3"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func asset(_ data: Data = Data("owned original".utf8), name: String = "文档.txt") throws -> OwnedFileAsset {
        let value = OwnedFileAsset(id: UUID(), filename: name, byteCount: data.count, sha256: RepresentationStorage.digest(data))
        try storage.create(value, data: data, didCreateDirectory: {})
        return value
    }
    private func isolated(_ token: QuarantinedOwnedFile) -> URL {
        storage.directory.appendingPathComponent(".reclamation").appendingPathComponent(token.operationID.uuidString).appendingPathComponent(token.candidate.assetID.uuidString)
    }
    func testPrepareCountsOnlyBothOwnedCopiesWithoutMutation() throws {
        for data in [Data(), Data(repeating: 7, count: 8_193)] {
            let value = try asset(data), candidate = try XCTUnwrap(storage.prepareReclamation(value))
            XCTAssertEqual(candidate.logicalBytes, Int64(data.count * 2))
            XCTAssertGreaterThanOrEqual(candidate.allocatedBytes, 0)
            XCTAssertEqual(candidate.byteCount, data.count)
            XCTAssertEqual(candidate.sha256, value.sha256)
            XCTAssertEqual(try storage.read(value), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.directory.appendingPathComponent(".reclamation").path))
        }
    }
    func testEditedProjectionAndDamagedOriginalArePreserved() throws {
        let value = try asset(), projection = try storage.fileURL(value)
        try Data("external app edit".utf8).write(to: projection)
        XCTAssertNil(try storage.prepareReclamation(value))
        XCTAssertEqual(try String(contentsOf: projection), "external app edit")
        let another = try asset()
        try Data("damaged".utf8).write(to: storage.assetDirectory(another.id).appendingPathComponent("payload"))
        XCTAssertNil(try storage.prepareReclamation(another))
    }
    func testAdditionalFilesDirectoriesAndMissingProjectionRemainUntouched() throws {
        for child in ["extra", "files/extra", "unexpected/folder"] {
            let value = try asset(), root = storage.assetDirectory(value.id)
            let url = root.appendingPathComponent(child)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: url)
            XCTAssertNil(try storage.prepareReclamation(value))
            XCTAssertEqual(try String(contentsOf: url), "keep")
        }
        let value = try asset()
        try FileManager.default.removeItem(at: storage.fileURL(value))
        XCTAssertNil(try storage.prepareReclamation(value))
        XCTAssertNoThrow(try storage.read(value))
    }
    func testSymlinkAndHardLinkNeverBecomeCandidates() throws {
        let outside = directory.appendingPathComponent("outside")
        try Data("external".utf8).write(to: outside)
        for name in ["payload", "files/文档.txt"] {
            let value = try asset(), location = storage.assetDirectory(value.id).appendingPathComponent(name)
            try FileManager.default.removeItem(at: location)
            try FileManager.default.createSymbolicLink(at: location, withDestinationURL: outside)
            XCTAssertNil(try storage.prepareReclamation(value))
        }
        let hardLinked = try asset(), original = storage.assetDirectory(hardLinked.id).appendingPathComponent("payload")
        try FileManager.default.linkItem(at: original, to: directory.appendingPathComponent("hard-link"))
        XCTAssertNil(try storage.prepareReclamation(hardLinked))
        XCTAssertEqual(try String(contentsOf: outside), "external")
    }
    func testFilesDirectorySymlinkDoesNotInspectItsDestination() throws {
        let value = try asset(), folder = storage.assetDirectory(value.id).appendingPathComponent("files")
        let moved = directory.appendingPathComponent("external-directory")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        XCTAssertNil(try storage.prepareReclamation(value))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(value.filename).path))
    }
    func testFrozenFingerprintRejectsSameBytesInNewInode() throws {
        let value = try asset(), candidate = try XCTUnwrap(storage.prepareReclamation(value))
        let projection = try storage.fileURL(value), data = try Data(contentsOf: projection)
        try FileManager.default.removeItem(at: projection); try data.write(to: projection)
        XCTAssertThrowsError(try storage.quarantine(candidate, operationID: UUID()))
        XCTAssertEqual(try Data(contentsOf: projection), data)
    }
    func testQuarantineTokenIsDeterministicCodableAndRestoreIsIdempotent() throws {
        let value = try asset(), candidate = try XCTUnwrap(storage.prepareReclamation(value)), operation = UUID()
        let expected = storage.preparedQuarantine(candidate: candidate, operationID: operation)
        let token = try storage.quarantine(candidate, operationID: operation)
        XCTAssertEqual(expected, token)
        XCTAssertEqual(try JSONDecoder().decode(QuarantinedOwnedFile.self, from: JSONEncoder().encode(token)), token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.assetDirectory(value.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated(token).path))
        XCTAssertEqual(try storage.quarantine(candidate, operationID: operation), token)
        try storage.restore(token); try storage.restore(token)
        XCTAssertEqual(try storage.read(value), Data("owned original".utf8))
    }
    func testPlannedJournalBeforeRenameRestoresAsNoOp() throws {
        let value = try asset(), candidate = try XCTUnwrap(storage.prepareReclamation(value))
        let token = storage.preparedQuarantine(candidate: candidate, operationID: UUID())
        XCTAssertNoThrow(try storage.restore(token))
        XCTAssertThrowsError(try storage.removeQuarantined(token))
        XCTAssertNoThrow(try storage.read(value))
    }
    func testQuarantineAndRestoreNeverOverwriteExistingDirectory() throws {
        let value = try asset(), candidate = try XCTUnwrap(storage.prepareReclamation(value)), operation = UUID()
        let token = storage.preparedQuarantine(candidate: candidate, operationID: operation)
        let target = isolated(token)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: target.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try storage.quarantine(candidate, operationID: operation))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("sentinel")), "sentinel")
        try FileManager.default.removeItem(at: target)
        _ = try storage.quarantine(candidate, operationID: operation)
        try FileManager.default.createDirectory(at: storage.assetDirectory(value.id), withIntermediateDirectories: false)
        try Data("new folder".utf8).write(to: storage.assetDirectory(value.id).appendingPathComponent("keep"))
        XCTAssertThrowsError(try storage.restore(token))
        XCTAssertEqual(try String(contentsOf: storage.assetDirectory(value.id).appendingPathComponent("keep")), "new folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("payload").path))
    }
    func testQuarantineRootSymlinkCannotRedirectWrites() throws {
        let value = try asset(), candidate = try XCTUnwrap(storage.prepareReclamation(value))
        let external = directory.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: storage.directory.appendingPathComponent(".reclamation"), withDestinationURL: external)
        XCTAssertThrowsError(try storage.quarantine(candidate, operationID: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        XCTAssertNoThrow(try storage.read(value))
    }
    func testConfirmedQuarantineDeletesOnlyItsExpectedFilesAndRepeatsSafely() throws {
        let value = try asset(), protected = try asset(Data("other".utf8))
        let token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        let result = try storage.removeQuarantined(token)
        XCTAssertTrue(result.complete); XCTAssertNil(result.failure)
        XCTAssertEqual(result.removedFileCount, 2)
        XCTAssertEqual(result.removedLogicalBytes, Int64(value.byteCount * 2))
        XCTAssertEqual(result.removedAllocatedBytes, token.candidate.allocatedBytes)
        XCTAssertNoThrow(try storage.read(protected))
        let again = try storage.removeQuarantined(token)
        XCTAssertTrue(again.complete); XCTAssertEqual(again.removedFileCount, 0)
    }
    func testInterruptedDeletionReportsPartialWorkAndResumesAfterRestart() throws {
        let value = try asset(), token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        let first = try storage.removeQuarantined(token) { name in
            if name == "payload" { throw OwnedFileReclamationError.io(EIO) }
        }
        XCTAssertFalse(first.complete); XCTAssertNotNil(first.failure)
        XCTAssertEqual(first.removedFileCount, 1); XCTAssertEqual(first.removedLogicalBytes, Int64(value.byteCount))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated(token).appendingPathComponent("payload").path))
        storage = try OwnedFileStorage(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let recovered = try JSONDecoder().decode(QuarantinedOwnedFile.self, from: JSONEncoder().encode(token))
        let second = try storage.removeQuarantined(recovered)
        XCTAssertTrue(second.complete); XCTAssertEqual(second.removedFileCount, 1)
        XCTAssertEqual(first.removedLogicalBytes + second.removedLogicalBytes, token.candidate.logicalBytes)
    }
    func testModifiedQuarantinedProjectionPreventsDeletionAndRestoresUnchangedEdit() throws {
        let value = try asset(), token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        let projection = isolated(token).appendingPathComponent("files").appendingPathComponent(value.filename)
        try Data("edited after rename".utf8).write(to: projection)
        XCTAssertThrowsError(try storage.removeQuarantined(token))
        try storage.restore(token)
        XCTAssertEqual(try String(contentsOf: storage.fileURL(value)), "edited after rename")
        XCTAssertNoThrow(try storage.read(value))
    }
    func testReplacementDuringDeletionIsPreservedAndCountsNoFalseSuccess() throws {
        let value = try asset(), token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        let projection = isolated(token).appendingPathComponent("files").appendingPathComponent(value.filename)
        let result = try storage.removeQuarantined(token) { name in
            if name == value.filename {
                try FileManager.default.removeItem(at: projection)
                try Data("replacement".utf8).write(to: projection)
            }
        }
        XCTAssertFalse(result.complete); XCTAssertEqual(result.removedFileCount, 0)
        XCTAssertEqual(try String(contentsOf: projection), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated(token).appendingPathComponent("payload").path))
    }
    func testMovedQuarantineCannotDeleteThroughPreviouslyOpenedDirectoryHandles() throws {
        let value = try asset(), token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        let outside = directory.appendingPathComponent("moved-outside")
        let result = try storage.removeQuarantined(token) { name in
            if name == value.filename { try FileManager.default.moveItem(at: self.isolated(token), to: outside) }
        }
        XCTAssertFalse(result.complete); XCTAssertEqual(result.removedFileCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("files").appendingPathComponent(value.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload").path))
    }
    func testUnexpectedEntryAfterPartialDeleteRemainsAndBlocksRetry() throws {
        let value = try asset(), token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        let extra = isolated(token).appendingPathComponent("extra")
        let result = try storage.removeQuarantined(token) { name in
            if name == value.id.uuidString { try Data("must survive".utf8).write(to: extra) }
        }
        XCTAssertFalse(result.complete); XCTAssertEqual(result.removedFileCount, 2)
        XCTAssertThrowsError(try storage.removeQuarantined(token))
        XCTAssertEqual(try String(contentsOf: extra), "must survive")
    }
    func testMeasurementIncludesModifiedUnknownAndIsolatedFilesButExcludesLeaseLocks() throws {
        let first = try asset(Data("first".utf8)), second = try asset(Data("second".utf8))
        try Data("externally edited projection".utf8).write(to: storage.fileURL(first))
        _ = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(second)), operationID: UUID())
        let orphan = UUID(), orphanDirectory = storage.assetDirectory(orphan)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: false)
        try Data("orphan".utf8).write(to: orphanDirectory.appendingPathComponent("data"))
        let leaseDirectory = storage.directory.appendingPathComponent(".leases")
        try FileManager.default.createDirectory(at: leaseDirectory, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 500).write(to: leaseDirectory.appendingPathComponent("lock"))
        let measurement = try storage.ownedStorageMeasurement(registeredAssetIDs: [first.id, second.id])
        XCTAssertTrue(measurement.isComplete)
        let changedBytes = "externally edited projection".utf8.count
        let expectedBytes: Int64 = 23 + Int64(changedBytes)
        XCTAssertEqual(measurement.logicalBytes, expectedBytes)
        XCTAssertGreaterThan(measurement.allocatedBytes, 0)
        XCTAssertEqual(measurement.unregisteredDirectoryIDs, [orphan])
        XCTAssertGreaterThanOrEqual(measurement.unknownEntryCount, 1)
    }
    func testMeasurementDoesNotFollowLinksOrDoubleCountHardLinkedInodes() throws {
        let value = try asset(Data("content".utf8)), outside = directory.appendingPathComponent("outside")
        try Data(repeating: 2, count: 20_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: storage.directory.appendingPathComponent("outside-link"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: storage.assetDirectory(value.id).appendingPathComponent("payload"), to: storage.directory.appendingPathComponent("extra-link"))
        let measurement = try storage.ownedStorageMeasurement(registeredAssetIDs: [value.id])
        XCTAssertEqual(measurement.logicalBytes, 14)
        XCTAssertFalse(measurement.isComplete)
        XCTAssertEqual(measurement.skippedEntryCount, 1)
        XCTAssertGreaterThanOrEqual(measurement.unknownEntryCount, 2)
        XCTAssertEqual(try Data(contentsOf: outside).count, 20_000)
    }
    func testMeasurementDepthBudgetFailsWithoutRemovingUnknownContents() throws {
        var path = storage.directory
        for _ in 0..<18 { path.appendPathComponent("nested") }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: path.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try storage.ownedStorageMeasurement(registeredAssetIDs: []))
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("sentinel")), "keep")
    }
    func testForgedJournalFilenameCannotEscapeExpectedDirectory() throws {
        let value = try asset(), token = try storage.quarantine(XCTUnwrap(storage.prepareReclamation(value)), operationID: UUID())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        var candidate = try XCTUnwrap(object["candidate"] as? [String: Any]); candidate["filename"] = "../../outside"; object["candidate"] = candidate
        let malformed = try JSONDecoder().decode(QuarantinedOwnedFile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try storage.removeQuarantined(malformed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated(token).appendingPathComponent("payload").path))
    }
}
