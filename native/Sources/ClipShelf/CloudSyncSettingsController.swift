import ClipShelfLocalization
import AppKit
import ClipShelfCore

@MainActor
final class CloudSyncSettingsController: NSWindowController {
    private let service: CloudSyncService
    private let preferences: UserDefaults
    private let status = NSTextField(wrappingLabelWithString: L10n.text("正在检查此构建的同步配置…"))
    private let toggle = NSButton(title: L10n.text("开启 iCloud 同步…"), target: nil, action: nil)
    private let sync = NSButton(title: L10n.text("立即同步"), target: nil, action: nil)
    private let fileTransfers = OwnedFileTransferStatusView()
    private var fileItems: [OwnedFileTransferStatusItem] = []
    private var transferReadGeneration: UInt64 = 0
    private var enabled = false
    private var running = false
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var generation: UInt64 = 0
    var onDataChanged: (() -> Void)?

    init(store: HistoryStore, preferences: UserDefaults = .standard) {
        service = CloudSyncService(store: store)
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf · iCloud 同步")
        window.minSize = NSSize(width: 560, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        toggle.target = self; toggle.action = #selector(toggleSync)
        sync.target = self; sync.action = #selector(syncNow)
        fileTransfers.onRetry = { [weak self] in self?.syncNow() }
        sync.isEnabled = false; toggle.isEnabled = false
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("开启后，将历史与分组同步到当前 Apple Account 的私有 iCloud 数据库。可以选择是否上传已有本地内容。同步不会改写任何设备当前的系统剪贴板。"))
        let detail = NSTextField(wrappingLabelWithString: L10n.text("关闭只停止本机传输，保留已保存的本地与云端内容。离线编辑会在恢复连接后同步，冲突版本保留为副本。切换 Apple Account 后需要重新确认；旧账号内容不会上传到新账号。"))
        detail.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [toggle, sync]); actions.spacing = 12
        let body = NSStackView(views: [status, explanation, detail, actions, fileTransfers])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 20
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = body
        for text in [status, explanation, detail] { text.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48).isActive = true }
        fileTransfers.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48).isActive = true
        fileTransfers.heightAnchor.constraint(equalToConstant: 180).isActive = true
        fileTransfers.update([], isRunning: false, enabled: false)
        Task { @MainActor [weak self] in await self?.refreshAvailability() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        refreshFileTransfers()
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    /// A previous explicit opt-in may resume, but never adopts additional pre-existing local data.
    func resumeIfEnabled() {
        guard preferences.bool(forKey: "cloudSyncEnabled") else { return }
        guard let account = preferences.string(forKey: "cloudSyncAccount") else {
            preferences.set(false, forKey: "cloudSyncEnabled")
            return
        }
        enable(includeLocalData: false, expectedAccountID: account)
    }

    func stop() {
        generation &+= 1
        transferReadGeneration &+= 1
        timer?.invalidate(); timer = nil
        operation?.cancel(); operation = nil
    }

    private func refreshAvailability() async {
        switch await service.configurationStatus() {
        case .unavailable(let reason):
            status.stringValue = reason; toggle.isEnabled = false; sync.isEnabled = false
        case .disabled:
            if !running { status.stringValue = L10n.text("同步已关闭 · 内容保存在本机") }
            toggle.isEnabled = !running; sync.isEnabled = false
        case .available:
            toggle.isEnabled = !running; sync.isEnabled = !running
        }
    }

    @objc private func toggleSync() {
        if enabled {
            stop()
            running = true; toggle.isEnabled = false; sync.isEnabled = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.service.disable()
                    self.enabled = false; self.preferences.set(false, forKey: "cloudSyncEnabled")
                    self.toggle.title = L10n.text("开启 iCloud 同步…")
                } catch { self.status.stringValue = L10n.text("未能保存关闭状态，请重试。") }
                self.running = false; await self.refreshAvailability()
                self.refreshFileTransfers()
            }
            return
        }
        guard !running else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("开启这台 Mac 的 iCloud 同步？")
        alert.informativeText = L10n.text("将使用系统设置中当前登录的 Apple Account。之后新增和编辑的同步内容会上传；读取的远端内容会保存在这台 Mac。")
        let include = Self.makeLocalHistoryUploadChoice(title: L10n.text("同时上传此前未归属其他账号的本地历史与分组"))
        alert.accessoryView = include
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("开启同步"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        enable(includeLocalData: include.state == .on)
    }

    static func makeLocalHistoryUploadChoice(title: String) -> NSButton {
        let choice = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        choice.cell?.wraps = true
        choice.cell?.lineBreakMode = .byWordWrapping
        let bounds = NSRect(x: 0, y: 0, width: 430, height: CGFloat.greatestFiniteMagnitude)
        let height = ceil(choice.cell?.cellSize(forBounds: bounds).height ?? 36)
        choice.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(36, height))
        return choice
    }

    private func enable(includeLocalData: Bool, expectedAccountID: String? = nil) {
        guard !running else { return }
        running = true; toggle.isEnabled = false; sync.isEnabled = false
        status.stringValue = L10n.text("正在连接当前 iCloud 账号…")
        generation &+= 1
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let account = try await self.service.enable(includeLocalData: includeLocalData, expectedAccountID: expectedAccountID)
                guard current == self.generation, !Task.isCancelled else { return }
                self.preferences.set(account, forKey: "cloudSyncAccount")
                self.enabled = true; self.preferences.set(true, forKey: "cloudSyncEnabled")
                self.toggle.title = L10n.text("关闭本机同步")
                self.running = false
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncNow() }
                }
                self.syncNow()
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                if case SyncError.accountChanged = error { self.preferences.set(false, forKey: "cloudSyncEnabled") }
                self.running = false; self.status.stringValue = L10n.text("同步未开启：\(error.localizedDescription)")
                self.toggle.isEnabled = true; self.sync.isEnabled = false
            }
        }
    }

    @objc private func syncNow() {
        guard enabled, !running else { return }
        running = true; toggle.isEnabled = true; sync.isEnabled = false
        fileTransfers.update(fileItems, isRunning: true, enabled: enabled)
        status.stringValue = L10n.text("正在同步… 本地内容仍可使用。")
        generation &+= 1
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if current == self.generation {
                    self.running = false; self.toggle.isEnabled = true; self.sync.isEnabled = self.enabled
                    self.refreshFileTransfers()
                    self.onDataChanged?()
                }
            }
            do {
                let summary = try await self.service.synchronize()
                guard current == self.generation, !Task.isCancelled else { return }
                let completion = summary.pendingFiles == 0 && summary.failedFiles == 0 ? L10n.text("已同步") : L10n.text("记录已处理，部分文件尚未完成")
                self.status.stringValue = L10n.text("\(completion) · 上传 \(summary.uploadedOperations) 项变更，接收 \(summary.downloadedOperations) 项变更 · \(L10n.date(Date(), includesDate: false))")
            } catch SyncError.accountChanged {
                guard current == self.generation, !Task.isCancelled else { return }
                self.enabled = false; self.timer?.invalidate(); self.timer = nil
                self.preferences.set(false, forKey: "cloudSyncEnabled")
                self.toggle.title = L10n.text("开启 iCloud 同步…")
                self.status.stringValue = L10n.text("Apple Account 已改变，同步已停止。请确认新账号后重新开启。")
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.status.stringValue = L10n.text("同步暂未完成，将保留本地变更并重试。\n\(error.localizedDescription)")
            }
        }
    }

    private func refreshFileTransfers() {
        transferReadGeneration &+= 1
        let current = transferReadGeneration
        guard enabled else {
            fileItems = []; fileTransfers.update([], isRunning: running, enabled: false); return
        }
        fileTransfers.update(fileItems, isRunning: running, enabled: enabled)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let states = try await self.service.ownedFileTransferStates()
                guard current == self.transferReadGeneration, self.enabled else { return }
                self.fileItems = OwnedFileTransferStatusItem.outstanding(states)
                self.fileTransfers.update(self.fileItems, isRunning: self.running, enabled: true)
            } catch {
                guard current == self.transferReadGeneration, self.enabled else { return }
                self.fileTransfers.unavailable(error.localizedDescription, isRunning: self.running, enabled: true)
            }
        }
    }
}
