import ClipShelfLocalization
import AppKit
import ApplicationServices
import ClipShelfCore
import OSLog

@MainActor
final class PasteCoordinator {
    private static let outcomeLogger = Logger(subsystem: "io.github.bestbbb.clipshelf", category: "PasteOutcome")
    struct Target {
        let application: NSRunningApplication
        let window: AXUIElement?
        let focusedElement: AXUIElement?
        let selectedRange: CFRange?

        init(application: NSRunningApplication, window: AXUIElement?, focusedElement: AXUIElement?, selectedRange: CFRange? = nil) {
            self.application = application; self.window = window
            self.focusedElement = focusedElement; self.selectedRange = selectedRange
        }
    }

    /// Dispatched means a paste command was submitted, not that the destination app
    /// has confirmed insertion. Only this outcome may consume a Paste Stack item.
    enum Outcome: Equatable { case dispatched, copiedOnly, cancelled, failed, busy }

    private final class Attempt {
        let id = UUID().uuidString
        let startedAt: TimeInterval
        let mode: PasteStrictness
        let target: Target?
        let isContextCurrent: (() -> Bool)?
        let onDispatched: (() -> Void)?
        let onCompleted: ((Outcome) -> Void)?
        var task: Task<Void, Never>?
        var dispatching = false
        var waitingForClickRelease = false
        var method: PasteDispatch.Method?
        init(startedAt: TimeInterval, mode: PasteStrictness, target: Target?, isContextCurrent: (() -> Bool)?, onDispatched: (() -> Void)?, onCompleted: ((Outcome) -> Void)?) {
            self.startedAt = startedAt
            self.mode = mode
            self.target = target; self.isContextCurrent = isContextCurrent
            self.onDispatched = onDispatched; self.onCompleted = onCompleted
        }
    }

    var onClipboardWrite: (() -> Void)?
    var onResult: ((String) -> Void)?
    var onFailureMessage: ((String) -> Void)?
    var publications: OwnedFilePublicationCoordinator?
    var preferences = PastePreferences()
    let outcomeLog = PasteOutcomeLog()
    private(set) var lastCapturedTarget: Target?
    private var attempt: Attempt?
    private let clipboard: PasteClipboard
    private let environment: PasteEnvironment

    init(pasteboard: NSPasteboard = .general) {
        clipboard = PasteSystemClipboard(pasteboard); environment = PasteSystemEnvironment()
    }
    init(clipboard: PasteClipboard, environment: PasteEnvironment) {
        self.clipboard = clipboard; self.environment = environment
    }

    var hasPermission: Bool { environment.hasPermission }
    var hasPendingAttempt: Bool { attempt != nil }
    var isWaitingForClickRelease: Bool { attempt?.waitingForClickRelease == true }
    func canPaste(to target: Target?) -> Bool {
        guard hasPermission, let target, environment.isRunning(target) else { return false }
        switch preferences.mode(for: target.application.bundleIdentifier) {
        case .compatible: return true
        case .strict: return environment.hasWindow(target)
        case .copyOnly: return false
        }
    }
    func requestPermission() { environment.requestPermission() }
    func returnToTargetIfIdle(_ target: Target?) {
        guard attempt == nil, let target, environment.isRunning(target),
              environment.foreground(for: target) == .clipShelf else { return }
        guard environment.activate(target), environment.hasWindow(target), environment.raiseWindow(target) else { return }
        environment.restoreFocusedElement(target)
    }
    func captureTarget(forApplicationLaunch: Bool = false) -> Target? {
        let target = environment.captureTarget()
        lastCapturedTarget = target
        if forApplicationLaunch, let target, environment.isLauncherSurface(target) {
            ValidationTrace.emit(.destinationChoiceRequired, bundleID: target.application.bundleIdentifier, state: .unavailable)
            return nil
        }
        Self.outcomeLogger.notice("captured bundle=\(target?.application.bundleIdentifier ?? "none", privacy: .public) window=\(target?.window != nil, privacy: .public) input=\(target?.focusedElement != nil, privacy: .public)")
        return target
    }
    func destinationChoices() -> [PasteDestinationChoice] { environment.destinationChoices() }
    func captureDestination(processIdentifier: pid_t) -> Target? {
        let target = environment.captureDestination(processIdentifier: processIdentifier)
        lastCapturedTarget = target
        return target
    }

