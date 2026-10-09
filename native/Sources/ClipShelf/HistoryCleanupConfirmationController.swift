import ClipShelfLocalization
import AppKit
import ClipShelfCore

@MainActor
private final class HistoryCleanupPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class HistoryCleanupDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One immutable summary and one response per instance. The coordinator owns
/// the plan and validates it again when the user explicitly confirms.
@MainActor
final class HistoryCleanupConfirmationController: NSWindowController, NSWindowDelegate {
    var presentWindow: ((NSWindow, NSWindow?) -> Void)?
    private let request: HistoryCleanupRequest
    private let summary: HistoryCleanupSummary
    private enum State { case ready, presented, finished }
    private var state = State.ready
    private var completion: ((Bool) -> Void)?
    private var confirmButton: NSButton?
    private let cancelButton = NSButton(title: L10n.text("取消"), target: nil, action: nil)

    init(request: HistoryCleanupRequest, summary: HistoryCleanupSummary) {
        self.request = request
        self.summary = summary
        let panel = HistoryCleanupPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.text("历史清理确认")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 320)
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.respond(false) }
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(relativeTo parent: NSWindow? = nil, completion: @escaping (Bool) -> Void) {
        guard state == .ready, let window else { return }
        state = .presented
        self.completion = completion
        if let presentWindow { presentWindow(window, parent) }
        else {
            if let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame {
                let size = NSSize(width: min(window.frame.width, screen.width), height: min(window.frame.height, screen.height))
                window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                       width: size.width, height: size.height), display: false)
            }
            parent?.addChildWindow(window, ordered: .above)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(cancelButton)
    }

    /// Programmatic cancellation is coordinated by the caller, so no response
    /// can leak from a retired confirmation into its replacement.
    func dismiss() { finish(response: nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        respond(false)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        respond(false)
    }

    @objc private func cancelCleanup() { respond(false) }
    @objc private func confirmCleanup() {
        guard permitsConfirmation else { return }
        respond(true)
    }

    private func respond(_ value: Bool) {
        guard state == .presented else { return }
        finish(response: value)
    }

    private func finish(response: Bool?) {
        guard state != .finished else { return }
        let callback = state == .presented ? completion : nil
        state = .finished
        completion = nil
        confirmButton?.isEnabled = false
        cancelButton.isEnabled = false
        (window as? HistoryCleanupPanel)?.onCancel = nil
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
        if let response { callback?(response) }
    }

    private var permitsConfirmation: Bool {
        switch request {
        case .clearHistory: return summary.affectedCount > 0
        case .retention, .automatic: return true
        }
    }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        defer { InterfaceLayout.apply(to: root) }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel(L10n.text("历史清理影响摘要"))
        let document = HistoryCleanupDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        root.addSubview(scroll)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        func add(_ text: String, label: String, emphasis: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.font = .systemFont(ofSize: emphasis ? 19 : 13, weight: emphasis ? .semibold : .regular)
            field.setAccessibilityLabel(label)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let heading: String, scope: String, confirmTitle: String
        switch request {
        case .clearHistory:
            heading = summary.affectedCount == 0 ? L10n.text("没有可清理的历史") : L10n.text("清空剪贴板历史？")
            scope = L10n.text("范围：当前全部剪贴板历史。分组中已固定的内容仍会保留。")
            confirmTitle = L10n.text("确认清空历史")
        case .retention(let days):
            heading = L10n.text("更改历史保留期限？")
            scope = L10n.text("将历史保留期限设为 \(days) 天，并立即清理超过期限的历史；之后会按此期限自动清理。")
            confirmTitle = L10n.text("确认更改期限")
        case .automatic(let days):
            heading = L10n.text("历史清理规则")
            scope = L10n.text("当前规则：保留最近 \(days) 天的历史。以下是本次超过期限的内容。")
            confirmTitle = L10n.text("确认清理")
        }
        add(heading, label: L10n.text("清理标题"), emphasis: true)
        add(scope, label: L10n.text("清理范围"))
        add(L10n.text("删除 \(summary.deletedCount) 条未固定记录。"), label: L10n.text("删除记录数量"))
        add(L10n.text("\(summary.preservedPinnedCount) 条固定记录仅移出历史，仍保留在分组中。"), label: L10n.text("保留固定记录数量"))
        add(L10n.text("以上受影响记录中，\(summary.privateSyncCount) 条关联私有同步，\(summary.sharedSyncCount) 条关联共享分组。同步关联数已包含在上面的数量中，不是额外删除。"), label: L10n.text("清理同步影响"))
        add(L10n.text("这些关联记录的变化会影响同步内容及共享参与者。离线只会延后同步，暂时停用传输也不代表仅在本机清理。"), label: L10n.text("同步范围说明"))
        add(L10n.text("另有 \(summary.excludedCount) 条因旧账号、只读权限或访问已撤销等原因保留，本次不会修改。"), label: L10n.text("不修改记录数量"))
        if summary.affectedCount == 0 {
            let emptyMessage: String
            if case .retention = request { emptyMessage = L10n.text("当前没有需要清理的内容；仍可确认更改保留期限。") }
            else { emptyMessage = L10n.text("本次不会删除记录或将固定内容移出历史。") }
            add(emptyMessage, label: L10n.text("空清理说明"))
        }
        add(L10n.text("清理不能通过撤销恢复，也不保证立即释放磁盘空间。"), label: L10n.text("不可撤销说明"))

        cancelButton.title = permitsConfirmation ? L10n.text("取消") : L10n.text("关闭")
        cancelButton.target = self
        cancelButton.action = #selector(cancelCleanup)
        // Return is deliberately the non-destructive default; Tab reaches the
        // explicit confirmation button for keyboard-only use.
        cancelButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel(cancelButton.title)
        let spacer = NSView()
        let actions = NSStackView(views: [spacer, cancelButton])
        actions.spacing = 12
        actions.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actions)
        if permitsConfirmation {
            let button = NSButton(title: confirmTitle, target: self, action: #selector(confirmCleanup))
            button.setAccessibilityLabel(confirmTitle)
            confirmButton = button
            actions.addArrangedSubview(button)
            cancelButton.nextKeyView = button
            button.nextKeyView = cancelButton
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            actions.heightAnchor.constraint(equalToConstant: 32),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // Label alignment rectangles are narrower than their AppKit frames.
            // Keep those outer insets inside the scroll viewport as well.
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
    }
}
