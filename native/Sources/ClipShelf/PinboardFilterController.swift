import ClipShelfLocalization
import AppKit
import ClipShelfCore

@MainActor
final class PinboardFilterController: NSViewController {
    var onApply: ((Set<UUID>) -> Void)?
    var onCancel: (() -> Void)?
    private let boards: [Pinboard]
    private let selected: Set<UUID>
    private var buttons: [(UUID, NSButton)] = []

    init(boards: [Pinboard], selected: Set<UUID>) {
        self.boards = boards; self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 340))
        let title = NSTextField(labelWithString: L10n.text("选择要搜索的分组"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: L10n.text("同时勾选多个分组；可继续组合类型、来源和时间。未勾选时搜索全部内容。"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        for board in boards {
            let button = NSButton(checkboxWithTitle: board.name, target: nil, action: nil)
            button.state = selected.contains(board.id) ? .on : .off
            button.setAccessibilityLabel(L10n.text("筛选分组：\(board.name)"))
            buttons.append((board.id, button)); rows.addArrangedSubview(button)
        }
        if boards.isEmpty { rows.addArrangedSubview(NSTextField(labelWithString: L10n.text("还没有分组，可从“分组操作”中新建。"))) }
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = rows
        let clear = NSButton(title: L10n.text("取消勾选"), target: self, action: #selector(clearSelection))
        let cancel = NSButton(title: L10n.text("取消"), target: self, action: #selector(cancelSelection))
        let apply = NSButton(title: L10n.text("应用筛选"), target: self, action: #selector(applySelection))
        apply.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [clear, NSView(), cancel, apply])
        actions.orientation = .horizontal; actions.spacing = 8
        for child in [title, note, scroll, actions] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor), note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: note.trailingAnchor), scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            actions.leadingAnchor.constraint(equalTo: title.leadingAnchor), actions.trailingAnchor.constraint(equalTo: note.trailingAnchor), actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
    }
    @objc private func clearSelection() { buttons.forEach { $0.1.state = .off } }
    @objc private func cancelSelection() { onCancel?() }
    @objc private func applySelection() { onApply?(Set(buttons.filter { $0.1.state == .on }.map(\.0))) }
}
