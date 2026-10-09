import AppKit
import ClipShelfCore

private final class HistoryFilterDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class HistoryFilterActionButton: NSButton {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        return super.performKeyEquivalent(with: event)
    }
}

/// Applies the complete draft once; callers own popover dismissal and query/session guards.
@MainActor
final class HistoryFilterController: NSViewController {
    var onApply: ((HistoryQuery) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var draft: HistoryFilterDraft
    private var options: HistoryFilterOptions
    private var finished = false
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startEnabled = NSButton(checkboxWithTitle: "开始（含）", target: nil, action: nil)
    private let endEnabled = NSButton(checkboxWithTitle: "结束（含）", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let boardRows = NSStackView()
    private var boardButtons: [(UUID, NSButton)] = []
    private let message = NSTextField(wrappingLabelWithString: "")
    private let applyButton = HistoryFilterActionButton(title: "应用筛选", target: nil, action: nil)

    init(query: HistoryQuery, options: HistoryFilterOptions) {
        draft = HistoryFilterDraft(query: query)
        self.options = options
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 420, height: 580)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateOptions(_ options: HistoryFilterOptions) {
        guard options != self.options else { return }
        self.options = options
        guard isViewLoaded else { return }
        let window = view.window
        let focusedBoardIndex = boardButtons.firstIndex { $0.1 === window?.firstResponder }
        let focusedBoardID = focusedBoardIndex.map { boardButtons[$0].0 }
        refreshChoices()
        validateDraft()
        // Option refreshes replace board rows, but must not retire the user's
        // keyboard position. Unavailable selected boards still have a row.
        if let focusedBoardID, let window, view.window === window {
            let replacement = boardButtons.first { $0.0 == focusedBoardID }?.1
                ?? focusedBoardIndex.flatMap { index in boardButtons.isEmpty ? nil : boardButtons[min(index, boardButtons.count - 1)].1 }
            window.makeFirstResponder(replacement ?? typePopup)
        }
    }

    func focusInitialControl() { view.window?.makeFirstResponder(typePopup) }
    override func viewDidAppear() { super.viewDidAppear(); focusInitialControl() }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let title = NSTextField(labelWithString: "全部筛选")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let queryNote = NSTextField(wrappingLabelWithString: draft.query.text.isEmpty ? "组合条件搜索全部历史和固定内容。" : "保留搜索词：\(draft.query.text)")
        queryNote.maximumNumberOfLines = 2
        queryNote.font = .systemFont(ofSize: 11); queryNote.textColor = .secondaryLabelColor
        queryNote.setAccessibilityLabel("保留的搜索关键词")
        let clear = NSButton(title: "清除筛选", target: self, action: #selector(clearDraft))
        clear.toolTip = "只清除筛选条件，保留搜索关键词与排序；按“应用筛选”后生效。"
        let cancel = HistoryFilterActionButton(title: "取消", target: self, action: #selector(cancelDraft))
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        applyButton.target = self; applyButton.action = #selector(applyDraft)
        applyButton.keyEquivalent = "\r"; applyButton.keyEquivalentModifierMask = []
        let actions = NSStackView(views: [clear, NSView(), cancel, applyButton])
        actions.orientation = .horizontal; actions.spacing = 8
        message.font = .systemFont(ofSize: 11); message.maximumNumberOfLines = 4
        message.setAccessibilityLabel("筛选状态")
        message.setContentCompressionResistancePriority(.required, for: .vertical)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.setAccessibilityLabel("全部筛选条件")
        let document = HistoryFilterDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        for child in [title, queryNote, scroll, message, actions] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            queryNote.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            queryNote.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            queryNote.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: queryNote.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: queryNote.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            message.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: queryNote.trailingAnchor),
            message.heightAnchor.constraint(equalToConstant: 58),
            message.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: queryNote.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        for (popup, label) in [(typePopup, "内容类型"), (sourcePopup, "来源 App"), (devicePopup, "来源设备"), (datePopup, "复制时间"), (orderPopup, "排列顺序")] {
            popup.setAccessibilityLabel("全部筛选：\(label)")
            popup.target = self
            popup.action = #selector(choicesChanged(_:))
            popup.menu?.autoenablesItems = false
        }
        datePopup.addItems(withTitles: ["任意时间", "今天", "最近 7 天", "最近 30 天", "自定义范围"])
        orderPopup.addItems(withTitles: ["最近复制", "分组内手动顺序"])
        for (label, popup) in [("类型", typePopup), ("来源 App", sourcePopup), ("设备", devicePopup), ("时间", datePopup)] {
            let row = fieldRow(label, control: popup)
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (check, picker) in [(startEnabled, startPicker), (endEnabled, endPicker)] {
            check.target = self; check.action = #selector(datesChanged)
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.target = self; picker.action = #selector(datesChanged)
            picker.setAccessibilityLabel(check === startEnabled ? "复制时间开始（含）" : "复制时间结束（含）")
            check.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let row = NSStackView(views: [check, picker])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            stack.addArrangedSubview(row)
        }
        let boardTitle = NSTextField(labelWithString: "分组（可多选；未勾选为全部内容）")
        boardTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(boardTitle)
        boardRows.orientation = .vertical; boardRows.alignment = .leading; boardRows.spacing = 7
        boardRows.translatesAutoresizingMaskIntoConstraints = false
        let boardsScroll = NSScrollView()
        boardsScroll.hasVerticalScroller = true; boardsScroll.autohidesScrollers = true; boardsScroll.drawsBackground = false
        boardsScroll.setAccessibilityLabel("全部筛选：分组列表")
        let boardsDocument = HistoryFilterDocumentView()
        boardsDocument.translatesAutoresizingMaskIntoConstraints = false
        boardsScroll.documentView = boardsDocument
        boardsDocument.addSubview(boardRows)
        stack.addArrangedSubview(boardsScroll)
        NSLayoutConstraint.activate([
            boardsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            boardsScroll.heightAnchor.constraint(equalToConstant: 140),
            boardsDocument.widthAnchor.constraint(equalTo: boardsScroll.contentView.widthAnchor),
            boardRows.leadingAnchor.constraint(equalTo: boardsDocument.leadingAnchor),
            boardRows.trailingAnchor.constraint(equalTo: boardsDocument.trailingAnchor),
            boardRows.topAnchor.constraint(equalTo: boardsDocument.topAnchor),
            boardRows.bottomAnchor.constraint(equalTo: boardsDocument.bottomAnchor)
        ])
        let orderRow = fieldRow("排序", control: orderPopup)
        stack.addArrangedSubview(orderRow); orderRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let help = NSTextField(wrappingLabelWithString: "各类条件共同生效，多分组之间任一匹配即可。设备指最初采集内容的 ClipShelf 安装，不推断 iPhone 等物理来源。Tab 切换控件，Return 应用，Esc 取消。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help); help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshChoices(); refreshDates(); validateDraft()
    }

    private func fieldRow(_ label: String, control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func add(_ title: String, key: String, to popup: NSPopUpButton, enabled: Bool = true) {
        popup.addItem(withTitle: title); popup.lastItem?.representedObject = key; popup.lastItem?.isEnabled = enabled
    }
    private func select(_ key: String, in popup: NSPopUpButton) { popup.select(popup.itemArray.first { $0.representedObject as? String == key }) }
    private func refreshChoices() {
        typePopup.removeAllItems(); add("所有类型", key: "all", to: typePopup)
        for (kind, title) in [(ClipboardContentKind.text, "文本"), (.link, "链接"), (.image, "图片"), (.file, "文件"), (.color, "颜色")] { add(title, key: kind.rawValue, to: typePopup) }
        select(draft.query.kind?.rawValue ?? "all", in: typePopup)
        sourcePopup.removeAllItems(); add("所有来源 App", key: "all", to: sourcePopup)
        var sources = options.sources
        if let selected = draft.query.sourceBundleID, sources[selected] == nil { sources[selected] = "暂不可用 · \(selected)" }
        for (id, title) in sources.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) { add(title, key: "source:" + id, to: sourcePopup) }
        select(draft.query.sourceBundleID.map { "source:" + $0 } ?? "all", in: sourcePopup)
        devicePopup.removeAllItems(); add("所有来源设备", key: "all", to: devicePopup)
        add("此 Mac", key: options.localDeviceID?.uuidString ?? "local-unavailable", to: devicePopup, enabled: options.localDeviceID != nil)
        var devices = options.devices
        if case .device(let id) = draft.query.deviceFilter, id != options.localDeviceID, devices[id] == nil { devices[id] = "暂不可用设备" }
        for (id, title) in devices.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where id != options.localDeviceID { add("\(title.prefix(20)) · \(id.uuidString.prefix(8))", key: id.uuidString, to: devicePopup) }
        add("未知（含来源矛盾）", key: "unknown", to: devicePopup)
        switch draft.query.deviceFilter {
        case .all: select("all", in: devicePopup)
        case .unknown: select("unknown", in: devicePopup)
        case .device(let id): select(id.uuidString, in: devicePopup)
        }
        boardRows.arrangedSubviews.forEach { boardRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        boardButtons = []
        var seen = Set<UUID>()
        let boards = options.pinboards.filter { seen.insert($0.id).inserted }
        let missing = draft.query.pinboardIDs.subtracting(seen).sorted { $0.uuidString < $1.uuidString }
        for (id, title) in boards.map({ ($0.id, $0.name) }) + missing.map({ ($0, "已不可用分组 · \($0.uuidString.prefix(8))") }) {
            let check = NSButton(checkboxWithTitle: title, target: self, action: #selector(boardsChanged))
            check.state = draft.query.pinboardIDs.contains(id) ? .on : .off
            check.setAccessibilityLabel("筛选分组：\(title)")
            check.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            boardButtons.append((id, check)); boardRows.addArrangedSubview(check)
            check.widthAnchor.constraint(lessThanOrEqualTo: boardRows.widthAnchor).isActive = true
        }
        if boardButtons.isEmpty { boardRows.addArrangedSubview(NSTextField(labelWithString: "暂无分组，搜索全部内容。")) }
        orderPopup.selectItem(at: draft.query.sortOrder == .pinboard ? 1 : 0)
    }
    private func refreshDates() {
        startEnabled.state = draft.query.copiedAfter == nil ? .off : .on
        endEnabled.state = draft.query.copiedBefore == nil ? .off : .on
        startPicker.dateValue = draft.query.copiedAfter.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil } ?? Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        endPicker.dateValue = draft.query.copiedBefore.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil } ?? Date()
        startPicker.isEnabled = startEnabled.state == .on; endPicker.isEnabled = endEnabled.state == .on
        datePopup.selectItem(at: draft.query.copiedAfter == nil && draft.query.copiedBefore == nil ? 0 : 4)
    }
    @discardableResult private func validateDraft() -> Bool {
        do {
            try draft.validate(availablePinboardIDs: Set(options.pinboards.map(\.id)))
            message.stringValue = draft.availabilityNotice(options: options) ?? "“清除筛选”保留关键词和排序；应用后才改变结果。"
            message.textColor = .secondaryLabelColor; applyButton.isEnabled = !finished
            return true
        } catch {
            message.stringValue = error.localizedDescription; message.textColor = .systemRed; applyButton.isEnabled = false
            return false
        }
    }

    @objc private func choicesChanged(_ sender: NSPopUpButton) {
        guard !finished else { return }
        if sender === typePopup { draft.query.kind = (sender.selectedItem?.representedObject as? String).flatMap(ClipboardContentKind.init(rawValue:)) }
        else if sender === sourcePopup { let value = sender.selectedItem?.representedObject as? String; draft.query.sourceBundleID = value?.hasPrefix("source:") == true ? String(value!.dropFirst(7)) : nil }
        else if sender === devicePopup {
            switch sender.selectedItem?.representedObject as? String {
            case "all": draft.query.deviceFilter = .all
            case "unknown": draft.query.deviceFilter = .unknown
            case .some(let key): if let id = UUID(uuidString: key) { draft.query.deviceFilter = .device(id) }
            case .none: break
            }
        } else if sender === orderPopup { draft.query.sortOrder = sender.indexOfSelectedItem == 1 ? .pinboard : .recent }
        else if sender === datePopup {
            let index = sender.indexOfSelectedItem
            switch index {
            case 0: draft.query.copiedAfter = nil; draft.query.copiedBefore = nil
            case 1: draft.query.copiedAfter = Calendar.current.startOfDay(for: Date()); draft.query.copiedBefore = nil
            case 2, 3: draft.query.copiedAfter = Calendar.current.date(byAdding: .day, value: index == 2 ? -7 : -30, to: Date()); draft.query.copiedBefore = nil
            default:
                if draft.query.copiedAfter == nil { draft.query.copiedAfter = Calendar.current.date(byAdding: .day, value: -7, to: Date()) }
                if draft.query.copiedBefore == nil { draft.query.copiedBefore = Date() }
            }
            refreshDates(); datePopup.selectItem(at: index)
        }
        validateDraft()
    }
    @objc private func datesChanged() {
        guard !finished else { return }
        draft.query.copiedAfter = startEnabled.state == .on ? startPicker.dateValue : nil
        draft.query.copiedBefore = endEnabled.state == .on ? endPicker.dateValue : nil
        startPicker.isEnabled = startEnabled.state == .on; endPicker.isEnabled = endEnabled.state == .on
        datePopup.selectItem(at: draft.query.copiedAfter == nil && draft.query.copiedBefore == nil ? 0 : 4)
        validateDraft()
    }
    @objc private func boardsChanged() {
        guard !finished else { return }
        draft.query.pinboardIDs = Set(boardButtons.filter { $0.1.state == .on }.map(\.0))
        validateDraft()
    }
    @objc private func clearDraft() {
        guard !finished else { return }
        draft.clearFilters(); refreshChoices(); refreshDates(); validateDraft()
    }
    @objc private func cancelDraft() { guard !finished else { return }; finished = true; applyButton.isEnabled = false; onCancel?() }
    @objc private func applyDraft() {
        guard !finished, validateDraft(), let onApply else { return }
        finished = true; applyButton.isEnabled = false; onApply(draft.query)
    }
}
