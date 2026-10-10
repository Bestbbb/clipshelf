import Foundation
import XCTest
@testable import ClipShelfCore

final class SharedRecoveryContentQuotaTests: XCTestCase {
    func testReadOnlyDowngradePreservesRejectedDraftAboveQuotaButNewLocalRecoveryRemainsLimited() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-shared-recovery-quota-\(UUID())")
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = "synthetic-owner"
        let source = try store.createPinboard(name: "Source")
        _ = try store.create(ClipboardRecord(text: "a", pinboardID: source.id))
        try store.configureSharing(accountID: account)
        let descriptor = SharedBoardDescriptor(
            boardID: UUID(), accountID: account, containerIdentifier: "iCloud.synthetic",
            zoneName: "ClipShelfShared_synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        let shared = try store.createSharedCopy(from: source.id, descriptor: descriptor)
        let accepted = try store.pendingSharedOperations(boardID: shared.id, accountID: account)
        XCTAssertEqual(accepted.count, 2)
        try store.acknowledgeSharedOperations(boardID: shared.id, accountID: account,
                                              operationIDs: Set(accepted.map(\.operationID)))
        var edited = try XCTUnwrap(store.search(HistoryQuery(pinboardIDs: [shared.id])).first)
        edited.text = "b"
        _ = try store.update(record: edited)
        let pending = try store.pendingSharedOperations(boardID: shared.id, accountID: account)
        XCTAssertEqual(pending.count, 1)
        let rejected = try XCTUnwrap(pending.first)
        let before = try store.contentQuotaStatus()
        _ = try store.setContentQuotaLimit(before.usedBytes, expectedRevision: before.policyRevision)

        try store.updateSharedAccess(boardID: shared.id, accountID: account, access: .readOnly)
        let reason = String(repeating: "permission downgraded; ", count: 20)
        try store.rejectPendingSharedEdits(boardID: shared.id, accountID: account, reason: reason)

        let restored = try XCTUnwrap(store.item(id: edited.id))
        XCTAssertEqual(restored.text, "a")
        XCTAssertEqual(restored.pinboardID, shared.id)
        let drafts = try store.failedSharedDrafts(boardID: shared.id, accountID: account)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.operation.operationID, rejected.operationID)
        XCTAssertEqual(drafts.first?.operation.record?.text, "b")
        XCTAssertEqual(drafts.first?.reason, reason)
        XCTAssertEqual(try store.synchronized {
            try store.syncScalar("SELECT CAST(count(*) AS TEXT) FROM sync_outbox WHERE account_id = ?", [descriptor.namespace])
        }, "0")
        let after = try store.contentQuotaStatus()
        XCTAssertEqual(after.recordBytes, before.recordBytes)
        XCTAssertGreaterThan(after.syncPayloadBytes, before.syncPayloadBytes,
                             "Preserving the rejection reason adds bytes to the original operation payload")
        XCTAssertGreaterThan(after.usedBytes, before.usedBytes)
        XCTAssertGreaterThan(after.exceededBytes, 0)

        // Creating a separate local copy is a new save, so it must still obey the limit.
        let recordCount = try store.synchronized {
            try store.syncScalar("SELECT CAST(count(*) AS TEXT) FROM clipboard_records", [])
        }
        XCTAssertThrowsError(try store.recoverFailedSharedDraft(operationID: rejected.operationID,
                                                               boardID: shared.id, accountID: account)) {
            guard case .exceeded = $0 as? ContentQuotaError else { return XCTFail("Expected quota failure, got \($0)") }
        }
        XCTAssertEqual(try store.synchronized {
            try store.syncScalar("SELECT CAST(count(*) AS TEXT) FROM clipboard_records", [])
        }, recordCount)
        XCTAssertEqual(try store.item(id: edited.id), restored)
        XCTAssertEqual(try store.failedSharedDrafts(boardID: shared.id, accountID: account).map(\.id), [rejected.operationID])
        XCTAssertEqual(try store.contentQuotaStatus(), after)
    }
}
