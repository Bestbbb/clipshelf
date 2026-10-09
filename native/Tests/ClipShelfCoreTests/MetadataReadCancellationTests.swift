import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

private final class CancellingLowerFunction {
    let cancellation: HistoryReadCancellation
    var calls = 0
    let cancelAt: Int
    init(cancellation: HistoryReadCancellation, cancelAt: Int) {
        self.cancellation = cancellation
        self.cancelAt = cancelAt
    }
}

final class MetadataReadCancellationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-read-cancellation-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    }

    func testAlreadyCancelledRequestDoesNotStartATransactionAndLaterReadsAndWritesSucceed() throws {
        let store = try makeStore()
        let first = try store.record(ClipboardRecord(text: "first"))
        let cancellation = HistoryReadCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel(); cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertThrowsError(try store.metadataPage(HistoryQuery(), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try store.metadataPage(HistoryQuery(limit: 0), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
        let second = try store.record(ClipboardRecord(text: "second"))
        XCTAssertEqual(try store.metadataPage(HistoryQuery()).records.map(\.id), [second.id, first.id])
    }

    func testCancellationWhileWaitingForConnectionReturnsBeforeItsWriterFinishes() throws {
        let store = try makeStore()
        let writerHoldingConnection = expectation(description: "writer holds the connection")
        let writerFinished = expectation(description: "writer commits successfully")
        let readerStarted = expectation(description: "reader was dispatched")
        let readerFinished = expectation(description: "cancelled reader retires while writer still holds lock")
        let releaseWriter = DispatchSemaphore(value: 0)
        let cancellation = HistoryReadCancellation()
        let record = ClipboardRecord(text: "writer must not be interrupted")
        DispatchQueue.global().async {
            do {
                try store.synchronized {
                    try store.transaction {
                        try store.insert(record)
                        writerHoldingConnection.fulfill()
                        guard releaseWriter.wait(timeout: .now() + 10) == .success else {
                            throw NSError(domain: "MetadataReadCancellationTests", code: 1)
                        }
                    }
                }
            } catch { XCTFail("Unrelated writer failed: \(error)") }
            writerFinished.fulfill()
        }
        wait(for: [writerHoldingConnection], timeout: 3)
        DispatchQueue.global().async {
            readerStarted.fulfill()
            do {
                _ = try store.metadataPage(HistoryQuery(), cancellation: cancellation)
                XCTFail("Expected the waiting read to be cancelled")
            } catch { XCTAssertTrue(error is CancellationError) }
            readerFinished.fulfill()
        }
        wait(for: [readerStarted], timeout: 3)
        // Allow the dispatched read to enter the contended lock before cancellation. The
        // assertion is ordering, not a latency benchmark: the writer remains explicitly held.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
        wait(for: [readerFinished], timeout: 3)
        releaseWriter.signal()
        wait(for: [writerFinished], timeout: 3)
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
        XCTAssertEqual(try store.metadataPage(HistoryQuery()).records.map(\.id), [record.id])
    }

    func testActiveWindowCountAndAnchorScansStopInsideSQLiteAndLeaveConnectionUsable() throws {
        let store = try makeStore()
        let records = (0..<2_000).map { ClipboardRecord(text: "ordinary record \($0)") }
        try store.transaction { for record in records { try store.insert(record) } }
        for mode in 0..<3 {
            let cancellation = HistoryReadCancellation()
            let function = CancellingLowerFunction(cancellation: cancellation, cancelAt: 100)
            // Cancellation occurs from inside the running SQL expression, after actual rows
            // have been examined. No row matches, so row-loop checks alone cannot stop this scan.
            installCancellingLower(function, in: store)
            let query = HistoryQuery(text: "zz", limit: 300)
            XCTAssertThrowsError(try store.metadataPage(query,
                anchorID: mode == 2 ? records[0].id : nil,
                boundary: mode == 1 ? .last : nil,
                cancellation: cancellation)) {
                XCTAssertTrue($0 is CancellationError, "Mode \(mode): \($0)")
            }
            XCTAssertTrue(cancellation.isCancelled)
            XCTAssertGreaterThanOrEqual(function.calls, 100)
            XCTAssertLessThan(function.calls, records.count, "The SQL scan must stop before visiting the full library")
            XCTAssertEqual(sqlite3_get_autocommit(store.database), 1, "Cancelled read transaction must be closed")
            let inserted = try store.record(ClipboardRecord(text: "ordinary follow-up \(mode)"))
            let page = try store.metadataPage(HistoryQuery(text: "o", limit: 300), boundary: .last)
            XCTAssertEqual(page.records.count, 300)
            XCTAssertNotNil(try store.itemMetadata(id: inserted.id))
        }
    }

    func testSuccessAndNonCancellationFailureReleaseCallbackContext() throws {
        let store = try makeStore()
        _ = try store.record(ClipboardRecord(text: "retained content"))
        weak var successToken: HistoryReadCancellation?
        do {
            let cancellation = HistoryReadCancellation(); successToken = cancellation
            XCTAssertEqual(try store.metadataPage(HistoryQuery(), cancellation: cancellation).records.count, 1)
        }
        XCTAssertNil(successToken, "SQLite must not retain the completed read's callback context")
        weak var failedToken: HistoryReadCancellation?
        do {
            let cancellation = HistoryReadCancellation(); failedToken = cancellation
            XCTAssertThrowsError(try store.metadataPage(
                HistoryQuery(copiedAfter: Date(timeIntervalSinceReferenceDate: .nan)), cancellation: cancellation)) {
                guard case HistoryStoreError.invalidTimestamp = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertNil(failedToken)
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
        _ = try store.record(ClipboardRecord(text: "still writable"))
        XCTAssertEqual(try store.metadataPage(HistoryQuery()).records.count, 2)
    }

    func testLateCancellationCannotInterruptAnotherReadOrWrite() throws {
        let store = try makeStore()
        try store.transaction {
            for index in 0..<400 { try store.insert(ClipboardRecord(text: "original \(index)")) }
        }
        let finished = HistoryReadCancellation()
        _ = try store.metadataPage(HistoryQuery(), cancellation: finished)
        finished.cancel()
        _ = try store.record(ClipboardRecord(text: "new original"))
        let fresh = HistoryReadCancellation()
        let result = try store.metadataPage(HistoryQuery(text: "o", limit: 300), boundary: .last, cancellation: fresh)
        XCTAssertEqual(result.records.count, 300)
        XCTAssertFalse(fresh.isCancelled)
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
    }

    private func installCancellingLower(_ function: CancellingLowerFunction, in store: HistoryStore) {
        let status = sqlite3_create_function_v2(store.database, "lower", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            Unmanaged.passRetained(function).toOpaque(), { context, _, values in
                guard let context, let raw = sqlite3_user_data(context) else { return }
                let function = Unmanaged<CancellingLowerFunction>.fromOpaque(raw).takeUnretainedValue()
                function.calls += 1
                if function.calls == function.cancelAt { function.cancellation.cancel() }
                guard let value = values?[0], let text = sqlite3_value_text(value) else {
                    sqlite3_result_null(context); return
                }
                let lowered = String(cString: text).lowercased()
                lowered.withCString { sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }, nil, nil, { raw in
                if let raw { Unmanaged<CancellingLowerFunction>.fromOpaque(raw).release() }
            })
        XCTAssertEqual(status, SQLITE_OK)
    }
}
