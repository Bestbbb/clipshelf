import ClipShelfLocalization
import AppKit
import ShareInboxShared
import UniformTypeIdentifiers
import Security

/// This controller is hosted by the source app, not by the clipboard manager.
@MainActor final class ShareViewController: NSViewController {
    private let destinations = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: L10n.text("正在准备分享内容…"))
    private let saveButton = NSButton(title: L10n.text("保存到收件箱"), target: nil, action: nil)
    private var directory: ShareInboxDirectory?
    private var catalog: ShareInboxCatalog?
    private var draft: ShareInboxDraft?
    private var loading: Task<Void, Never>?
    private let loader = ShareProviderLoader()
    private var ready = false
    private var finished = false

    override func loadView() {
        let host = Bundle(for: ShareViewController.self)
        var language = InterfaceLanguage.system
        if let identifier = host.object(forInfoDictionaryKey: "ClipShelfAppGroupIdentifier") as? String,
           !identifier.isEmpty, !identifier.contains("$("), !identifier.contains("YOUR_"),
           let task = SecTaskCreateFromSelf(nil),
           let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
           groups.contains(identifier), let preferences = UserDefaults(suiteName: identifier) {
            language = preferences.string(forKey: "interfaceLanguage").flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
        }
        L10n.configure(language: language, preferredLanguages: Locale.preferredLanguages, hostBundle: host)
        status.stringValue = L10n.text("正在准备分享内容…")
        saveButton.title = L10n.text("保存到收件箱")
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        let title = NSTextField(labelWithString: L10n.text("保存到 ClipShelf"))
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("选择历史记录或目的板。内容先保存在共享收件箱，ClipShelf 运行时导入；若已退出，将在下次启动后导入。"))
        explanation.textColor = .secondaryLabelColor
        destinations.addItem(withTitle: L10n.text("选择保存位置…"))
        destinations.target = self; destinations.action = #selector(selectionChanged)
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"; saveButton.isEnabled = false
        let cancel = NSButton(title: L10n.text("取消"), target: self, action: #selector(cancelShare))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, explanation, destinations, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            destinations.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        InterfaceLayout.apply(to: view)
        preferredContentSize = NSSize(width: 480, height: 270)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard loading == nil, !finished else { return }
        do {
            let directory = try ShareInboxDirectory.configured(bundle: Bundle(for: ShareViewController.self))
            let catalog = try directory.readCatalog()
            guard !catalog.destinations.isEmpty else { throw ShareInboxError.unavailableDestination }
            self.directory = directory; self.catalog = catalog
            for destination in catalog.destinations {
                let name = destination.boardID == nil ? L10n.text("剪贴板历史") : destination.name
                destinations.addItem(withTitle: name + (destination.isShared ? L10n.text("（共享）") : ""))
            }
            let inputs = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            var providers: [NSItemProvider] = []
            for input in inputs {
                let attachments = input.attachments ?? []
                if attachments.isEmpty, let text = input.attributedContentText?.string, !text.isEmpty {
                    providers.append(NSItemProvider(object: text as NSString))
                } else { providers.append(contentsOf: attachments) }
            }
            guard !providers.isEmpty else { throw ShareInboxError.invalidData }
            let draft = try directory.makeDraft(itemCount: providers.count)
            self.draft = draft
            let loader = self.loader
            loading = Task { [weak self] in
                do {
                    try await loader.load(providers, into: draft)
                    guard !Task.isCancelled, let self, !self.finished else { return }
                    self.ready = true
                    self.status.stringValue = L10n.text("已准备 \(providers.count) 项；只有点击保存后才会提交。")
                    self.selectionChanged()
                } catch {
                    draft.cancel()
                    guard let self, !self.finished else { return }
                    self.show(error)
                }
            }
        } catch { show(error) }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if !finished { stopLoading() }
    }
    @objc private func selectionChanged() { saveButton.isEnabled = ready && destinations.indexOfSelectedItem > 0 && !finished }
    @objc private func save() {
        guard ready, let draft, let catalog, destinations.indexOfSelectedItem > 0 else { return }
        let index = destinations.indexOfSelectedItem - 1
        guard catalog.destinations.indices.contains(index) else { return }
        do {
            try draft.publish(destination: catalog.destinations[index], catalog: catalog)
            finished = true
            status.stringValue = L10n.text("已保存到收件箱，等待 ClipShelf 导入。")
            saveButton.isEnabled = false
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            show(error)
            if ShareInboxDraft.canRetryPublication(after: error) {
                // Keep the already loaded providers and selected destination. Saving again
                // retries the same draft after the user has made space available.
                ready = true
                selectionChanged()
            }
        }
    }
    @objc private func cancelShare() {
        finished = true; stopLoading()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
    private func stopLoading() { loading?.cancel(); loader.cancel(); draft?.cancel(); draft = nil }
    private func show(_ error: Error) {
        ready = false; saveButton.isEnabled = false
        status.stringValue = (error as? LocalizedError)?.errorDescription ?? L10n.text("无法读取分享内容。请先启动已正确签名并配置 App Group 的 ClipShelf，然后重试。")
        status.textColor = .systemRed
    }
}
