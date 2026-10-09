import ClipShelfCore
@testable import ClipShelf
import XCTest

@MainActor
final class StackCoordinatorTests: XCTestCase {
    func testPersistedCaptureOnlyEntersOriginalLiveSession() async {
        let stack = StackCoordinator()
        let record = ClipboardRecord(text: "captured")
        stack.activate()
        let originalSession = stack.sessionID
        stack.activate()
        XCTAssertEqual(stack.sessionID, originalSession)
        stack.appendCaptured(record, lease: nil, capturedIn: originalSession)
        XCTAssertEqual(stack.queue, [record])
        stack.end()
        stack.appendCaptured(record, lease: nil, capturedIn: originalSession)
        XCTAssertTrue(stack.queue.isEmpty)
        stack.activate()
        XCTAssertNotEqual(stack.sessionID, originalSession)
        stack.appendCaptured(record, lease: nil, capturedIn: originalSession)
        stack.appendCaptured(record, lease: nil, capturedIn: nil)
        XCTAssertTrue(stack.queue.isEmpty)
        stack.appendCaptured(record, lease: nil, capturedIn: stack.sessionID)
        XCTAssertEqual(stack.queue, [record])
    }

    func testClearingEvenAnEmptyStackRejectsEarlierPendingCaptures() async {
        let stack = StackCoordinator()
        stack.activate()
        let beforeClear = stack.sessionID
        stack.clear()
        XCTAssertTrue(stack.isActive)
        stack.appendCaptured(ClipboardRecord(text: "before clear"), lease: nil, capturedIn: beforeClear)
        XCTAssertTrue(stack.queue.isEmpty)
        let afterClear = stack.sessionID
        stack.appendCaptured(ClipboardRecord(text: "after clear"), lease: nil, capturedIn: afterClear)
        XCTAssertEqual(stack.queue.map(\.text), ["after clear"])
        stack.clear()
        stack.appendCaptured(ClipboardRecord(text: "late"), lease: nil, capturedIn: afterClear)
        XCTAssertTrue(stack.queue.isEmpty)
    }

    func testDuplicateCopiesKeepDistinctOccurrences() async {
        let stack = StackCoordinator()
        let record = ClipboardRecord(text: "repeated")
        stack.activate()
        stack.append(record)
        stack.append(record)
        let firstToken = stack.nextOccurrenceID

        XCTAssertEqual(stack.queue.count, 2)
        XCTAssertEqual(stack.markDispatched(expectedOccurrenceID: firstToken), record)
        XCTAssertEqual(stack.queue.count, 1)
        XCTAssertNotEqual(stack.nextOccurrenceID, firstToken)
        XCTAssertNil(stack.markDispatched(expectedOccurrenceID: firstToken))
        XCTAssertEqual(stack.queue.count, 1, "A repeated dispatch completion must not consume the second copy")
    }

    func testReverseConsumptionAndRecoveryPreserveCaptureOrder() async {
        let stack = StackCoordinator()
        let records = ["A", "B", "C"].map { ClipboardRecord(text: $0) }
        stack.activate()
        records.forEach(stack.append)
        stack.direction = .reverse

        XCTAssertEqual(stack.peek(), records[2])
        XCTAssertEqual(stack.markDispatched(), records[2])
        let additional = ClipboardRecord(text: "D")
        stack.append(additional)
        XCTAssertEqual(stack.restoreLastConsumed(), records[2])
        XCTAssertEqual(stack.queue.map(\.text), ["A", "B", "C", "D"])
        XCTAssertNil(stack.restoreLastConsumed(), "Recovery is one-level and may only occur once")
    }

    func testRestoredOccurrenceRejectsOldDispatchToken() async {
        let stack = StackCoordinator()
        let record = ClipboardRecord(text: "A")
        stack.activate()
        stack.append(record)
        let token = stack.nextOccurrenceID
        _ = stack.markDispatched(expectedOccurrenceID: token)
        XCTAssertTrue(stack.isActive)
        XCTAssertNil(stack.peek())
        XCTAssertTrue(stack.canRestoreLastConsumed)

        _ = stack.restoreLastConsumed()
        XCTAssertEqual(stack.peek(), record)
        XCTAssertNotEqual(stack.nextOccurrenceID, token)
        XCTAssertNil(stack.markDispatched(expectedOccurrenceID: token))
    }

    func testQueueEditsRejectStaleDispatchAndRecoveryUsesNeighbors() async {
        let stack = StackCoordinator()
        stack.activate()
        ["A", "B", "C"].forEach { stack.append(ClipboardRecord(text: $0)) }
        let token = stack.nextOccurrenceID
        _ = stack.remove(at: 0)
        XCTAssertNil(stack.markDispatched(expectedOccurrenceID: token))
        XCTAssertEqual(stack.peek()?.text, "B")
        _ = stack.markDispatched()
        stack.append(ClipboardRecord(text: "D"))
        _ = stack.restoreLastConsumed()
        XCTAssertEqual(stack.queue.map(\.text), ["B", "C", "D"])
    }

    func testInactiveClearEndAndReactivationBoundaries() async {
        let stack = StackCoordinator()
        let record = ClipboardRecord(text: "A")
        stack.append(record)
        XCTAssertTrue(stack.queue.isEmpty)
        stack.activate()
        stack.append(record)
        stack.activate()
        XCTAssertEqual(stack.queue.count, 1, "Repeated activation must not discard a live queue")
        _ = stack.markDispatched()
        stack.clear()
        XCTAssertTrue(stack.isActive)
        XCTAssertNil(stack.restoreLastConsumed())
        stack.append(record)
        stack.end()
        XCTAssertFalse(stack.isActive)
        XCTAssertNil(stack.peek())
        XCTAssertTrue(stack.queue.isEmpty)
        stack.activate()
        XCTAssertNil(stack.restoreLastConsumed())
    }

    func testInvalidActionsDoNotEmitChanges() async {
        let stack = StackCoordinator()
        var changes = 0
        stack.onChange = { changes += 1 }
        stack.append(ClipboardRecord(text: "ignored"))
        stack.end()
        XCTAssertEqual(changes, 0)
        stack.activate()
        stack.direction = .forward
        XCTAssertNil(stack.remove(at: -1))
        XCTAssertNil(stack.markDispatched())
        XCTAssertNil(stack.restoreLastConsumed())
        XCTAssertEqual(changes, 1)
        stack.direction = .reverse
        XCTAssertEqual(changes, 2)
    }
}
