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
enum PasteFocusState { case ready, differentWindow, differentElement }

/// All process-global input and accessibility operations live behind this seam.
/// Tests supply an entirely in-memory implementation, including the clock.
@MainActor
protocol PasteEnvironment: AnyObject {
    var hasPermission: Bool { get }
    var uptime: TimeInterval { get }
    var ownProcessIdentifier: pid_t { get }
    func requestPermission()
    func captureTarget() -> PasteCoordinator.Target?
    func processIdentifier(of target: PasteCoordinator.Target) -> pid_t
    func isRunning(_ target: PasteCoordinator.Target) -> Bool
    func hasWindow(_ target: PasteCoordinator.Target) -> Bool
    func foreground(for target: PasteCoordinator.Target) -> PasteForeground
    func activate(_ target: PasteCoordinator.Target) -> Bool
    func raiseWindow(_ target: PasteCoordinator.Target) -> Bool
    func restoreFocusedElement(_ target: PasteCoordinator.Target)
    func focusState(for target: PasteCoordinator.Target) -> PasteFocusState
    var heldModifiers: PasteModifiers { get }
    func prepareCommandV() -> (() -> Void)?
    func waitForReadiness() async throws
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
    var hasPermission: Bool { AXIsProcessTrusted() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var ownProcessIdentifier: pid_t { ProcessInfo.processInfo.processIdentifier }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func captureTarget() -> PasteCoordinator.Target? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ownProcessIdentifier else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        return .init(application: application, window: Self.attribute(app, kAXFocusedWindowAttribute),
                     focusedElement: Self.attribute(app, kAXFocusedUIElementAttribute))
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
        }
    }
    func focusState(for target: PasteCoordinator.Target) -> PasteFocusState {
        let app = AXUIElementCreateApplication(target.application.processIdentifier)
        guard let original = target.window, let current = Self.attribute(app, kAXFocusedWindowAttribute),
              CFEqual(original, current) else { return .differentWindow }
        if let original = target.focusedElement {
            guard let current = Self.attribute(app, kAXFocusedUIElementAttribute), CFEqual(original, current) else {
                return .differentElement
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
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: StackKeyMonitor.syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: StackKeyMonitor.syntheticEventTag)
        return { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
    }
    func waitForReadiness() async throws { try await Task.sleep(nanoseconds: 15_000_000) }
    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
