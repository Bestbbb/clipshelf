import ClipShelfCore
import Foundation
import XCTest
@testable import ClipShelf

private actor LifecycleTransportFixture: SharedBoardLifecycleTransport {
    let account = "synthetic-account"
    var operationLog: [String: [SyncOperation]] = [:]
    var permissions: [UUID: SharedBoardAccess] = [:]
    var createdCount = 0
    var stoppedCount = 0
    var updatedPermissionsCount = 0
    func counts() -> (Int, Int, Int) { (createdCount, stoppedCount, updatedPermissionsCount) }
    func resolveAccount(expectedAccountID: String?) async throws -> String {
        if let expectedAccountID, expectedAccountID != account { throw SharedBoardError.accountChanged }
        return account
    }
    func createShare(boardID: UUID, title: String, allowEditing: Bool, expectedAccountID: String) async throws -> SharedBoardDescriptor {
        guard expectedAccountID == account else { throw SharedBoardError.accountChanged }
        createdCount += 1
        permissions[boardID] = .owner
        return SharedBoardDescriptor(boardID: boardID, accountID: account, containerIdentifier: "iCloud.test.synthetic",
                                     zoneName: "ClipShelfShared_" + boardID.uuidString, zoneOwnerName: "owner",
                                     shareRecordName: "share", shareURL: URL(string: "https://www.icloud.com/share/synthetic"))
    }
    func acceptShare(url: URL, expectedAccountID: String) async throws -> SharedBoardDescriptor { throw SharedBoardError.notRegistered }
    func stopSharing(_ board: SharedBoardDescriptor) async throws { stoppedCount += 1; permissions[board.boardID] = .revoked }
    func leave(_ board: SharedBoardDescriptor) async throws { permissions[board.boardID] = .revoked }
    func updateLinkPermission(board: SharedBoardDescriptor, allowEditing: Bool) async throws { updatedPermissionsCount += 1 }
    func access(for board: SharedBoardDescriptor) async throws -> SharedBoardAccess { permissions[board.boardID] ?? .revoked }
    func push(_ operations: [SyncOperation], board: SharedBoardDescriptor) async throws -> Set<UUID> {
        guard (permissions[board.boardID] ?? .revoked).canWrite else { throw SharedBoardError.remotePermissionDenied }
        var log = operationLog[board.namespace] ?? []
        let ids = Set(log.map(\.operationID))
        log.append(contentsOf: operations.filter { !ids.contains($0.operationID) })
        operationLog[board.namespace] = log
        return Set(operations.map(\.operationID))
    }
    func pull(board: SharedBoardDescriptor, after cursor: Data?, limit: Int) async throws -> SyncChangeBatch {
        let log = operationLog[board.namespace] ?? []
        let start = cursor.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        return SyncChangeBatch(operations: Array(log.dropFirst(start)), cursor: Data(String(log.count).utf8))
    }
}

final class CloudSharingCoordinatorTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-share-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testExplicitEnableCreateInvitationAndStopWithLocalCopy() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let source = try store.createPinboard(name: "Project")
        let original = try store.create(ClipboardRecord(text: "selected content", pinboardID: source.id))
        let transport = LifecycleTransportFixture()
        let manager = CloudSharingCoordinator(store: store, transport: transport)
        XCTAssertNil(try store.sharingConfiguration().accountID)
        do { _ = try await manager.createSharedCopy(boardID: source.id); XCTFail("Explicit enable required") } catch { }
        do { _ = try await manager.enable(expectedAccountID: "wrong-account"); XCTFail("Expected account mismatch") } catch { }
        XCTAssertNil(try store.sharingConfiguration().accountID)
        _ = try await manager.enable(expectedAccountID: "synthetic-account")
        let shared = try await manager.createSharedCopy(boardID: source.id)
        XCTAssertNotEqual(shared.boardID, source.id)
        let url = try await manager.invitationURL(boardID: shared.boardID)
        XCTAssertEqual(url?.host, "www.icloud.com")
        try await manager.updateLinkPermission(boardID: shared.boardID, allowEditing: true)
        try await manager.stopSharing(boardID: shared.boardID, keepLocalCopy: true)
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertEqual(try store.search(HistoryQuery(pinboardIDs: [shared.boardID])), [])
        XCTAssertTrue(try store.pinboards().contains { $0.name.hasSuffix("(本地副本)") })
        let states = try await manager.states()
        XCTAssertEqual(states.first?.access, .revoked)
        let counts = await transport.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(counts.2, 1)
        try await manager.disable()
        XCTAssertNil(try store.sharingConfiguration().accountID)
        XCTAssertEqual(try store.item(id: original.id), original)
    }

    func testSystemStopSharingOnlyCleansLocalStateAndIsIdempotent() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let source = try store.createPinboard(name: "System sharing")
        try store.create(ClipboardRecord(text: "keep cached content", pinboardID: source.id))
        let transport = LifecycleTransportFixture()
        let manager = CloudSharingCoordinator(store: store, transport: transport)
        _ = try await manager.enable()
        let shared = try await manager.createSharedCopy(boardID: source.id)
        try await manager.sharingStoppedExternally(boardID: shared.boardID)
        try await manager.sharingStoppedExternally(boardID: shared.boardID)
        let counts = await transport.counts()
        XCTAssertEqual(counts.1, 0, "Native presenter has already deleted the CKShare")
        XCTAssertEqual(try store.pinboards().filter { $0.name.hasSuffix("(本地副本)") }.count, 1)
        XCTAssertEqual(try store.sharedBoards(accountID: "synthetic-account").first?.access, .revoked)
        XCTAssertEqual(try store.search(HistoryQuery(pinboardIDs: [shared.boardID])).count, 0)
    }
}
