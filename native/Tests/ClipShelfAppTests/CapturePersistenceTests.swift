import CSQLite
import Foundation
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

/// Only a real INSERT is held, with a deadline so a regression cannot deadlock the suite.
private final class CaptureSQLProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    let entered: XCTestExpectation
    private var claimed = false
    private var observedMain = false
    private var timedOut = false

    init(entered: XCTestExpectation) { self.entered = entered }
    func observe(_ statement: OpaquePointer?) {
        guard let statement, let sql = sqlite3_sql(statement),
              String(cString: sql).uppercased().hasPrefix("INSERT INTO CLIPBOARD_RECORDS") else { return }
        lock.lock()
        guard !claimed else { lock.unlock(); return }
        claimed = true; observedMain = Thread.isMainThread
        let onMain = observedMain
        lock.unlock()
        entered.fulfill()
        // Record the main-thread violation without blocking that thread on our gate.
        guard !onMain else { return }
        let expired = gate.wait(timeout: .now() + 3) == .timedOut
        lock.lock(); timedOut = expired; lock.unlock()
    }
    func release() { gate.signal() }
    var result: (claimed: Bool, observedMain: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (claimed, observedMain, timedOut)
    }
}

@MainActor final class CapturePersistenceTests: XCTestCase {
    private func makeStore() throws -> (URL, HistoryStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-capture-persistence-\(UUID())", isDirectory: true)
        return (directory, try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3")))
    }
    private func input(_ text: String, date: Date = Date(timeIntervalSince1970: 1_234), session: UUID? = nil) -> CapturePersistenceInput {
        let data = Data(text.utf8)
        return CapturePersistenceInput(snapshot: ClipboardCaptureSnapshot(parts: [
            .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: data)])
        ], sourceApp: "Synthetic Source", sourceBundleID: "test.capture.source", copiedAt: date, byteCount: data.count), stackSessionID: session)
    }

    func testNonFileRepresentationsDoNotBlockOwnedReclamation() {
        let parts: [ClipboardPart] = [
            .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("file:///absent/file".utf8))]),
            .init(representations: [
                .init(typeIdentifier: "public.url", data: Data("https://example.invalid".utf8)),
                .init(typeIdentifier: "public.png", data: Data([0, 1, 2]))
            ])
        ]
        for values in [[], parts] {
            let value = CapturePersistenceInput(snapshot: .init(parts: values, byteCount: 0), stackSessionID: UUID())
            XCTAssertFalse(value.blocksOwnedReclamation)
        }
    }

    func testAnyFrozenFileURLRepresentationBlocksReclamationWithoutResolvingItsData() {
        for data in [Data(), Data([255, 0]), Data("file:///deliberately-absent-clipshelf-test-file".utf8)] {
            let parts: [ClipboardPart] = [
                .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("first".utf8))]),
                .init(representations: [
                    .init(typeIdentifier: "public.png", data: Data()),
                    .init(typeIdentifier: "public.file-url", data: data)
                ])
            ]
            let value = CapturePersistenceInput(snapshot: .init(parts: parts, byteCount: 0), stackSessionID: nil)
            XCTAssertTrue(value.blocksOwnedReclamation)
        }
    }

    func testSavePersistsFrozenRepresentationsSourceAndCaptureDateAcrossReopen() async throws {
        let (directory, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceText = "冻结内容\n code 🧪", rtf = Data("{\\rtf1 rich}".utf8), html = Data("<b>rich</b>".utf8)
        var originalData = Data(sourceText.utf8)
        let representations: [ClipboardRepresentation] = [
            .init(typeIdentifier: "public.utf8-plain-text", data: originalData),
            .init(typeIdentifier: "public.rtf", data: rtf),
            .init(typeIdentifier: "public.html", data: html),
            .init(typeIdentifier: "test.capture.opaque", data: Data([0, 255, 7, 3]))
        ]
        let copiedAt = Date(timeIntervalSince1970: 1_234_567.125)
        let snapshot = ClipboardCaptureSnapshot(parts: [.init(representations: representations)],
            sourceApp: "Frozen Source", sourceBundleID: "test.frozen", copiedAt: copiedAt,
            byteCount: representations.reduce(0) { $0 + $1.data.count })
        originalData.resetBytes(in: 0..<originalData.count)
        let saved = try await CapturePersistence.save(.init(snapshot: snapshot, stackSessionID: UUID()), to: store)
        let record = try XCTUnwrap(saved.records.first)
        XCTAssertEqual(saved.records.count, 1)
        let reopened = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let stored = try XCTUnwrap(reopened.item(id: record.id))
        XCTAssertEqual(stored.text, sourceText); XCTAssertEqual(stored.parts, snapshot.parts)
        XCTAssertEqual(stored.rtf, rtf); XCTAssertEqual(stored.html, html)
        XCTAssertEqual(stored.sourceApp, snapshot.sourceApp); XCTAssertEqual(stored.sourceBundleID, snapshot.sourceBundleID)
        XCTAssertEqual(stored.copiedAt, copiedAt)
        XCTAssertEqual(try reopened.search(HistoryQuery()).count, 1)
    }

    func testRealCommitFailureRetainsFrozenQueueAndExplicitRetrySavesEveryEntryOnceInOrder() async throws {
        let (directory, store) = try makeStore()
        defer { sqlite3_commit_hook(store.database, nil, nil); try? FileManager.default.removeItem(at: directory) }
        let first = input("first", date: Date(timeIntervalSince1970: 10), session: UUID())
        let second = input("second", date: Date(timeIntervalSince1970: 20), session: UUID())
        let subject = CaptureIngestionCoordinator<CapturePersistenceInput, RetainedClipboardRecords> {
            try await CapturePersistence.save($0, to: store)
        }
        let failed = expectation(description: "real transaction rejected")
        let completed = expectation(description: "both persisted after retry"); completed.expectedFulfillmentCount = 2
        var savedInputs: [CapturePersistenceInput] = [], savedRecords: [ClipboardRecord] = []
        subject.onFailure = { received, _ in
            XCTAssertEqual(received.snapshot.parts, first.snapshot.parts)
            XCTAssertEqual(received.stackSessionID, first.stackSessionID)
            failed.fulfill()
        }
        subject.onSaved = { received, result in
            savedInputs.append(received); savedRecords.append(contentsOf: result.records); completed.fulfill()
        }
        sqlite3_commit_hook(store.database, { _ in 1 }, nil)
        XCTAssertTrue(subject.enqueue(first, byteCount: first.snapshot.byteCount))
        XCTAssertTrue(subject.enqueue(second, byteCount: second.snapshot.byteCount))
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(subject.hasFailure); XCTAssertFalse(subject.isProcessing)
        XCTAssertEqual(subject.pendingCount, 2)
        XCTAssertEqual(subject.pendingBytes, first.snapshot.byteCount + second.snapshot.byteCount)
        XCTAssertTrue(savedRecords.isEmpty)
        XCTAssertTrue(try store.search(HistoryQuery()).isEmpty, "The failed COMMIT must not leave a row behind")
        sqlite3_commit_hook(store.database, nil, nil)
        subject.retry(); subject.retry()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(savedRecords.map(\.text), ["first", "second"])
        XCTAssertEqual(savedInputs.map(\.stackSessionID), [first.stackSessionID, second.stackSessionID])
        XCTAssertEqual(savedRecords.map(\.copiedAt), [first.snapshot.copiedAt, second.snapshot.copiedAt])
        XCTAssertEqual(Set(savedRecords.map(\.id)).count, 2)
        XCTAssertEqual(try store.search(HistoryQuery()).count, 2)
        XCTAssertEqual(subject.pendingCount, 0); XCTAssertEqual(subject.pendingBytes, 0)
        XCTAssertFalse(subject.hasFailure); XCTAssertFalse(subject.isProcessing)
    }

    func testActualSQLWriteRunsOffMainAndMainActorRemainsResponsiveDuringBlockedInsert() async throws {
        let (directory, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "real INSERT reached")
        let probe = CaptureSQLProbe(entered: entered)
        sqlite3_trace_v2(store.database, UInt32(SQLITE_TRACE_STMT), { _, raw, statement, _ in
            guard let raw else { return 0 }
            Unmanaged<CaptureSQLProbe>.fromOpaque(raw).takeUnretainedValue().observe(statement.map { OpaquePointer($0) })
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())
        defer { probe.release(); sqlite3_trace_v2(store.database, 0, nil, nil) }
        var finished = false
        let value = input("real worker write")
        let saving = Task { @MainActor in
            let result = try await CapturePersistence.save(value, to: store)
            finished = true
            return result
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(probe.result.claimed); XCTAssertFalse(probe.result.observedMain)
        XCTAssertFalse(finished)
        var mainActionRan = false
        await Task { @MainActor in mainActionRan = true }.value
        XCTAssertTrue(mainActionRan); XCTAssertFalse(finished)
        probe.release()
        let saved = try await saving.value
        XCTAssertTrue(finished); XCTAssertFalse(probe.result.timedOut)
        XCTAssertEqual(saved.records.first?.text, "real worker write")
        withExtendedLifetime(probe) {}
    }
}
