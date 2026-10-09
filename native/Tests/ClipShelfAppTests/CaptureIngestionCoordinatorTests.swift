import XCTest
@testable import ClipShelf

private enum IngestionTestError: Error { case rejected }

private actor ControlledIngestionProcessor {
    private var continuations: [Int: CheckedContinuation<Int, Error>] = [:]
    private(set) var inputs: [Int] = []
    private var activeCount = 0
    private(set) var maximumActiveCount = 0
    private let onStart: @Sendable (Int, Int) -> Void
    init(onStart: @escaping @Sendable (Int, Int) -> Void) { self.onStart = onStart }

    // Deliberately ignores cancellation, as a backend commit may already be unavoidable.
    func process(_ input: Int) async throws -> Int {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            inputs.append(input)
            continuations[input] = continuation
            onStart(input, inputs.count)
        }
    }

    func finish(_ input: Int, result: Result<Int, Error>) {
        continuations.removeValue(forKey: input)?.resume(with: result)
    }
}

@MainActor
final class CaptureIngestionCoordinatorTests: XCTestCase {
    private func processor(_ starts: [XCTestExpectation]) -> ControlledIngestionProcessor {
        ControlledIngestionProcessor { _, ordinal in
            guard starts.indices.contains(ordinal - 1) else { XCTFail("Unexpected process invocation"); return }
            starts[ordinal - 1].fulfill()
        }
    }

