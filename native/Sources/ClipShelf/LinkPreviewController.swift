import AppKit
import WebKit

private final class LinkPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A disposable browser created only after an explicit preview action. No metadata fetch,
/// cookie store, WebView or network request is created by a history card or this initializer.
@MainActor
final class LinkPreviewController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var onDismiss: (() -> Void)?
    private let initialURL: URL
    private let address = NSTextField(string: "")
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "仅在此预览中访问网页 · 临时浏览会话")
    private let back = NSButton(title: "后退", target: nil, action: nil)
    private let forward = NSButton(title: "前进", target: nil, action: nil)
    private let reload = NSButton(title: "重新加载", target: nil, action: nil)
    private let external = NSButton(title: "在浏览器中打开", target: nil, action: nil)
    private let browserHost = NSView()
    private var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var keyMonitor: Any?
    private var presented = false

    init(url: URL) {
        initialURL = url
        let panel = LinkPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
                                     styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "链接预览"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 400)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildInterface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func allows(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    func present(relativeTo parent: NSWindow?) {
        guard !presented, let window else { return }
        presented = true
        if let frame = (parent?.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        parent?.addChildWindow(window, ordered: .above)
        installKeyMonitor()
        window.makeKeyAndOrderFront(nil)
        guard Self.allows(initialURL) else { status.stringValue = "仅支持不含登录凭据的 HTTP 或 HTTPS 链接。"; return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.allowsLinkPreview = false
        browser.translatesAutoresizingMaskIntoConstraints = false
        browserHost.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: browserHost.leadingAnchor), browser.trailingAnchor.constraint(equalTo: browserHost.trailingAnchor),
            browser.topAnchor.constraint(equalTo: browserHost.topAnchor), browser.bottomAnchor.constraint(equalTo: browserHost.bottomAnchor)
        ])
        webView = browser
        observations = [
            browser.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } },
            browser.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } },
            browser.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } },
            browser.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } },
            browser.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } }
        ]
        address.stringValue = initialURL.absoluteString
        browser.load(URLRequest(url: initialURL))
        window.makeFirstResponder(browser)
    }

    func dismiss() { window?.close(); releaseBrowser() }

    private func releaseBrowser() {
        guard presented else { return }
        presented = false
        observations.forEach { $0.invalidate() }; observations.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let window { window.parent?.removeChildWindow(window) }
        address.stringValue = ""; progress.doubleValue = 0
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) { releaseBrowser() }

    private func buildInterface() {
        let root = NSView()
        window?.contentView = root
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        reload.target = self; reload.action = #selector(reloadPage)
        external.target = self; external.action = #selector(openExternally)
        back.isEnabled = false; forward.isEnabled = false
        let close = NSButton(title: "返回列表", target: self, action: #selector(closePreview))
        close.keyEquivalent = "\u{1b}"
        let toolbar = NSStackView(views: [back, forward, reload, external, close]); toolbar.spacing = 8
        address.isEditable = false; address.isSelectable = true
        address.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        address.setAccessibilityLabel("当前网页真实地址")
        address.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.setAccessibilityLabel("网页加载进度")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for view in [toolbar, address, progress, browserHost, status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            address.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), address.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            address.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor), progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 8), progress.heightAnchor.constraint(equalToConstant: 3),
            browserHost.leadingAnchor.constraint(equalTo: root.leadingAnchor), browserHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browserHost.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 4), browserHost.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9)
        ])
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.presented, event.window === self.window else { return event }
            if (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" { self.dismiss(); return nil }
            return event
        }
    }

    private func updateNavigation() {
        guard presented, let webView else { return }
        if let url = webView.url { address.stringValue = url.absoluteString; address.toolTip = url.absoluteString }
        progress.doubleValue = webView.estimatedProgress
        progress.isHidden = !webView.isLoading
        back.isEnabled = webView.canGoBack; forward.isEnabled = webView.canGoForward
        external.isEnabled = Self.allows(webView.url ?? initialURL)
        reload.title = webView.isLoading ? "停止加载" : "重新加载"
    }

    @objc private func closePreview() { dismiss() }
    @objc private func goBack() { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func reloadPage() {
        if webView?.isLoading == true { webView?.stopLoading() } else { webView?.reload() }
    }
    @objc private func openExternally() {
        let url = webView?.url ?? initialURL
        guard Self.allows(url) else { return }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard presented, Self.allows(navigationAction.request.url), !navigationAction.shouldPerformDownload else {
            if presented { status.stringValue = "此预览不打开文件、自定义协议或下载。" }
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            // A user-clicked target=_blank link stays in this window; scripted popups are discarded.
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
            else { status.stringValue = "网页弹出窗口已阻止。" }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        guard presented, Self.allows(navigationResponse.response.url), navigationResponse.canShowMIMEType,
              !disposition.trimmingCharacters(in: .whitespaces).hasPrefix("attachment") else {
            if presented { status.stringValue = "此内容需要下载或不支持内置显示，请自行选择外部浏览器打开。" }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        status.stringValue = "正在连接网页 · 临时浏览会话"; updateNavigation()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.stringValue = "临时浏览会话 · 关闭后释放此预览"; updateNavigation()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    private func show(_ error: Error) {
        guard presented, (error as NSError).code != NSURLErrorCancelled else { return }
        status.stringValue = "网页未能加载：\(error.localizedDescription)"; updateNavigation()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status.stringValue = "网页进程已停止，可重新加载。"; updateNavigation()
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel(nil) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel(nil) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
