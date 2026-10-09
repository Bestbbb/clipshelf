import AppKit
import ShareInboxShared
import UniformTypeIdentifiers

/// This controller is hosted by the source app, not by the clipboard manager.
@MainActor final class ShareViewController: NSViewController {
    private let destinations = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "正在准备分享内容…")
    private let saveButton = NSButton(title: "保存到收件箱", target: nil, action: nil)
    private var directory: ShareInboxDirectory?
    private var catalog: ShareInboxCatalog?
    private var draft: ShareInboxDraft?
    private var loading: Task<Void, Never>?
    private let loader = ShareProviderLoader()
    private var ready = false
    private var finished = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        let title = NSTextField(labelWithString: "保存到 ClipShelf")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "选择历史记录或目的板。内容先保存在共享收件箱，ClipShelf 运行时导入；若已退出，将在下次启动后导入。")
        explanation.textColor = .secondaryLabelColor
        destinations.addItem(withTitle: "选择保存位置…")
        destinations.target = self; destinations.action = #selector(selectionChanged)
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"; saveButton.isEnabled = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelShare))
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
        preferredContentSize = NSSize(width: 480, height: 270)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard loading == nil, !finished else { return }
        do {
            let directory = try ShareInboxDirectory.configured()
            let catalog = try directory.readCatalog()
            guard !catalog.destinations.isEmpty else { throw ShareInboxError.unavailableDestination }
            self.directory = directory; self.catalog = catalog
            for destination in catalog.destinations {
                destinations.addItem(withTitle: destination.name + (destination.isShared ? "（共享）" : ""))
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
                    self.status.stringValue = "已准备 \(providers.count) 项；只有点击保存后才会提交。"
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
            status.stringValue = "已保存到收件箱，等待 ClipShelf 导入。"
            saveButton.isEnabled = false
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch { show(error) }
    }
    @objc private func cancelShare() {
        finished = true; stopLoading()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
    private func stopLoading() { loading?.cancel(); loader.cancel(); draft?.cancel(); draft = nil }
    private func show(_ error: Error) {
        ready = false; saveButton.isEnabled = false
        status.stringValue = (error as? LocalizedError)?.errorDescription ?? "无法读取分享内容。请先启动已正确签名并配置 App Group 的 ClipShelf，然后重试。"
        status.textColor = .systemRed
    }
}
