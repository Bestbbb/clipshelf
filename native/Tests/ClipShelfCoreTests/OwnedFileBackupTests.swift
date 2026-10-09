import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

final class OwnedFileBackupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshelf-owned-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func store(_ name: String) throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }

    private func filePart(_ url: String = "file:///missing-original/example.txt") -> ClipboardPart {
        ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(url.utf8))])
    }

    @discardableResult
    private func createOwned(_ store: HistoryStore, text: String = "owned file", data: Data = Data("original bytes".utf8),
                             id: UUID = UUID(), pinboardID: UUID? = nil) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(id: id, text: text, parts: [filePart()], pinboardID: pinboardID),
                         ownedFiles: [OwnedFileImport(partIndex: 0, representationIndex: 0, filename: "example.txt", data: data)],
                         expectedSyncConfiguration: store.syncConfiguration(),
                         expectedSharingConfiguration: store.sharingConfiguration())
    }

    private func fileURL(_ record: ClipboardRecord, part: Int = 0) throws -> URL {
        let representation = try XCTUnwrap(record.parts[part].representations.first)
        XCTAssertEqual(representation.typeIdentifier, "public.file-url")
        let url = try XCTUnwrap(URL(string: String(decoding: representation.data, as: UTF8.self)))
        XCTAssertTrue(url.isFileURL)
        return url
    }

    private func readArchive(_ url: URL) throws -> HistoryBackup {
        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: Data(contentsOf: url))
        XCTAssertEqual(envelope.checksum, RepresentationStorage.digest(envelope.payload))
        return try JSONDecoder().decode(HistoryBackup.self, from: envelope.payload)
    }

    private func writeArchive(_ backup: HistoryBackup) throws -> URL {
        let payload = try JSONEncoder().encode(backup)
        let envelope = BackupEnvelope(checksum: RepresentationStorage.digest(payload), payload: payload)
        let url = directory.appendingPathComponent("\(UUID().uuidString).clipshelfbackup")
        try JSONEncoder().encode(envelope).write(to: url)
        return url
    }

    private func ownedDirectories(_ store: HistoryStore) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(at: store.ownedFileStorage.directory,
                                                       includingPropertiesForKeys: nil).map(\.lastPathComponent))
    }

    private func assetCount(_ store: HistoryStore) throws -> Int {
        let statement = try store.prepare("SELECT COUNT(*) FROM owned_file_assets")
        defer { sqlite3_finalize(statement) }
        try store.check(sqlite3_step(statement), allowingRow: true)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func manifestFixture() -> HistoryBackup {
        let bytes = Data("portable archive content".utf8)
        let record = ClipboardRecord(text: "archived owned file", parts: [filePart()])
        let asset = OwnedFileAsset(id: UUID(), filename: "example.txt", byteCount: bytes.count,
                                   sha256: RepresentationStorage.digest(bytes))
        return HistoryBackup(records: [record], pinboards: [], ownedFiles: [OwnedFileBackupAsset(asset: asset, data: bytes)],
                             ownedFileBindings: [OwnedFileBinding(recordID: record.id, partIndex: 0,
                                                                 representationIndex: 0, assetID: asset.id)])
    }

    func testSchema3RestoresMultipleSameNamedFilesAfterOriginalRootIsRemoved() throws {
        let archiveURL = directory.appendingPathComponent("portable.clipshelfbackup")
        let firstBytes = Data("first part".utf8), secondBytes = Data([0, 1, 2, 255])
        let originalID: UUID, originalAssets: Set<UUID>, oldURLs: [URL]
        do {
            let source = try store("source")
            let record = try source.create(ClipboardRecord(text: "two same filenames", parts: [filePart(), filePart()]),
                                           ownedFiles: [
                                            OwnedFileImport(partIndex: 0, representationIndex: 0, filename: "相同.txt", data: firstBytes),
                                            OwnedFileImport(partIndex: 1, representationIndex: 0, filename: "相同.txt", data: secondBytes),
                                           ], expectedSyncConfiguration: source.syncConfiguration(),
                                           expectedSharingConfiguration: source.sharingConfiguration())
            originalID = record.id
            originalAssets = Set(try source.ownedFileBindings(recordID: record.id).map(\.assetID))
            oldURLs = try [fileURL(record), fileURL(record, part: 1)]
            try source.exportBackup(to: archiveURL)
        }
        let archive = try readArchive(archiveURL)
        XCTAssertEqual(archive.schemaVersion, 3)
        XCTAssertEqual(archive.ownedFiles?.count, 2)
        XCTAssertEqual(archive.ownedFileBindings?.count, 2)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("source"))
        XCTAssertTrue(oldURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let target = try store("elsewhere")
        let summary = try target.restoreBackup(from: archiveURL, mode: .replace)
        XCTAssertEqual(summary.importedRecords, 1)
        let restored = try XCTUnwrap(target.item(id: originalID))
        let bindings = try target.ownedFileBindings(recordID: restored.id)
        XCTAssertEqual(bindings.map(\.partIndex), [0, 1])
        XCTAssertTrue(Set(bindings.map(\.assetID)).isDisjoint(with: originalAssets))
        for (part, bytes) in [firstBytes, secondBytes].enumerated() {
            let url = try fileURL(restored, part: part)
            XCTAssertTrue(url.path.hasPrefix(target.ownedFileStorage.directory.path + "/"))
            XCTAssertEqual(url.lastPathComponent, "相同.txt")
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let reopened = try store("elsewhere")
        XCTAssertEqual(try reopened.ownedFileBindings(recordID: restored.id), bindings)
        XCTAssertEqual(try Data(contentsOf: fileURL(XCTUnwrap(reopened.item(id: restored.id)))), firstBytes)
    }

    func testExportUsesImmutableOriginalAfterEditableProjectionChanges() throws {
        let source = try store("source")
        let original = try createOwned(source)
        try Data("edited by another application".utf8).write(to: fileURL(original))
        let url = directory.appendingPathComponent("immutable.clipshelfbackup")
        try source.exportBackup(to: url)
        XCTAssertEqual(try readArchive(url).ownedFiles?.first?.data, Data("original bytes".utf8))
        let target = try store("target")
        _ = try target.restoreBackup(from: url, mode: .replace)
        XCTAssertEqual(try Data(contentsOf: fileURL(XCTUnwrap(target.item(id: original.id)))), Data("original bytes".utf8))
    }

    func testUnownedURLsAreNeverReadOrPromotedEvenWhenTheyResembleManagedPaths() throws {
        let source = try store("source")
        let missing = source.ownedFileStorage.directory.appendingPathComponent(UUID().uuidString + "/files/missing.txt")
        let references = [missing.absoluteString, "file:///missing-external-location/file.txt", "https://example.invalid/file.txt"]
        var originals: [ClipboardRecord] = []
        for reference in references {
            originals.append(try source.create(ClipboardRecord(text: reference, parts: [filePart(reference)])))
        }
        let url = directory.appendingPathComponent("references.clipshelfbackup")
        try source.exportBackup(to: url)
        let backup = try readArchive(url)
        XCTAssertTrue(backup.ownedFiles?.isEmpty ?? true)
        XCTAssertTrue(backup.ownedFileBindings?.isEmpty ?? true)
        let target = try store("target")
        _ = try target.restoreBackup(from: url, mode: .replace)
        for original in originals {
            XCTAssertEqual(try target.item(id: original.id)?.parts, original.parts)
            XCTAssertEqual(try target.ownedFileBindings(recordID: original.id), [])
        }
        XCTAssertEqual(try assetCount(target), 0)
    }

    func testSchema2KeepsLegacyReferencesWithAbsentOwnedFields() throws {
        let original = ClipboardRecord(text: "legacy", parts: [filePart()])
        let backup = HistoryBackup(schemaVersion: 2, records: [original], pinboards: [])
        let target = try store("legacy")
        _ = try target.restoreBackup(from: writeArchive(backup), mode: .replace)
        XCTAssertEqual(try target.item(id: original.id), original)
        XCTAssertEqual(try target.ownedFileBindings(recordID: original.id), [])
        XCTAssertEqual(try assetCount(target), 0)
    }

    func testSchema2CannotSmuggleOwnedAssetsOrBindings() throws {
        for field in ["assets", "bindings", "both", "empty"] {
            var backup = manifestFixture()
            backup.schemaVersion = 2
            if field == "assets" { backup.ownedFileBindings = nil }
            if field == "bindings" { backup.ownedFiles = nil }
            if field == "empty" { backup.ownedFiles = []; backup.ownedFileBindings = [] }
            let target = try store("legacy-smuggle-\(field)")
            let original = try target.create(ClipboardRecord(text: "must survive"))
            XCTAssertThrowsError(try target.restoreBackup(from: writeArchive(backup), mode: .replace), field)
            XCTAssertEqual(try target.load(), [original], field)
            XCTAssertEqual(try assetCount(target), 0, field)
            XCTAssertEqual(try ownedDirectories(target), [], field)
        }
    }

    func testMalformedManifestFailsBeforeReplacingExistingRecordsOrFiles() throws {
        let fixture = manifestFixture()
        let file = try XCTUnwrap(fixture.ownedFiles?.first)
        let binding = try XCTUnwrap(fixture.ownedFileBindings?.first)
        func changedAsset(filename: String? = nil, byteCount: Int? = nil, sha256: String? = nil) -> OwnedFileBackupAsset {
            OwnedFileBackupAsset(asset: OwnedFileAsset(id: file.asset.id, filename: filename ?? file.asset.filename,
                                                       byteCount: byteCount ?? file.asset.byteCount,
                                                       sha256: sha256 ?? file.asset.sha256), data: file.data)
        }
        let cases: [(String, (inout HistoryBackup) -> Void)] = [
            ("duplicate asset", { $0.ownedFiles = [file, file] }),
            ("duplicate slot", { $0.ownedFileBindings = [binding, binding] }),
            ("missing asset", { $0.ownedFiles = [] }),
            ("orphan asset", { $0.ownedFileBindings = [] }),
            ("unknown record", { $0.ownedFileBindings = [OwnedFileBinding(recordID: UUID(), partIndex: 0, representationIndex: 0, assetID: file.asset.id)] }),
            ("unknown asset", { $0.ownedFileBindings = [OwnedFileBinding(recordID: binding.recordID, partIndex: 0, representationIndex: 0, assetID: UUID())] }),
            ("negative part", { $0.ownedFileBindings = [OwnedFileBinding(recordID: binding.recordID, partIndex: -1, representationIndex: 0, assetID: file.asset.id)] }),
            ("missing representation", { $0.ownedFileBindings = [OwnedFileBinding(recordID: binding.recordID, partIndex: 0, representationIndex: 1, assetID: file.asset.id)] }),
            ("wrong representation type", { $0.records[0].parts[0].representations[0].typeIdentifier = "public.utf8-plain-text" }),
            ("digest mismatch", { $0.ownedFiles = [changedAsset(sha256: String(repeating: "0", count: 64))] }),
            ("size mismatch", { $0.ownedFiles = [changedAsset(byteCount: file.data.count + 1)] }),
            ("overflowing declared size", { $0.ownedFiles = [changedAsset(byteCount: Int.max)] }),
            ("negative declared size", { $0.ownedFiles = [changedAsset(byteCount: -1)] }),
            ("filename traversal", { $0.ownedFiles = [changedAsset(filename: "../../escaped.txt")] }),
            ("absolute filename", { $0.ownedFiles = [changedAsset(filename: "/tmp/escaped.txt")] }),
            ("nul filename", { $0.ownedFiles = [changedAsset(filename: "evil\0.txt")] }),
        ]
        let target = try store("manifest-target")
        let original = try createOwned(target, text: "keep existing owned file")
        let originalBindings = try target.ownedFileBindings(recordID: original.id)
        let directories = try ownedDirectories(target)
        for (name, mutate) in cases {
            var malformed = fixture
            mutate(&malformed)
            XCTAssertThrowsError(try target.restoreBackup(from: writeArchive(malformed), mode: .replace), name)
            XCTAssertEqual(try target.load(), [original], name)
            XCTAssertEqual(try target.ownedFileBindings(recordID: original.id), originalBindings, name)
            XCTAssertEqual(try ownedDirectories(target), directories, name)
            XCTAssertEqual(try assetCount(target), 1, name)
            XCTAssertEqual(try Data(contentsOf: fileURL(original)), Data("original bytes".utf8), name)
        }
    }

    func testRepeatedMergeComparesOwnedContentInsteadOfRebasedPaths() throws {
        let backup = manifestFixture()
        let url = try writeArchive(backup)
        let target = try store("repeat")
        XCTAssertEqual(try target.restoreBackup(from: url, mode: .merge).importedRecords, 1)
        let first = try target.load()
        let bindings = try target.ownedFileBindings(recordID: backup.records[0].id)
        let directories = try ownedDirectories(target)
        XCTAssertEqual(try target.restoreBackup(from: url, mode: .merge).importedRecords, 0)
        XCTAssertEqual(try target.load(), first)
        XCTAssertEqual(try target.ownedFileBindings(recordID: backup.records[0].id), bindings)
        XCTAssertEqual(try ownedDirectories(target), directories)
        XCTAssertEqual(try assetCount(target), 1)
    }

    func testMergeConflictBindsOwnedFileToFinalNewRecordID() throws {
        let backup = manifestFixture()
        let target = try store("conflict")
        let existing = try target.create(ClipboardRecord(id: backup.records[0].id, text: "existing unrelated text"))
        XCTAssertEqual(try target.restoreBackup(from: writeArchive(backup), mode: .merge).importedRecords, 1)
        XCTAssertEqual(try target.item(id: existing.id), existing)
        XCTAssertEqual(try target.ownedFileBindings(recordID: existing.id), [])
        let imported = try XCTUnwrap(target.load().first { $0.id != existing.id })
        let binding = try XCTUnwrap(target.ownedFileBindings(recordID: imported.id).first)
        XCTAssertEqual(binding.recordID, imported.id)
        XCTAssertNotEqual(binding.assetID, backup.ownedFiles?.first?.asset.id)
        XCTAssertEqual(try Data(contentsOf: fileURL(imported)), backup.ownedFiles?.first?.data)
        let roundtrip = directory.appendingPathComponent("conflict-roundtrip.clipshelfbackup")
        try target.exportBackup(to: roundtrip)
        XCTAssertEqual(try readArchive(roundtrip).ownedFileBindings?.map(\.recordID), [imported.id])
    }

    func testSyncedArchiveRemapsRecordAndAssetWhileKeepingRestoredFileLocal() throws {
        let source = try store("synced-source")
        try source.configureSync(accountID: "source-account")
        let original = try createOwned(source)
        let originalAsset = try XCTUnwrap(source.ownedFileBindings(recordID: original.id).first?.assetID)
        let archive = directory.appendingPathComponent("synced.clipshelfbackup")
        try source.exportBackup(to: archive)
        let target = try store("fresh-local")
        let summary = try target.restoreBackup(from: archive, mode: .replace)
        XCTAssertTrue(summary.identitiesRemapped)
        let imported = try XCTUnwrap(target.load().first)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNil(try target.item(id: original.id))
        let binding = try XCTUnwrap(target.ownedFileBindings(recordID: imported.id).first)
        XCTAssertEqual(binding.recordID, imported.id)
        XCTAssertNotEqual(binding.assetID, originalAsset)
        XCTAssertEqual(try Data(contentsOf: fileURL(imported)), Data("original bytes".utf8))
        try target.configureSync(accountID: "different-account", includeLocalData: false)
        XCTAssertEqual(try target.pendingSyncOperations(accountID: "different-account"), [])
    }

    func testSharedAssetIsEncodedOnceAndRestoredForBothTrustedCopies() throws {
        let source = try store("clones")
        let board = try source.createPinboard(name: "Original")
        let original = try createOwned(source, pinboardID: board.id)
        _ = try source.copyBoardToLocal(boardID: board.id)
        let archiveURL = directory.appendingPathComponent("clones.clipshelfbackup")
        try source.exportBackup(to: archiveURL)
        let archive = try readArchive(archiveURL)
        XCTAssertEqual(archive.records.count, 2)
        XCTAssertEqual(archive.ownedFiles?.count, 1)
        XCTAssertEqual(archive.ownedFileBindings?.count, 2)
        let target = try store("clones-restored")
        _ = try target.restoreBackup(from: archiveURL, mode: .replace)
        var restoredAssetIDs = Set<UUID>()
        for record in archive.records {
            let restored = try XCTUnwrap(target.item(id: record.id))
            let binding = try XCTUnwrap(target.ownedFileBindings(recordID: restored.id).first)
            restoredAssetIDs.insert(binding.assetID)
            XCTAssertEqual(try Data(contentsOf: fileURL(restored)), Data("original bytes".utf8))
        }
        XCTAssertEqual(restoredAssetIDs.count, 1)
        try target.delete(id: original.id)
        let survivor = try XCTUnwrap(archive.records.first { $0.id != original.id })
        XCTAssertEqual(try Data(contentsOf: fileURL(XCTUnwrap(target.item(id: survivor.id)))), Data("original bytes".utf8))
    }

    func testSecondRecordSQLFailureRollsBackReplacementFilesAndPreservesPortableRecovery() throws {
        let source = try store("rollback-source")
        try createOwned(source, text: "restore first", data: Data("first".utf8))
        try createOwned(source, text: "restore second", data: Data("second".utf8))
        let archive = directory.appendingPathComponent("rollback.clipshelfbackup")
        try source.exportBackup(to: archive)
        let target = try store("rollback-target")
        let original = try createOwned(target, text: "pre-restore file")
        let originalBindings = try target.ownedFileBindings(recordID: original.id)
        let directories = try ownedDirectories(target)
        try target.execute("CREATE TRIGGER fail_second_restore BEFORE INSERT ON clipboard_records WHEN NEW.text = 'restore second' BEGIN SELECT RAISE(ABORT, 'synthetic second restore failure'); END")
        XCTAssertThrowsError(try target.restoreBackup(from: archive, mode: .replace))
        try target.execute("DROP TRIGGER fail_second_restore")
        XCTAssertEqual(try target.load(), [original])
        XCTAssertEqual(try target.ownedFileBindings(recordID: original.id), originalBindings)
        XCTAssertEqual(try ownedDirectories(target), directories)
        XCTAssertEqual(try assetCount(target), 1)
        XCTAssertEqual(try Data(contentsOf: fileURL(original)), Data("original bytes".utf8))

        let recoveries = try FileManager.default.contentsOfDirectory(
            at: target.databaseURL.deletingLastPathComponent().appendingPathComponent("Backups"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "clipshelfbackup" }
        let recovery = try XCTUnwrap(recoveries.first)
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(try readArchive(recovery).ownedFiles?.first?.data, Data("original bytes".utf8))
        let recoveryTarget = try store("recovery-target")
        _ = try recoveryTarget.restoreBackup(from: recovery, mode: .replace)
        XCTAssertEqual(try Data(contentsOf: fileURL(XCTUnwrap(recoveryTarget.item(id: original.id)))), Data("original bytes".utf8))

        XCTAssertEqual(try target.restoreBackup(from: archive, mode: .replace).importedRecords, 2,
                       "Failure cleanup must leave the same archive retryable")
    }

    func testCorruptImmutableOriginalDoesNotPublishPartialBackup() throws {
        let source = try store("corrupt")
        let original = try createOwned(source)
        let assetID = try XCTUnwrap(source.ownedFileBindings(recordID: original.id).first?.assetID)
        let payload = source.ownedFileStorage.assetDirectory(assetID).appendingPathComponent("payload")
        try Data("tampered bytes".utf8).write(to: payload)
        let archive = directory.appendingPathComponent("must-not-exist.clipshelfbackup")
        XCTAssertThrowsError(try source.exportBackup(to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try source.item(id: original.id), original)
        XCTAssertEqual(try source.ownedFileBindings(recordID: original.id).count, 1)
    }
}
