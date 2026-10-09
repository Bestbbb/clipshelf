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

    func testSourceAndFormatChangesAndNonAdjacentDuplicatesRemainDistinct() throws {
        let store = try HistoryStore(databaseURL: databaseURL)
        let records = [
            ClipboardRecord(text: "same", sourceApp: "A", sourceBundleID: "a"),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "a"),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "b"),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "b", rtf: Data()),
            ClipboardRecord(text: "same", sourceApp: "B", sourceBundleID: "b", rtf: Data(), html: Data()),
            ClipboardRecord(text: "other"),
            ClipboardRecord(text: "same", sourceApp: "A", sourceBundleID: "a"),
        ]
        for record in records { try store.record(record) }
        XCTAssertEqual(try store.load(), records.reversed())
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
