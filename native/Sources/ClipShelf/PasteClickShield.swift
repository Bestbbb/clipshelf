import AppKit

/// Keeps the second press of a card double-click out of the input beneath the
/// dismissed shelf. The window covers only the original click tolerance area,
/// cannot take keyboard focus, and expires with the system double-click interval.
@MainActor
final class PasteClickShield {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class Surface: NSView {
        var onDown: ((NSEvent) -> Void)?
        var onUp: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onDown?(event) }
        override func mouseUp(with event: NSEvent) { onUp?() }
    }
    static func protectedFrame(at point: NSPoint) -> NSRect? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return NSRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
    }
    static func remainingDuration(eventTime: TimeInterval, now: TimeInterval, interval: TimeInterval) -> TimeInterval? {
        guard eventTime.isFinite, now.isFinite, interval.isFinite, interval > 0,
              now >= eventTime else { return nil }
        let remaining = eventTime + interval - now
        return remaining > 0 ? remaining : nil
    }
    private let window = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
    private var timer: Timer?
    private var pressed = false
    private var expired = false

    init() {
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        // Completely transparent pixels are not a reliable WindowServer hit
        // surface. Retain a barely visible backing pixel in the small click area.
        window.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.setAccessibilityElement(false)
        let surface = Surface()
        surface.onDown = { [weak self] event in
            self?.pressed = true
            ValidationTrace.emit(.pasteClickShieldCaptured, mouseClickCount: event.clickCount)
        }
        surface.onUp = { [weak self] in
            guard let self else { return }
            self.pressed = false
            if self.expired { self.cancel() }
        }
        window.contentView = surface
    }

    func protect(_ event: NSEvent) {
        cancel()
        guard event.type == .leftMouseUp, let source = event.window,
              let frame = Self.protectedFrame(at: source.convertPoint(toScreen: event.locationInWindow)),
              let duration = Self.remainingDuration(eventTime: event.timestamp, now: ProcessInfo.processInfo.systemUptime,
                                                    interval: NSEvent.doubleClickInterval) else { return }
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        ValidationTrace.emit(.pasteClickShieldArmed)
        timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expired = true
                // Preserve ownership of a down/up pair across the expiry boundary.
                if !self.pressed { self.cancel() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        pressed = false; expired = false
        window.orderOut(nil)
    }
}
