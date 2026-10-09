import AppKit
import ClipShelfLocalization

@MainActor
final class LanguageSettingsController: NSWindowController {
    private let preferences: LanguagePreferences
    private let presentWindow: @MainActor (NSWindow) -> Void
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: L10n.text("保存语言设置"), target: nil, action: nil)
    var isPresentationAllowed: (() -> Bool)?
    var onPreparePresentation: (() -> Void)?

    init(preferences: LanguagePreferences, presentWindow: (@MainActor (NSWindow) -> Void)? = nil) {
        self.preferences = preferences
        self.presentWindow = presentWindow ?? { window in
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf · 语言设置")
        window.minSize = NSSize(width: 540, height: 300); window.isReleasedWhenClosed = false
        super.init(window: window)
        let heading = NSTextField(labelWithString: L10n.text("下次启动使用的界面语言"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("保存后在下次启动 ClipShelf 时生效，不会自动重启。当前草稿、同步、更新和其他正在进行的任务会继续保留。"))
        explanation.textColor = .secondaryLabelColor
        for language in InterfaceLanguage.allCases {
            let title = language == .system ? L10n.text("跟随系统") : language.nativeName
            picker.addItem(withTitle: title); picker.lastItem?.representedObject = language.rawValue
        }
        picker.setAccessibilityIdentifier("language.selection")
        picker.setAccessibilityLabel(L10n.text("界面语言"))
        picker.target = self; picker.action = #selector(selectionChanged)
        status.setAccessibilityIdentifier("language.status")
        saveButton.setAccessibilityIdentifier("language.save")
        saveButton.target = self; saveButton.action = #selector(saveSelection)
        let close = NSButton(title: L10n.text("关闭"), target: self, action: #selector(closeSettings))
        close.setAccessibilityIdentifier("language.close"); close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, close, saveButton]); buttons.spacing = 12
        let detail = NSStackView(views: [heading, explanation, picker, status])
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 16
        detail.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = detail
        let content = NSStackView(views: [scroll, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        window.contentView = content
        defer { InterfaceLayout.apply(to: content) }
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 174),
            detail.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -18),
            explanation.widthAnchor.constraint(equalTo: detail.widthAnchor),
            picker.widthAnchor.constraint(equalTo: detail.widthAnchor),
            status.widthAnchor.constraint(equalTo: detail.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        loadSavedSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard isPresentationAllowed?() != false else { return }
        onPreparePresentation?()
        guard isPresentationAllowed?() != false, let window else { return }
        loadSavedSelection()
        presentWindow(window)
    }
    func suspend() { window?.orderOut(nil) }
    private func loadSavedSelection() {
        if let item = picker.itemArray.first(where: { $0.representedObject as? String == preferences.selectedLanguage.rawValue }) {
            picker.select(item)
        }
        picker.isEnabled = preferences.allowsChanges
        saveButton.isEnabled = preferences.allowsChanges
        status.stringValue = preferences.allowsChanges
            ? L10n.text("仅改变界面语言；剪贴板内容、分组名称和系统输入法不受影响。")
            : L10n.text("演示和验证模式不能保存语言设置；真实设置保持不变。")
    }
    @objc private func selectionChanged() {
        guard preferences.allowsChanges else { return }
        status.stringValue = L10n.text("选择尚未保存。保存后，下次启动生效。")
    }
    @objc func saveSelection() {
        guard let raw = picker.selectedItem?.representedObject as? String,
              let language = InterfaceLanguage(rawValue: raw) else { return }
        do {
            try preferences.save(language)
            status.stringValue = L10n.text("语言设置已保存，下次启动生效。你可以继续当前工作，稍后自行退出并重新打开 ClipShelf。")
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func closeSettings() { close() }
}
