import ClipShelfLocalization
import AppKit
import ClipShelfCore

private final class SuggestionFloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}

/// An ephemeral, nonactivating view. It never captures context or owns a model session.
@MainActor
final class SuggestionPanelController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onPaste: ((UUID, PasteCoordinator.Target) -> Void)?
    var onClose: (() -> Void)?
    var onRequestScreenPermission: (() -> Void)?
    private var target: PasteCoordinator.Target?
    private var selections: [ContextSuggestionService.Selection] = []
    private var records: [UUID: ClipboardRecordMetadata] = [:]
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let model = NSTextField(labelWithString: L10n.text("Apple Intelligence · 本机模型"))
    private let progress = NSProgressIndicator()
    private let permission = NSButton(title: L10n.text("允许读取目标窗口…"), target: nil, action: nil)
    private let paste = NSButton(title: L10n.text("粘贴所选内容"), target: nil, action: nil)
    private var displayed = false

    init() {
        let panel = SuggestionFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L10n.text("ClipShelf · 智能建议")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.onReturn = { [weak self] in self?.pasteSelected() }
        model.font = .systemFont(ofSize: 12, weight: .semibold)
        model.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        status.maximumNumberOfLines = 3
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let header = NSStackView(views: [progress, model])
        header.spacing = 8
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.width = 430
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(pasteSelected)
        table.setAccessibilityLabel(L10n.text("本机模型建议的剪贴板内容"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        permission.target = self
        permission.action = #selector(requestPermission)
        paste.target = self
        paste.action = #selector(pasteSelected)
        let close = NSButton(title: L10n.text("关闭"), target: self, action: #selector(closePanel))
        let buttons = NSStackView(views: [permission, paste, close])
        buttons.spacing = 8
        let privacy = NSTextField(wrappingLabelWithString: L10n.text("仅本次读取原窗口 · 截图和识别文字不保存 · 关闭即取消"))
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        let content = NSStackView(views: [header, status, scroll, privacy, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content
        defer { InterfaceLayout.apply(to: content) }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 480),
            content.heightAnchor.constraint(equalToConstant: 470),
            status.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(equalToConstant: 270),
            privacy.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The caller captures the target before showing this panel. No app activation.
    func showLoading(target: PasteCoordinator.Target) {
        self.target = target
        displayed = true
        clearResults()
        status.stringValue = L10n.text("正在读取原窗口并由本机模型选择相关内容…")
        model.stringValue = L10n.text("Apple Intelligence · 本机模型")
        permission.isHidden = true
        progress.startAnimation(nil)
        if let screen = window?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            window?.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.midY - 235))
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func show(result: ContextSuggestionService.Result, records: [ClipboardRecordMetadata]) {
        guard displayed, target != nil else { return }
        progress.stopAnimation(nil)
        permission.isHidden = true
        self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selections = result.suggestions.filter { self.records[$0.id] != nil }
        model.stringValue = result.modelLabel
        status.stringValue = selections.isEmpty ? L10n.text("没有找到明显相关的内容。可关闭后使用普通搜索。") : L10n.text("根据原窗口，从 \(result.candidateCount) 个候选中选出 \(selections.count) 项。")
        table.reloadData()
        if !selections.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        paste.isEnabled = !selections.isEmpty
    }

    func showError(message: String, canRequestScreenPermission: Bool = false) {
        guard displayed else { return }
        clearResults()
        progress.stopAnimation(nil)
        status.stringValue = message
        permission.isHidden = !canRequestScreenPermission
    }

    func dismiss() {
        let notify = displayed
        displayed = false
        target = nil
        clearResults()
        status.stringValue = ""
        model.stringValue = ""
        progress.stopAnimation(nil)
        window?.orderOut(nil)
        if notify { onClose?() }
    }

    func windowWillClose(_ notification: Notification) { dismiss() }
    func numberOfRows(in tableView: NSTableView) -> Int { selections.count }
    func tableViewSelectionDidChange(_ notification: Notification) { paste.isEnabled = selections.indices.contains(table.selectedRow) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard selections.indices.contains(row), let record = records[selections[row].id] else { return nil }
        let title = NSTextField(labelWithString: record.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        let reason = NSTextField(labelWithString: selections[row].reason)
        reason.font = .systemFont(ofSize: 11)
        reason.textColor = .secondaryLabelColor
        reason.lineBreakMode = .byTruncatingTail
        reason.maximumNumberOfLines = 1
        let stack = NSStackView(views: [title, reason])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        InterfaceLayout.apply(to: stack)
        return stack
    }
    private func clearResults() {
        selections.removeAll()
        records.removeAll()
        table.reloadData()
        paste.isEnabled = false
    }
    @objc private func closePanel() { dismiss() }
    @objc private func requestPermission() { onRequestScreenPermission?() }
    @objc private func pasteSelected() {
        guard let target, selections.indices.contains(table.selectedRow) else { return }
        onPaste?(selections[table.selectedRow].id, target)
    }
}
