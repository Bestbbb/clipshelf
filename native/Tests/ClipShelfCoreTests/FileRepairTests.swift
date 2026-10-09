import CSQLite
import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ClipShelfCore

final class FileRepairTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "history") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"))
    }
    private func ref(_ record: ClipboardRecord) -> ClipboardSelectionReference { .init(id: record.id, revision: record.revision) }
    private func part(_ url: URL, extra: [ClipboardRepresentation] = []) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: "public.file-url", data: Data(url.absoluteString.utf8))] + extra)
    }
    private func existing(_ name: String = "new 中文.txt", bytes: Data = Data("new contents".utf8)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    private func snapshot(_ store: HistoryStore, _ record: ClipboardRecord) throws -> ClipboardFileRepairSnapshot {
        try store.fileRepairSnapshot(ref(record))
    }
    private func owned(_ store: HistoryStore, boardID: UUID? = nil) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: "owned.txt", parts: [part(directory.appendingPathComponent("placeholder"))], pinboardID: boardID),
                         ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "owned.txt", data: Data("immutable bytes\0中文".utf8))],
                         expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }
    private func shared(_ store: HistoryStore, owned isOwned: Bool) throws -> (UUID, ClipboardRecord) {
        let local = try store.createPinboard(name: "local")
        if isOwned { _ = try owned(store, boardID: local.id) }
        else { _ = try store.create(ClipboardRecord(text: "missing", parts: [part(directory.appendingPathComponent("missing"))], pinboardID: local.id)) }
        try store.configureSharing(accountID: "test-account")
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "test-account", containerIdentifier: "iCloud.synthetic",
                                              zoneName: "test", zoneOwnerName: "test-owner", shareRecordName: "test-share")
        let board = try store.createSharedCopy(from: local.id, descriptor: descriptor)
        let record = try XCTUnwrap(store.search(.init(pinboardIDs: [board.id])).first)
        return (board.id, record)
    }

    func testFileURLParsingKeepsWhitespaceAndRejectsRemoteOrAmbiguousURLs() throws {
        let trailing = try existing(" leading trailing .txt ")
        XCTAssertEqual(ClipboardFileAccess.url(from: Data(trailing.absoluteString.utf8))?.path, trailing.path)
        XCTAssertEqual(ClipboardFileAccess.availability(of: trailing), .available)
        XCTAssertNotNil(ClipboardFileAccess.url(from: Data("file://localhost/tmp/a%20".utf8)))
        for raw in ["file://remote/tmp/a", "file:///tmp/a?x=1", "file:///tmp/a#fragment", "file:///tmp/a%00b", "https://example.test/a", "file://user@localhost/tmp/a", "file://localhost:80/tmp/a", "file:relative", "file:///tmp/a\0"] {
            XCTAssertNil(ClipboardFileAccess.url(from: Data(raw.utf8)), raw)
        }
        XCTAssertNil(ClipboardFileAccess.url(from: Data([255])))
        XCTAssertTrue(ClipboardFileAccess.isFileURLType("public.file-url"))
        XCTAssertFalse(ClipboardFileAccess.isFileURLType("public.url"))
    }

    func testAvailabilityFollowsOrdinarySymlinksButNeverOpensFIFO() throws {
        let url = try existing(), link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertEqual(ClipboardFileAccess.availability(of: link), .available)
        XCTAssertEqual(ClipboardFileAccess.availability(of: directory), .available)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(ClipboardFileAccess.availability(of: link), .missing)
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(ClipboardFileAccess.availability(of: fifo), .unreadable)
    }

    func testRelocationNormalizesOnlyAffectedPartAndStrictUndoRestoresEverything() throws {
        let store = try store(), missing = directory.appendingPathComponent("missing.txt"), replacement = try existing()
        let second = part(try existing("second.txt"), extra: [.init(typeIdentifier: "org.example.opaque", data: Data([0, 255]))])
        let old = try store.create(ClipboardRecord(text: "missing.txt\nsecond.txt", rtf: Data("old rtf".utf8), html: Data("old html".utf8),
            parts: [part(missing, extra: [.init(typeIdentifier: "public.url", data: Data(missing.absoluteString.utf8)),
                .init(typeIdentifier: "public.utf8-plain-text", data: Data(missing.path.utf8)),
                .init(typeIdentifier: "NSFilenamesPboardType", data: Data("old names".utf8)),
                .init(typeIdentifier: "public.png", data: Data([1, 2])),
                .init(typeIdentifier: "org.example.file-location", data: Data([3, 4]))]), second], renamedTitle: "My title"))
        let snapshot = try snapshot(store, old)
        XCTAssertEqual(snapshot.files.map(\.status), [.missing, .available])
        let undo = try store.relocateExternalFile(snapshot, file: snapshot.files[0], to: replacement)
        let result = try XCTUnwrap(store.item(id: old.id))
        XCTAssertEqual(result.parts[0], part(replacement)); XCTAssertEqual(result.parts[1], second)
        XCTAssertEqual(result.text, replacement.lastPathComponent + "\nsecond.txt")
        XCTAssertEqual(result.renamedTitle, old.renamedTitle); XCTAssertNil(result.rtf); XCTAssertNil(result.html)
        XCTAssertEqual(result.revision, old.revision + 1)
        XCTAssertTrue(try store.ownedFileBindings(recordID: old.id).isEmpty)
        _ = try store.undoSelectionEdit(undo)
        var expected = old; expected.revision += 2
        XCTAssertEqual(try store.item(id: old.id), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("new contents".utf8))
    }

    func testUserTextAndUnrelatedPartArePreservedWhenFileIsReplaced() throws {
        let store = try store(), replacement = try existing()
        let old = try store.create(ClipboardRecord(text: "User-written description", parts: [part(directory.appendingPathComponent("gone"))]))
        let view = try snapshot(store, old)
        _ = try store.relocateExternalFile(view, file: view.files[0], to: replacement)
        XCTAssertEqual(try store.item(id: old.id)?.text, old.text)
    }

    func testSameFileAliasesStayConsistentAndDifferentAliasesAreRejected() throws {
        let store = try store(), missing = directory.appendingPathComponent("old.txt"), replacement = try existing()
        let alias = try XCTUnwrap(UTType(tag: "example-file-reference", tagClass: UTTagClass(rawValue: "com.apple.nspboard-type"), conformingTo: .fileURL)).identifier
        XCTAssertTrue(ClipboardFileAccess.isFileURLType(alias))
        var record = ClipboardRecord(text: "old.txt", parts: [part(missing, extra: [.init(typeIdentifier: alias, data: Data(missing.absoluteString.utf8))])])
        let original = try store.create(record), view = try snapshot(store, original)
        _ = try store.relocateExternalFile(view, file: view.files[1], to: replacement)
        let representations = try XCTUnwrap(store.item(id: original.id)).parts[0].representations
        XCTAssertEqual(representations.map(\.typeIdentifier), ["public.file-url", alias])
        XCTAssertEqual(Set(representations.map(\.data)), [Data(replacement.absoluteString.utf8)])
        record.id = UUID(); record.parts[0].representations[1].data = Data(directory.appendingPathComponent("different").absoluteString.utf8)
        let ambiguous = try store.create(record), invalid = try snapshot(store, ambiguous)
        XCTAssertThrowsError(try store.relocateExternalFile(invalid, file: invalid.files[0], to: replacement))
        XCTAssertEqual(try store.item(id: ambiguous.id), ambiguous)
    }

    func testInvalidSingleURLCanBeReplacedWithoutInferringOwnership() throws {
        let store = try store(), replacement = try existing()
        let original = try store.create(ClipboardRecord(text: "custom", parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data("https://remote.invalid/old".utf8))])]))
        let view = try snapshot(store, original)
        XCTAssertEqual(view.files[0].status, .invalidURL)
        _ = try store.relocateExternalFile(view, file: view.files[0], to: replacement)
        XCTAssertEqual(try store.item(id: original.id)?.parts, [part(replacement)])
    }

    func testSnapshotCannotCrossStoresBeForgedOrOutliveRevisionOrConfigurationABA() throws {
        let store = try store(), replacement = try existing()
        let original = try store.create(ClipboardRecord(text: "old", parts: [part(directory.appendingPathComponent("old"))]))
        let view = try snapshot(store, original)
        let foreign = try self.store("foreign"); _ = try foreign.create(original)
        XCTAssertThrowsError(try foreign.relocateExternalFile(view, file: view.files[0], to: replacement))
        let forged = ClipboardFileRepairSnapshot(record: view.record, files: view.files, syncConfiguration: view.syncConfiguration,
                                                 sharingConfiguration: view.sharingConfiguration, isReadOnly: false)
        XCTAssertThrowsError(try store.relocateExternalFile(forged, file: forged.files[0], to: replacement))
        let changedFile = ClipboardFileReference(partIndex: 0, representationIndex: 0, rawURL: Data(), url: nil, status: .invalidURL, isOwned: false)
        XCTAssertThrowsError(try store.relocateExternalFile(view, file: changedFile, to: replacement))
        let peer = try self.store(); var changed = original; changed.text = "external edit"
        _ = try peer.update(record: changed)
        XCTAssertThrowsError(try store.relocateExternalFile(view, file: view.files[0], to: replacement))
        let fresh = try snapshot(store, XCTUnwrap(store.item(id: original.id)))
        try peer.configureSync(accountID: "A"); try peer.configureSync(accountID: nil)
        XCTAssertThrowsError(try store.relocateExternalFile(fresh, file: fresh.files[0], to: replacement))
        let latest = try snapshot(store, XCTUnwrap(store.item(id: original.id)))
        try peer.configureSharing(accountID: "A"); try peer.configureSharing(accountID: nil)
        XCTAssertThrowsError(try store.relocateExternalFile(latest, file: latest.files[0], to: replacement))
    }

    func testInactivePrivateAccountAndSharedReadOnlyCannotRelocate() throws {
        let store = try store(), replacement = try existing()
        try store.configureSync(accountID: "A")
        let original = try store.create(ClipboardRecord(text: "old", parts: [part(directory.appendingPathComponent("old"))]))
        try store.configureSync(accountID: "B")
        XCTAssertThrowsError(try snapshot(store, original))
        let other = try self.store("shared"), (board, record) = try shared(other, owned: false)
        let writableView = try snapshot(other, record)
        try other.updateSharedAccess(boardID: board, accountID: "test-account", access: .readOnly)
        let readOnlyView = try snapshot(other, record)
        XCTAssertTrue(readOnlyView.isReadOnly)
        XCTAssertThrowsError(try other.relocateExternalFile(writableView, file: writableView.files[0], to: replacement))
        XCTAssertThrowsError(try other.relocateExternalFile(readOnlyView, file: readOnlyView.files[0], to: replacement))
        try other.updateSharedAccess(boardID: board, accountID: "test-account", access: .revoked)
        XCTAssertThrowsError(try snapshot(other, record))
    }

    func testProjectionRestoresOriginalBytesWithoutSQLOrCloudMutationAndAllowsEditedExistingFile() throws {
        let store = try store(); try store.configureSync(accountID: "A")
        let record = try owned(store), view = try snapshot(store, record), url = try XCTUnwrap(view.files[0].url)
        let originalBytes = try Data(contentsOf: url)
        let operations = try store.pendingSyncOperations(accountID: "A")
        try FileManager.default.removeItem(at: url)
        let missingView = try snapshot(store, record)
        // Snapshot preparation now registers its live asset lease; projection repair itself remains read-only in SQL.
        let before = sqlite3_total_changes64(store.database)
        XCTAssertTrue(missingView.files[0].isOwned); XCTAssertEqual(missingView.files[0].status, .missing)
        XCTAssertEqual(try store.restoreMissingOwnedProjection(missingView, file: missingView.files[0]), .restored(url))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(sqlite3_total_changes64(store.database), before)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "A").map(\.operationID), operations.map(\.operationID))
        XCTAssertEqual(try store.item(id: record.id), record)
        try Data("edited externally".utf8).write(to: url)
        XCTAssertEqual(try store.restoreMissingOwnedProjection(missingView, file: missingView.files[0]), .alreadyPresent(url))
        XCTAssertEqual(try Data(contentsOf: url), Data("edited externally".utf8))
        XCTAssertThrowsError(try store.relocateExternalFile(view, file: view.files[0], to: existing()))
        let asset = try store.ownedFileAssetWithoutLock(id: XCTUnwrap(store.ownedFileBindings(recordID: record.id).first).assetID)
        XCTAssertEqual(try store.ownedFileStorage.read(asset), originalBytes)
    }

    func testProjectionRestoresMissingProjectionDirectoryAndDoesNotRequireWriteAccessToSharedBoard() throws {
        let store = try store(), (board, record) = try shared(store, owned: true)
        let initial = try snapshot(store, record), url = try XCTUnwrap(initial.files[0].url)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try store.updateSharedAccess(boardID: board, accountID: "test-account", access: .readOnly)
        let readOnly = try snapshot(store, record)
        XCTAssertTrue(readOnly.isReadOnly)
        XCTAssertEqual(try store.restoreMissingOwnedProjection(readOnly, file: readOnly.files[0]), .restored(url))
        XCTAssertEqual(try store.item(id: record.id), record)
        try FileManager.default.removeItem(at: url)
        try store.updateSharedAccess(boardID: board, accountID: "test-account", access: .revoked)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(readOnly, file: readOnly.files[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOwnedProjectionRefusesSymlinkHardlinkFIFOAndCorruptPayload() throws {
        let store = try store(), record = try owned(store), view = try snapshot(store, record)
        let url = try XCTUnwrap(view.files[0].url), target = try existing()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertEqual(try snapshot(store, record).files[0].status, .unsafeProjection)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(link(target.path, url.path), 0)
        XCTAssertEqual(try snapshot(store, record).files[0].status, .unsafeProjection)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertEqual(try snapshot(store, record).files[0].status, .unsafeProjection)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        try FileManager.default.removeItem(at: url)
        let asset = try store.ownedFileAssetWithoutLock(id: XCTUnwrap(store.ownedFileBindings(recordID: record.id).first).assetID)
        let payload = store.ownedFileStorage.assetDirectory(asset.id).appendingPathComponent("payload")
        try Data("corrupt original".utf8).write(to: payload)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), [])
        XCTAssertEqual(try Data(contentsOf: target), Data("new contents".utf8))
    }

    func testProjectionParentSymlinkDoesNotWriteOutsideOwnedDirectory() throws {
        let store = try store(), record = try owned(store), view = try snapshot(store, record)
        let url = try XCTUnwrap(view.files[0].url), files = url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: files)
        try FileManager.default.createSymbolicLink(at: files, withDestinationURL: directory)
        XCTAssertEqual(try snapshot(store, record).files[0].status, .unsafeProjection)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("owned.txt").path))
    }

    func testCommitFailureRemovesOnlyNewProjectionAndPreservesOriginalAndDatabase() throws {
        let store = try store(), record = try owned(store), view = try snapshot(store, record)
        let url = try XCTUnwrap(view.files[0].url)
        try FileManager.default.removeItem(at: url)
        sqlite3_set_authorizer(store.database, { _, operation, argument, _, _, _ in
            if operation == SQLITE_TRANSACTION, let argument, String(cString: argument) == "COMMIT" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        sqlite3_set_authorizer(store.database, nil, nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let asset = try store.ownedFileAssetWithoutLock(id: XCTUnwrap(store.ownedFileBindings(recordID: record.id).first).assetID)
        XCTAssertEqual(try store.ownedFileStorage.read(asset), Data("immutable bytes\0中文".utf8))
        XCTAssertEqual(try store.item(id: record.id), record)
        XCTAssertEqual(try store.restoreMissingOwnedProjection(view, file: view.files[0]), .restored(url))
    }

    func testRelocationOutboxFailureRollsBackAllRepresentations() throws {
        let store = try store(); try store.configureSync(accountID: "A")
        let record = try store.create(ClipboardRecord(text: "missing", parts: [part(directory.appendingPathComponent("missing"))]))
        let view = try snapshot(store, record), replacement = try existing()
        try store.execute("CREATE TRIGGER fail_repair_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertThrowsError(try store.relocateExternalFile(view, file: view.files[0], to: replacement))
        XCTAssertEqual(try store.item(id: record.id), record)
        XCTAssertEqual(try Data(contentsOf: replacement), Data("new contents".utf8))
    }
    func testOutputChecksFrozenRevisionsBudgetAndCurrentAccountInOneSnapshot() throws {
        let store = try store(), record = try owned(store)
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        XCTAssertEqual(try store.resolveSelectionForOutput([ref(record)], expectedSyncConfiguration: sync,
                                                           expectedSharingConfiguration: sharing), [record])
        XCTAssertThrowsError(try store.resolveSelectionForOutput([ref(record)], maximumPayloadBytes: 0))
        let peer = try self.store(); var modified = record; modified.renamedTitle = "Changed"
        let updated = try peer.update(record: modified)
        XCTAssertThrowsError(try store.resolveSelectionForOutput([ref(record)]))
        try peer.configureSharing(accountID: "A"); try peer.configureSharing(accountID: nil)
        XCTAssertThrowsError(try store.resolveSelectionForOutput([ref(updated)], expectedSharingConfiguration: sharing))
        try peer.configureSync(accountID: "A", includeLocalData: true)
        try peer.configureSync(accountID: "B")
        XCTAssertThrowsError(try store.resolveSelectionForOutput([ref(updated)]))
        // Generic resolution still supports deletion and recovery of locally retained older-account data.
        XCTAssertEqual(try store.resolveSelection([ref(updated)]), [updated])
    }

    func testOwnedRestorationRejectsStaleAndInactiveAccountButGenericReadSurvivesMissingProjection() throws {
        let store = try store(); try store.configureSync(accountID: "A")
        let record = try owned(store), view = try snapshot(store, record), url = try XCTUnwrap(view.files[0].url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try store.resolveSelection([ref(record)]), [record])
        XCTAssertThrowsError(try store.resolveSelectionForOutput([ref(record)]))
        let peer = try self.store(); try peer.configureSync(accountID: "B")
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try peer.configureSync(accountID: "A")
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(view, file: view.files[0]))
        let fresh = try snapshot(store, record)
        var modified = record; modified.renamedTitle = "Changed"
        _ = try peer.update(record: modified)
        XCTAssertThrowsError(try store.restoreMissingOwnedProjection(fresh, file: fresh.files[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCapturedOutputUsesRegistryAfterRecordChangesWithoutAdoptingOrdinaryURL() throws {
        let store = try store(), record = try owned(store), view = try snapshot(store, record)
        let url = try XCTUnwrap(view.files[0].url), external = try existing()
        var changed = record; changed.renamedTitle = "new metadata"
        _ = try store.update(record: changed)
        XCTAssertNoThrow(try store.validateCapturedFileOutput([record, record]))
        try store.delete(id: record.id)
        XCTAssertNoThrow(try store.validateCapturedFileOutput([record]))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        XCTAssertThrowsError(try store.validateCapturedFileOutput([record]))
        let ordinary = ClipboardRecord(text: "external", parts: [part(external)])
        XCTAssertNoThrow(try store.validateCapturedFileOutput([ordinary]))
        XCTAssertEqual(try store.syncScalar("SELECT count(*) FROM owned_file_bindings", []), "0")
    }

    func testProjectionRollbackDoesNotDeleteAConcurrentReplacement() throws {
        let store = try store(), record = try owned(store), view = try snapshot(store, record)
        let url = try XCTUnwrap(view.files[0].url)
        let asset = try store.ownedFileAssetWithoutLock(id: XCTUnwrap(store.ownedFileBindings(recordID: record.id).first).assetID)
        try FileManager.default.removeItem(at: url)
        let publication = try store.ownedFileStorage.restoreMissingProjection(asset)
        XCTAssertEqual(publication.result, .restored(url))
        try FileManager.default.removeItem(at: url)
        try Data("concurrent replacement".utf8).write(to: url)
        publication.rollback()
        XCTAssertEqual(try Data(contentsOf: url), Data("concurrent replacement".utf8))
        XCTAssertEqual(try store.ownedFileStorage.read(asset), Data("immutable bytes\0中文".utf8))
    }

}
