import ClipShelfCore
@testable import ClipShelf
import XCTest

@MainActor final class StackDispatchTests: XCTestCase {
    private let clock = HandoffClock()

    private func stack(_ values: [String] = ["A", "B", "C"]) -> StackCoordinator {
        let stack = StackCoordinator(scheduleHandoff: clock.schedule); stack.activate()
        values.forEach { stack.append(ClipboardRecord(text: $0)) }
        return stack
    }

    func testRapidRequestsAreSerializedKeepTheirOwnTargetsAndConsumeOnlyOnDispatch() {
        let stack = stack()
        var sent: [(String, String, (PasteCoordinator.Outcome) -> Void)] = []
        for target in ["field-1", "field-2", "field-3"] {
            XCTAssertTrue(stack.requestPaste { request, done in sent.append((request.record.text, target, done)) })
        }
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(stack.queue.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(stack.pendingPasteCount, 3)
        XCTAssertFalse(stack.requestPaste { _, _ in XCTFail("Cannot queue more gestures than available occurrences") })
        sent[0].2(.dispatched)
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(stack.queue.map(\.text), ["B", "C"])
        sent[0].2(.dispatched)
        XCTAssertEqual(sent.count, 1, "Repeated completion must not bypass the handoff")
        clock.advance(by: StackCoordinator.clipboardHandoffInterval)
        XCTAssertEqual(sent.count, 2, "A repeated completion must not release the next action")
        sent[1].2(.dispatched)
        clock.advance(by: StackCoordinator.clipboardHandoffInterval)
        sent[2].2(.dispatched)
        XCTAssertEqual(sent.map { $0.0 }, ["A", "B", "C"])
        XCTAssertEqual(sent.map { $0.1 }, ["field-1", "field-2", "field-3"])
        XCTAssertTrue(stack.queue.isEmpty); XCTAssertEqual(stack.pendingPasteCount, 0)
        XCTAssertEqual(stack.restoreLastConsumed()?.text, "C")
    }

    func testEveryNonDispatchOutcomeRetainsItemsAndStopsQueuedAutomaticActions() {
        for outcome in [PasteCoordinator.Outcome.failed, .copiedOnly, .cancelled, .busy] {
            let stack = stack()
            var reply: ((PasteCoordinator.Outcome) -> Void)?
            XCTAssertTrue(stack.requestPaste { _, done in reply = done })
            XCTAssertTrue(stack.requestPaste { _, _ in XCTFail("Failure must not continue automatically") })
            reply?(outcome)
            XCTAssertEqual(stack.queue.map(\.text), ["A", "B", "C"])
            XCTAssertFalse(stack.canRestoreLastConsumed); XCTAssertEqual(stack.pendingPasteCount, 0)
            XCTAssertTrue(stack.requestPaste { request, done in
                XCTAssertEqual(request.record.text, "A"); done(.dispatched)
            })
            reply?(.dispatched)
            XCTAssertEqual(stack.queue.map(\.text), ["B", "C"])
        }
    }

    func testDirectionChangeAffectsNextRequestWithoutRepeatingInFlightOccurrence() {
        let stack = stack()
        var sent: [(StackCoordinator.DispatchRequest, (PasteCoordinator.Outcome) -> Void)] = []
        stack.requestPaste { sent.append(($0, $1)) }
        stack.requestPaste { sent.append(($0, $1)) }
        stack.direction = .reverse
        XCTAssertTrue(stack.isDispatchCurrent(sent[0].0))
        sent[0].1(.dispatched)
        XCTAssertEqual(stack.queue.map(\.text), ["B", "C"])
        clock.advance(by: StackCoordinator.clipboardHandoffInterval)
        XCTAssertEqual(sent[1].0.record.text, "C")
        stack.direction = .forward
        sent[1].1(.dispatched)
        XCTAssertEqual(stack.queue.map(\.text), ["B"])
        XCTAssertEqual(stack.restoreLastConsumed()?.text, "C")
        XCTAssertEqual(stack.queue.map(\.text), ["B", "C"])
    }

    func testEndClearAndRemovingActiveOccurrenceInvalidateContextBeforeCancellationCallback() {
        for operation in ["end", "clear", "remove"] {
            let stack = stack()
            var request: StackCoordinator.DispatchRequest!, reply: ((PasteCoordinator.Outcome) -> Void)!
            stack.requestPaste { request = $0; reply = $1 }
            stack.requestPaste { _, _ in XCTFail("Canceled requests must not continue") }
            var cancellations = 0
            stack.onCancelPendingPaste = {
                cancellations += 1
                XCTAssertFalse(stack.isDispatchCurrent(request))
                reply(.cancelled)
            }
            if operation == "end" { stack.end(); stack.activate() }
            else if operation == "clear" { stack.clear() }
            else { _ = stack.remove(at: 0) }
            stack.append(ClipboardRecord(text: "new session item"))
            let afterCancellation = stack.queue.map(\.id)
            reply(.dispatched)
            XCTAssertEqual(cancellations, 1); XCTAssertEqual(stack.pendingPasteCount, 0)
            XCTAssertEqual(stack.queue.map(\.id), afterCancellation)
            XCTAssertFalse(stack.canRestoreLastConsumed)
        }
    }

    func testSuspensionCancelsActionsButKeepsQueueAndFreshRetryRejectsOldCompletion() {
        let stack = stack(["A", "A"])
        var previous: ((PasteCoordinator.Outcome) -> Void)!, current: ((PasteCoordinator.Outcome) -> Void)!
        var oldRequest: StackCoordinator.DispatchRequest!
        stack.requestPaste { oldRequest = $0; previous = $1 }
        stack.requestPaste { _, _ in XCTFail("Suspension clears queued gestures") }
        stack.cancelPendingPastes()
        XCTAssertEqual(stack.queue.count, 2); XCTAssertFalse(stack.isDispatchCurrent(oldRequest))
        stack.requestPaste { _, done in current = done }
        previous(.dispatched)
        XCTAssertEqual(stack.queue.count, 2); XCTAssertEqual(stack.pendingPasteCount, 1)
        current(.dispatched)
        XCTAssertEqual(stack.queue.count, 1)
    }

    func testRemovingAnotherOccurrenceAndRestoringPreviousDoesNotRetargetCurrentAction() {
        let stack = stack(["A", "B", "C", "D"])
        _ = stack.markDispatched()
        var current: StackCoordinator.DispatchRequest!, reply: ((PasteCoordinator.Outcome) -> Void)!
        stack.requestPaste { current = $0; reply = $1 }
        XCTAssertEqual(current.record.text, "B")
        XCTAssertEqual(stack.restoreLastConsumed()?.text, "A")
        _ = stack.remove(at: 2)
        XCTAssertTrue(stack.isDispatchCurrent(current))
        reply(.dispatched)
        XCTAssertEqual(stack.queue.map(\.text), ["A", "D"])
        XCTAssertEqual(stack.restoreLastConsumed()?.text, "B")
        XCTAssertEqual(stack.queue.map(\.text), ["A", "B", "D"])
    }

    func testSynchronousCompletionAndOnChangeReentrancyCannotStartStaleQueuedWork() {
        let stack = stack()
        var first: ((PasteCoordinator.Outcome) -> Void)!, sent: [String] = []
        stack.requestPaste { request, done in sent.append(request.record.text); first = done }
        stack.requestPaste { _, _ in XCTFail("Ending in onChange invalidates the pending request") }
        stack.onChange = { if stack.queue.count == 2 { stack.end() } }
        first(.dispatched)
        XCTAssertEqual(sent, ["A"]); XCTAssertFalse(stack.isActive)
        XCTAssertEqual(stack.pendingPasteCount, 0)
        stack.onChange = nil; stack.activate(); stack.append(ClipboardRecord(text: "D"))
        stack.requestPaste { request, done in sent.append(request.record.text); done(.dispatched); done(.dispatched) }
        XCTAssertEqual(sent, ["A", "D"]); XCTAssertTrue(stack.queue.isEmpty)
    }

    func testDelayedReceiverReadsEachClipboardValueWithinHandoffWindow() {
        let stack = stack(["A", "B"])
        var clipboard = "", received: [String] = [], submitted: [String] = []
        let action: StackCoordinator.PasteAction = { [clock] request, done in
            clipboard = request.record.text
            submitted.append(request.record.text)
            // Model an event already posted, whose recipient reads later.
            clock.schedule(0.15) { received.append(clipboard) }
            done(.dispatched)
        }
        stack.requestPaste(using: action)
        stack.requestPaste(using: action)
        XCTAssertEqual(submitted, ["A"])
        clock.advance(by: 0.15)
        XCTAssertEqual(received, ["A"])
        XCTAssertEqual(clipboard, "A")
        clock.advance(by: 0.05)
        XCTAssertEqual(submitted, ["A", "B"])
        clock.advance(by: 0.15)
        XCTAssertEqual(received, ["A", "B"])
        XCTAssertTrue(stack.queue.isEmpty)
        // Receivers slower than the configured window have no read ACK; this
        // test intentionally proves only the bounded handoff behavior.
    }

    func testHandoffExistsWithoutBacklogAndBeforeReentrantChangeObserver() {
        let stack = stack(["A", "B"])
        var submitted: [String] = []
        stack.onChange = {
            guard stack.queue.count == 1 else { return }
            stack.requestPaste { request, done in
                submitted.append(request.record.text); done(.dispatched)
            }
        }
        stack.requestPaste { request, done in
            submitted.append(request.record.text); done(.dispatched)
        }
        XCTAssertEqual(submitted, ["A"])
        XCTAssertEqual(stack.pendingPasteCount, 1)
        clock.advance(by: StackCoordinator.clipboardHandoffInterval)
        XCTAssertEqual(submitted, ["A", "B"])
    }

    func testCancelEndAndClearDiscardBacklogAndOldTimerCannotReleaseNewHandoff() {
        for operation in ["cancel", "end", "clear"] {
            let stack = stack()
            stack.requestPaste { _, done in done(.dispatched) }
            stack.requestPaste { _, _ in XCTFail("Canceled backlog must never write") }
            clock.advance(by: 0.1)
            if operation == "cancel" { stack.cancelPendingPastes() }
            else if operation == "end" { stack.end(); stack.activate() }
            else { stack.clear() }
            if operation != "cancel" {
                stack.append(ClipboardRecord(text: "X")); stack.append(ClipboardRecord(text: "Y"))
            }
            let expected = stack.queue.map(\.text)
            var submitted: [String] = []
            stack.requestPaste { request, done in submitted.append(request.record.text); done(.dispatched) }
            stack.requestPaste { request, done in submitted.append(request.record.text); done(.dispatched) }
            XCTAssertEqual(submitted, [expected[0]])
            clock.advance(by: 0.1)
            XCTAssertEqual(submitted, [expected[0]], "Old timer must not release the new session's handoff")
            clock.advance(by: 0.1)
            XCTAssertEqual(submitted, expected)
            stack.end()
        }
    }
}

@MainActor private final class HandoffClock {
    private var now: TimeInterval = 0
    private var scheduled: [(deadline: TimeInterval, order: Int, action: @MainActor () -> Void)] = []
    private var nextOrder = 0

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        scheduled.append((now + delay, nextOrder, action)); nextOrder += 1
    }

    func advance(by interval: TimeInterval) {
        let end = now + interval
        while let next = scheduled.enumerated().filter({ $0.element.deadline <= end + 0.000_001 }).min(by: {
            ($0.element.deadline, $0.element.order) < ($1.element.deadline, $1.element.order)
        }) {
            let event = scheduled.remove(at: next.offset)
            now = event.deadline; event.action()
        }
        now = end
    }
}
