import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor
private final class PasteFakeClipboard: PasteClipboard {
    var changeCount = 20
    var succeeds = true
    var writes = 0
    var text = "previous"
    func replaceContents(with items: [NSPasteboardItem]) -> PasteClipboardWrite {
        writes += 1; changeCount += 1
        if succeeds { text = items.compactMap { $0.string(forType: .string) }.joined(separator: "\n") }
        return .init(succeeded: succeeds, changeCount: changeCount)
    }
    func replaceExternally() { changeCount += 1; text = "other content" }
}

@MainActor
private final class PasteFakeEnvironment: PasteEnvironment {
    var hasPermission = true
    var uptime: TimeInterval = 100
    var ownProcessIdentifier: pid_t = 100
    var targetPID: pid_t = 200
    var running = true
    var windowAvailable = true
    var front: PasteForeground = .target
    var focus: PasteFocusState = .ready
    var heldModifiers: PasteModifiers = []
    var activationSucceeds = true
    var raiseSucceeds = true
    var eventCreationSucceeds = true
    var activates = 0, raises = 0, focusRestores = 0, prepares = 0, dispatches = 0
    var onActivate: (() -> Void)?
    var onRaise: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onDispatch: (() -> Void)?
    var waits: [CheckedContinuation<Void, Error>] = []
    // .current supplies only an inert Target value. None of its process/window
    // properties is inspected: all validation comes from this fake environment.
    var target: PasteCoordinator.Target { .init(application: .current, window: nil, focusedElement: nil) }
    func requestPermission() { XCTFail("Tests must not request system permissions") }
    func captureTarget() -> PasteCoordinator.Target? { target }
    func processIdentifier(of target: PasteCoordinator.Target) -> pid_t { targetPID }
    func isRunning(_ target: PasteCoordinator.Target) -> Bool { running }
    func hasWindow(_ target: PasteCoordinator.Target) -> Bool { windowAvailable }
    func foreground(for target: PasteCoordinator.Target) -> PasteForeground { front }
    func activate(_ target: PasteCoordinator.Target) -> Bool { activates += 1; onActivate?(); return activationSucceeds }
    func raiseWindow(_ target: PasteCoordinator.Target) -> Bool { raises += 1; onRaise?(); return raiseSucceeds }
    func restoreFocusedElement(_ target: PasteCoordinator.Target) { focusRestores += 1 }
    func focusState(for target: PasteCoordinator.Target) -> PasteFocusState { focus }
    func prepareCommandV() -> (() -> Void)? {
        prepares += 1; onPrepare?()
        guard eventCreationSucceeds else { return nil }
        return { self.dispatches += 1; self.onDispatch?() }
    }
    func waitForReadiness() async throws { try await withCheckedThrowingContinuation { waits.append($0) } }
    func advance(_ seconds: TimeInterval = 0.015) {
        uptime += seconds
        let pending = waits; waits = []
        pending.forEach { $0.resume() }
    }
    func failWait() {
        let pending = waits; waits = []
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class PasteHarness {
    let clipboard = PasteFakeClipboard()
    let environment = PasteFakeEnvironment()
    let coordinator: PasteCoordinator
    var outcomes: [PasteCoordinator.Outcome] = []
    var messages: [String] = []
    var copied = 0, dismissed = 0, acknowledged = 0
    init() {
        coordinator = PasteCoordinator(clipboard: clipboard, environment: environment)
        coordinator.onResult = { [weak self] in self?.messages.append($0) }
    }
    func paste(allowHeldCommand: Bool = false, context: (() -> Bool)? = nil,
               onCopied: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
               completion: ((PasteCoordinator.Outcome) -> Void)? = nil) {
        coordinator.paste([ClipboardRecord(text: "intended content")], plainText: true, target: environment.target,
            dismiss: { self.dismissed += 1; onDismiss?() },
            onCopied: { self.copied += 1; onCopied?() }, onDispatched: { self.acknowledged += 1 },
            allowHeldCommand: allowHeldCommand, isContextCurrent: context,
            onCompleted: { self.outcomes.append($0); completion?($0) })
    }
    func settle() async { for _ in 0..<20 { await Task.yield() } }
    func stop() async { coordinator.cancel(); environment.failWait(); await settle() }
}

final class PasteCoordinatorTests: XCTestCase {
    @MainActor func testNormalPathCopiesDismissesAndDispatchesExactlyOnce() async {
        let h = PasteHarness()
        h.paste()
        XCTAssertEqual(h.clipboard.text, "intended content")
        XCTAssertEqual(h.copied, 1); XCTAssertEqual(h.dismissed, 1)
        await h.settle()
        XCTAssertEqual(h.outcomes, [.dispatched]); XCTAssertEqual(h.environment.dispatches, 1)
        XCTAssertEqual(h.acknowledged, 1)
        h.coordinator.cancel(); h.environment.advance(2); await h.settle()
        XCTAssertEqual(h.outcomes, [.dispatched]); XCTAssertEqual(h.environment.dispatches, 1)
    }

    @MainActor func testCancellationInsideWriteObserverStillAcknowledgesPublishedOutput() async {
        let h = PasteHarness()
        h.coordinator.onClipboardWrite = { h.coordinator.cancel() }
        h.paste()
        await h.settle()
        XCTAssertEqual(h.clipboard.writes, 1); XCTAssertEqual(h.copied, 1)
        XCTAssertEqual(h.dismissed, 0); XCTAssertEqual(h.environment.activates, 0)
        XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.dispatches, 0)
    }

    @MainActor func testCancellationInsideCopiedOrDismissCallbackCannotResumePaste() async {
        for stage in 0...1 {
            let h = PasteHarness()
            h.paste(onCopied: { if stage == 0 { h.coordinator.cancel() } },
                    onDismiss: { if stage == 1 { h.coordinator.cancel() } })
            await h.settle()
            XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.dispatches, 0)
            XCTAssertEqual(h.environment.activates, 0)
        }
    }

