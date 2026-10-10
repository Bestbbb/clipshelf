import ClipShelfCore
import Foundation
import XCTest
@testable import ClipShelf

@MainActor final class CaptureContentQuotaTests: XCTestCase {
    func testQuotaFailurePreservesFrozenFIFOAndRaisingLimitRequiresExplicitRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-capture-quota-\(UUID())")
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try store.contentQuotaStatus()
        _ = try store.setContentQuotaLimit(1, expectedRevision: initial.policyRevision)
        func input(_ text: String, date: TimeInterval) -> CapturePersistenceInput {
            let data = Data(text.utf8)
            return CapturePersistenceInput(snapshot: .init(parts: [.init(representations: [
                .init(typeIdentifier: "public.utf8-plain-text", data: data)
            ])], sourceApp: "Quota Fixture", sourceBundleID: "test.quota.capture", copiedAt: Date(timeIntervalSince1970: date), byteCount: data.count), stackSessionID: UUID())
        }
        let first = input("first frozen capture", date: 10), second = input("second frozen capture", date: 20)
        let ingestion = CaptureIngestionCoordinator<CapturePersistenceInput, RetainedClipboardRecords> {
            try await CapturePersistence.save($0, to: store)
        }
        let rejected = expectation(description: "real Core quota rejected first capture")
        let saved = expectation(description: "both original captures persisted"); saved.expectedFulfillmentCount = 2
        var outputs: [ClipboardRecord] = [], originalInputs: [CapturePersistenceInput] = []
        var failures = 0
        ingestion.onFailure = { received, error in
            failures += 1
            XCTAssertEqual(received.snapshot.parts, first.snapshot.parts)
            guard case .exceeded = error as? ContentQuotaError else { XCTFail("Expected quota rejection: \(error)"); return }
            rejected.fulfill()
        }
        ingestion.onSaved = { received, retained in
            originalInputs.append(received); outputs.append(contentsOf: retained.records); saved.fulfill()
        }
        XCTAssertTrue(ingestion.enqueue(first, byteCount: first.snapshot.byteCount))
        XCTAssertTrue(ingestion.enqueue(second, byteCount: second.snapshot.byteCount))
        await fulfillment(of: [rejected], timeout: 3)
        XCTAssertTrue(ingestion.hasFailure)
        XCTAssertFalse(ingestion.isProcessing)
        XCTAssertEqual(ingestion.pendingCount, 2)
        XCTAssertEqual(ingestion.pendingBytes, first.snapshot.byteCount + second.snapshot.byteCount)
        XCTAssertTrue(try store.search(HistoryQuery()).isEmpty)
        let policy = try store.contentQuotaStatus()
        _ = try store.setContentQuotaLimit(nil, expectedRevision: policy.policyRevision)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(ingestion.hasFailure, "A policy change must not resume capture automatically")
        XCTAssertTrue(outputs.isEmpty)
        ingestion.retry(); ingestion.retry()
        await fulfillment(of: [saved], timeout: 3)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(outputs.map(\.text), ["first frozen capture", "second frozen capture"])
        XCTAssertEqual(outputs.map(\.copiedAt), [first.snapshot.copiedAt, second.snapshot.copiedAt])
        XCTAssertEqual(originalInputs.map(\.stackSessionID), [first.stackSessionID, second.stackSessionID])
        XCTAssertEqual(Set(outputs.map(\.id)).count, 2)
        XCTAssertEqual(try store.search(HistoryQuery()).count, 2)
        XCTAssertEqual(ingestion.pendingCount, 0)
        XCTAssertFalse(ingestion.hasFailure)
    }
}
