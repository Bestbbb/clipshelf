import ClipShelfLocalization
import AppKit
import ClipShelfCore

private final class StackFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StackPanelController: NSWindowController {
    var onEnd: (() -> Void)?
    var onReverse: (() -> Void)?
    var onRestore: (() -> Void)?
    var onClear: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var isPresentationAllowed: (() -> Bool)?
    private let rows = NSStackView()
    private let direction = NSButton(title: L10n.text("顺序 ↓"), target: nil, action: nil)
    private let restore = NSButton(title: L10n.text("恢复上一项"), target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: L10n.text("复制内容加入队列，在目标 App 按 ⌘V 逐项粘贴。"))

    init() {
        let panel = StackFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 310),
                                       styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L10n.text("ClipShelf · 顺序粘贴")
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        direction.target = self; direction.action = #selector(reverse)
        restore.target = self; restore.action = #selector(restorePrevious)
        let end = NSButton(title: L10n.text("结束"), target: self, action: #selector(endSession))
        let clear = NSButton(title: L10n.text("清空队列"), target: self, action: #selector(clearQueue))
        let top = NSStackView(views: [direction, restore, end])
        for button in [direction, restore, end] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        let content = NSStackView(views: [summary, top, scroll, clear])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 330), content.heightAnchor.constraint(equalToConstant: 310),
            top.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(equalToConstant: 160),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func suspend() { window?.orderOut(nil) }

    func update(_ stack: StackCoordinator) {
        guard stack.isActive else { window?.orderOut(nil); return }
        guard isPresentationAllowed?() != false else { suspend(); return }
        direction.title = stack.direction == .forward ? L10n.text("顺序 ↓") : L10n.text("反序 ↑")
        restore.isEnabled = stack.canRestoreLastConsumed
        summary.stringValue = stack.queue.isEmpty ? L10n.text("队列为空。继续复制可加入内容；普通 ⌘V 已恢复。") : L10n.text("\(stack.queue.count) 项待用 · 在目标 App 按 ⌘V 逐项粘贴")
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, record) in stack.queue.enumerated() {
            let label = NSTextField(labelWithString: "\(index + 1). \(record.title)")
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
            let remove = NSButton(title: "×", target: self, action: #selector(removeRow(_:)))
            remove.tag = index; remove.setAccessibilityLabel(L10n.text("从队列移除第 \(index + 1) 项"))
            let row = NSStackView(views: [label, remove]); row.spacing = 5
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        if window?.isVisible != true, let visible = NSScreen.main?.visibleFrame {
            window?.setFrameOrigin(NSPoint(x: visible.maxX - 350, y: visible.maxY - 350))
            window?.orderFrontRegardless()
        }
    }
    @objc private func endSession() { onEnd?() }
    @objc private func reverse() { onReverse?() }
    @objc private func restorePrevious() { onRestore?() }
    @objc private func clearQueue() { onClear?() }
    @objc private func removeRow(_ sender: NSButton) { onRemove?(sender.tag) }
}
