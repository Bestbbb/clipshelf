import AppKit
import ClipShelfCore
import Foundation
import ShareInboxShared
import XCTest
@testable import ClipShelf

final class ShareInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: ShareInboxDirectory!
    private var store: HistoryStore!
    private var service: ShareInboxService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-share-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        inbox = try ShareInboxDirectory(root: root.appendingPathComponent("group"))
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite3"))
        service = try ShareInboxService(store: store, privateDirectory: root.appendingPathComponent("private"), inbox: inbox)
    }
    override func tearDownWithError() throws {
        service = nil; store = nil; inbox = nil
        try FileManager.default.removeItem(at: root)
    }
    @discardableResult private func enqueue(_ text: String = "synthetic share", destination: ShareInboxDestination? = nil) throws -> UUID {
        let catalog = try inbox.readCatalog()
        let draft = try inbox.makeDraft(itemCount: 1)
        try draft.append(data: Data(text.utf8), typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        return try draft.publish(destination: destination ?? XCTUnwrap(catalog.destinations.first), catalog: catalog)
    }
    func testCancelAndDeinitializationNeverPublish() async throws {
        try await service.publishDestinations()
        let draft = try inbox.makeDraft(itemCount: 1)
        try draft.append(data: Data("secret fixture".utf8), typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        draft.cancel()
        XCTAssertThrowsError(try draft.publish(destination: inbox.readCatalog().destinations[0], catalog: inbox.readCatalog()))
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inbox.staging.path).isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testPublishRequiresCurrentSelectedDestinationAndAccountBinding() async throws {
        try await service.publishDestinations()
        let old = try inbox.readCatalog()
        let draft = try inbox.makeDraft(itemCount: 1)
        try draft.append(data: Data("fixture".utf8), typeIdentifier: "public.utf8-plain-text", itemIndex: 0)
        XCTAssertThrowsError(try draft.publish(destination: .init(boardID: UUID(), name: "unknown"), catalog: old))
        try store.configureSync(accountID: "different-account")
        try await service.publishDestinations()
        XCTAssertThrowsError(try draft.publish(destination: old.destinations[0], catalog: old))
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }
    func testConfidentialAndSizeItemLimits() throws {
        XCTAssertThrowsError(try inbox.makeDraft(itemCount: 0))
        XCTAssertThrowsError(try inbox.makeDraft(itemCount: 21))
        let draft = try inbox.makeDraft(itemCount: 1)
        XCTAssertThrowsError(try draft.append(data: Data(), typeIdentifier: "org.nspasteboard.ConcealedType", itemIndex: 0))
        XCTAssertThrowsError(try draft.append(data: Data(count: ShareInboxDirectory.maximumBytes + 1), typeIdentifier: "public.png", itemIndex: 0))
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }
    func testImportAssignsLocalIDsAndPreservesRepeatedShares() async throws {
        try await service.publishDestinations()
        let one = try enqueue("same"), two = try enqueue("same")
        let result = try await service.importPending()
        XCTAssertEqual(result.imported, 2); XCTAssertTrue(result.failures.isEmpty)
        let records = try store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertFalse(records.contains { $0.id == one || $0.id == two })
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }
    func testReplayAfterUserDeletionDoesNotResurrect() async throws {
        try await service.publishDestinations()
        let id = try enqueue()
        let incoming = inbox.inbox.appendingPathComponent(id.uuidString)
        let backup = root.appendingPathComponent("saved-incoming")
        try FileManager.default.copyItem(at: incoming, to: backup)
        let initial = try await service.importPending()
        XCTAssertEqual(initial.imported, 1)
        try store.delete(id: XCTUnwrap(store.load().first).id)
        try FileManager.default.copyItem(at: backup, to: incoming)
        let replay = try await service.importPending()
        XCTAssertEqual(replay.imported, 0); XCTAssertEqual(replay.alreadyImported, 1)
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testMalformedPayloadRemainsRecoverable() async throws {
        try await service.publishDestinations()
        let id = try enqueue()
        let envelope = try inbox.read(id).0
        let file = inbox.inbox.appendingPathComponent(id.uuidString).appendingPathComponent(envelope.items[0].representations[0].filename)
        try Data("tampered".utf8).write(to: file)
        let result = try await service.importPending()
        XCTAssertEqual(result.imported, 0); XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try inbox.pendingIDs(), [id]); XCTAssertTrue(try store.load().isEmpty)
    }
    func testRejectsSymlinksAndPathTraversal() async throws {
        try await service.publishDestinations()
        let id = try enqueue()
        let directory = inbox.inbox.appendingPathComponent(id.uuidString)
        let envelope = try inbox.read(id).0
        let payload = directory.appendingPathComponent(envelope.items[0].representations[0].filename)
        let unrelated = root.appendingPathComponent("unrelated")
        try Data("synthetic share".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: unrelated)
        XCTAssertThrowsError(try inbox.data(for: envelope.items[0].representations[0], operationID: id))
        let manifest = directory.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        var representations = try XCTUnwrap(items[0]["representations"] as? [[String: Any]])
        representations[0]["filename"] = "../../unrelated"
        items[0]["representations"] = representations; object["items"] = items
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        XCTAssertThrowsError(try inbox.read(id))
    }
    func testQueuedFileSurvivesInboxCleanup() async throws {
        try await service.publishDestinations()
        let catalog = try inbox.readCatalog(), bytes = Data("synthetic document".utf8)
        let draft = try inbox.makeDraft(itemCount: 1)
        try draft.append(data: bytes, typeIdentifier: "io.github.bestbbb.clipshelf.shared-file", itemIndex: 0, originalFilename: "示例.txt")
        try draft.publish(destination: catalog.destinations[0], catalog: catalog)
        let result = try await service.importPending()
        XCTAssertEqual(result.imported, 1)
        let representation = try XCTUnwrap(store.load().first?.parts.first?.representations.first)
        XCTAssertEqual(representation.typeIdentifier, "public.file-url")
        let url = try XCTUnwrap(URL(string: XCTUnwrap(String(data: representation.data, encoding: .utf8))))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(url.path.contains("/ShareImports/Files/")); XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }
    func testAccountChangeAndDisabledImportDoNotRedirectQueuedContent() async throws {
        try await service.publishDestinations()
        let id = try enqueue()
        try await service.publishDestinations(allowImports: false)
        let paused = try await service.importPending()
        XCTAssertEqual(paused.imported, 0); XCTAssertEqual(try inbox.pendingIDs(), [id])
        try store.configureSync(accountID: "new-account")
        try await service.publishDestinations()
        let switched = try await service.importPending()
        XCTAssertEqual(switched.imported, 0); XCTAssertEqual(switched.failures.count, 1)
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testAtomicCreateRejectsAccountSwitchBackWithNewGeneration() throws {
        let expectedSync = try store.syncConfiguration()
        let expectedSharing = try store.sharingConfiguration()
        try store.configureSync(accountID: "intervening-account")
        try store.configureSync(accountID: expectedSync.accountID)
        XCTAssertThrowsError(try store.create(ClipboardRecord(text: "must not cross account transition"),
            expectedSyncConfiguration: expectedSync, expectedSharingConfiguration: expectedSharing))
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testPrivateBoardOwnershipCatalogAndImport() async throws {
        try store.configureSync(accountID: "one")
        let board = try store.createPinboard(name: "First account")
        try await service.publishDestinations()
        let destination = try XCTUnwrap(inbox.readCatalog().destinations.first { $0.boardID == board.id })
        try enqueue(destination: destination)
        let result = try await service.importPending()
        XCTAssertEqual(result.imported, 1); XCTAssertEqual(try store.load().first?.pinboardID, board.id)
        try store.configureSync(accountID: "two")
        try await service.publishDestinations()
        XCTAssertFalse(try inbox.readCatalog().destinations.contains { $0.boardID == board.id })
    }
    func testSharedBoardReadOnlyRejectionAndNamespace() async throws {
        try store.configureSharing(accountID: "sharing-account")
        let source = try store.createPinboard(name: "Share fixture")
        let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "sharing-account", containerIdentifier: "iCloud.test.container", zoneName: "zone", zoneOwnerName: "owner", shareRecordName: "share")
        let board = try store.createSharedCopy(from: source.id, descriptor: descriptor)
        try await service.publishDestinations()
        let destination = try XCTUnwrap(inbox.readCatalog().destinations.first { $0.boardID == board.id })
        XCTAssertTrue(destination.isShared)
        let id = try enqueue(destination: destination)
        try store.updateSharedAccess(boardID: board.id, accountID: descriptor.accountID, access: .readOnly)
        let blocked = try await service.importPending()
        XCTAssertEqual(blocked.imported, 0); XCTAssertEqual(blocked.failures.count, 1)
        XCTAssertEqual(try inbox.pendingIDs(), [id])
        try store.updateSharedAccess(boardID: board.id, accountID: descriptor.accountID, access: .readWrite)
        let allowed = try await service.importPending()
        XCTAssertEqual(allowed.imported, 1)
        let record = try XCTUnwrap(store.search(HistoryQuery(pinboardIDs: [board.id])).first)
        XCTAssertFalse(record.isInHistory)
        let operations = try store.pendingSharedOperations(boardID: board.id, accountID: descriptor.accountID)
        XCTAssertTrue(operations.contains { $0.entityID == record.id })
    }
    func testRealItemProviderLoadsTextButDoesNotPublishUntilSave() async throws {
        try await service.publishDestinations()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.utf8-plain-text", visibility: .all) { completion in
            completion(Data("provider fixture 你好".utf8), nil)
            return nil
        }
        let draft = try inbox.makeDraft(itemCount: 1)
        try await ShareProviderLoader().load([provider], into: draft)
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
        let catalog = try inbox.readCatalog()
        try draft.publish(destination: catalog.destinations[0], catalog: catalog)
        let result = try await service.importPending()
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(try store.load().first?.text, "provider fixture 你好")
    }
    func testProviderConfidentialMarkerRejectsEntireBatchBeforeReading() async throws {
        let confidential = NSItemProvider()
        confidential.registerDataRepresentation(forTypeIdentifier: "org.nspasteboard.ConcealedType", visibility: .all) { completion in
            XCTFail("Confidential bytes must not be requested")
            completion(Data(), nil); return nil
        }
        let draft = try inbox.makeDraft(itemCount: 1)
        do { try await ShareProviderLoader().load([confidential], into: draft); XCTFail("Expected rejection") }
        catch ShareInboxError.confidential {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }
    func testCancelledProviderCannotStageOrPublish() async throws {
        let loader = ShareProviderLoader(); loader.cancel()
        let draft = try inbox.makeDraft(itemCount: 1)
        do { try await loader.load([NSItemProvider(object: "fixture" as NSString)], into: draft); XCTFail("Expected cancellation") }
        catch ShareInboxError.cancelled {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(try inbox.pendingIDs().isEmpty)
    }
    func testMissingAppGroupFailsExplicitly() {
        XCTAssertThrowsError(try ShareInboxDirectory.configured(bundle: Bundle(for: Self.self)))
    }
}