    @MainActor func testReentrantPasteDuringCopyReturnsBusyWithoutSecondWrite() async {
        let h = PasteHarness()
        h.coordinator.onClipboardWrite = { h.paste() }
        h.paste()
        await h.settle()
        XCTAssertEqual(h.clipboard.writes, 1)
        XCTAssertEqual(h.outcomes, [.busy, .dispatched]); XCTAssertEqual(h.environment.dispatches, 1)
    }

    @MainActor func testClipboardOwnershipIsCapturedBeforeWriteAndCopiedCallbacks() async {
        for stage in 0...1 {
            let h = PasteHarness()
            if stage == 0 { h.coordinator.onClipboardWrite = { h.clipboard.replaceExternally() } }
            h.paste(onCopied: { if stage == 1 { h.clipboard.replaceExternally() } })
            await h.settle()
            XCTAssertEqual(h.clipboard.text, "other content")
            XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.dispatches, 0)
            XCTAssertEqual(h.copied, 1)
        }
    }

    @MainActor func testMissingPermissionWindowOrTargetOnlyCopiesWithoutSystemRestore() async {
        for mode in 0...2 {
            let h = PasteHarness()
            if mode == 0 { h.environment.hasPermission = false }
            if mode == 1 { h.environment.windowAvailable = false }
            if mode == 2 { h.environment.running = false }
            h.paste(); await h.settle()
            XCTAssertEqual(h.clipboard.writes, 1); XCTAssertEqual(h.outcomes, [.copiedOnly])
            XCTAssertEqual(h.environment.activates, 0); XCTAssertEqual(h.environment.dispatches, 0)
        }
        let h = PasteHarness()
        h.coordinator.paste([ClipboardRecord(text: "copy only")], plainText: true, target: nil, dismiss: {},
                            onCompleted: { h.outcomes.append($0) })
        XCTAssertEqual(h.outcomes, [.copiedOnly])
        XCTAssertEqual(h.clipboard.text, "copy only")
    }

    @MainActor func testFailedWriteDoesNotDismissRestoreOrDispatch() async {
        let h = PasteHarness(); h.clipboard.succeeds = false
        h.paste(); await h.settle()
        XCTAssertEqual(h.outcomes, [.failed]); XCTAssertEqual(h.copied, 0); XCTAssertEqual(h.dismissed, 0)
        XCTAssertEqual(h.environment.activates, 0); XCTAssertEqual(h.environment.dispatches, 0)
    }

    @MainActor func testDelayedWindowAndFieldRestorationCanSucceedWithinDeadline() async {
        let h = PasteHarness(); h.environment.front = .clipShelf; h.environment.focus = .differentWindow
        h.paste(); await h.settle()
        XCTAssertEqual(h.environment.waits.count, 1)
        h.environment.front = .target; h.environment.advance(0.1); await h.settle()
        XCTAssertTrue(h.outcomes.isEmpty)
        h.environment.focus = .differentElement; h.environment.advance(0.1); await h.settle()
        XCTAssertTrue(h.outcomes.isEmpty)
        h.environment.focus = .ready; h.environment.advance(0.1); await h.settle()
        XCTAssertEqual(h.outcomes, [.dispatched]); XCTAssertEqual(h.environment.dispatches, 1)
    }

    @MainActor func testNeverRestoredWindowOrElementDoesNotDispatch() async {
        for focus in [PasteFocusState.differentWindow, .differentElement] {
            let h = PasteHarness(); h.environment.focus = focus
            h.paste(); await h.settle()
            h.environment.advance(1); await h.settle()
            XCTAssertEqual(h.outcomes, [.copiedOnly]); XCTAssertEqual(h.environment.dispatches, 0)
            XCTAssertEqual(h.messages.count, 1)
        }
    }

    @MainActor func testModifiersMustReleaseForPanelButStackCanKeepCommandHeld() async {
        let panel = PasteHarness(); panel.environment.heldModifiers = .command
        panel.paste(); await panel.settle()
        XCTAssertTrue(panel.outcomes.isEmpty)
        panel.environment.heldModifiers = []; panel.environment.advance(); await panel.settle()
        XCTAssertEqual(panel.outcomes, [.dispatched])
        let stack = PasteHarness(); stack.environment.heldModifiers = .command
        stack.paste(allowHeldCommand: true); await stack.settle()
        XCTAssertEqual(stack.outcomes, [.dispatched])
        for modifier in [PasteModifiers.shift, .option, .control] {
            let h = PasteHarness(); h.environment.heldModifiers = [.command, modifier]
            h.paste(allowHeldCommand: true); await h.settle()
            XCTAssertTrue(h.outcomes.isEmpty); XCTAssertEqual(h.environment.dispatches, 0)
            await h.stop()
        }
    }

    @MainActor func testClipboardReplacementWhileWaitingCancels() async {
        let h = PasteHarness(); h.environment.heldModifiers = .command
        h.paste(); await h.settle()
        h.clipboard.replaceExternally(); h.environment.heldModifiers = []; h.environment.advance()
        await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.dispatches, 0)
    }

    @MainActor func testCancellationAtDeadlineDoesNotPublishLateFailureOrClearNextAttempt() async {
        let h = PasteHarness(); h.environment.heldModifiers = .command
        h.paste(); await h.settle()
        h.coordinator.cancel()
        h.paste(); await h.settle()
        h.environment.heldModifiers = []; h.environment.advance(2); await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled, .copiedOnly])
        XCTAssertEqual(h.messages.count, 1, "Only the still-current request may report its timeout")
        XCTAssertEqual(h.environment.dispatches, 0)
        h.paste(); await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled, .copiedOnly, .dispatched])
    }

    @MainActor func testOldCanceledWaitCannotDispatchOrClearNewReadyAttempt() async {
        let h = PasteHarness(); h.environment.heldModifiers = .command
        h.paste(); await h.settle(); h.coordinator.cancel()
        h.environment.heldModifiers = []; h.paste(); h.environment.advance(); await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled, .dispatched]); XCTAssertEqual(h.environment.dispatches, 1)
        XCTAssertEqual(h.messages.count, 1)
    }

    @MainActor func testActivationObserverRemembersSwitchAwayAndBackBetweenPolls() async {
        let h = PasteHarness(); h.environment.heldModifiers = .command
        h.paste(); await h.settle()
        h.coordinator.applicationDidActivate(processIdentifier: h.environment.targetPID)
        h.coordinator.applicationDidActivate(processIdentifier: h.environment.ownProcessIdentifier)
        XCTAssertTrue(h.outcomes.isEmpty)
        h.coordinator.applicationDidActivate(processIdentifier: 300)
        h.coordinator.applicationDidActivate(processIdentifier: h.environment.targetPID)
        h.environment.heldModifiers = []; h.environment.advance(); await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.dispatches, 0)
    }

    @MainActor func testChangedForegroundCancelsWithoutReactivatingOldTarget() async {
        let h = PasteHarness(); h.environment.front = .other
        h.paste(); await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.activates, 0)
        let pending = PasteHarness(); pending.environment.heldModifiers = .command
        pending.paste(); await pending.settle()
        pending.environment.front = .other; pending.environment.advance(); await pending.settle()
        XCTAssertEqual(pending.outcomes, [.cancelled]); XCTAssertEqual(pending.environment.activates, 1)
    }

    @MainActor func testCancelDuringActivationDoesNotRaiseWindowOrDispatch() async {
        let h = PasteHarness(); h.environment.onActivate = { h.coordinator.cancel() }
        h.paste(); await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.raises, 0)
        XCTAssertEqual(h.environment.dispatches, 0)
    }

    @MainActor func testFailedActivationOrRaiseOnlyCopies() async {
        for stage in 0...1 {
            let h = PasteHarness()
            if stage == 0 { h.environment.activationSucceeds = false } else { h.environment.raiseSucceeds = false }
            h.paste(); await h.settle()
            XCTAssertEqual(h.outcomes, [.copiedOnly]); XCTAssertEqual(h.environment.dispatches, 0)
        }
    }

    @MainActor func testContextInvalidBeforeCopyOrDuringWaitPreventsOutput() async {
        let before = PasteHarness(); before.paste(context: { false })
        XCTAssertEqual(before.clipboard.writes, 0); XCTAssertEqual(before.outcomes, [.cancelled])
        let during = PasteHarness(); during.environment.heldModifiers = .command
        var valid = true
        during.paste(context: { valid }); await during.settle()
        valid = false; during.environment.heldModifiers = []; during.environment.advance(); await during.settle()
        XCTAssertEqual(during.outcomes, [.cancelled]); XCTAssertEqual(during.environment.dispatches, 0)
    }

    @MainActor func testFinalDispatchBoundaryRechecksEveryMutableCondition() async {
        for mutation in 0...6 {
            let h = PasteHarness(); var context = true
            h.environment.onPrepare = {
                switch mutation {
                case 0: h.clipboard.replaceExternally()
                case 1: h.environment.front = .other
                case 2: h.environment.focus = .differentWindow
                case 3: h.environment.focus = .differentElement
                case 4: h.environment.heldModifiers = .shift
                case 5: h.environment.hasPermission = false
                default: context = false
                }
            }
            h.paste(context: { context }); await h.settle()
            XCTAssertEqual(h.environment.dispatches, 0, "mutation \(mutation)")
            XCTAssertEqual(h.outcomes.count, 1)
            XCTAssertNotEqual(h.outcomes.first, .dispatched)
        }
    }

    @MainActor func testPredicateReentrantCancellationCannotDispatch() async {
        let h = PasteHarness()
        h.paste(context: {
            if h.environment.prepares > 0 { h.coordinator.cancel() }
            return true
        })
        await h.settle()
        XCTAssertEqual(h.outcomes, [.cancelled]); XCTAssertEqual(h.environment.dispatches, 0)
    }

    @MainActor func testCompletionCanStartNextPasteAfterPriorAttemptIsReleased() async {
        let h = PasteHarness(); var requestedNext = false
        h.paste(completion: { outcome in
            if outcome == .dispatched && !requestedNext { requestedNext = true; h.paste() }
        })
        await h.settle()
        XCTAssertEqual(h.outcomes, [.dispatched, .dispatched]); XCTAssertEqual(h.environment.dispatches, 2)
        XCTAssertEqual(h.clipboard.writes, 2)
    }

    @MainActor func testEventCreationFailureAndCancelledWaitCompleteExactlyOnce() async {
        let h = PasteHarness(); h.environment.eventCreationSucceeds = false
        h.paste(); await h.settle()
        XCTAssertEqual(h.outcomes, [.copiedOnly]); XCTAssertEqual(h.environment.dispatches, 0)
        let waiting = PasteHarness(); waiting.environment.heldModifiers = .command
        waiting.paste(); await waiting.settle(); waiting.environment.failWait(); await waiting.settle()
        XCTAssertEqual(waiting.outcomes, [.cancelled]); XCTAssertEqual(waiting.environment.dispatches, 0)
    }

    @MainActor func testCancellationAfterEventSubmissionDoesNotMisreportUnsentOutput() async {
        let h = PasteHarness(); h.environment.onDispatch = { h.coordinator.cancel() }
        h.paste(); await h.settle()
        XCTAssertEqual(h.outcomes, [.dispatched]); XCTAssertEqual(h.environment.dispatches, 1)
        XCTAssertEqual(h.acknowledged, 1)
    }
}
