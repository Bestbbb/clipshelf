import Foundation
import XCTest
@testable import ClipShelfCore

final class SelectionContentQuotaTests: XCTestCase {
    func testSyncedSelectionDeletionCanGrowItsTombstoneAboveQuotaWithoutBlockingCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-selection-quota-\(UUID())")
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = "synthetic-account"
        try store.configureSync(accountID: account)
        let record = try store.create(ClipboardRecord(text: "x"))
        let published = try store.pendingSyncOperations(accountID: account)
        XCTAssertEqual(published.count, 1)
        try store.acknowledgeSyncOperations(accountID: account, operationIDs: Set(published.map(\.operationID)))
        let before = try store.contentQuotaStatus()
        XCTAssertEqual(before.syncPayloadBytes, 0)
        XCTAssertGreaterThan(before.usedBytes, 0)
        _ = try store.setContentQuotaLimit(before.usedBytes, expectedRevision: before.policyRevision)

        let undo = try store.deleteSelection([.init(id: record.id, revision: record.revision)])
        withExtendedLifetime(undo) {}
        XCTAssertNil(try store.item(id: record.id))
        let deletion = try XCTUnwrap(store.pendingSyncOperations(accountID: account).first)
        XCTAssertEqual(deletion.entityID, record.id)
        XCTAssertEqual(deletion.action, .delete)
        XCTAssertEqual(deletion.baseOperationID, published.first?.operationID)
        let after = try store.contentQuotaStatus()
        XCTAssertEqual(after.recordBytes, 0)
        XCTAssertGreaterThan(after.usedBytes, before.usedBytes, "The required tombstone is larger than the deleted tiny record")
        XCTAssertGreaterThan(after.exceededBytes, 0)

        // Only explicit deletion is exempt. Normal creation must retain quota enforcement.
        XCTAssertThrowsError(try store.create(ClipboardRecord(text: "still blocked"))) {
            guard case .exceeded = $0 as? ContentQuotaError else { return XCTFail("Expected quota failure, got \($0)") }
        }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: account).map(\.operationID), [deletion.operationID])
    }
}
