import AppKit

@MainActor
protocol PanelPresentationAnimation: AnyObject {
    func start()
    func cancel()
}

/// Entry motion only. Hiding never waits for an animation or its completion.
/// The duration and travel are ClipShelf design choices, not measured Paste values.
@MainActor
final class PanelPresentationMotion {
    typealias MakeAnimation = @MainActor (TimeInterval, @escaping (CGFloat) -> Void, @escaping () -> Void) -> any PanelPresentationAnimation

    private struct Entry {
        let id: UUID
        weak var window: NSWindow?
        let destination: NSPoint
        let start: NSPoint
        let animation: any PanelPresentationAnimation
    }

    private let reduceMotion: @MainActor () -> Bool
    private let makeAnimation: MakeAnimation
    private let notificationCenter: NotificationCenter
    private var accessibilityObserver: NSObjectProtocol?
    private var entry: Entry?
    private var generation = UUID()
    var isAnimating: Bool { entry != nil }

    init(reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         notificationCenter: NotificationCenter? = nil,
         makeAnimation: @escaping MakeAnimation = { AppKitPanelPresentationAnimation(duration: $0, progress: $1, completion: $2) }) {
        self.reduceMotion = reduceMotion
        self.makeAnimation = makeAnimation
        let center = notificationCenter ?? NSWorkspace.shared.notificationCenter
        self.notificationCenter = center
        accessibilityObserver = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.reduceMotion() else { return }
                self.finish()
            }
        }
    }

    func present(window: NSWindow, animated: Bool = true) {
        let wasVisible = window.isVisible
        let (previous, id) = retire()
        guard generation == id else { return }
        if let previous, let previousWindow = previous.window {
            previousWindow.setFrameOrigin(previous.destination)
            guard generation == id else { return }
            previousWindow.alphaValue = 1
            guard generation == id else { return }
        }
        guard animated, !wasVisible, !reduceMotion() else {
            window.alphaValue = 1
            guard generation == id else { return }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let destination = window.frame.origin
        let start = NSPoint(x: destination.x, y: destination.y - 18)
        let animation = makeAnimation(0.14, { [weak self] progress in
            self?.advance(id: id, progress: progress)
        }, { [weak self] in
            self?.complete(id: id)
        })
        guard generation == id else { return }
        entry = Entry(id: id, window: window, destination: destination, start: start, animation: animation)
        window.setFrameOrigin(start)
        guard generation == id else { return }
        window.alphaValue = 0
        guard generation == id else { return }
        window.makeKeyAndOrderFront(nil)
        // A native window callback may have hidden or repositioned it while ordering in.
        guard entry?.id == id, window.isVisible else {
            if generation == id { cancelPreservingFrame() }
            return
        }
        ValidationTrace.emit(.panelEntranceStarted)
        animation.start()
    }

    func hide(window: NSWindow) {
        let (previous, id) = retire()
        guard generation == id else { return }
        window.orderOut(nil)
        guard generation == id, !window.isVisible else { return }
        // Normalize only after sensitive content is no longer visible.
        if let previous, previous.window === window { window.setFrameOrigin(previous.destination) }
        guard generation == id, !window.isVisible else { return }
        window.alphaValue = 1
    }

    func finish() {
        let (previous, id) = retire()
        guard generation == id, let previous, let window = previous.window else { return }
        window.setFrameOrigin(previous.destination)
        guard generation == id else { return }
        window.alphaValue = 1
    }

    /// A user resize/move has already supplied newer geometry. Do not overwrite it.
    func cancelPreservingFrame() {
        let (previous, id) = retire()
        guard generation == id else { return }
        previous?.window?.alphaValue = 1
    }

    private func retire() -> (Entry?, UUID) {
        let id = UUID()
        generation = id
        let previous = entry
        entry = nil
        // Retire before stopping: the driver may synchronously call back.
        previous?.animation.cancel()
        if previous != nil { ValidationTrace.emit(.panelEntranceCancelled) }
        return (previous, id)
    }

    private func advance(id: UUID, progress: CGFloat) {
        guard generation == id, let current = entry, current.id == id, let window = current.window else { return }
        guard window.isVisible else { cancelPreservingFrame(); return }
        guard !reduceMotion() else { finish(); return }
        guard progress.isFinite else { return }
        let value = min(1, max(0, progress))
        window.setFrameOrigin(NSPoint(x: current.destination.x,
                                     y: current.start.y + (current.destination.y - current.start.y) * value))
        guard generation == id, entry?.id == id, window.isVisible else { return }
        window.alphaValue = value
    }

    private func complete(id: UUID) {
        guard generation == id, let current = entry, current.id == id else { return }
        entry = nil
        guard let window = current.window, window.isVisible else { return }
        window.setFrameOrigin(current.destination)
        guard generation == id, window.isVisible else { return }
        window.alphaValue = 1
        guard generation == id else { return }
        ValidationTrace.emit(.panelEntranceCompleted)
    }

    deinit {
        if let accessibilityObserver { notificationCenter.removeObserver(accessibilityObserver) }
    }
}

/// NSAnimation's nonblocking mode runs on the run loop where it starts (main here).
/// Stopping this driver leaves no property writer running.
@MainActor
private final class AppKitPanelPresentationAnimation: PanelPresentationAnimation {
    private let animation: PanelProgressAnimation

    init(duration: TimeInterval, progress: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        animation = PanelProgressAnimation(duration: duration, progress: { value in
            MainActor.assumeIsolated { progress(value) }
        }, completion: {
            MainActor.assumeIsolated { completion() }
        })
    }

    func start() { animation.start() }
    func cancel() { animation.stop() }
}

private final class PanelProgressAnimation: NSAnimation {
    private let progress: (CGFloat) -> Void
    private let completion: () -> Void

    init(duration: TimeInterval, progress: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.progress = progress
        self.completion = completion
        super.init(duration: duration, animationCurve: .easeOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common] }

    override var currentProgress: Float {
        didSet {
            progress(CGFloat(currentValue))
            if currentProgress >= 1 { completion() }
        }
    }
}
