import Foundation
import XCTest
@testable import ClipShelfCore

final class OwnedSyncProtocolTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func store(_ name: String = "db") throws -> HistoryStore { try HistoryStore(databaseURL: root.appendingPathComponent(name + ".sqlite")) }
    private func scope(account: String = "account", zone: String = "zone") -> SyncOwnedFileScope {
        .init(accountID: account, containerIdentifier: "iCloud.test", database: .privateDatabase, zoneOwnerName: "owner", zoneName: zone, namespace: account)
    }
    private func descriptor(_ data: Data = Data("payload".utf8), filename: String = "测试.txt") -> SyncOwnedFileDescriptor {
        .init(digest: RepresentationStorage.digest(data), byteCount: data.count, filename: filename)
    }
    private func fixture(_ file: SyncOwnedFileDescriptor) -> (ClipboardRecord, SyncOwnedFileManifest) {
        let record = ClipboardRecord(text: file.filename, parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data(SyncOwnedFileManifest.token(digest: file.digest, filename: file.filename).utf8))])])
        return (record, .init(files: [file], bindings: [.init(partIndex: 0, representationIndex: 0, digest: file.digest, filename: file.filename)]))
    }
    private func imported(_ store: HistoryStore) throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: "file", parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data())])]),
                         ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "测试.txt", data: Data("payload".utf8))],
                         expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }
    func testLegacyJSONRoundTripDoesNotAddOptionalFieldsAndUnknownWireRejected() throws {
        let id = UUID(), record = ClipboardRecord(id: id, text: "legacy")
        let old = SyncOperation(accountID: "account", entityID: id, entityKind: .clipboard, action: .upsert, baseRevision: 0, revision: 1, record: record)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(old), decoded = try JSONDecoder().decode(SyncOperation.self, from: before)
        XCTAssertEqual(try encoder.encode(decoded), before)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        XCTAssertNil(object["ownedFiles"]); XCTAssertNil(object["formatVersion"])
        var future = object; future["formatVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(SyncOperation.self, from: JSONSerialization.data(withJSONObject: future)))
        let (fileRecord, manifest) = fixture(descriptor())
        let missingVersion = SyncOperation(accountID: "account", entityID: fileRecord.id, entityKind: .clipboard, action: .upsert, baseRevision: 0, revision: 1, record: fileRecord, ownedFiles: manifest)
        XCTAssertThrowsError(try JSONDecoder().decode(SyncOperation.self, from: encoder.encode(missingVersion)))
    }
    func testManifestRejectsInvalidNamesDigestsLimitsDuplicateAndDanglingSlots() throws {
        let file = descriptor(), (record, manifest) = fixture(file)
        XCTAssertNoThrow(try manifest.validate(record: record))
        for name in ["", ".", "..", "../x", "x/y", "x\\y", "x\0y", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try descriptor(filename: name).validate())
        }
        for bad in [SyncOwnedFileDescriptor(digest: "bad", byteCount: 7, filename: "x"),
                    .init(digest: file.digest, byteCount: -1, filename: "x"),
                    .init(digest: file.digest, byteCount: SyncOwnedFileLimits.maximumFileBytes + 1, filename: "x")] { XCTAssertThrowsError(try bad.validate()) }
        XCTAssertThrowsError(try SyncOwnedFileManifest(version: 2, files: [file], bindings: manifest.bindings).validate(record: record))
        XCTAssertThrowsError(try SyncOwnedFileManifest(files: [file, file], bindings: manifest.bindings).validate(record: record))
        XCTAssertThrowsError(try SyncOwnedFileManifest(files: [file], bindings: manifest.bindings + manifest.bindings).validate(record: record))
        XCTAssertThrowsError(try SyncOwnedFileManifest(files: [file], bindings: [.init(partIndex: 2, representationIndex: 0, digest: file.digest, filename: file.filename)]).validate(record: record))
        let contradictory = SyncOwnedFileDescriptor(digest: file.digest, byteCount: file.byteCount + 1, filename: "other")
        XCTAssertThrowsError(try SyncOwnedFileManifest(files: [file, contradictory], bindings: manifest.bindings).validate(record: record))
        var alias = record; alias.parts[0].representations.append(.init(typeIdentifier: "public.url", data: Data("file:///sender/path".utf8)))
        XCTAssertThrowsError(try manifest.validate(record: alias))
        var path = record; path.parts[0].representations[0].data = Data("file:///sender/path".utf8)
        XCTAssertThrowsError(try manifest.validate(record: path))
    }
    func testStagingRejectsFinalAndParentSymlinkLengthDigestAndHardlink() throws {
        let bytes = Data("payload".utf8), file = descriptor(), input = root.appendingPathComponent("input")
        try bytes.write(to: input)
        XCTAssertNoThrow(try SyncOwnedFileStaging.copy(from: input, descriptor: file))
        let final = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: input)
        XCTAssertThrowsError(try SyncOwnedFileStaging.copy(from: final, descriptor: file))
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
        XCTAssertThrowsError(try SyncOwnedFileStaging.copy(from: parent.appendingPathComponent("input"), descriptor: file))
        XCTAssertThrowsError(try SyncOwnedFileStaging.copy(from: input, descriptor: .init(digest: file.digest, byteCount: file.byteCount + 1, filename: file.filename)))
        XCTAssertThrowsError(try SyncOwnedFileStaging.copy(from: input, descriptor: descriptor(Data("another".utf8))))
        let hard = root.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: input, to: hard)
        XCTAssertThrowsError(try SyncOwnedFileStaging.copy(from: hard, descriptor: file))
    }
    func testStagingCopiesBytesAndOwnsLifetimeIndependently() throws {
        let input = root.appendingPathComponent("input"), bytes = Data("payload".utf8)
        try bytes.write(to: input)
        var stage: SyncOwnedFileStaging? = try .copy(from: input, descriptor: descriptor())
        let path = try XCTUnwrap(stage?.fileURL)
        try Data("changed".utf8).write(to: input)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        stage = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testOpaqueContextRejectsOtherStoreZoneChangeAndAccountABA() throws {
        let a = try store(), b = try store("other")
        try a.configureSync(accountID: "account"); try b.configureSync(accountID: "account")
        let context = try a.makeSyncTransferContext(scope: scope())
        XCTAssertThrowsError(try b.validateSyncTransferContext(context))
        _ = try a.makeSyncTransferContext(scope: scope(zone: "different"))
        XCTAssertThrowsError(try a.validateSyncTransferContext(context))
        let fresh = try a.makeSyncTransferContext(scope: scope())
        try a.configureSync(accountID: "B"); try a.configureSync(accountID: "account")
        XCTAssertThrowsError(try a.validateSyncTransferContext(fresh))
        XCTAssertThrowsError(try a.makeSyncTransferContext(scope: scope(account: "B")))
    }
    func testSharedAccessABACannotReuseContextEvenWhenAccountAndDescriptorMatch() throws {
        let store = try store(), board = SharedBoardDescriptor(boardID: UUID(), accountID: "account", containerIdentifier: "iCloud.test", zoneName: "zone", zoneOwnerName: "owner", shareRecordName: "share")
        try store.configureSharing(accountID: "account"); try store.registerSharedBoard(board, access: .readWrite)
        let scope = SyncOwnedFileScope(accountID: "account", containerIdentifier: board.containerIdentifier, database: .sharedDatabase, zoneOwnerName: board.zoneOwnerName, zoneName: board.zoneName, namespace: board.namespace)
        let context = try store.makeSyncTransferContext(scope: scope)
        try store.updateSharedAccess(boardID: board.boardID, accountID: "account", access: .readOnly)
        try store.updateSharedAccess(boardID: board.boardID, accountID: "account", access: .readWrite)
        XCTAssertThrowsError(try store.validateSyncTransferContext(context, writing: true))
        let replacement = try store.makeSyncTransferContext(scope: scope)
        try store.registerSharedBoard(board, access: .readWrite)
        XCTAssertThrowsError(try store.validateSyncTransferContext(replacement))
        XCTAssertThrowsError(try store.makeSyncTransferContext(scope: .init(accountID: "account", containerIdentifier: "iCloud.test", database: .privateDatabase, zoneOwnerName: "owner", zoneName: "zone", namespace: board.namespace)))
    }
    func testDuplicateFileTypesAreRejectedAndMultipleFilePartsPreserveSubsequentContent() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        let other = ClipboardPart(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("keep me".utf8))])
        let record = ClipboardRecord(text: "two files", parts: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data()), .init(typeIdentifier: "public.file-url", data: Data()), .init(typeIdentifier: "opaque", data: Data("sender bookmark".utf8))]), other])
        let imports: [OwnedFileImport] = [.init(partIndex: 0, representationIndex: 0, filename: "one", data: Data([1])), .init(partIndex: 0, representationIndex: 1, filename: "two", data: Data([2]))]
        XCTAssertThrowsError(try store.create(record, ownedFiles: imports, expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration()))
        var valid = record
        valid.parts = [.init(representations: [record.parts[0].representations[0]]), .init(representations: [record.parts[0].representations[1]]), other]
        let saved = try store.create(valid, ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "one", data: Data([1])), .init(partIndex: 1, representationIndex: 0, filename: "two", data: Data([2]))], expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        let operation = try XCTUnwrap(store.pendingSyncOperations(accountID: "account").first { $0.entityID == saved.id })
        let wire = try XCTUnwrap(operation.record), manifest = try XCTUnwrap(operation.ownedFiles)
        XCTAssertEqual(wire.parts.count, 3); XCTAssertEqual(wire.parts[2], other)
        XCTAssertEqual(manifest.bindings.map(\.partIndex), [0, 1]); XCTAssertEqual(manifest.files.map(\.filename), ["one", "two"])
        let context = try store.makeSyncTransferContext(scope: scope())
        for (index, file) in manifest.files.enumerated() {
            let upload = try store.prepareSyncOwnedUpload(operationID: operation.operationID, file: file, context: context)
            XCTAssertEqual(try Data(contentsOf: upload.fileURL), Data([UInt8(index + 1)]))
        }
    }
    func testCorruptCachedOriginalDefersOnlyNewRevisionAndCanDownloadAgain() throws {
        let a = try store("a"), b = try store("b")
        try a.configureSync(accountID: "account"); try b.configureSync(accountID: "account")
        let original = try imported(a), first = try XCTUnwrap(a.pendingSyncOperations(accountID: "account").first)
        let uploadContext = try a.makeSyncTransferContext(scope: scope()), receiveContext = try b.makeSyncTransferContext(scope: scope())
        try b.applyRemoteChanges(accountID: "account", changes: [first], nextCursor: Data([1]))
        let request = try XCTUnwrap(b.pendingSyncOwnedDownloads(context: receiveContext).first)
        let upload = try a.prepareSyncOwnedUpload(operationID: first.operationID, file: request.file, context: uploadContext)
        try b.acceptSyncOwnedDownload(request, stagedFileURL: upload.fileURL, context: receiveContext)
        let old = try XCTUnwrap(b.item(id: original.id)), binding = try XCTUnwrap(b.ownedFileBindings(recordID: old.id).first)
        let corrupt = b.ownedFileStorage.assetDirectory(binding.assetID).appendingPathComponent("payload")
        try Data("damaged".utf8).write(to: corrupt)
        var edit = original; edit.renamedTitle = "new revision"
        _ = try a.update(record: edit)
        let second = try XCTUnwrap(a.pendingSyncOperations(accountID: "account").last)
        let text = ClipboardRecord(text: "independent")
        let independent = SyncOperation(accountID: "account", entityID: text.id, entityKind: .clipboard, action: .upsert, baseRevision: 0, revision: 1, record: text)
        try b.applyRemoteChanges(accountID: "account", changes: [second, independent], nextCursor: Data([2]))
        XCTAssertEqual(try b.item(id: old.id)?.renamedTitle, old.renamedTitle)
        XCTAssertNotNil(try b.item(id: text.id))
        let retry = try XCTUnwrap(b.pendingSyncOwnedDownloads(context: receiveContext).first)
        try b.acceptSyncOwnedDownload(retry, stagedFileURL: upload.fileURL, context: receiveContext)
        XCTAssertEqual(try b.item(id: old.id)?.renamedTitle, edit.renamedTitle)
        let restored = try XCTUnwrap(b.ownedFileBindings(recordID: old.id).first)
        XCTAssertNotEqual(restored.assetID, binding.assetID)
        XCTAssertEqual(try b.ownedFileStorage.read(b.ownedFileAssetWithoutLock(id: restored.assetID)), Data("payload".utf8))
    }
    func testStatusQueriesAreReadOnlyAndHidePreviousAccounts() throws {
        let store = try store(); try store.configureSync(accountID: "account")
        _ = try imported(store)
        let operation = try XCTUnwrap(store.pendingSyncOperations(accountID: "account").first)
        let file = try XCTUnwrap(operation.ownedFiles?.files.first), context = try store.makeSyncTransferContext(scope: scope())
        try store.recordSyncOwnedUpload(operationID: operation.operationID, file: file, context: context, error: "offline")
        XCTAssertEqual(try store.syncOwnedTransferStates().count, 1)
        let before = try store.pendingSyncOperations(accountID: "account")
        _ = try store.syncOwnedTransferStates()
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "account"), before)
        try store.configureSync(accountID: "other")
        XCTAssertTrue(try store.syncOwnedTransferStates().isEmpty)
    }
}
