import ClipShelfLocalization
import AppKit

@MainActor
final class UpdateSettingsController: NSWindowController {
    private let coordinator: AppUpdateCoordinator
    private let status = NSTextField(wrappingLabelWithString: "")
    private let lastCheck = NSTextField(wrappingLabelWithString: "")
    private let automaticChecks = NSButton(checkboxWithTitle: L10n.text("自动检查更新"), target: nil, action: nil)
    private let automaticDownloads = NSButton(checkboxWithTitle: L10n.text("自动下载更新并在退出后安装"), target: nil, action: nil)
    private let check = NSButton(title: L10n.text("检查更新…"), target: nil, action: nil)
    private let retry = NSButton(title: L10n.text("重试安装重启"), target: nil, action: nil)

    init(coordinator: AppUpdateCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf · 应用更新"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 580, height: 380)
        super.init(window: window)
        status.setAccessibilityIdentifier("update.status")
        automaticChecks.setAccessibilityIdentifier("update.automaticChecks")
        automaticDownloads.setAccessibilityIdentifier("update.automaticDownloads")
        check.setAccessibilityIdentifier("update.check"); retry.setAccessibilityIdentifier("update.retryRestart")
        automaticChecks.target = self; automaticChecks.action = #selector(changeAutomaticChecks)
        automaticDownloads.target = self; automaticDownloads.action = #selector(changeAutomaticDownloads)
        check.target = self; check.action = #selector(checkNow)
        retry.target = self; retry.action = #selector(retryRestart)
        let version = NSTextField(labelWithString: coordinator.versionDescription)
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("自动检查和自动下载默认关闭。开启后由 Sparkle 检查签名并提供更新。关闭开关不会撤销已下载、等待正常退出安装的更新。安装重启仍会确认未保存草稿，并等待正在进行的存储事务完成。"))
        explanation.textColor = .secondaryLabelColor; lastCheck.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let detail = NSStackView(views: [version, status, lastCheck, explanation])
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 14
        detail.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = detail
        let buttons = NSStackView(views: [check, retry]); buttons.spacing = 12
        let content = NSStackView(views: [scroll, automaticChecks, automaticDownloads, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = content
        defer { InterfaceLayout.apply(to: content) }
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            detail.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -18),
            status.widthAnchor.constraint(equalTo: detail.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: detail.widthAnchor),
            lastCheck.widthAnchor.constraint(equalTo: detail.widthAnchor),
        ])
        refreshView()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        refreshView(); window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    /// Root calls this alongside menu rendering in coordinator.onChange.
    func refreshView() {
        status.stringValue = coordinator.status
        lastCheck.stringValue = coordinator.lastUpdateCheckDate.map { L10n.text("上次检查：\(L10n.date($0))") } ?? L10n.text("尚无检查记录。")
        automaticChecks.state = coordinator.automaticallyChecksForUpdates ? .on : .off
        automaticDownloads.state = coordinator.automaticallyDownloadsUpdates ? .on : .off
        automaticChecks.isEnabled = coordinator.isAvailable
        automaticDownloads.isEnabled = coordinator.canChangeAutomaticDownloads
        check.isEnabled = coordinator.canCheck
        retry.isEnabled = coordinator.canRetryPendingRestart
        retry.isHidden = !coordinator.hasPendingRestart
    }
    @objc private func changeAutomaticChecks() { coordinator.setAutomaticallyChecksForUpdates(automaticChecks.state == .on); refreshView() }
    @objc private func changeAutomaticDownloads() { coordinator.setAutomaticallyDownloadsUpdates(automaticDownloads.state == .on); refreshView() }
    @objc private func checkNow() { coordinator.checkForUpdates(); refreshView() }
    @objc private func retryRestart() { coordinator.retryPendingRestart(); refreshView() }
}
