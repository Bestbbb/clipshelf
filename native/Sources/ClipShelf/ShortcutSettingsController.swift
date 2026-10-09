import ClipShelfLocalization
import AppKit

private final class ShortcutSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ShortcutSettingsController: NSWindowController, NSWindowDelegate {
    var onValidate: ((KeyboardShortcutConfiguration) -> Result<Void, Error>)?
    var onApply: ((KeyboardShortcutConfiguration, Bool) -> Result<Void, Error>)?
    var onTryActivation: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }
    var isKeyWindow: Bool { window?.isKeyWindow == true }
    private(set) var draft = KeyboardShortcutConfiguration.defaults
    private(set) var draftAlwaysPlainText = false
    private var hasDraftSession = false
    private var registrationMessage: String?
    private var eventMonitor: Any?
    private let activateApplication: @MainActor () -> Void
    private var recorders: [ShortcutRecorderView] = []
    private let quickPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let plainPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let alwaysPlain = NSButton(checkboxWithTitle: L10n.text("始终以纯文本粘贴（文件和图片保持原格式）"), target: nil, action: nil)
    private let applyButton = NSButton(title: L10n.text("保存"), target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(activateApplication: (@MainActor () -> Void)? = nil) {
        self.activateApplication = activateApplication ?? { NSApp.activate(ignoringOtherApps: true) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf 快捷键")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 360)
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(configuration: KeyboardShortcutConfiguration, alwaysPlainText: Bool, registrationMessage: String? = nil) {
        self.registrationMessage = registrationMessage
        if !hasDraftSession {
            draft = configuration; draftAlwaysPlainText = alwaysPlainText
            hasDraftSession = true
            errorLabel.stringValue = registrationMessage ?? ""
            refreshDraftControls()
            window?.center()
        }
        validateDraftInline()
        installMonitor()
        activateApplication()
        window?.makeKeyAndOrderFront(nil)
    }

    func keyboardInputSourceDidChange(registrationMessage: String? = nil) {
        self.registrationMessage = registrationMessage
        stopRecording()
        refreshDraftControls()
        if hasDraftSession { validateDraftInline() }
    }

    /// Carbon may consume a registered chord before AppKit can deliver a keyDown.
    @discardableResult
    func captureRegisteredShortcut(_ chord: ShortcutChord) -> Bool {
        guard isVisible, isKeyWindow, let recorder = recorders.first(where: \.isRecording) else { return false }
        return recorder.captureRegisteredShortcut(chord)
    }

    @discardableResult
    func handleRecorderEvent(_ event: NSEvent) -> Bool {
        guard isVisible, isKeyWindow, event.window === window,
              let recorder = recorders.first(where: \.isRecording) else { return false }
        return recorder.capture(event)
    }

    private func installMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleRecorderEvent(event) ? nil : event
        }
    }

    private func stopRecording() { recorders.forEach { $0.cancelRecording() } }
    private func removeMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }
    private func finishDraftSession() {
        stopRecording(); removeMonitor(); hasDraftSession = false
        window?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    func windowWillClose(_ notification: Notification) { finishDraftSession() }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel(L10n.text("快捷键设置内容"))
        let document = ShortcutSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        root.addSubview(scroll)
        let heading = NSTextField(labelWithString: L10n.text("快捷键与粘贴"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: L10n.text("唤起面板与 Paste Stack 是全局快捷键；切换分组仅在结果列表中生效。点击快捷键框开始录制，Esc 取消录制。"))
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [heading, description])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let fields: [(String, ShortcutChord)] = [
            (L10n.text("唤起 / 收起面板"), draft.activation), (L10n.text("开启 Paste Stack"), draft.stack),
            (L10n.text("上一个分组"), draft.previousPinboard), (L10n.text("下一个分组"), draft.nextPinboard)
        ]
        for (index, field) in fields.enumerated() {
            let recorder = ShortcutRecorderView(title: field.0, chord: field.1)
            recorders.append(recorder)
            recorder.onBeginRecording = { [weak self, weak recorder] in
                guard let self else { return }
                self.recorders.filter { $0 !== recorder }.forEach { $0.cancelRecording() }
                self.errorLabel.stringValue = self.registrationMessage ?? ""
            }
            recorder.onChange = { [weak self] chord in
                guard let self else { return }
                switch index {
                case 0: self.draft.activation = chord
                case 1: self.draft.stack = chord
                case 2: self.draft.previousPinboard = chord
                default: self.draft.nextPinboard = chord
                }
                self.validateDraftInline()
            }
            stack.addArrangedSubview(row(field.0, control: recorder))
        }
        for popup in [quickPopup, plainPopup] {
            for modifier in ShortcutModifier.allCases {
                popup.addItem(withTitle: modifier.displayName)
                popup.lastItem?.representedObject = modifier.rawValue
            }
            popup.target = self; popup.action = #selector(modifiersChanged)
        }
        quickPopup.setAccessibilityLabel(L10n.text("Quick Paste 单个修饰键"))
        plainPopup.setAccessibilityLabel(L10n.text("纯文本单个修饰键"))
        stack.addArrangedSubview(row(L10n.text("Quick Paste 修饰键"), control: quickPopup))
        stack.addArrangedSubview(row(L10n.text("纯文本修饰键"), control: plainPopup))
        alwaysPlain.target = self; alwaysPlain.action = #selector(alwaysPlainChanged)
        alwaysPlain.setAccessibilityLabel(L10n.text("始终以纯文本粘贴"))
        stack.addArrangedSubview(alwaysPlain)
        let quickHelp = NSTextField(wrappingLabelWithString: L10n.text("在结果列表按住 Quick Paste 修饰键显示 1–9 编号；再加纯文本修饰键可直接粘贴纯文本。纯文本修饰键也用于 Return 和双击。"))
        quickHelp.font = .systemFont(ofSize: 11); quickHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(quickHelp)
        quickHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let fixedHeading = NSTextField(labelWithString: L10n.text("固定快捷键"))
        fixedHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        let fixed = NSTextField(wrappingLabelWithString: L10n.text("Return 粘贴 · Space 预览 · ←/→ 选择 · Shift-←/→ 扩选 · ⌘A 全选结果\n⌘C 复制 · Delete 删除 · ⌘Z 撤销 · ⌘E 编辑 · ⌘R 重命名 · ⌘O 打开\n⌘F 搜索 / 全部筛选 · ⌘G 定位 · ⌘N 新建文本 · ⇧⌘N 新建分组 · ⌘, 设置\n⌥⌘←/→ 调整分组内顺序 · ⌘↑/↓ 全部结果首尾 · ⌘T 暂停 / 继续记录"))
        fixed.font = .systemFont(ofSize: 11); fixed.textColor = .secondaryLabelColor
        fixed.setAccessibilityLabel(L10n.text("固定应用内快捷键说明"))
        stack.addArrangedSubview(fixedHeading); stack.addArrangedSubview(fixed)
        fixed.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.setAccessibilityLabel(L10n.text("快捷键设置错误"))
        errorLabel.heightAnchor.constraint(equalToConstant: 42).isActive = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(errorLabel)

        let defaults = NSButton(title: L10n.text("恢复默认"), target: self, action: #selector(restoreDefaults))
        let trial = NSButton(title: L10n.text("试用唤起面板"), target: self, action: #selector(tryActivation))
        trial.toolTip = L10n.text("打开面板检查位置与操作，不改写剪贴板。")
        let cancel = NSButton(title: L10n.text("取消"), target: self, action: #selector(cancelChanges))
        cancel.keyEquivalent = "\u{1b}"
        let apply = applyButton
        apply.target = self; apply.action = #selector(applyChanges)
        apply.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [defaults, trial, spacer, cancel, apply])
        buttons.orientation = .horizontal; buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            errorLabel.leadingAnchor.constraint(equalTo: buttons.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: buttons.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -12),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
        refreshDraftControls()
    }

    private func row(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 164).isActive = true
        control.widthAnchor.constraint(equalToConstant: 270).isActive = true
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        return row
    }

    private func refreshDraftControls() {
        let chords = [draft.activation, draft.stack, draft.previousPinboard, draft.nextPinboard]
        for (recorder, chord) in zip(recorders, chords) { recorder.cancelRecording(); recorder.chord = chord }
        for (popup, modifier) in [(quickPopup, draft.quickPaste), (plainPopup, draft.plainText)] {
            if let item = popup.itemArray.first(where: { $0.representedObject as? String == modifier.rawValue }) { popup.select(item) }
        }
        alwaysPlain.state = draftAlwaysPlainText ? .on : .off
    }

    @discardableResult
    private func validateDraftInline() -> Bool {
        do {
            try draft.validate()
            if let onValidate { try onValidate(draft).get() }
            errorLabel.stringValue = registrationMessage ?? ""
            applyButton.isEnabled = true
            return true
        } catch {
            errorLabel.stringValue = error.localizedDescription
            applyButton.isEnabled = false
            return false
        }
    }

    @objc private func modifiersChanged() {
        if let value = quickPopup.selectedItem?.representedObject as? String, let modifier = ShortcutModifier(rawValue: value) { draft.quickPaste = modifier }
        if let value = plainPopup.selectedItem?.representedObject as? String, let modifier = ShortcutModifier(rawValue: value) { draft.plainText = modifier }
        validateDraftInline()
    }
    @objc private func alwaysPlainChanged() { draftAlwaysPlainText = alwaysPlain.state == .on }
    @objc private func restoreDefaults() {
        stopRecording(); draft = .defaults
        refreshDraftControls(); validateDraftInline()
    }
    @objc private func cancelChanges() { finishDraftSession() }
    @objc private func tryActivation() {
        stopRecording(); removeMonitor(); window?.orderOut(nil)
        onTryActivation?()
    }
    @objc private func applyChanges() {
        stopRecording()
        guard validateDraftInline() else { return }
        guard let onApply else { errorLabel.stringValue = L10n.text("设置尚未就绪，请稍后重试。"); return }
        switch onApply(draft, draftAlwaysPlainText) {
        case .success: registrationMessage = nil; errorLabel.stringValue = ""; finishDraftSession()
        case .failure(let error): errorLabel.stringValue = error.localizedDescription
        }
    }
}
