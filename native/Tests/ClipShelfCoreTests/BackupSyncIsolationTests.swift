import Foundation
import XCTest
@testable import ClipShelfCore

final class BackupSyncIsolationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-backup-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String) throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3"))
    }
    private func accountABackup() throws -> (URL, ClipboardRecord, Pinboard) {
        let source = try store("source-A")
        try source.configureSync(accountID: "account-A")
        let board = try source.createPinboard(name: "Account A board")
        let record = ClipboardRecord(text: "Account A private text", parts: [ClipboardPart(representations: [
            ClipboardRepresentation(typeIdentifier: "public.html", data: Data("<b>private A</b>".utf8)),
        ])], pinboardID: board.id)
        try source.create(record)
        let archive = directory.appendingPathComponent("account-A.clipshelfbackup")
        try source.exportBackup(to: archive)
        return (archive, record, board)
    }

    func testAccountAArchiveCannotReplaceAccountBOrEnqueueCloudDeletes() throws {
        let (archive, _, _) = try accountABackup()
        let destination = try store("destination-B")
        try destination.configureSync(accountID: "account-B")
        let original = try destination.create(ClipboardRecord(text: "B existing item"))
        let pending = try destination.pendingSyncOperations(accountID: "account-B")
        XCTAssertThrowsError(try destination.restoreBackup(from: archive, mode: .replace)) { error in
            guard case HistoryStoreError.syncedProfileRequiresLocalMerge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try destination.load(), [original])
        XCTAssertEqual(try destination.pendingSyncOperations(accountID: "account-B"), pending)
        try destination.configureSync(accountID: nil)
        XCTAssertThrowsError(try destination.restoreBackup(from: archive, mode: .replace), "Disabling sync does not erase ownership")
        try destination.configureSync(accountID: "account-B")
        XCTAssertEqual(try destination.pendingSyncOperations(accountID: "account-B"), pending)
    }

    func testCrossAccountMergeCreatesLocalIDsAndPreservesQueuesAcrossEditAndRestart() throws {
        let (archive, sourceRecord, sourceBoard) = try accountABackup()
        let destination = try store("destination-B")
        try destination.configureSync(accountID: "account-B")
        _ = try destination.create(ClipboardRecord(text: "B existing item"))
        let pending = try destination.pendingSyncOperations(accountID: "account-B")
        let summary = try destination.restoreBackup(from: archive, mode: .merge)
        XCTAssertTrue(summary.restoredAsLocalOnly); XCTAssertTrue(summary.identitiesRemapped)
        var imported = try XCTUnwrap(destination.search(HistoryQuery(text: "Account A private text")).first)
        XCTAssertNotEqual(imported.id, sourceRecord.id); XCTAssertNotEqual(imported.pinboardID, sourceBoard.id)
        XCTAssertEqual(imported.parts, sourceRecord.parts)
        let importedBoardID = try XCTUnwrap(imported.pinboardID)
        XCTAssertNil(try destination.pinboardNamespace(id: importedBoardID))
        XCTAssertEqual(try destination.pendingSyncOperations(accountID: "account-B"), pending)
        imported.text = "Locally edited restored text"
        _ = try destination.update(record: imported)
        var board = try XCTUnwrap(destination.pinboards().first { $0.id == importedBoardID })
        board.name = "Local restored board"; try destination.updatePinboard(board)
        try destination.create(ClipboardRecord(text: "New item kept in restored local board", pinboardID: importedBoardID))
        let reopened = try store("destination-B")
        try reopened.configureSync(accountID: "account-B", includeLocalData: false)
        XCTAssertEqual(try reopened.pendingSyncOperations(accountID: "account-B"), pending)
        let localIDs = Set(try reopened.search(HistoryQuery(pinboardIDs: [importedBoardID])).map(\.id))
        try reopened.configureSync(accountID: "account-B", includeLocalData: true)
        let optedIn = try reopened.pendingSyncOperations(accountID: "account-B")
        XCTAssertTrue(Set(optedIn.map(\.entityID)).isSuperset(of: localIDs.union([importedBoardID])))
        XCTAssertFalse(optedIn.contains { $0.entityID == sourceRecord.id || $0.entityID == sourceBoard.id })
    }

    func testFreshProfileRemapsSyncedArchiveAndOrdinaryEnableDoesNotUploadIt() throws {
        let (archive, original, _) = try accountABackup()
        let fresh = try store("fresh")
        _ = try fresh.restoreBackup(from: archive, mode: .replace)
        let restored = try XCTUnwrap(fresh.load().first)
        XCTAssertNotEqual(restored.id, original.id)
        try fresh.configureSync(accountID: "account-B", includeLocalData: false)
        XCTAssertEqual(try fresh.pendingSyncOperations(accountID: "account-B").count, 0)
        try fresh.delete(id: restored.id)
        XCTAssertEqual(try fresh.pendingSyncOperations(accountID: "account-B").count, 0, "Deleting a restored local copy cannot enqueue a cloud tombstone")
    }

    func testRestoreIntoDisabledOwnedProfileDoesNotModifyEitherAccountQueue() throws {
        let (archive, _, _) = try accountABackup()
        let destination = try store("disabled")
        try destination.configureSync(accountID: "account-B")
        try destination.create(ClipboardRecord(text: "queued B"))
        let before = try destination.pendingSyncOperations(accountID: "account-B")
        try destination.configureSync(accountID: nil)
        _ = try destination.restoreBackup(from: archive, mode: .merge)
        try destination.configureSync(accountID: "account-A", includeLocalData: false)
        XCTAssertEqual(try destination.pendingSyncOperations(accountID: "account-A").count, 0)
        try destination.configureSync(accountID: "account-B", includeLocalData: false)
        XCTAssertEqual(try destination.pendingSyncOperations(accountID: "account-B"), before)
    }

    func testRestoredLocalCopyCannotMoveIntoCloudBoardWithoutExplicitOptIn() throws {
        let (archive, _, _) = try accountABackup()
        let destination = try store("destination-B")
        try destination.configureSync(accountID: "account-B")
        let cloudBoard = try destination.createPinboard(name: "Cloud B")
        _ = try destination.restoreBackup(from: archive, mode: .merge)
        let record = try XCTUnwrap(destination.load().first)
        XCTAssertThrowsError(try destination.move(recordID: record.id, to: cloudBoard.id))
        XCTAssertEqual(try destination.item(id: record.id)?.pinboardID, record.pinboardID)
        let pending = try destination.pendingSyncOperations(accountID: "account-B")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.entityID, cloudBoard.id)
    }
}
