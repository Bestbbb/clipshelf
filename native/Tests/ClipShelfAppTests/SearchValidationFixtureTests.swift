import ClipShelfCore
import Foundation
import XCTest
@testable import ClipShelf

final class SearchValidationFixtureTests: XCTestCase {
    func testFixtureExercisesDeepHistoryBoardAndUnknownDeviceWithoutRealData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-search-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), recordsLocalOrigin: true)
        try SearchValidationFixtures.populate(store)
        let historyTarget = try XCTUnwrap(store.searchMetadata(HistoryQuery(text: "TARGET-DEEP-HISTORY")).first)
        let history = try store.metadataPage(HistoryQuery(limit: 300), anchorID: historyTarget.id)
        XCTAssertGreaterThan(history.offset, 300)
        XCTAssertEqual(history.focusID, historyTarget.id)
        XCTAssertLessThanOrEqual(history.records.count, 300)
        let boardTarget = try XCTUnwrap(store.searchMetadata(HistoryQuery(text: "TARGET-DEEP-BOARD")).first)
        let boardID = try XCTUnwrap(boardTarget.pinboardID)
        let board = HistoryQuery(pinboardIDs: [boardID], limit: 300, sortOrder: .pinboard)
        XCTAssertEqual(try store.metadataOffset(of: boardTarget.id, query: board), 400)
        XCTAssertEqual(try store.metadataPage(board, anchorID: boardTarget.id).focusID, boardTarget.id)
        XCTAssertEqual(try store.metadataDevices().count, 2)
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(limit: 1_000, deviceFilter: .unknown)).count, 300)
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(limit: 1_000, deviceFilter: .device(store.localDeviceIdentity().id))).count, 301)
    }
}
