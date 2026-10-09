import AppKit

@MainActor
final class StackKeyMonitor {
    static let syntheticEventTag: Int64 = 0x434C49505348454C
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedKeyDown = false
    var isMonitoring: Bool { eventTap != nil }
    var shouldHandlePaste: (() -> Bool)?
    var onPaste: (() -> Void)?
    var onUnavailable: (() -> Void)?

    func start() -> Bool {
        stop()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<StackKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil; runLoopSource = nil; swallowedKeyDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.stop(); self?.onUnavailable?() }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag { return Unmanaged.passUnretained(event) }
        let isV = event.getIntegerValueField(.keyboardEventKeycode) == 9
        if type == .keyUp, isV, swallowedKeyDown { swallowedKeyDown = false; return nil }
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard type == .keyDown, isV, modifiers == .maskCommand else { return Unmanaged.passUnretained(event) }
        guard shouldHandlePaste?() == true else { return Unmanaged.passUnretained(event) }
        if swallowedKeyDown || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        swallowedKeyDown = true
        DispatchQueue.main.async { [weak self] in self?.onPaste?() }
        return nil
    }
}