    @discardableResult
    func copy(_ record: ClipboardRecord, plainText: Bool = false) -> Bool { copy([record], plainText: plainText) }

    @discardableResult
    func copy(_ records: [ClipboardRecord], plainText: Bool = false) -> Bool {
        writeClipboard(records, plainText: plainText) != nil
    }

    private func writeClipboard(_ records: [ClipboardRecord], plainText: Bool) -> Int? {
        let items: [NSPasteboardItem]
        do {
            // Register before exposing URLs. Failure leaves the existing clipboard
            // untouched, and an ambiguous write keeps its durable protection.
            let lease = plainText ? nil : try publications?.retain(records)
            items = try ClipboardCodec.items(for: records, plainText: plainText)
            if let lease, let publication = try publications?.publish(lease: lease, purpose: .clipboard) {
                ClipboardCodec.markPublication(publication.id, in: items)
            }
        } catch { onResult?(error.localizedDescription); return nil }
        let write = clipboard.replaceContents(with: items)
        onClipboardWrite?()
        publications?.reconcileClipboard()
        if !write.succeeded { onResult?(L10n.text("无法写入系统剪贴板，请重试。")) }
        return write.succeeded ? write.changeCount : nil
    }

    func paste(_ record: ClipboardRecord, plainText: Bool, target: Target?,
               clickHandoff: PasteClickHandoff? = nil, dismiss: @escaping () -> Void) {
        paste([record], plainText: plainText, target: target, dismiss: dismiss, clickHandoff: clickHandoff)
    }

    func paste(_ records: [ClipboardRecord], plainText: Bool, target: Target?, dismiss: @escaping () -> Void,
               onCopied: (() -> Void)? = nil, onDispatched: (() -> Void)? = nil,
               allowHeldCommand: Bool = false, isContextCurrent: (() -> Bool)? = nil,
               clickHandoff: PasteClickHandoff? = nil,
               onCompleted: ((Outcome) -> Void)? = nil) {
        guard attempt == nil else {
            let mode = preferences.mode(for: target?.application.bundleIdentifier)
            ValidationTrace.emit(.pasteCompleted, bundleID: target?.application.bundleIdentifier,
                state: .busy, attemptID: UUID().uuidString, elapsedMS: 0, strictness: mode)
            outcomeLog.append(.init(timestamp: Date(), bundleID: target?.application.bundleIdentifier,
                mode: mode, outcome: .busy, failure: nil, method: nil, elapsedMS: 0))
            onCompleted?(.busy); return
        }
        // Claim the attempt before any callback. Dismissal, copy notifications,
        // and Stack callbacks can cancel or reenter synchronously.
        let request = Attempt(startedAt: environment.uptime, mode: preferences.mode(for: target?.application.bundleIdentifier),
                              target: target, isContextCurrent: isContextCurrent,
                              onDispatched: onDispatched, onCompleted: onCompleted)
        attempt = request
        trace(.pastePrepared, target: target, state: .prepared)
        guard contextIsCurrent(request) else { return }
        guard let writtenCount = writeClipboard(records, plainText: plainText) else {
            finish(request, .failed, failure: .writeFailed); return
        }
        // This acknowledgement describes the completed write, even if a write
        // observer canceled the paste. Export callers use it to retain files
        // already published on the clipboard instead of discarding them.
        onCopied?()
        guard contextIsCurrent(request), clipboardIsCurrent(writtenCount, request: request) else { return }
        if request.mode == .copyOnly {
            finish(request, .copiedOnly, message: L10n.text("内容已复制，可在目标应用按 ⌘V。"), failure: .copyOnlyMode)
            return
        }
        guard hasPermission, let target, environment.isRunning(target),
              request.mode != .strict || environment.hasWindow(target) else {
            finish(request, .copiedOnly, message: L10n.text("内容已复制，请切回目标应用按 ⌘V。"), failure: .restoreUnavailable); return
        }
        if let clickHandoff, clickHandoff.mouseUpTimestamp.isFinite, clickHandoff.doubleClickInterval.isFinite,
           environment.uptime < clickHandoff.releaseAfter || environment.hasPressedMouseButtons || !clickHandoff.isReleased() {
            request.waitingForClickRelease = true
            ValidationTrace.emit(.pasteClickHandoffWaiting, state: .prepared, attemptID: request.id)
            request.task = Task { @MainActor [weak self] in
                await self?.waitForClickRelease(request, target: target, writtenCount: writtenCount,
                    handoff: clickHandoff, allowHeldCommand: allowHeldCommand, dismiss: dismiss)
            }
            return
        }
        restoreAndDispatch(request, target: target, writtenCount: writtenCount, allowHeldCommand: allowHeldCommand, dismiss: dismiss)
    }

