import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

private enum QueryFixtureError: Error { case rejected, timeout }

/// A synchronous database-like reader that deliberately cannot finish until released.
private final class ControlledPageReader: @unchecked Sendable {
    private let lock = NSLock()
    private let starts: [Int: XCTestExpectation]
    private let gates: [Int: DispatchSemaphore]
    private var inputs: [Int] = []
    private var tokens: [Int: HistoryReadCancellation] = [:]
    private var count = 0
    private var peak = 0

    init(_ starts: [Int: XCTestExpectation]) {
        self.starts = starts
        gates = starts.mapValues { _ in DispatchSemaphore(value: 0) }
    }
    func read(_ input: Int, cancellation: HistoryReadCancellation, fail: Bool = false) throws -> Int {
        XCTAssertFalse(Thread.isMainThread, "SQLite work must not block the interface")
        lock.lock()
        inputs.append(input); tokens[input] = cancellation
        count += 1; peak = max(peak, count)
        lock.unlock()
        defer { lock.lock(); count -= 1; lock.unlock() }
        starts[input]?.fulfill()
        guard let gate = gates[input], gate.wait(timeout: .now() + 5) == .success else {
            throw QueryFixtureError.timeout
        }
        if fail { throw QueryFixtureError.rejected }
        return input
    }
    func release(_ input: Int) { gates[input]?.signal() }
    var executed: [Int] { lock.lock(); defer { lock.unlock() }; return inputs }
    var maximumOverlap: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func cancelled(_ input: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return tokens[input]?.isCancelled == true
    }
}

@MainActor final class HistoryPageQueryCoordinatorTests: XCTestCase {
    func testTypingBurstRunsOnlyActiveAndLatestReadWithoutBlockingMainActor() async {
        let first = expectation(description: "first read"), latest = expectation(description: "latest read")
        let completed = expectation(description: "latest published")
        let reader = ControlledPageReader([1: first, 4: latest])
        let subject = HistoryPageQueryCoordinator<Int>()
        var outputs: [Int] = []
        subject.submit(read: { try reader.read(1, cancellation: $0) }, completion: { _ in XCTFail("Obsolete result") })
        await fulfillment(of: [first], timeout: 2)
        for input in 2...4 {
            subject.submit(read: { try reader.read(input, cancellation: $0) }, completion: { result in
                if case .success(let value) = result { outputs.append(value) } else { XCTFail("Current read failed") }
                completed.fulfill()
            })
        }
        XCTAssertTrue(reader.cancelled(1))
        XCTAssertEqual(reader.executed, [1])
        var responsive = false
        await Task { @MainActor in responsive = true }.value
        XCTAssertTrue(responsive)
        reader.release(1)
        await fulfillment(of: [latest], timeout: 2)
        XCTAssertEqual(reader.executed, [1, 4])
        reader.release(4)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(outputs, [4]); XCTAssertEqual(reader.maximumOverlap, 1)
    }

    func testDismissCancelsActiveAndQueuedReadAndReopenWaitsForOldWorkerToFinish() async {
        let first = expectation(description: "first read"), reopened = expectation(description: "reopened read")
        let completed = expectation(description: "reopened published")
        let reader = ControlledPageReader([1: first, 3: reopened])
        let subject = HistoryPageQueryCoordinator<Int>()
        let panel = ClipboardPanelController()
        panel.onDismiss = { subject.cancel() }
        subject.submit(read: { try reader.read(1, cancellation: $0, fail: true) }, completion: { _ in XCTFail("Old error") })
        await fulfillment(of: [first], timeout: 2)
        subject.submit(read: { try reader.read(2, cancellation: $0) }, completion: { _ in XCTFail("Cancelled queue") })
        panel.hidePreservingDraft()
        subject.submit(read: { try reader.read(3, cancellation: $0) }, completion: { result in
            XCTAssertEqual(try? result.get(), 3); completed.fulfill()
        })
        XCTAssertTrue(reader.cancelled(1)); XCTAssertEqual(reader.executed, [1])
        reader.release(1)
        await fulfillment(of: [reopened], timeout: 2)
        reader.release(3)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(reader.executed, [1, 3]); XCTAssertEqual(reader.maximumOverlap, 1)
        panel.dismiss()
    }

    func testCurrentFailurePublishesOnceAndCompletionCanSubmitRetry() async {
        let first = expectation(description: "failed read"), retry = expectation(description: "retry read")
        let done = expectation(description: "retry published")
        let reader = ControlledPageReader([1: first, 2: retry])
        let subject = HistoryPageQueryCoordinator<Int>()
        var failures = 0, values: [Int] = []
        subject.submit(read: { try reader.read(1, cancellation: $0, fail: true) }, completion: { result in
            guard case .failure(QueryFixtureError.rejected) = result else { XCTFail("Expected current error"); return }
            failures += 1
            subject.submit(read: { try reader.read(2, cancellation: $0) }, completion: { result in
                if let value = try? result.get() { values.append(value) }
                done.fulfill()
            })
        })
        await fulfillment(of: [first], timeout: 2); reader.release(1)
        await fulfillment(of: [retry], timeout: 2); reader.release(2)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(failures, 1); XCTAssertEqual(values, [2]); XCTAssertEqual(reader.maximumOverlap, 1)
    }

    func testCancelWithoutReplacementDropsLateSuccessAndAllowsFreshRequest() async {
        let first = expectation(description: "first read"), fresh = expectation(description: "fresh read")
        let done = expectation(description: "fresh published")
        let oldResult = expectation(description: "old result stays hidden"); oldResult.isInverted = true
        let reader = ControlledPageReader([1: first, 3: fresh])
        let subject = HistoryPageQueryCoordinator<Int>()
        subject.submit(read: { try reader.read(1, cancellation: $0) }, completion: { _ in oldResult.fulfill() })
        await fulfillment(of: [first], timeout: 2)
        subject.submit(read: { try reader.read(2, cancellation: $0) }, completion: { _ in oldResult.fulfill() })
        subject.cancel(); subject.cancel(); reader.release(1)
        await fulfillment(of: [oldResult], timeout: 0.1)
        XCTAssertEqual(reader.executed, [1])
        subject.submit(read: { try reader.read(3, cancellation: $0) }, completion: { result in
            XCTAssertEqual(try? result.get(), 3); done.fulfill(); subject.cancel()
        })
        await fulfillment(of: [fresh], timeout: 2); reader.release(3)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(reader.executed, [1, 3]); XCTAssertEqual(reader.maximumOverlap, 1)
    }

    func testDeinitCancelsActualWorkerAndDoesNotRetainCoordinator() async {
        let first = expectation(description: "first read")
        let callback = expectation(description: "owner gone"); callback.isInverted = true
        let reader = ControlledPageReader([1: first])
        var subject: HistoryPageQueryCoordinator<Int>? = HistoryPageQueryCoordinator()
        let remainingOwner = { [weak subject] in subject }
        subject?.submit(read: { try reader.read(1, cancellation: $0) }, completion: { _ in callback.fulfill() })
        await fulfillment(of: [first], timeout: 2)
        subject = nil
        XCTAssertNil(remainingOwner()); XCTAssertTrue(reader.cancelled(1))
        reader.release(1)
        await fulfillment(of: [callback], timeout: 0.1)
    }
}
