import ApplicationServices
import Foundation

/// A timeout applies to one AX object, not all equal objects. Bound every read
/// and share one budget across a snapshot so a hung app cannot multiply delays.
@MainActor
final class PasteAXSession {
    static let timeout: TimeInterval = 0.25
    private let pid: pid_t
    private let clock: () -> TimeInterval
    private let deadline: TimeInterval
    private var unresponsive = false
    private let copy: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError

    init(pid: pid_t, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         copy: @escaping (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue) {
        self.pid = pid; self.clock = clock; self.copy = copy
        deadline = clock() + Self.timeout
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, Float(timeout))
        return element
    }
    static func systemWide() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(element, Float(timeout))
        return element
    }

    func perform(on element: AXUIElement, _ operation: () -> AXError) -> AXError {
        let remaining = deadline - clock()
        guard !unresponsive, remaining > 0 else { return .cannotComplete }
        _ = AXUIElementSetMessagingTimeout(element, Float(min(Self.timeout, remaining)))
        let result = operation()
        if result == .cannotComplete {
            unresponsive = true
            ValidationTrace.emit(.axTimeout, pid: pid, state: .unavailable)
        }
        return result
    }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard perform(on: element, { copy(element, name as CFString, &value) }) == .success else { return nil }
        return value
    }
    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