    private func waitForClickRelease(_ request: Attempt, target: Target, writtenCount: Int,
                                    handoff: PasteClickHandoff, allowHeldCommand: Bool, dismiss: @escaping () -> Void) async {
        let deadline = max(environment.uptime, handoff.releaseAfter) + 0.9
        while contextIsCurrent(request) {
            guard clipboardIsCurrent(writtenCount, request: request), targetIsCurrent(target, request: request) else { return }
            guard environment.uptime < deadline else {
                finish(request, .cancelled, failure: .mouseReleaseDeadline); return
            }
            if environment.uptime >= handoff.releaseAfter && !environment.hasPressedMouseButtons && handoff.isReleased() {
                request.waitingForClickRelease = false
                restoreAndDispatch(request, target: target, writtenCount: writtenCount, allowHeldCommand: allowHeldCommand, dismiss: dismiss)
                return
            }
            do { try await environment.waitForReadiness() }
            catch { finish(request, .cancelled, failure: .waitCancelled); return }
        }
    }

    private func restoreAndDispatch(_ request: Attempt, target: Target, writtenCount: Int,
                                    allowHeldCommand: Bool, dismiss: () -> Void) {
        guard contextIsCurrent(request), clipboardIsCurrent(writtenCount, request: request),
              targetIsCurrent(target, request: request) else { return }
        let deadline = environment.uptime + 0.9
        dismiss()
        guard contextIsCurrent(request) else { return }
        guard clipboardIsCurrent(writtenCount, request: request) else { return }
        guard targetIsCurrent(target, request: request) else { return }
        guard environment.activate(target) else {
            finish(request, .copiedOnly, message: L10n.text("未能恢复目标应用；内容已复制。"), failure: .activationFailed); return
        }
        guard contextIsCurrent(request), targetIsCurrent(target, request: request) else { return }
        if !environment.raiseWindow(target), request.mode == .strict {
            finish(request, .copiedOnly, message: L10n.text("原窗口已不可用；内容已复制，请手动粘贴。"), failure: .windowRaiseFailed); return
        }
        guard contextIsCurrent(request), targetIsCurrent(target, request: request) else { return }
        environment.restoreFocusedElement(target)
        guard contextIsCurrent(request) else { return }
        request.task = Task { @MainActor [weak self] in
            await self?.waitAndDispatch(request, target: target, writtenCount: writtenCount, allowHeldCommand: allowHeldCommand, deadline: deadline)
        }
    }

