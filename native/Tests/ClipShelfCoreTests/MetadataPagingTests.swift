import Foundation
import XCTest
@testable import ClipShelfCore

final class MetadataPagingTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-page-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testBoundedAnchorWindowUsesFilteredPinboardOrderAndPreservesPageFlags() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let board = try store.createPinboard(name: "large board")
        let device = UUID()
        let records = (0..<701).map { ClipboardRecord(text: "searchable entry \($0)", pinboardID: board.id, pinboardOrder: Int64($0), originDeviceID: device, originDeviceName: "Mac") }
        try store.transaction { for record in records { try store.insert(record) } }
        let query = HistoryQuery(text: "searchable", pinboardIDs: [board.id], limit: 300, sortOrder: .pinboard, deviceFilter: .device(device))
        let page = try store.metadataPage(query, anchorID: records[550].id)
        XCTAssertEqual(page.offset, 400); XCTAssertEqual(page.records.count, 300); XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.records.first?.id, records[400].id); XCTAssertEqual(page.focusID, records[550].id)
        let next = try store.metadataPage(query, anchorID: records[550].id, displacement: 150)
        XCTAssertEqual(next.offset, 550); XCTAssertEqual(next.records.count, 151); XCTAssertFalse(next.hasMore)
        XCTAssertEqual(next.focusID, records[700].id)
        let first = try store.metadataPage(query)
        XCTAssertEqual(first.offset, 0); XCTAssertEqual(first.records.count, 300); XCTAssertTrue(first.hasMore); XCTAssertNil(first.focusID)
        XCTAssertThrowsError(try store.metadataPage(query, anchorID: records[700].id, displacement: 1))
        XCTAssertThrowsError(try store.metadataPage(query, anchorID: records[0].id, displacement: -1))
        XCTAssertThrowsError(try store.metadataPage(query, anchorID: UUID()))
        var different = query; different.deviceFilter = .unknown
        XCTAssertThrowsError(try store.metadataPage(different, anchorID: records[550].id))
        try store.delete(id: records[550].id)
        XCTAssertThrowsError(try store.metadataPage(query, anchorID: records[550].id))
        XCTAssertEqual(try store.metadataPage(query, offset: 100).records.count, 300)
    }
    func testDeletingEntireLastPageFallsBackToLastBoundedWindow() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let records = (0..<908).map { ClipboardRecord(text: "history item \($0)") }
        try store.transaction { for record in records { try store.insert(record) } }
        let query = HistoryQuery(limit: 300)
        let last = try store.metadataPage(query, offset: 900)
        XCTAssertEqual(last.records.count, 8)
        for record in last.records { try store.delete(id: record.id) }
        let refreshed = try store.metadataPage(query, offset: 900)
        XCTAssertEqual(refreshed.offset, 600); XCTAssertEqual(refreshed.records.count, 300)
        XCTAssertFalse(refreshed.hasMore); XCTAssertNil(refreshed.focusID)
        XCTAssertEqual(refreshed.records.map(\.id), records[8..<308].reversed().map(\.id))
        XCTAssertThrowsError(try store.metadataPage(query, offset: 900, anchorID: last.records[0].id))
    }

    func testLargeEarlierDeletionRebasesOffsetUsingTheSameFiltersAndEmptyResultsResetToZero() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let device = UUID(), other = UUID()
        let selected = (0..<908).map { ClipboardRecord(text: "matching item \($0)", originDeviceID: device, originDeviceName: "Mac") }
        try store.transaction {
            for record in selected { try store.insert(record) }
            for index in 0..<100 { try store.insert(ClipboardRecord(text: "matching excluded \(index)", originDeviceID: other, originDeviceName: "Mac")) }
        }
        let query = HistoryQuery(text: "matching", limit: 300, deviceFilter: .device(device))
        XCTAssertEqual(try store.metadataPage(query, offset: 900).records.count, 8)
        // Most newer records disappear while the UI still holds a deep page offset.
        for record in selected[108...] { try store.delete(id: record.id) }
        let rebased = try store.metadataPage(query, offset: 900)
        XCTAssertEqual(rebased.offset, 0); XCTAssertEqual(rebased.records.count, 108)
        XCTAssertFalse(rebased.hasMore); XCTAssertNil(rebased.focusID)
        XCTAssertEqual(rebased.records.map(\.id), selected.prefix(108).reversed().map(\.id))
        var emptyQuery = query; emptyQuery.text = "no matching content"
        let filteredEmpty = try store.metadataPage(emptyQuery, offset: 900)
        XCTAssertEqual(filteredEmpty.offset, 0); XCTAssertTrue(filteredEmpty.records.isEmpty)
        XCTAssertFalse(filteredEmpty.hasMore); XCTAssertNil(filteredEmpty.focusID)
        try store.clear()
        XCTAssertEqual(try store.metadataPage(query, offset: 900).offset, 0)
    }

}
