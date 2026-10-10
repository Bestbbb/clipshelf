import AppKit

/// A failed paste must remain visible after the shelf closes, without taking
/// focus from the destination or asking the user to dismiss another window.
@MainActor
final class PasteFeedbackController {
    private let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
    private let label = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init() {
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.ignoresMouseEvents = true
        window.hasShadow = true
        window.setAccessibilityIdentifier("paste.feedback")
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        window.contentView = background
    }

    func show(_ message: String, on screen: NSScreen?) {
        hide()
        guard let frame = screen?.visibleFrame else { return }
        label.stringValue = message
        let width = min(480, frame.width - 40)
        window.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 80,
                               width: width, height: 84), display: false)
        window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() { timer?.invalidate(); timer = nil; window.orderOut(nil) }
}
