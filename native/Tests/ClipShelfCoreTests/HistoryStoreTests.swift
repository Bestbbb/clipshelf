import Foundation
import XCTest
@testable import ClipShelfCore

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite3") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPersistsOriginalUnicodeNewlinesNullsAndRichRepresentationsAcrossRestart() throws {
        let record = ClipboardRecord(
            text: "你好 👩🏽‍💻\nLine two\r\n\t e\u{301}\0after null",
            sourceApp: "测试 Editor", sourceBundleID: "example.editor",
            copiedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            rtf: Data([0, 1, 255, 123, 125]), html: Data("<b>你好</b>".utf8)
        )
        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            XCTAssertEqual(try store.record(record), record)
        }
        let reopened = try HistoryStore(databaseURL: databaseURL)
        XCTAssertEqual(try reopened.load(), [record])
    }

    func testAdjacentDuplicateKeepsIdentityAndUpdatesTime() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let first = ClipboardRecord(text: "same", sourceApp: "Editor", copiedAt: Date(timeIntervalSince1970: 1))
        let second = ClipboardRecord(text: "same", sourceApp: "Editor", copiedAt: Date(timeIntervalSince1970: 2))
        try store.record(first)
        let stored = try store.record(second)
        XCTAssertEqual(stored.id, first.id)
        XCTAssertEqual(stored.copiedAt, second.copiedAt)
        XCTAssertEqual(try store.load(), [stored])
    }

    func testSourceAndFormatChangesRemainDistinct() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let records = [
            ClipboardRecord(text: "same", sourceApp: "A", sourceBundleID: "a"),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "a"),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "b"),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "b", rtf: Data()),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "b", rtf: Data(), html: Data()),
            ClipboardRecord(text: "other"),
        ]
        for record in records { try store.record(record) }
        XCTAssertEqual(try store.load(), records.reversed())
    }

    func testInterleavedRecopyPromotesOriginalAcrossRestartAndRetainsPinboard() throws {
        let first: ClipboardRecord
        let board: Pinboard
        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            board = try store.createPinboard(name: "Saved")
            first = try store.record(ClipboardRecord(text: "alpha", sourceApp: "Editor", pinboardID: board.id))
            try store.record(ClipboardRecord(text: "beta"))
        }
        let reopened = try HistoryStore(databaseURL: databaseURL)
        let recopied = try reopened.record(ClipboardRecord(text: "alpha", sourceApp: "Editor"))
        XCTAssertEqual(recopied.id, first.id)
        XCTAssertEqual(recopied.revision, first.revision + 1)
        XCTAssertEqual(recopied.pinboardID, board.id)
        XCTAssertEqual(recopied.pinboardOrder, first.pinboardOrder)
        XCTAssertEqual(try reopened.load().map(\.text), ["alpha", "beta"])
        XCTAssertEqual(try reopened.load().count, 2)
    }

    func testRecopyPreservesRepresentationAndObjectDistinctions() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        func record(_ parts: [[String]]) -> ClipboardRecord {
            ClipboardRecord(text: "same", parts: parts.map { part in
                ClipboardPart(representations: part.enumerated().map { ClipboardRepresentation(typeIdentifier: $0.offset == 0 ? "public.utf8-plain-text" : "public.html", data: Data($0.element.utf8)) })
            })
        }
        let first = try store.record(record([["a"], ["b"]]))
        let reversed = try store.record(record([["b"], ["a"]]))
        let merged = try store.record(record([["a", "b"]]))
        let different = try store.record(record([["a"], ["c"]]))
        let recopied = try store.record(record([["a"], ["b"]]))
        XCTAssertEqual(recopied.id, first.id)
        XCTAssertEqual(try store.load().map(\.id), [first.id, different.id, merged.id, reversed.id])
    }

    func testRecopyDoesNotMergeEqualPrefixesOrNullSuffixes() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let prefix = String(repeating: "👩🏽‍💻", count: 140)
        let values = [prefix + "a", prefix + "b", "null\0one", "null\0two"]
        for value in values { try store.record(ClipboardRecord(text: value)) }
        let original = try XCTUnwrap(store.load().last)
        XCTAssertEqual(try store.record(ClipboardRecord(text: values[0])).id, original.id)
        XCTAssertEqual(try store.load().count, 4)
    }

    func testSQLLikeTextIsStoredAsData() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let malicious = ClipboardRecord(text: "'); DROP TABLE clipboard_records; --", sourceApp: "' OR 1=1 --")
        try store.record(malicious)
        try store.record(ClipboardRecord(text: "still available"))
        XCTAssertEqual(try store.load().count, 2)
        XCTAssertEqual(try store.load().last, malicious)
    }

    func testDeleteClearAndLimitsSurviveRestart() throws {
        let first = ClipboardRecord(text: "one")
        let second = ClipboardRecord(text: "two")
        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            try store.record(first)
            try store.record(second)
            XCTAssertEqual(try store.load(limit: 1), [second])
            XCTAssertEqual(try store.load(limit: 0), [])
            XCTAssertEqual(try store.load(limit: -1), [])
            try store.delete(id: second.id)
            try store.delete(id: UUID())
        }
        do {
            let reopened = try HistoryStore(databaseURL: databaseURL)
            XCTAssertEqual(try reopened.load(), [first])
            try reopened.clear()
        }
        XCTAssertEqual(try HistoryStore(databaseURL: databaseURL).load(), [])
    }

    func testCaptureOrderDoesNotDependOnWallClock() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let first = ClipboardRecord(text: "first", copiedAt: Date(timeIntervalSince1970: 200))
        let second = ClipboardRecord(text: "second", copiedAt: Date(timeIntervalSince1970: 100))
        try store.record(first)
        try store.record(second)
        XCTAssertEqual(try store.load(), [second, first])
    }

    func testFailedInsertRollsBackAndLeavesStoreUsable() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let first = ClipboardRecord(text: "first")
        try store.record(first)
        XCTAssertThrowsError(try store.record(ClipboardRecord(id: first.id, text: "different")))
        let next = ClipboardRecord(text: "next")
        try store.record(next)
        XCTAssertEqual(try store.load(), [next, first])
    }

    func testCorruptAndUnopenableDatabaseThrows() throws {
        try Data("this is not a sqlite database".utf8).write(to: databaseURL)
        XCTAssertThrowsError(try HistoryStore(databaseURL: databaseURL))
        XCTAssertThrowsError(try HistoryStore(databaseURL: directory))
        XCTAssertThrowsError(try HistoryStore(databaseURL: URL(string: "https://example.test/history")!))
    }

    func testCreatesMissingParentDirectoryAndRejectsInvalidTime() throws {
        let nested = directory.appendingPathComponent("one/two/history.sqlite3")
        let store = try HistoryStore(databaseURL: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertThrowsError(try store.record(ClipboardRecord(text: "bad date", copiedAt: Date(timeIntervalSince1970: .nan))))
        XCTAssertEqual(try store.load(), [])
    }

    func testConcurrentCapturesAreSerializedWithoutLosingRecords() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let failuresLock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try store.record(ClipboardRecord(text: "capture \(index)"))
            } catch {
                failuresLock.lock()
                failures.append(error)
                failuresLock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty)
        let records = try store.load()
        XCTAssertEqual(records.count, 40)
        XCTAssertEqual(Set(records.map(\.text)).count, 40)
    }
}
