import AppKit
import ApplicationServices

struct PasteModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let option = Self(rawValue: 1 << 3)
}

enum PasteForeground { case target, clipShelf, other }
enum PasteFocusState { case ready, differentWindow, differentElement, differentSelection }

struct PasteDispatch {
    enum Method: String, Codable, Sendable { case menu, keyboard }
    let method: Method
    /// Acceptance by the system is not confirmation of insertion by the input.
    let send: () -> Bool
}

/// All process-global input and accessibility operations live behind this seam.
/// Tests supply an entirely in-memory implementation, including the clock.
@MainActor
protocol PasteEnvironment: AnyObject {
    var hasPermission: Bool { get }
    var uptime: TimeInterval { get }
    var ownProcessIdentifier: pid_t { get }
    func requestPermission()
    func captureTarget() -> PasteCoordinator.Target?
    func destinationChoices() -> [PasteCoordinator.Target]
    func isLauncherSurface(_ target: PasteCoordinator.Target) -> Bool
    func processIdentifier(of target: PasteCoordinator.Target) -> pid_t
    func isRunning(_ target: PasteCoordinator.Target) -> Bool
    func hasWindow(_ target: PasteCoordinator.Target) -> Bool
    func foreground(for target: PasteCoordinator.Target) -> PasteForeground
    func activate(_ target: PasteCoordinator.Target) -> Bool
    func raiseWindow(_ target: PasteCoordinator.Target) -> Bool
    func restoreFocusedElement(_ target: PasteCoordinator.Target)
    func focusState(for target: PasteCoordinator.Target) -> PasteFocusState
    var heldModifiers: PasteModifiers { get }
    var focusSettleInterval: TimeInterval { get }
    func preparePaste(for target: PasteCoordinator.Target) -> PasteDispatch?
    func prepareCommandV() -> (() -> Void)?
    func waitForReadiness() async throws
}

extension PasteEnvironment {
    func destinationChoices() -> [PasteCoordinator.Target] { [] }
    func isLauncherSurface(_ target: PasteCoordinator.Target) -> Bool { false }
    var focusSettleInterval: TimeInterval { 0.08 }
    func preparePaste(for target: PasteCoordinator.Target) -> PasteDispatch? {
        guard let send = prepareCommandV() else { return nil }
        return PasteDispatch(method: .keyboard, send: { send(); return true })
    }
}

struct PasteClipboardWrite {
    let succeeded: Bool
    let changeCount: Int
}

@MainActor
protocol PasteClipboard: AnyObject {
    var changeCount: Int { get }
    func replaceContents(with items: [NSPasteboardItem]) -> PasteClipboardWrite
}

@MainActor
final class PasteSystemClipboard: PasteClipboard {
    private let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    func replaceContents(with items: [NSPasteboardItem]) -> PasteClipboardWrite {
        pasteboard.clearContents()
        let succeeded = pasteboard.writeObjects(items)
        // Capture ownership before any app callback can replace the clipboard.
        return PasteClipboardWrite(succeeded: succeeded, changeCount: pasteboard.changeCount)
    }
}

@MainActor
final class PasteSystemEnvironment: PasteEnvironment {
    private var targetHistory = PasteTargetHistory<PasteCoordinator.Target>(ownPID: ProcessInfo.processInfo.processIdentifier)
    private var observers: [NSObjectProtocol] = []
    private let workspaceCenter = NSWorkspace.shared.notificationCenter

