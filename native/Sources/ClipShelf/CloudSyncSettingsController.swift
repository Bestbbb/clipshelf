import AppKit
import ClipShelfCore

@MainActor
final class CloudSyncSettingsController: NSWindowController {
    private let service: CloudSyncService
    private let preferences: UserDefaults
    private let status = NSTextField(wrappingLabelWithString: "正在检查此构建的同步配置…")
    private let toggle = NSButton(title: "开启 iCloud 同步…", target: nil, action: nil)
    private let sync = NSButton(title: "立即同步", target: nil, action: nil)
    private var enabled = false
    private var running = false
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var generation: UInt64 = 0
    var onDataChanged: (() -> Void)?

    init(store: HistoryStore, preferences: UserDefaults = .standard) {
        service = CloudSyncService(store: store)
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClipShelf · iCloud 同步"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        toggle.target = self; toggle.action = #selector(toggleSync)
        sync.target = self; sync.action = #selector(syncNow)
        sync.isEnabled = false; toggle.isEnabled = false
        let explanation = NSTextField(wrappingLabelWithString: "开启后，将历史与分组同步到当前 Apple Account 的私有 iCloud 数据库。可以选择是否上传已有本地内容。同步不会改写任何设备当前的系统剪贴板。")
        let detail = NSTextField(wrappingLabelWithString: "关闭只停止本机传输，保留已保存的本地与云端内容。离线编辑会在恢复连接后同步，冲突版本保留为副本。切换 Apple Account 后需要重新确认；旧账号内容不会上传到新账号。")
        detail.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [toggle, sync]); actions.spacing = 12
        let body = NSStackView(views: [status, explanation, detail, actions])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 20
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = body
        for text in [status, explanation, detail] { text.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48).isActive = true }
        Task { @MainActor [weak self] in await self?.refreshAvailability() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() { window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

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
        timer?.invalidate(); timer = nil
        operation?.cancel(); operation = nil
    }

    private func refreshAvailability() async {
        switch await service.configurationStatus() {
        case .unavailable(let reason):
            status.stringValue = reason; toggle.isEnabled = false; sync.isEnabled = false
        case .disabled:
            if !running { status.stringValue = "同步已关闭 · 内容保存在本机" }
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
                    self.toggle.title = "开启 iCloud 同步…"
                } catch { self.status.stringValue = "未能保存关闭状态，请重试。" }
                self.running = false; await self.refreshAvailability()
            }
            return
        }
        guard !running else { return }
        let alert = NSAlert(); alert.messageText = "开启这台 Mac 的 iCloud 同步？"
        alert.informativeText = "将使用系统设置中当前登录的 Apple Account。之后新增和编辑的同步内容会上传；读取的远端内容会保存在这台 Mac。"
        let include = NSButton(checkboxWithTitle: "同时上传此前未归属其他账号的本地历史与分组", target: nil, action: nil)
        include.frame = NSRect(x: 0, y: 0, width: 430, height: 36)
        alert.accessoryView = include
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "开启同步")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        enable(includeLocalData: include.state == .on)
    }

    private func enable(includeLocalData: Bool, expectedAccountID: String? = nil) {
        guard !running else { return }
        running = true; toggle.isEnabled = false; sync.isEnabled = false
        status.stringValue = "正在连接当前 iCloud 账号…"
        generation &+= 1
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let account = try await self.service.enable(includeLocalData: includeLocalData, expectedAccountID: expectedAccountID)
                guard current == self.generation, !Task.isCancelled else { return }
                self.preferences.set(account, forKey: "cloudSyncAccount")
                self.enabled = true; self.preferences.set(true, forKey: "cloudSyncEnabled")
                self.toggle.title = "关闭本机同步"
                self.running = false
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncNow() }
                }
                self.syncNow()
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                if case SyncError.accountChanged = error { self.preferences.set(false, forKey: "cloudSyncEnabled") }
                self.running = false; self.status.stringValue = "同步未开启：\(error.localizedDescription)"
                self.toggle.isEnabled = true; self.sync.isEnabled = false
            }
        }
    }

    @objc private func syncNow() {
        guard enabled, !running else { return }
        running = true; toggle.isEnabled = true; sync.isEnabled = false
        status.stringValue = "正在同步… 本地内容仍可使用。"
        generation &+= 1
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if current == self.generation {
                    self.running = false; self.toggle.isEnabled = true; self.sync.isEnabled = self.enabled
                }
            }
            do {
                let summary = try await self.service.synchronize()
                guard current == self.generation, !Task.isCancelled else { return }
                self.status.stringValue = "已同步 · 上传 \(summary.uploadedOperations) 项变更，下载 \(summary.downloadedOperations) 项变更 · \(Date().formatted(date: .omitted, time: .shortened))"
                self.onDataChanged?()
            } catch SyncError.accountChanged {
                guard current == self.generation, !Task.isCancelled else { return }
                self.enabled = false; self.timer?.invalidate(); self.timer = nil
                self.preferences.set(false, forKey: "cloudSyncEnabled")
                self.toggle.title = "开启 iCloud 同步…"
                self.status.stringValue = "Apple Account 已改变，同步已停止。请确认新账号后重新开启。"
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.status.stringValue = "同步暂未完成，将保留本地变更并重试。\n\(error.localizedDescription)"
            }
        }
    }
}