    private func waitAndDispatch(_ request: Attempt, target: Target, writtenCount: Int, allowHeldCommand: Bool, deadline: TimeInterval) async {
        var lastFocus: PasteFocusState?
        var readySince: TimeInterval?
        var restoredAfterActivation = false
        while contextIsCurrent(request) {
            guard environment.uptime < deadline else { break }
            guard clipboardIsCurrent(writtenCount, request: request), targetIsCurrent(target, request: request) else { return }
            if environment.foreground(for: target) == .target && modifiersAreReady(allowHeldCommand) {
                // Compatible mode samples AX for diagnosis once. Custom editors
                // can replace their AX objects on activation; identity is not an insertion acknowledgement.
                var focus = lastFocus ?? .ready
                if request.mode == .strict || lastFocus == nil { focus = environment.focusState(for: target) }
                // Activation can complete after the initial restoration. Retry
                // the original input once after its process is actually active.
                if request.mode == .strict, !restoredAfterActivation && (focus == .differentElement || focus == .differentSelection) {
                    restoredAfterActivation = true
                    environment.restoreFocusedElement(target)
                    guard contextIsCurrent(request), clipboardIsCurrent(writtenCount, request: request),
                          targetIsCurrent(target, request: request) else { return }
                    focus = environment.focusState(for: target)
                }
                lastFocus = focus
                if focus == .ready || request.mode == .compatible {
                    let since = readySince ?? environment.uptime
                    readySince = since
                    let settleInterval = request.mode == .strict ? environment.focusSettleInterval : environment.compatibleFocusSettleInterval
                    if environment.uptime - since < settleInterval {
                        do { try await environment.waitForReadiness() }
                        catch { finish(request, .cancelled, failure: .waitCancelled); return }
                        continue
                    }
                    guard let dispatch = environment.preparePaste(for: target) else {
                        finish(request, .copiedOnly, message: L10n.text("无法创建粘贴按键；内容已复制。"), failure: .eventCreationFailed); return
                    }
                    // Preparing an event is not permission to send it. Recheck the
                    // request, clipboard, app, modifiers, window and field at the
                    // final boundary, including callbacks that changed context.
                    guard contextIsCurrent(request), clipboardIsCurrent(writtenCount, request: request),
                          targetIsCurrent(target, request: request) else { return }
                    guard environment.uptime < deadline, environment.foreground(for: target) == .target, modifiersAreReady(allowHeldCommand),
                          (request.mode != .strict || environment.focusState(for: target) == .ready) else {
                        finish(request, .cancelled, message: L10n.text("目标已改变；内容已复制，请手动粘贴。"), failure: .finalReadinessChanged); return
                    }
                    guard contextIsCurrent(request), clipboardIsCurrent(writtenCount, request: request),
                          targetIsCurrent(target, request: request) else { return }
                    guard environment.uptime < deadline, environment.foreground(for: target) == .target,
                          modifiersAreReady(allowHeldCommand) else {
                        finish(request, .cancelled, failure: .finalReadinessChanged); return
                    }
                    request.dispatching = true
                    request.method = dispatch.method
                    let accepted = dispatch.send()
                    guard accepted else {
                        request.dispatching = false
                        // Dispatch failure can be ambiguous. Never send a second action after it.
                        finish(request, .copiedOnly, message: L10n.text("内容已复制，请切回目标应用按 ⌘V。"), failure: .eventDispatchFailed)
                        return
                    }
                    ValidationTrace.emit(.pasteDispatch, pid: target.application.processIdentifier,
                        bundleID: target.application.bundleIdentifier, hasTargetWindow: target.window != nil,
                        hasInputElement: target.focusedElement != nil, state: .dispatched, method: dispatch.method, attemptID: request.id)
                    finish(request, .dispatched, message: L10n.text("已发出粘贴操作。"))
                    return
                }
                readySince = nil
            } else {
                readySince = nil
            }
            // AX focus restoration can settle later than application activation.
            // Wait for the original window/field instead of failing the first poll.
            do { try await environment.waitForReadiness() }
            catch { finish(request, .cancelled, failure: .waitCancelled); return }
        }
        guard contextIsCurrent(request) else { return }
        let foreground = String(describing: environment.foreground(for: target))
        let modifiers = environment.heldModifiers.rawValue
        Self.outcomeLogger.notice("readiness_timeout foreground=\(foreground, privacy: .public) focus=\(String(describing: lastFocus), privacy: .public) modifiers=\(modifiers, privacy: .public)")
        let message: String
        switch lastFocus {
        case .differentWindow: message = L10n.text("原窗口焦点未恢复；内容已复制。")
        case .differentElement, .differentSelection: message = L10n.text("原输入位置未恢复；内容已复制，请手动粘贴。")
        default: message = L10n.text("目标或修饰键尚未就绪；内容已复制，请手动粘贴。")
        }
        finish(request, .copiedOnly, message: message, failure: .deadline)
    }

    private func modifiersAreReady(_ allowHeldCommand: Bool) -> Bool {
        let held = environment.heldModifiers
        return (allowHeldCommand ? held.subtracting(.command) : held).isEmpty
    }

    private func contextIsCurrent(_ request: Attempt) -> Bool {
        guard attempt === request else { return false }
        let valid = request.isContextCurrent?() != false
        // The predicate itself may synchronously cancel or start another request.
        guard attempt === request else { return false }
        if !valid { finish(request, .cancelled, failure: .contextChanged) }
        return valid
    }

    private func clipboardIsCurrent(_ count: Int, request: Attempt) -> Bool {
        guard clipboard.changeCount == count else {
            finish(request, .cancelled, message: L10n.text("剪贴板已被新的复制替换，本次自动粘贴已取消。"), failure: .clipboardChanged); return false
        }
        return true
    }

