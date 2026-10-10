import Foundation
import XCTest
@testable import ClipShelfCore

final class PinboardOrderIdentityTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pinboard-order-identity-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite"))
    }
    private func id(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000" + suffix)!
    }
    private func fixture(_ value: HistoryStore) throws -> (Pinboard, [ClipboardRecord]) {
        let board = try value.createPinboard(name: "Stable equal ranks")
        let records = try ["01", "02", "03"].map { suffix in
            try value.create(ClipboardRecord(id: id(suffix), text: "item " + suffix,
                                            pinboardID: board.id, pinboardOrder: 17))
        }
        return (board, records)
    }
    private func ordered(_ store: HistoryStore, _ board: UUID) throws -> [ClipboardRecord] {
        try store.search(.init(pinboardIDs: [board], sortOrder: .pinboard))
    }

    func testReplacementIdentityPreservesEqualRankPositionAcrossRestartAndMetadataProjection() throws {
        let value = try store(), (board, records) = try fixture(value)
        let position = try value.historyOrderWithoutLock(id: records[0].id)
        try value.delete(id: records[0].id)
        var restored = records[0]
        restored.id = id("99"); restored.pinboardOrderIdentity = records[0].id
        try value.transaction { try value.insert(restored, historyOrder: position) }
        let expected = [restored.id, records[1].id, records[2].id]
        XCTAssertEqual(try ordered(value, board.id).map(\.id), expected)
        XCTAssertEqual(try value.searchMetadata(.init(pinboardIDs: [board.id], sortOrder: .pinboard)).map(\.id), expected)
        XCTAssertEqual(try value.item(id: restored.id), restored)
        XCTAssertEqual(try ordered(store(), board.id).map(\.id), expected)
    }

    func testExplicitSharedTieStillHasDeterministicFinalIDOrdering() throws {
        let value = try store(), board = try value.createPinboard(name: "tie")
        for suffix in ["03", "01", "02"] {
            _ = try value.create(ClipboardRecord(id: id(suffix), text: suffix, pinboardID: board.id,
                                                 pinboardOrder: 17, pinboardOrderIdentity: id("55")))
        }
        XCTAssertEqual(try ordered(value, board.id).map(\.id), [id("01"), id("02"), id("03")])
    }

    func testContentReplacementKeepsCreatedExplicitIdentityAndLegacyRowsRemainNil() throws {
        let value = try store(), (board, records) = try fixture(value)
        XCTAssertNil(try value.item(id: records[0].id)?.pinboardOrderIdentity)
        var legacyEdit = records[0]; legacyEdit.text = "legacy edited"; legacyEdit.pinboardOrderIdentity = id("77")
        XCTAssertNil(try value.update(record: legacyEdit).pinboardOrderIdentity)
        var edited = try value.create(ClipboardRecord(text: "explicit", pinboardID: board.id,
                                                     pinboardOrder: 17, pinboardOrderIdentity: id("55")))
        edited.text = "edited"; edited.pinboardOrderIdentity = id("77")
        let committed = try value.update(record: edited)
        XCTAssertEqual(try value.item(id: committed.id), committed)
        XCTAssertEqual(try store().item(id: committed.id)?.pinboardOrderIdentity, id("55"))
        XCTAssertNil(try store().item(id: records[0].id)?.pinboardOrderIdentity)
    }

    func testLocalBoardCopyPreservesEqualRankOrderWhileAllocatingFreshRecordIDs() throws {
        let value = try store(), (board, records) = try fixture(value)
        let copy = try value.copyBoardToLocal(boardID: board.id)
        let copied = try ordered(value, copy.id)
        XCTAssertEqual(copied.map(\.text), records.map(\.text))
        XCTAssertEqual(copied.map(\.pinboardOrderIdentity), records.map { Optional($0.id) })
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: records.map(\.id)))
    }

    func testBackupMergeIntoSyncedProfilePreservesTieOrderThroughIdentityRemapping() throws {
        let source = try store("source"), (_, records) = try fixture(source)
        let archive = directory.appendingPathComponent("library.clipshelfbackup")
        try source.exportBackup(to: archive)
        let target = try store("target")
        try target.configureSync(accountID: "private-account")
        let summary = try target.restoreBackup(from: archive, mode: .merge)
        XCTAssertTrue(summary.identitiesRemapped)
        let board = try XCTUnwrap(target.pinboards().first)
        let copied = try ordered(target, board.id)
        XCTAssertEqual(copied.map(\.text), records.map(\.text))
        XCTAssertEqual(copied.map(\.pinboardOrderIdentity), records.map { Optional($0.id) })
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: records.map(\.id)))
    }

    func testMalformedStoredIdentityFailsRecordAndMetadataReads() throws {
        let value = try store(), (_, records) = try fixture(value)
        try value.syncExecute("UPDATE clipboard_records SET pinboard_order_identity = 'not-a-uuid' WHERE id = ?", [records[0].id.uuidString])
        XCTAssertThrowsError(try value.item(id: records[0].id))
        XCTAssertThrowsError(try value.searchMetadata(.init()))
    }
}