    init() {
        if let app = NSWorkspace.shared.frontmostApplication { targetHistory.activated(app.processIdentifier) }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    if name == NSWorkspace.didActivateApplicationNotification { self.targetHistory.activated(app.processIdentifier) }
                    else { self.targetHistory.deactivated(app.processIdentifier, capture: Self.snapshot) }
                }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.targetHistory.clear() }
            })
        }
    }

    deinit { for observer in observers { workspaceCenter.removeObserver(observer) } }
    var hasPermission: Bool { AXIsProcessTrusted() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var ownProcessIdentifier: pid_t { ProcessInfo.processInfo.processIdentifier }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func captureTarget() -> PasteCoordinator.Target? {
        guard let target = targetHistory.resolve(foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                 capture: Self.snapshot), !target.application.isTerminated else {
            ValidationTrace.emit(.targetCaptured, state: .unavailable)
            return nil
        }
        let application = target.application
        ValidationTrace.emit(.targetCaptured, pid: application.processIdentifier, bundleID: application.bundleIdentifier,
                             hasTargetWindow: target.window != nil, hasInputElement: target.focusedElement != nil, state: .captured)
        return target
    }

    func destinationChoices() -> [PasteCoordinator.Target] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownProcessIdentifier && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            .compactMap { Self.snapshot($0.processIdentifier) }
            .filter { $0.window != nil }
    }

    func isLauncherSurface(_ target: PasteCoordinator.Target) -> Bool {
        let role = target.focusedElement.flatMap { Self.stringAttribute($0, kAXRoleAttribute) }
        return PasteLaunchPolicy.requiresDestinationChoice(bundleID: target.application.bundleIdentifier, focusedRole: role)
    }

    private static func snapshot(_ pid: pid_t) -> PasteCoordinator.Target? {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        let input = Self.focusedElement(app: app, pid: pid)
        return PasteCoordinator.Target(application: application, window: Self.attribute(app, kAXFocusedWindowAttribute),
                                       focusedElement: input, selectedRange: input.flatMap(Self.selectedRange))
    }
    func processIdentifier(of target: PasteCoordinator.Target) -> pid_t { target.application.processIdentifier }
    func isRunning(_ target: PasteCoordinator.Target) -> Bool { !target.application.isTerminated }
    func hasWindow(_ target: PasteCoordinator.Target) -> Bool { target.window != nil }
    func foreground(for target: PasteCoordinator.Target) -> PasteForeground {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid == target.application.processIdentifier { return .target }
        return pid == ownProcessIdentifier ? .clipShelf : .other
    }
    func activate(_ target: PasteCoordinator.Target) -> Bool { target.application.activate(options: []) }
    func raiseWindow(_ target: PasteCoordinator.Target) -> Bool {
        guard let window = target.window else { return false }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }
    func restoreFocusedElement(_ target: PasteCoordinator.Target) {
        if let element = target.focusedElement {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if var range = target.selectedRange, let value = AXValueCreate(.cfRange, &range) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
    }
    func focusState(for target: PasteCoordinator.Target) -> PasteFocusState {
        var traceState = ValidationTrace.State.ready
        defer {
            ValidationTrace.emit(.focusChecked, pid: target.application.processIdentifier,
                                 bundleID: target.application.bundleIdentifier, hasTargetWindow: target.window != nil,
                                 hasInputElement: target.focusedElement != nil, state: traceState)
        }
        let app = AXUIElementCreateApplication(target.application.processIdentifier)
        guard let original = target.window, let current = Self.attribute(app, kAXFocusedWindowAttribute),
              CFEqual(original, current) else { traceState = .differentWindow; return .differentWindow }
        if let original = target.focusedElement {
            guard let current = Self.focusedElement(app: app, pid: target.application.processIdentifier), CFEqual(original, current) else {
                traceState = .differentElement
                return .differentElement
            }
            if let expected = target.selectedRange {
                guard let actual = Self.selectedRange(current), actual.location == expected.location, actual.length == expected.length else {
                    traceState = .differentSelection
                    return .differentSelection
                }
            }
        }
        return .ready
    }
    var heldModifiers: PasteModifiers {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var result: PasteModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        return result
    }
    func prepareCommandV() -> (() -> Void)? {
        guard let events = Self.commandVEvents(restoring: CGEventSource.flagsState(.combinedSessionState)) else { return nil }
        return { events.down.post(tap: .cghidEventTap); events.up.post(tap: .cghidEventTap) }
    }

    func preparePaste(for target: PasteCoordinator.Target) -> PasteDispatch? {
        // A nonactivating shelf can own keyboard focus while the destination is
        // still the frontmost application. Deliver to that captured process,
        // rather than relying on the global event route or an AX menu action
        // whose success does not establish that the input handled Paste.
        Self.commandVDispatch(to: target.application.processIdentifier,
                              restoring: CGEventSource.flagsState(.combinedSessionState))
    }

    static func commandVDispatch(to pid: pid_t, restoring flags: CGEventFlags,
                                post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) -> PasteDispatch? {
        guard pid > 0, let events = commandVEvents(restoring: flags) else { return nil }
        return PasteDispatch(method: .keyboard, send: {
            post(events.down, pid); post(events.up, pid)
            return true
        })
    }

    /// Build without posting so release-state regressions can be checked without
    /// touching the desktop. Synthetic input must not mutate the hardware table.
    static func commandVEvents(restoring flags: CGEventFlags) -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
        down.flags = flags.union(.maskCommand)
        // An unconditional Command flag on key-up leaves the combined session
        // reporting Command held even though we never pressed that modifier.
        // Preserve a real held Command for Stack; otherwise release our flag.
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: StackKeyMonitor.syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: StackKeyMonitor.syntheticEventTag)
        return (down, up)
    }
    func waitForReadiness() async throws { try await Task.sleep(nanoseconds: 15_000_000) }
    private static func focusedElement(app: AXUIElement, pid: pid_t) -> AXUIElement? {
        // Some apps expose the current input only through system-wide focus.
        // Never borrow an element from another process as a destination.
        guard let element = attribute(app, kAXFocusedUIElementAttribute) ??
            attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return nil }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { return nil }
        return element
    }
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success else { return nil }
        return decodeSelectedRange(value)
    }
    static func decodeSelectedRange(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return range
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
