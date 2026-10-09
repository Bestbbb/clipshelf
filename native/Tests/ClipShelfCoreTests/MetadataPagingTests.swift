import Foundation
import CSQLite
import XCTest
@testable import ClipShelfCore

private final class MetadataBoundaryReadTrace {
    var action: (() throws -> Void)?
    var failure: Error?
}

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

    func testBoundaryUsesCompleteCombinedFiltersAndNeverReadsAttachmentBytes() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let firstBoard = try store.createPinboard(name: "First"), secondBoard = try store.createPinboard(name: "Second")
        let excludedBoard = try store.createPinboard(name: "Excluded")
        let device = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        func make(_ index: Int) -> ClipboardRecord {
            ClipboardRecord(text: "literal %_ 中文 \(index)", sourceApp: "Editor", sourceBundleID: "test.editor",
                            copiedAt: date, parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: Data([1, 2, 3]))])],
                            pinboardID: index.isMultiple(of: 2) ? firstBoard.id : secondBoard.id,
                            originDeviceID: device, originDeviceName: "Mac")
        }
        let records = (0..<612).map(make)
        try store.transaction {
            for record in records { try store.insert(record) }
            var excluded = make(612); excluded.text = "not the needle"; try store.insert(excluded)
            excluded = make(613); excluded.sourceBundleID = "test.other"; try store.insert(excluded)
            excluded = make(614); excluded.copiedAt = date.addingTimeInterval(-2); try store.insert(excluded)
            excluded = make(615); excluded.copiedAt = date.addingTimeInterval(2); try store.insert(excluded)
            excluded = make(616); excluded.originDeviceID = UUID(); try store.insert(excluded)
            excluded = make(617); excluded.parts = []; try store.insert(excluded)
            excluded = make(618); excluded.pinboardID = excludedBoard.id; try store.insert(excluded)
            excluded = make(619); excluded.originDeviceID = nil; excluded.originDeviceName = nil
            excluded.originDeviceConflict = true; try store.insert(excluded)
        }
        // Metadata boundary navigation remains usable when original binary data is unavailable.
        for file in try FileManager.default.contentsOfDirectory(at: store.representations.directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let query = HistoryQuery(text: "literal %_ 中文", kind: .image, sourceBundleID: "test.editor",
                                 copiedAfter: date.addingTimeInterval(-1), copiedBefore: date.addingTimeInterval(1),
                                 pinboardIDs: [firstBoard.id, secondBoard.id], limit: Int.max, deviceFilter: .device(device))
        let first = try store.metadataPage(query, boundary: .first)
        XCTAssertEqual(first.offset, 0); XCTAssertEqual(first.records.count, 300); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.focusID, records.last?.id)
        XCTAssertEqual(first.records.map(\.id), records.suffix(300).reversed().map(\.id))
        let last = try store.metadataPage(query, boundary: .last)
        XCTAssertEqual(last.offset, 312); XCTAssertEqual(last.records.count, 300); XCTAssertFalse(last.hasMore)
        XCTAssertEqual(last.focusID, records.first?.id)
        XCTAssertEqual(last.records.map(\.id), records.prefix(300).reversed().map(\.id))
    }

    func testBoundaryRespectsManualOrderSmallLimitsAndFullBoardTail() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let board = try store.createPinboard(name: "Manual")
        let records = (0..<701).map {
            ClipboardRecord(text: "rank \($0)", pinboardID: board.id, isInHistory: false, pinboardOrder: Int64($0))
        }
        // Insertion order is deliberately the reverse of manual rank.
        try store.transaction { for record in records.reversed() { try store.insert(record) } }
        let query = HistoryQuery(pinboardIDs: [board.id], limit: 7, sortOrder: .pinboard)
        let first = try store.metadataPage(query, boundary: .first)
        XCTAssertEqual(first.records.map(\.id), records.prefix(7).map(\.id))
        XCTAssertEqual(first.focusID, records[0].id); XCTAssertEqual(first.offset, 0); XCTAssertTrue(first.hasMore)
        let last = try store.metadataPage(query, boundary: .last)
        XCTAssertEqual(last.records.map(\.id), records.suffix(7).map(\.id))
        XCTAssertEqual(last.focusID, records[700].id); XCTAssertEqual(last.offset, 694); XCTAssertFalse(last.hasMore)
        var historyOnly = query; historyOnly.includePinned = false
        XCTAssertTrue(try store.metadataPage(historyOnly, boundary: .last).records.isEmpty)
        var larger = query; larger.limit = 500
        XCTAssertEqual(try store.metadataPage(larger, boundary: .last).records.count, 300)
    }

    func testBoundaryEmptyAndAmbiguousRequestsDoNotWeakenStrictAnchors() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let record = try store.create(ClipboardRecord(text: "one"))
        for boundary in [HistoryPageBoundary.first, .last] {
            let empty = try store.metadataPage(HistoryQuery(text: "absent", limit: 300), boundary: boundary)
            XCTAssertTrue(empty.records.isEmpty); XCTAssertEqual(empty.offset, 0); XCTAssertNil(empty.focusID); XCTAssertFalse(empty.hasMore)
            let single = try store.metadataPage(HistoryQuery(limit: 300), boundary: boundary)
            XCTAssertEqual(single.records.map(\.id), [record.id]); XCTAssertEqual(single.focusID, record.id)
            XCTAssertEqual(single.offset, 0); XCTAssertFalse(single.hasMore)
            XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), offset: 1, boundary: boundary)) {
                guard case HistoryStoreError.invalidPageRequest = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), offset: -1, boundary: boundary))
            XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), anchorID: record.id, boundary: boundary))
            XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), displacement: 1, boundary: boundary))
            let zeroLimit = try store.metadataPage(HistoryQuery(limit: 0), boundary: boundary)
            XCTAssertEqual(zeroLimit.offset, 0); XCTAssertTrue(zeroLimit.records.isEmpty); XCTAssertNil(zeroLimit.focusID)
        }
        XCTAssertThrowsError(try store.metadataPage(HistoryQuery(text: "absent"), anchorID: record.id))
        XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), anchorID: record.id, displacement: 1))
        XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), anchorID: record.id, displacement: -1))
        try store.delete(id: record.id)
        XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), anchorID: record.id))
        XCTAssertTrue(try store.metadataPage(HistoryQuery(), boundary: .last).records.isEmpty)
    }

    func testBoundariesRefreshAfterAppendsAndEndpointDeletion() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let records = (0..<305).map { ClipboardRecord(text: "history \($0)") }
        try store.transaction { for record in records { try store.insert(record) } }
        let query = HistoryQuery(limit: 300)
        XCTAssertEqual(try store.metadataPage(query, boundary: .last).offset, 5)
        let newest = try store.create(ClipboardRecord(text: "newest"))
        XCTAssertEqual(try store.metadataPage(query, boundary: .first).focusID, newest.id)
        XCTAssertEqual(try store.metadataPage(query, boundary: .last).offset, 6)
        try store.delete(id: records[0].id)
        let last = try store.metadataPage(query, boundary: .last)
        XCTAssertEqual(last.focusID, records[1].id); XCTAssertEqual(last.offset, 5); XCTAssertFalse(last.hasMore)
        try store.delete(id: newest.id)
        XCTAssertEqual(try store.metadataPage(query, boundary: .first).focusID, records.last?.id)
    }

    func testBoundaryCountAndWindowShareReadSnapshotAcrossExternalCommit() throws {
        let url = directory.appendingPathComponent("history.sqlite3")
        let reader = try HistoryStore(databaseURL: url), writer = try HistoryStore(databaseURL: url)
        let records = (0..<605).map { ClipboardRecord(text: "snapshot \($0)") }
        try reader.transaction { for record in records { try reader.insert(record) } }
        let probe = MetadataBoundaryReadTrace()
        probe.action = {
            try writer.delete(id: records[0].id)
            try writer.delete(id: records[1].id)
            _ = try writer.create(ClipboardRecord(text: "snapshot inserted during page read"))
        }
        // The count has already stepped; commit changes immediately before the page's SELECT.
        sqlite3_trace_v2(reader.database, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)),
                  String(cString: sql).hasPrefix("SELECT id, text, source_app") else { return 0 }
            let probe = Unmanaged<MetadataBoundaryReadTrace>.fromOpaque(context).takeUnretainedValue()
            if let action = probe.action {
                probe.action = nil
                do { try action() } catch { probe.failure = error }
            }
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())
        defer { sqlite3_trace_v2(reader.database, 0, nil, nil) }
        let query = HistoryQuery(text: "snapshot", limit: 300)
        let before = try reader.metadataPage(query, boundary: .last)
        XCTAssertNil(probe.failure); XCTAssertNil(probe.action)
        XCTAssertEqual(before.offset, 305); XCTAssertEqual(before.records.map(\.id), records.prefix(300).reversed().map(\.id))
        XCTAssertEqual(before.focusID, records[0].id); XCTAssertFalse(before.hasMore)
        let after = try reader.metadataPage(query, boundary: .last)
        XCTAssertEqual(after.offset, 304); XCTAssertEqual(after.focusID, records[2].id); XCTAssertFalse(after.hasMore)
        XCTAssertEqual(after.records.map(\.id), records[2..<302].reversed().map(\.id))
    }

}
