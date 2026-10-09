import Foundation
import XCTest
@testable import ClipShelfCore

final class IntegrationAccessTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-integration-access-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store() throws -> HistoryStore { try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3")) }

    func testAtomicCreateRejectsPrivateAccountRoundTripFromAnotherConnection() throws {
        let first = try store(), second = try store()
        try first.configureSync(accountID: "A")
        let expected = try first.syncConfiguration(), sharing = try first.sharingConfiguration()
        try second.configureSync(accountID: "B"); try second.configureSync(accountID: "A")
        let record = ClipboardRecord(text: "must not be inserted under stale consent")
        XCTAssertThrowsError(try first.create(record, expectedSyncConfiguration: expected, expectedSharingConfiguration: sharing))
        XCTAssertNil(try first.item(id: record.id))
        XCTAssertEqual(try first.pendingSyncOperations(accountID: "A").count, 0)
        XCTAssertThrowsError(try first.searchIntegrationMetadata(HistoryQuery(), expectedSyncConfiguration: expected, expectedSharingConfiguration: sharing))
    }

    func testAtomicCreateRejectsSharingAccountRoundTripFromAnotherConnection() throws {
        let first = try store(), second = try store()
        try first.configureSharing(accountID: "A")
        let sync = try first.syncConfiguration(), expected = try first.sharingConfiguration()
        try second.configureSharing(accountID: "B"); try second.configureSharing(accountID: "A")
        let record = ClipboardRecord(text: "must not import from an obsolete share consent")
        XCTAssertThrowsError(try first.create(record, expectedSyncConfiguration: sync, expectedSharingConfiguration: expected))
        XCTAssertNil(try first.item(id: record.id))
    }

    func testAtomicCreateValidatesDestinationOwnerInsideTransaction() throws {
        let store = try store()
        try store.configureSync(accountID: "A")
        let oldBoard = try store.createPinboard(name: "Old A")
        try store.configureSync(accountID: "B")
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        let rejected = ClipboardRecord(text: "B input cannot inherit old A", pinboardID: oldBoard.id)
        XCTAssertThrowsError(try store.create(rejected, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing))
        XCTAssertNil(try store.item(id: rejected.id))
        let allowed = ClipboardRecord(text: "Current B input")
        XCTAssertEqual(try store.create(allowed, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing), allowed)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "B").map(\.entityID), [allowed.id])
    }

    func testIntegrationReadFiltersOldAccountBeforePaginationAndCombinesDatePredicate() throws {
        let store = try store()
        let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let local = try store.create(ClipboardRecord(text: "query local", copiedAt: epoch))
        try store.configureSync(accountID: "A")
        let board = try store.createPinboard(name: "Old A")
        try store.create(ClipboardRecord(text: "query old pinned", copiedAt: epoch, pinboardID: board.id))
        try store.create(ClipboardRecord(text: "query old unpinned", copiedAt: epoch))
        try store.configureSync(accountID: "B")
        let current = try store.create(ClipboardRecord(text: "query current", copiedAt: epoch))
        let query = HistoryQuery(text: "query", copiedAfter: epoch.addingTimeInterval(-1), copiedBefore: epoch.addingTimeInterval(1), limit: 1)
        let sync = try store.syncConfiguration(), sharing = try store.sharingConfiguration()
        XCTAssertEqual(try store.searchIntegrationMetadata(query, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing).map(\.id), [current.id])
        XCTAssertEqual(try store.searchIntegrationMetadata(query, offset: 1, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing).map(\.id), [local.id])
        XCTAssertEqual(try store.searchIntegrationMetadata(query, offset: 2, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing).count, 0)
        try store.configureSync(accountID: nil)
        XCTAssertEqual(try store.searchIntegrationMetadata(query, expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: sharing).map(\.id), [local.id])
    }

    func testAtomicUpdateRejectsPrivateAccountABAWithoutAdoptingLocalContent() throws {
        let first = try store(), second = try store()
        let original = try first.create(ClipboardRecord(text: "local original"))
        try first.configureSync(accountID: "A", includeLocalData: false)
        let sync = try first.syncConfiguration(), sharing = try first.sharingConfiguration()
        try second.configureSync(accountID: "B"); try second.configureSync(accountID: "A")
        var edited = original; edited.text = "stale edit"
        XCTAssertThrowsError(try first.update(record: edited, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing)) { error in
            guard case SyncError.accountChanged = error else { return XCTFail("Expected account generation rejection, got \(error)") }
        }
        XCTAssertEqual(try first.item(id: original.id), original)
        XCTAssertEqual(try first.pendingSyncOperations(accountID: "A"), [])
        // The private-only optional gate also checks independently of the sharing gate.
        XCTAssertThrowsError(try first.update(record: edited, expectedSyncConfiguration: sync))
    }

    func testAtomicUpdateRejectsSharingAccountABAIndependently() throws {
        let first = try store(), second = try store()
        let original = try first.create(ClipboardRecord(text: "original"))
        try first.configureSharing(accountID: "A")
        let sharing = try first.sharingConfiguration()
        try second.configureSharing(accountID: "B"); try second.configureSharing(accountID: "A")
        var edited = original; edited.text = "stale sharing consent"
        XCTAssertThrowsError(try first.update(record: edited, expectedSharingConfiguration: sharing))
        XCTAssertEqual(try first.item(id: original.id), original)
    }

    func testConfigurationBoundEditAndUndoStillRejectExternalBodyRevision() throws {
        let first = try store(), second = try store()
        let original = try first.create(ClipboardRecord(text: "original"))
        let sync = try first.syncConfiguration(), sharing = try first.sharingConfiguration()
        var edited = original; edited.text = "saved edit"
        let saved = try first.update(record: edited, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing)
        var external = saved; external.text = "other connection edit"
        let latest = try second.update(record: external)
        var undo = original; undo.revision = saved.revision
        XCTAssertThrowsError(try first.update(record: undo, expectedSyncConfiguration: sync, expectedSharingConfiguration: sharing)) { error in
            guard case HistoryStoreError.staleRevision = error else { return XCTFail("Expected exact revision rejection, got \(error)") }
        }
        XCTAssertEqual(try first.item(id: original.id), latest)
    }
}