    private func targetIsCurrent(_ target: Target, request: Attempt) -> Bool {
        guard hasPermission, environment.isRunning(target) else { finish(request, .copiedOnly, failure: .permissionOrProcessUnavailable); return false }
        guard environment.foreground(for: target) != .other else {
            finish(request, .cancelled, message: L10n.text("目标已改变；内容已复制，请手动粘贴。"), failure: .changedForeground); return false
        }
        return true
    }

    private func finish(_ request: Attempt, _ outcome: Outcome, message: String? = nil,
                        failure: ValidationTrace.Failure? = nil) {
        guard attempt === request else { return }
        attempt = nil
        request.task?.cancel(); request.task = nil
        let state: ValidationTrace.State
        switch outcome {
        case .dispatched: state = .dispatched
        case .copiedOnly: state = .copiedOnly
        case .cancelled: state = .cancelled
        case .failed: state = .failed
        case .busy: state = .busy
        }
        trace(.pasteCompleted, target: request.target, state: state, failure: failure, request: request)
        outcomeLog.append(.init(timestamp: Date(), bundleID: request.target?.application.bundleIdentifier,
            mode: request.mode, outcome: outcome, failure: failure, method: request.method,
            elapsedMS: max(0, environment.uptime - request.startedAt) * 1000))
        // Keep cancellation reasons available after the panel has dismissed.
        // Never log clipboard data, window titles, paths or input contents.
        Self.outcomeLogger.notice("outcome=\(state.rawValue, privacy: .public) failure=\(failure?.rawValue ?? "none", privacy: .public) target=\(request.target != nil, privacy: .public) bundle=\(request.target?.application.bundleIdentifier ?? "none", privacy: .public) window=\(request.target?.window != nil, privacy: .public) input=\(request.target?.focusedElement != nil, privacy: .public)")
        if let message { onResult?(message) }
        if let message, outcome != .dispatched { onFailureMessage?(message) }
        if outcome == .dispatched { request.onDispatched?() }
        request.onCompleted?(outcome)
    }

    func cancel() {
        guard let request = attempt, !request.dispatching else { return }
        finish(request, .cancelled, failure: .explicitCancellation)
    }

    /// Event delivery can lag behind the card click that started this attempt.
    /// An older queued mouse-down cannot cancel the newer paste. A genuinely
    /// new click still cancels before we restore or insert into an old input.
    @discardableResult
    func cancelForMouseDown(at timestamp: TimeInterval, clickCount: Int = 1) -> Bool {
        guard let request = attempt, !request.dispatching, timestamp.isFinite,
              timestamp > request.startedAt else { return false }
        ValidationTrace.emit(.pastePointerChange, state: .cancelled, failure: .pointerChanged,
                             mouseClickCount: clickCount, mouseDeltaMS: (timestamp - request.startedAt) * 1000)
        finish(request, .cancelled, message: L10n.text("目标已改变；内容已复制，请手动粘贴。"), failure: .pointerChanged)
        return true
    }

    /// Workspace notifications close the A → B → A gap between polling ticks.
    /// Activating ClipShelf or the intended target is part of normal restoration.
    func applicationDidActivate(processIdentifier: pid_t) {
        guard let request = attempt, !request.dispatching, let target = request.target,
              processIdentifier != environment.ownProcessIdentifier,
              processIdentifier != environment.processIdentifier(of: target) else { return }
        ValidationTrace.emit(.pasteCancelledByActivation, pid: processIdentifier, state: .cancelled,
                             failure: .changedForeground)
        finish(request, .cancelled, message: L10n.text("目标已改变；内容已复制，请手动粘贴。"), failure: .changedForeground)
    }

    private func trace(_ event: ValidationTrace.Event, target: Target?, state: ValidationTrace.State,
                       failure: ValidationTrace.Failure? = nil, request: Attempt? = nil) {
        guard ValidationTrace.enabled else { return }
        let request = request ?? attempt
        ValidationTrace.emit(event, pid: target?.application.processIdentifier, bundleID: target?.application.bundleIdentifier,
                             hasTargetWindow: target?.window != nil, hasInputElement: target?.focusedElement != nil,
                             state: state, failure: failure, attemptID: request?.id,
                             elapsedMS: request.map { max(0, environment.uptime - $0.startedAt) * 1000 },
                             strictness: request?.mode)
    }
}