    private func assertInputs(_ gate: ControlledIngestionProcessor, _ expected: [Int],
                              file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await gate.inputs
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertSerial(_ gate: ControlledIngestionProcessor,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let maximum = await gate.maximumActiveCount
        XCTAssertEqual(maximum, 1, file: file, line: line)
    }

    func testPendingQueryIncludesFailedHeadAndWaitingInputsUntilDiscard() async {
        let started = expectation(description: "started"), failed = expectation(description: "failed")
        let gate = processor([started])
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        XCTAssertFalse(subject.containsPending { _ in true })
        subject.onFailure = { _, _ in failed.fulfill() }
        subject.enqueue(1, byteCount: 1); subject.enqueue(2, byteCount: 2)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(subject.containsPending { $0 == 1 })
        XCTAssertTrue(subject.containsPending { $0 == 2 })
        XCTAssertFalse(subject.containsPending { $0 == 3 })
        await gate.finish(1, result: .failure(IngestionTestError.rejected))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(subject.hasFailure)
        XCTAssertTrue(subject.containsPending { $0 == 1 })
        XCTAssertTrue(subject.containsPending { $0 == 2 })
        subject.discardPending()
        XCTAssertFalse(subject.containsPending { _ in true })
    }

    func testPendingQueryRetainsOnlyDiscardedActiveWorkerUntilSettled() async {
        let starts = (1...2).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        let settled = expectation(description: "both settled"); settled.expectedFulfillmentCount = 2
        subject.onSettled = { settled.fulfill() }
        subject.enqueue(1, byteCount: 1); subject.enqueue(2, byteCount: 2)
        await fulfillment(of: [starts[0]], timeout: 2)
        subject.discardPending(); subject.discardPending()
        subject.enqueue(3, byteCount: 3)
        XCTAssertTrue(subject.containsPending { $0 == 1 })
        XCTAssertFalse(subject.containsPending { $0 == 2 })
        XCTAssertTrue(subject.containsPending { $0 == 3 })
        await gate.finish(1, result: .failure(IngestionTestError.rejected))
        await fulfillment(of: [starts[1]], timeout: 2)
        XCTAssertFalse(subject.containsPending { $0 == 1 })
        XCTAssertTrue(subject.containsPending { $0 == 3 })
        await gate.finish(3, result: .success(3))
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertFalse(subject.containsPending { _ in true })
    }

    func testFIFOProcessingDoesNotBlockMainActorAndCountsActiveInput() async {
        let starts = (1...3).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        let saved = expectation(description: "saved all"); saved.expectedFulfillmentCount = 3
        var outputs: [Int] = [], settled = 0
        subject.onSaved = { input, output in XCTAssertEqual(output, input * 10); outputs.append(input); saved.fulfill() }
        subject.onSettled = { settled += 1 }
        for input in 1...3 { XCTAssertTrue(subject.enqueue(input, byteCount: input * 10)) }
        await fulfillment(of: [starts[0]], timeout: 2)
        var interfaceResponsive = false
        await Task { @MainActor in interfaceResponsive = true }.value
        XCTAssertTrue(interfaceResponsive)
        XCTAssertTrue(subject.isProcessing)
        XCTAssertEqual(subject.pendingCount, 3); XCTAssertEqual(subject.pendingBytes, 60)
        await assertInputs(gate, [1])
        for input in 1...3 {
            await gate.finish(input, result: .success(input * 10))
            if input < 3 { await fulfillment(of: [starts[input]], timeout: 2) }
        }
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(outputs, [1, 2, 3]); XCTAssertEqual(settled, 3)
        XCTAssertEqual(subject.pendingCount, 0); XCTAssertEqual(subject.pendingBytes, 0)
        XCTAssertFalse(subject.isProcessing); XCTAssertFalse(subject.hasFailure)
        await assertSerial(gate)
    }

    func testCountAndByteBackpressureRejectWithoutReplacingQueuedItems() async {
        let started = expectation(description: "started"), settled = expectation(description: "settled")
        let gate = processor([started])
        let subject = CaptureIngestionCoordinator<Int, Int>(maxPendingCount: 2, maxPendingBytes: 10,
                                                           process: { try await gate.process($0) })
        subject.onSettled = { settled.fulfill() }
        XCTAssertFalse(subject.enqueue(0, byteCount: -1))
        XCTAssertFalse(subject.enqueue(0, byteCount: 11))
        XCTAssertTrue(subject.enqueue(1, byteCount: 6))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(subject.enqueue(2, byteCount: 5))
        XCTAssertTrue(subject.enqueue(2, byteCount: 4))
        XCTAssertFalse(subject.enqueue(3, byteCount: 0))
        XCTAssertEqual(subject.pendingCount, 2); XCTAssertEqual(subject.pendingBytes, 10)
        subject.discardPending()
        await gate.finish(1, result: .success(10))
        await fulfillment(of: [settled], timeout: 2)
        await assertInputs(gate, [1])
    }

    func testFailureRetainsHeadAndFollowingInputsUntilExplicitRetry() async {
        let starts = (1...4).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(maxPendingCount: 3, maxPendingBytes: 30,
                                                           process: { try await gate.process($0) })
        let failed = expectation(description: "failed"), saved = expectation(description: "saved")
        saved.expectedFulfillmentCount = 3
        var outputs: [Int] = []
        subject.onFailure = { input, _ in XCTAssertEqual(input, 1); failed.fulfill() }
        subject.onSaved = { input, _ in outputs.append(input); saved.fulfill() }
        XCTAssertTrue(subject.enqueue(1, byteCount: 10)); XCTAssertTrue(subject.enqueue(2, byteCount: 10))
        await fulfillment(of: [starts[0]], timeout: 2)
        await gate.finish(1, result: .failure(IngestionTestError.rejected))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(subject.hasFailure); XCTAssertFalse(subject.isProcessing)
        XCTAssertEqual(subject.pendingCount, 2); XCTAssertEqual(subject.pendingBytes, 20)
        XCTAssertTrue(subject.enqueue(3, byteCount: 10))
        XCTAssertFalse(subject.enqueue(4, byteCount: 0))
        await assertInputs(gate, [1])
        subject.retry(); subject.retry()
        await fulfillment(of: [starts[1]], timeout: 2)
        await assertInputs(gate, [1, 1])
        for input in 1...3 {
            await gate.finish(input, result: .success(input))
            if input < 3 { await fulfillment(of: [starts[input + 1]], timeout: 2) }
        }
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(outputs, [1, 2, 3]); XCTAssertFalse(subject.hasFailure)
    }

    func testDiscardKeepsActiveExclusionAndBudgetButRejectsItsLateSuccess() async {
        let starts = (1...2).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(maxPendingCount: 2, maxPendingBytes: 10,
                                                           process: { try await gate.process($0) })
        let settled = expectation(description: "both settled"); settled.expectedFulfillmentCount = 2
        var outputs: [Int] = []
        subject.onSaved = { input, _ in outputs.append(input) }
        subject.onFailure = { _, _ in XCTFail("Old errors cannot affect a new generation") }
        subject.onSettled = { settled.fulfill() }
        XCTAssertTrue(subject.enqueue(1, byteCount: 6))
        await fulfillment(of: [starts[0]], timeout: 2)
        XCTAssertTrue(subject.enqueue(2, byteCount: 4))
        subject.discardPending()
        XCTAssertTrue(subject.isProcessing)
        XCTAssertEqual(subject.pendingCount, 1); XCTAssertEqual(subject.pendingBytes, 6)
        XCTAssertFalse(subject.enqueue(3, byteCount: 5))
        XCTAssertTrue(subject.enqueue(3, byteCount: 4))
        await assertInputs(gate, [1])
        await gate.finish(1, result: .success(10))
        await fulfillment(of: [starts[1]], timeout: 2)
        await assertInputs(gate, [1, 3]); XCTAssertTrue(outputs.isEmpty)
        await gate.finish(3, result: .success(30))
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(outputs, [3]); XCTAssertEqual(subject.pendingBytes, 0)
        await assertSerial(gate)
    }

    func testOldLateFailureOnlySettlesAndDoesNotPauseNewQueue() async {
        let starts = (1...2).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        let settled = expectation(description: "settled twice"); settled.expectedFulfillmentCount = 2
        var saved: [Int] = []
        subject.onFailure = { _, _ in XCTFail("Discarded failure must not stop capture again") }
        subject.onSaved = { input, _ in saved.append(input) }
        subject.onSettled = { settled.fulfill() }
        subject.enqueue(1, byteCount: 1)
        await fulfillment(of: [starts[0]], timeout: 2)
        subject.discardPending(); subject.discardPending()
        subject.enqueue(2, byteCount: 1)
        await gate.finish(1, result: .failure(IngestionTestError.rejected))
        await fulfillment(of: [starts[1]], timeout: 2)
        XCTAssertFalse(subject.hasFailure)
        await gate.finish(2, result: .success(2))
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(saved, [2]); XCTAssertEqual(subject.pendingCount, 0)
    }

    func testFailureCallbackMayDiscardAndStartNewGenerationWithoutOverlappingProcess() async {
        let starts = (1...2).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        let saved = expectation(description: "replacement saved")
        var settled = 0
        subject.onFailure = { [weak subject] _, _ in
            subject?.discardPending()
            XCTAssertEqual(subject?.enqueue(3, byteCount: 3), true)
        }
        subject.onSaved = { input, _ in XCTAssertEqual(input, 3); saved.fulfill() }
        subject.onSettled = { settled += 1 }
        subject.enqueue(1, byteCount: 1); subject.enqueue(2, byteCount: 2)
        await fulfillment(of: [starts[0]], timeout: 2)
        await gate.finish(1, result: .failure(IngestionTestError.rejected))
        await fulfillment(of: [starts[1]], timeout: 2)
        await gate.finish(3, result: .success(3))
        await fulfillment(of: [saved], timeout: 2)
        await assertInputs(gate, [1, 3]); XCTAssertEqual(settled, 2)
        await assertSerial(gate)
    }

    func testFailedRetryKeepsSameHeadUntilDiscarded() async {
        let starts = (1...3).map { expectation(description: "start \($0)") }
        let failures = (1...2).map { expectation(description: "failure \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        var failureCount = 0
        subject.onFailure = { input, _ in
            XCTAssertEqual(input, 1)
            failures[failureCount].fulfill()
            failureCount += 1
        }
        subject.enqueue(1, byteCount: 4); subject.enqueue(2, byteCount: 5)
        for attempt in 0...1 {
            await fulfillment(of: [starts[attempt]], timeout: 2)
            await gate.finish(1, result: .failure(IngestionTestError.rejected))
            await fulfillment(of: [failures[attempt]], timeout: 2)
            XCTAssertTrue(subject.hasFailure)
            XCTAssertFalse(subject.isProcessing)
            XCTAssertEqual(subject.pendingCount, 2); XCTAssertEqual(subject.pendingBytes, 9)
            if attempt == 0 { subject.retry() }
        }
        await assertInputs(gate, [1, 1])
        subject.discardPending()
        XCTAssertFalse(subject.hasFailure)
        XCTAssertEqual(subject.pendingCount, 0); XCTAssertEqual(subject.pendingBytes, 0)
        let saved = expectation(description: "replacement saved")
        subject.onSaved = { input, _ in XCTAssertEqual(input, 3); saved.fulfill() }
        subject.enqueue(3, byteCount: 6)
        await fulfillment(of: [starts[2]], timeout: 2)
        await gate.finish(3, result: .success(3))
        await fulfillment(of: [saved], timeout: 2)
        await assertInputs(gate, [1, 1, 3])
    }

    func testSuccessCallbackMayDiscardQueuedInputsAndEnqueueReplacement() async {
        let starts = (1...2).map { expectation(description: "start \($0)") }
        let gate = processor(starts)
        let subject = CaptureIngestionCoordinator<Int, Int>(process: { try await gate.process($0) })
        let saved = expectation(description: "saved twice"); saved.expectedFulfillmentCount = 2
        var outputs: [Int] = [], settled = 0
        subject.onSaved = { [weak subject] input, _ in
            outputs.append(input)
            if input == 1 {
                subject?.discardPending()
                XCTAssertEqual(subject?.enqueue(3, byteCount: 3), true)
                XCTAssertFalse(subject?.isProcessing ?? true)
            }
            saved.fulfill()
        }
        subject.onSettled = { settled += 1 }
        subject.enqueue(1, byteCount: 1); subject.enqueue(2, byteCount: 2)
        await fulfillment(of: [starts[0]], timeout: 2)
        await gate.finish(1, result: .success(1))
        await fulfillment(of: [starts[1]], timeout: 2)
        XCTAssertEqual(settled, 1)
        await gate.finish(3, result: .success(3))
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(outputs, [1, 3]); XCTAssertEqual(settled, 2)
        await assertInputs(gate, [1, 3])
        await assertSerial(gate)
    }
}
