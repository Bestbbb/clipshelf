import AppKit

@MainActor
final class StackKeyMonitor {
    static let syntheticEventTag: Int64 = 0x434C49505348454C
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedKeyDown = false
    private var stoppingAfterPress = false
    private var generation: UInt64 = 0
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    var isMonitoring: Bool { eventTap != nil }
    var shouldHandlePaste: (() -> Bool)?
    /// Called synchronously for a new physical gesture. Capture only cheap target
    /// identity here; defer accessibility reads and output to the returned action.
    /// Returning nil leaves the complete physical press available to its recipient.
    var preparePaste: (() -> (() -> Void)?)?
    var onUnavailable: (() -> Void)?

    init(schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
        DispatchQueue.main.async { action() }
    }) { self.schedule = schedule }

    func start() -> Bool {
        stop()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<StackKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                // This tap's only run-loop source is installed on the main loop below.
                return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        generation &+= 1
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil; runLoopSource = nil; swallowedKeyDown = false; stoppingAfterPress = false
    }

    /// After the last occurrence is consumed, keep swallowing the physical press
    /// we already own until key-up. Otherwise auto-repeat pastes the last item again.
    func stopAfterCurrentPress() {
        guard swallowedKeyDown else { stop(); return }
        generation &+= 1
        stoppingAfterPress = true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            handleTapDisabled()
            return Unmanaged.passUnretained(event)
        }
        let consumed = handleKeyEvent(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag)
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    func handleTapDisabled() {
        let capturedGeneration = generation
        schedule { [weak self] in
            guard let self, self.generation == capturedGeneration else { return }
            self.stop(); self.onUnavailable?()
        }
    }

    /// Pure event fields let tests exercise routing without creating a tap or
    /// reading physical input. Synthetic output never changes the owned press.
    func handleKeyEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags,
                        isRepeat: Bool = false, isSynthetic: Bool = false) -> Bool {
        guard !isSynthetic, keyCode == 9 else { return false }
        if type == .keyUp, swallowedKeyDown {
            swallowedKeyDown = false
            if stoppingAfterPress {
                if shouldHandlePaste?() == true { stoppingAfterPress = false }
                else { stop() }
            }
            return true
        }
        guard type == .keyDown else { return false }
        if swallowedKeyDown { return true }
        // Do not adopt an already-held key when Stack becomes available midway.
        guard !isRepeat else { return false }
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard modifiers == .maskCommand, shouldHandlePaste?() == true else { return false }
        let capturedGeneration = generation
        guard let action = preparePaste?(), generation == capturedGeneration else { return false }
        swallowedKeyDown = true
        schedule { [weak self] in
            guard let self, self.generation == capturedGeneration,
                  self.shouldHandlePaste?() == true else { return }
            action()
        }
        return true
    }
}
