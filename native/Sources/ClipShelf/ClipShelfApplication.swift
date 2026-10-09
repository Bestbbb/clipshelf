import AppKit
import ClipShelfCore
import Carbon
import ServiceManagement
import UniformTypeIdentifiers
import AppIntents
import CloudKit
import PDFKit

@MainActor
final class ClipShelfApplication: NSObject, NSApplicationDelegate {
    private let demo = CommandLine.arguments.contains("--demo")
    private let preferences = UserDefaults.standard
    private var store: HistoryStore?
    private var mcpSettings: MCPSettingsController?
    private var cloudSettings: CloudSyncSettingsController?
    private var sharingSettings: SharingSettingsController?
    private var shareInbox: ShareInboxService?
    private var shareInboxUnavailableReason = "此构建未配置系统分享扩展。"
    private var shareInboxTask: Task<Void, Never>?
    private var shareInboxTimer: Timer?
    private let panel = ClipboardPanelController()
    private let capture = CaptureService()
    private let paste = PasteCoordinator()
    private let hotKey = GlobalHotKey()
    private let stackHotKey = GlobalHotKey()
    private let stack = StackCoordinator()
    private let stackPanel = StackPanelController()
    private let stackKeys = StackKeyMonitor()
    private let intelligence = LocalIntelligenceService()
    private let systemIntegration = SystemIntegrationController()
    private let contextSuggestions = ContextSuggestionService()
    private let suggestionsPanel = SuggestionPanelController()
    private var suggestionTask: Task<Void, Never>?
    private var suggestionGeneration: UInt64 = 0
    private var suggestionTargetPID: pid_t?
    private var currentQuery = HistoryQuery(includePinned: false, limit: 300)
    private var queryGeneration: UInt64 = 0
    private var queryTask: Task<Void, Never>?
    private var pausedUntil: Date?
    private var pauseTimer: Timer?
    private var retentionTimer: Timer?
    private var statusItem: NSStatusItem!
    private var recordingItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var records: [ClipboardRecord] = []
    private var metadata: [ClipboardRecordMetadata] = []
    private var target: PasteCoordinator.Target?
    private var statusMessage: String?
    private var activationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var suspensionReasons = Set<String>()
    private var outsideMonitor: Any?
    private var sessionSuspended = false
    private let historyUndo = UndoManager()
    private var isTerminating = false
    private let defaultExclusions = ["com.1password.1password", "com.agilebits.onepassword7",
                                     "com.bitwarden.desktop", "com.apple.Passwords"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.register(defaults: ["retentionDays": 30])
        configureMenu()
        configurePanel()
        configureStack()
        configureSuggestions()
        if demo {
            records = Self.demoRecords
            statusMessage = "演示模式 · 合成内容 · 不读取或写入系统剪贴板"
            refresh()
            panel.show(records: records, on: NSScreen.main, status: statusText)
            return
        }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ClipShelf Development", isDirectory: true)
            store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
            configureShareInbox(store: store!, directory: directory)
            cloudSettings = CloudSyncSettingsController(store: store!)
            cloudSettings?.onDataChanged = { [weak self] in self?.reload() }
            cloudSettings?.resumeIfEnabled()
            sharingSettings = SharingSettingsController(store: store!)
            sharingSettings?.onDataChanged = { [weak self] in self?.reload() }
            sharingSettings?.onCopyLink = { [weak self] url in
                _ = self?.paste.copy(ClipboardRecord(text: url.absoluteString))
            }
            sharingSettings?.resumeIfEnabled()
            applyRetention()
            reload()
        } catch {
            statusMessage = "无法打开历史数据库，记录已停止。"
        }
        let excluded = preferences.stringArray(forKey: "excludedBundleIDs") ?? defaultExclusions
        systemIntegration.onImport = { [weak self] record in
            guard let self, let store = self.store else { throw ClipboardCodecError.noContent }
            let created = try store.create(record)
            self.reload(); self.scheduleOCR(for: created)
        }
        systemIntegration.onStatus = { [weak self] in self?.setStatus($0) }
        systemIntegration.registerServices()
        ClipboardIntentRuntime.shared.store = store
        ClipboardIntentRuntime.shared.enabled = preferences.bool(forKey: "shortcutsEnabled")
        ClipboardIntentRuntime.shared.onDataChanged = { [weak self] in self?.reload() }
        ClipShelfShortcuts.updateAppShortcutParameters()
        capture.excludedBundleIDs = Set(excluded)
        capture.onCapture = { [weak self] record in
            guard let self, let store = self.store else { return }
            do {
                let stored = try store.record(record)
                self.stack.append(stored)
                self.statusMessage = nil
                self.reload()
                self.scheduleOCR(for: stored)
            } catch {
                self.capture.stop()
                self.statusMessage = "保存失败，已暂停记录；现有历史仍可使用。"
                self.refresh()
            }
        }
        capture.onStatus = { [weak self] message in self?.setStatus(message) }
        paste.onClipboardWrite = { [weak self] in self?.capture.noteSelfWrite() }
        paste.onResult = { [weak self] message in self?.setStatus(message) }
        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        let shortcutModifiers = [UInt32(cmdKey | shiftKey), UInt32(controlKey | optionKey), UInt32(cmdKey | optionKey)]
        let hotKeyStatus = hotKey.register(modifiers: shortcutModifiers[max(0, min(2, preferences.integer(forKey: "shortcutPreset")))])
        stackHotKey.onPressed = { [weak self] in self?.toggleStack() }
        _ = stackHotKey.register(keyCode: UInt32(kVK_ANSI_C))
        if hotKeyStatus != noErr {
            statusMessage = "⌘⇧V 已被占用；可从菜单栏打开 ClipShelf。"
        }
        installObservers()
        if let deadline = preferences.object(forKey: "pauseUntil") as? Date, deadline > Date() {
            scheduleResume(at: deadline)
        } else if store != nil, preferences.bool(forKey: "recordingEnabled") { capture.start() }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        refresh()
        if store != nil, !preferences.bool(forKey: "hasSeenWelcome") {
            setStatus("欢迎使用 ClipShelf · 打开历史或选择开始记录以完成设置。")
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipShelf 剪贴板")
        let menu = NSMenu()
        let title = NSMenuItem(title: "ClipShelf · 开发预览", action: nil, keyEquivalent: "")
        menu.addItem(title)
        stateItem = NSMenuItem(title: "记录已暂停", action: nil, keyEquivalent: "")
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(item("打开剪贴板    ⌘⇧V", #selector(openFromMenu)))
        recordingItem = item("开始记录", #selector(toggleRecording))
        menu.addItem(recordingItem)
        permissionItem = item("开启直接粘贴…", #selector(enableDirectPaste))
        menu.addItem(permissionItem)
        menu.addItem(item("排除应用…", #selector(editExclusions)))
        let pauseMenuItem = NSMenuItem(title: "定时暂停", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        for (label, minutes) in [("暂停 5 分钟", 5), ("暂停 30 分钟", 30), ("暂停 1 小时", 60)] {
            let action = item(label, #selector(pauseFor(_:))); action.tag = minutes; pauseMenu.addItem(action)
        }
        pauseMenuItem.submenu = pauseMenu; menu.addItem(pauseMenuItem)
        menu.addItem(item("顺序粘贴 Stack    ⌘⇧C", #selector(toggleStack)))
        menu.addItem(.separator())
        menu.addItem(item("新建文本…", #selector(newText)))
        menu.addItem(item("从 iPhone 或 iPad 导入…", #selector(importFromCamera)))
        menu.addItem(item("系统分享收件箱…", #selector(checkShareInbox)))
        menu.addItem(item("允许快捷指令访问…", #selector(configureShortcuts)))
        menu.addItem(item("导出备份…", #selector(exportBackup)))
        menu.addItem(item("恢复备份…", #selector(restoreBackup)))
        let retentionRoot = NSMenuItem(title: "历史保留期限", action: nil, keyEquivalent: "")
        let retentionMenu = NSMenu()
        for (label, days) in [("1 天", 1), ("1 周", 7), ("1 月", 30), ("1 年", 365), ("永久", 0)] {
            let entry = item(label, #selector(changeRetention(_:))); entry.tag = days; retentionMenu.addItem(entry)
        }
        retentionRoot.submenu = retentionMenu; menu.addItem(retentionRoot)
        menu.addItem(item("清空历史…", #selector(clearHistory)))
        menu.addItem(item("打开数据文件夹", #selector(revealData)))
        menu.addItem(item("登录时启动…", #selector(toggleLoginItem)))
        menu.addItem(item("设置…", #selector(showSettings)))
        menu.addItem(item("MCP 与 AI 工具…", #selector(showMCPSettings)))
        menu.addItem(item("智能建议…", #selector(showSuggestions)))
        menu.addItem(item("iCloud 同步…", #selector(showCloudSettings)))
        menu.addItem(item("共享板…", #selector(showSharingSettings)))
        menu.addItem(.separator())
        let quit = item("退出 ClipShelf", #selector(quitApplication))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu

        let main = NSMenu()
        let appRoot = NSMenuItem()
        let appMenu = NSMenu()
        let appQuit = NSMenuItem(title: "退出 ClipShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(appQuit)
        appRoot.submenu = appMenu
        main.addItem(appRoot)
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        editRoot.submenu = edit
        main.addItem(editRoot)
        let servicesRoot = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "服务"); servicesRoot.submenu = services
        appMenu.addItem(servicesRoot); NSApp.servicesMenu = services
        let camera = NSMenuItem(title: "从设备导入", action: nil, keyEquivalent: "")
        camera.identifier = NSMenuItem.importFromDeviceIdentifier; edit.addItem(camera)
        NSApp.mainMenu = main
    }

    private func configurePanel() {
        panel.onShareRecord = { [weak self] record in
            guard let self, !self.demo, let view = self.panel.window?.contentView else { return }
            do { try self.systemIntegration.share(record, from: view) }
            catch { self.setStatus("该内容当前无法分享，请检查原文件是否可用。") }
        }
        panel.onCopyImageFile = { [weak self] record in
            guard let self, !self.demo else { return }
            do {
                let url = try SystemIntegrationController.exportImage(record)
                let file = ClipboardRecord(text: url.lastPathComponent, parts: [ClipboardPart(representations: [
                    ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(url.absoluteString.utf8))])])
                if self.paste.copy(file) { self.setStatus("图片已复制为 PNG 文件，可切回目标应用粘贴。") }
            } catch { self.setStatus("图片导出失败，系统剪贴板未改变。") }
        }
        panel.setCompactMode(!demo && preferences.bool(forKey: "compactPanel"))
        panel.onCompactModeChange = { [weak self] compact in
            guard let self, !self.demo else { return }
            self.preferences.set(compact, forKey: "compactPanel")
        }
        panel.resolveRecord = { [weak self] id, completion in
            guard let self else { completion(nil); return }
            if self.demo { completion(self.records.first { $0.id == id }); return }
            guard let store = self.store else { completion(nil); return }
            Task { @MainActor in
                let record = try? await Task.detached(priority: .userInitiated) { try store.item(id: id) }.value
                completion(record ?? nil)
            }
        }
        panel.onPaste = { [weak self] record, plain in
            guard let self else { return }
            if self.demo { self.setStatus("演示：已选择「\(record.title)」；不会写入剪贴板。"); return }
            self.paste.paste(record, plainText: self.outputAsPlainText([record], requested: plain), target: self.target) { self.panel.dismiss() }
        }
        panel.onCopy = { [weak self] record in
            guard let self else { return }
            if self.demo { self.setStatus("演示模式不会写入系统剪贴板。"); return }
            if self.paste.copy(record) { self.setStatus("内容已复制，可在目标应用按 ⌘V。") }
        }
        panel.onDelete = { [weak self] record in
            guard let self else { return }
            if self.demo { self.records.removeAll { $0.id == record.id }; self.refresh(); return }
            do { self.remember([record]); try self.store?.delete(id: record.id); self.reload() }
            catch { self.setStatus("删除失败，原记录仍保留。") }
        }
        panel.onPauseToggle = { [weak self] in self?.toggleRecording() }
        panel.onPermissions = { [weak self] in self?.enableDirectPaste() }
        panel.onDismiss = { [weak self] in self?.target = nil }
        panel.onPasteRecords = { [weak self] selected, plain in
            guard let self, !self.demo else { return }
            self.paste.paste(selected, plainText: self.outputAsPlainText(selected, requested: plain), target: self.target) { self.panel.dismiss() }
        }
        panel.onCopyRecords = { [weak self] selected in
            guard let self, !self.demo else { return }
            if self.paste.copy(selected) { self.setStatus("已复制 \(selected.count) 项。") }
        }
        panel.onDeleteRecords = { [weak self] selected in
            guard let self else { return }
            if self.demo { self.records.removeAll { item in selected.contains { $0.id == item.id } }; self.refresh(); return }
            do { self.remember(selected); for record in selected { try self.store?.delete(id: record.id) }; self.reload() }
            catch { self.setStatus("部分内容未能删除，请刷新后检查。") }
        }
        panel.onEdit = { [weak self] record, text, rtf in
            guard let self else { return }
            var edited = record
            edited.text = text; edited.rtf = rtf; edited.html = nil; edited.parts = []; edited.ocrText = nil
            self.updateRecord(edited)
        }
        panel.onRename = { [weak self] record, title in
            var edited = record; edited.renamedTitle = title
            self?.updateRecord(edited)
        }
        panel.onNewText = { [weak self] in self?.newText() }
        if !demo {
            panel.onQueryChange = { [weak self] query in self?.currentQuery = query; self?.reload() }
        }
        panel.onCreatePinboard = { [weak self] name, color in
            guard let self, !self.demo else { return }
            do { _ = try self.store?.createPinboard(name: name, color: color); self.reload() }
            catch { self.setStatus("无法创建分组，请检查名称与颜色。") }
        }
        panel.onUpdatePinboard = { [weak self] board in
            guard let self, !self.demo else { return }
            do { try self.store?.updatePinboard(board); self.reload() }
            catch { self.setStatus("无法更新分组，请重试。") }
        }
        panel.onReorderPinboards = { [weak self] ids in
            guard let self, !self.demo else { return }
            do { try self.store?.reorderPinboards(ids: ids); self.reload() }
            catch { self.setStatus("分组列表已改变，顺序未保存；请刷新后重试。"); self.reload() }
        }
        panel.onDeletePinboard = { [weak self] board in self?.deletePinboard(board) }
        panel.onMoveRecords = { [weak self] selected, boardID in
            guard let self, !self.demo else { return }
            do { self.remember(selected); for record in selected { try self.store?.move(recordID: record.id, to: boardID) }; self.reload() }
            catch { self.setStatus("部分内容未能移动，请刷新后检查。") }
        }
        panel.onExtractText = { [weak self] record in self?.extractText(record) }
        panel.onRotateImage = { [weak self] record in self?.rotateImage(record) }
        panel.onOpenRecord = { [weak self] record in self?.openRecord(record) }
        panel.onSettings = { [weak self] in self?.showSettings() }
        panel.onUndo = { [weak self] in self?.historyUndo.undo() }
        panel.onDropItems = { [weak self] items, boardID in
            guard let self, !self.demo else { return }
            do {
                if var record = try ClipboardCodec.record(from: items, sourceApp: "拖入", sourceBundleID: nil) {
                    record.pinboardID = boardID
                    let stored = try self.store?.create(record)
                    self.reload()
                    if let stored { self.scheduleOCR(for: stored) }
                }
            } catch { self.setStatus("拖入失败，原有内容未改变。") }
        }
    }

    private func installObservers() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.capture.noteFrontmostApplication(bundleID: app.bundleIdentifier)
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                if let pid = self.suggestionTargetPID, app.processIdentifier != pid { self.cancelSuggestions() }
                if self.panel.isVisible, app.processIdentifier != self.target?.application.processIdentifier {
                    self.paste.cancel()
                    self.panel.dismiss()
                }
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.paste.cancel(); self?.panel.dismiss(); self?.cancelSuggestions() }
        }
        for (notification, reason, suspended) in [
            (NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
            (NSWorkspace.willSleepNotification, "sleep", true),
            (NSWorkspace.didWakeNotification, "sleep", false)
        ] {
            lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(suspended, reason: reason) }
            })
        }
    }

    private func setSuspended(_ suspended: Bool, reason: String) {
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        sessionSuspended = !suspensionReasons.isEmpty
        if sessionSuspended {
            cancelSuggestions(); capture.stop(); paste.cancel(); panel.dismiss(); stackKeys.stop()
            if let shareInbox { Task { try? await shareInbox.publishDestinations(allowImports: false) } }
        } else {
            if preferences.bool(forKey: "recordingEnabled"), pausedUntil == nil, store != nil { capture.start() }
            if stack.peek() != nil, paste.hasPermission { _ = stackKeys.start() }
            processShareInbox()
        }
        refresh()
    }

    private func configureShareInbox(store: HistoryStore, directory: URL) {
        do {
            shareInbox = try ShareInboxService.configured(store: store, privateDirectory: directory)
            shareInboxTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.processShareInbox() }
            }
            processShareInbox()
        } catch {
            shareInboxUnavailableReason = error.localizedDescription
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { processShareInbox() }

    private func processShareInbox(retryUncertain: Bool = false, userInitiated: Bool = false) {
        guard !demo, !isTerminating else { return }
        guard !sessionSuspended else {
            if userInitiated { setStatus("会话恢复后才能导入系统分享。") }
            return
        }
        guard let shareInbox else {
            if userInitiated { showError("系统分享暂不可用", detail: shareInboxUnavailableReason) }
            return
        }
        guard shareInboxTask == nil else {
            if userInitiated { setStatus("正在检查系统分享收件箱，请稍候。") }
            return
        }
        shareInboxTask = Task { @MainActor [weak self] in
            defer { self?.shareInboxTask = nil }
            do {
                try await shareInbox.publishDestinations()
                guard let self, !Task.isCancelled, !self.sessionSuspended else { return }
                let result = try await shareInbox.importPending(retryUncertain: retryUncertain)
                guard !Task.isCancelled, !self.isTerminating else { return }
                if result.imported > 0 { self.reload() }
                if !result.failures.isEmpty {
                    self.setStatus("已导入 \(result.imported) 条系统分享；\(result.failures.count) 项尚未导入，内容保留在收件箱。")
                    if userInitiated {
                        self.showError("部分分享尚未导入", detail: result.failures.prefix(3).map(\.message).joined(separator: "\n"))
                    }
                } else if result.imported > 0 || userInitiated {
                    self.setStatus(result.imported > 0 ? "已导入 \(result.imported) 条系统分享。" : "系统分享收件箱已检查，没有待导入内容。")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setStatus("系统分享导入未完成，内容保留在收件箱。")
                if userInitiated { self.showError("系统分享导入未完成", detail: error.localizedDescription) }
            }
        }
    }

    @objc private func checkShareInbox() {
        guard !demo else { return }
        cancelSuggestions(); panel.dismiss()
        guard shareInbox != nil else { processShareInbox(userInitiated: true); return }
        let alert = NSAlert(); alert.messageText = "系统分享收件箱"
        alert.informativeText = "通过其他应用的分享菜单保存的内容会自动导入。如果上次导入因退出而中断，可以重试未确认项；请先检查历史，避免重复保存已手动恢复的内容。"
        alert.addButton(withTitle: "检查收件箱"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重试中断项")
        let choice = alert.runModal()
        guard choice != .alertSecondButtonReturn else { return }
        processShareInbox(retryUncertain: choice == .alertThirdButtonReturn, userInitiated: true)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private var statusText: String {
        if let statusMessage { return statusMessage }
        let recording = capture.isRunning ? "记录中" : "记录已暂停"
        let mode = paste.hasPermission ? "直接粘贴可用" : "复制模式 · 授权后可直接粘贴"
        return "\(recording) · \(demo ? records.count : metadata.count) 条结果 · \(mode)"
    }

    private func reload() {
        guard let store else { refresh(); return }
        queryTask?.cancel()
        queryGeneration &+= 1
        let generation = queryGeneration
        let query = currentQuery
        queryTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    (try store.searchMetadata(query), try store.pinboards(), try store.metadataSources())
                }.value
                guard let self, !Task.isCancelled, generation == self.queryGeneration else { return }
                self.metadata = result.0
                self.panel.setPinboards(result.1)
                self.panel.setSources(result.2)
                self.refresh()
            } catch { self?.setStatus("无法读取历史，请检查本机数据文件。") }
        }
    }

    private func refresh() {
        stateItem?.title = demo ? "演示模式 · 记录关闭" : (capture.isRunning ? "正在记录" : "记录已暂停")
        recordingItem?.title = capture.isRunning ? "暂停记录" : "开始记录"
        recordingItem?.isEnabled = !demo && store != nil
        permissionItem?.isEnabled = !demo
        permissionItem?.title = paste.hasPermission ? "检查直接粘贴权限…" : "开启直接粘贴…"
        statusItem?.button?.toolTip = "ClipShelf · \(capture.isRunning ? "记录中" : "已暂停")"
        panel.setCapturePaused(!capture.isRunning)
        if demo { panel.update(records: records, status: statusText) }
        else { panel.update(metadata: metadata, status: statusText) }
    }

    private func setStatus(_ message: String) { statusMessage = message; refresh() }

    private func outputAsPlainText(_ selected: [ClipboardRecord], requested: Bool) -> Bool {
        requested || (preferences.bool(forKey: "alwaysPlainText") && selected.allSatisfy(ClipboardCodec.supportsPlainText))
    }

    @objc private func openFromMenu() { togglePanel() }

    private func togglePanel() {
        cancelSuggestions()
        if panel.isVisible { panel.dismiss(); paste.cancel(); return }
        if !demo, store == nil {
            showError("历史数据库未能打开", detail: "原有文件会保留。请检查本机磁盘和数据目录权限后重新启动。")
            return
        }
        target = paste.captureTarget()
        if !demo, !preferences.bool(forKey: "hasSeenWelcome") { showWelcome() }
        statusMessage = demo ? "演示模式 · 合成内容 · 不读取或写入系统剪贴板" : nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if demo { panel.show(records: records, on: screen, status: statusText) }
        else { panel.show(metadata: metadata, on: screen, status: statusText) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible { togglePanel() }
        return true
    }

    @objc private func toggleRecording() {
        guard !demo, store != nil else { return }
        if !preferences.bool(forKey: "hasSeenWelcome") { showWelcome(); return }
        cancelSuggestions()
        if capture.isRunning { capture.stop() } else { capture.start() }
        pauseTimer?.invalidate(); pausedUntil = nil
        preferences.removeObject(forKey: "pauseUntil")
        preferences.set(capture.isRunning, forKey: "recordingEnabled")
        statusMessage = nil
        refresh()
    }

    @objc private func enableDirectPaste() {
        guard !demo else { return }
        panel.dismiss()
        paste.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        setStatus("在系统设置中允许 ClipShelf 使用辅助功能，然后重新打开面板。")
    }

    @objc private func editExclusions() {
        guard !demo else { return }
        cancelSuggestions()
        panel.dismiss()
        let alert = NSAlert()
        alert.messageText = "排除应用"
        alert.informativeText = "这些应用中之后复制的内容不会记录。填写应用的 Bundle ID，用逗号或换行分隔；已有历史不会自动删除。"
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = true; field.isSelectable = true; field.isBordered = true
        field.drawsBackground = true
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 95)
        field.stringValue = capture.excludedBundleIDs.sorted().joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let values = field.stringValue.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            capture.excludedBundleIDs = Set(values)
            preferences.set(values, forKey: "excludedBundleIDs")
        }
    }

    @objc private func newText() {
        guard !demo, store != nil else { return }
        cancelSuggestions()
        panel.dismiss()
        let alert = NSAlert()
        alert.messageText = "新建文本"
        alert.informativeText = "保存到本地历史，可从面板搜索和粘贴。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .systemFont(ofSize: 14)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !text.string.isEmpty {
            do {
                _ = try store?.create(ClipboardRecord(text: text.string, sourceApp: "ClipShelf",
                                                      sourceBundleID: Bundle.main.bundleIdentifier))
                reload()
            } catch { showError("保存失败", detail: "原有历史未改变，请检查本机磁盘空间。") }
        }
    }

    @objc private func clearHistory() {
        guard !demo, store != nil else { return }
        panel.dismiss()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空本地历史？"
        alert.informativeText = "此操作会清空本地历史，固定在分组中的内容会保留。未固定记录的删除无法撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store?.clearHistory(); reload() }
        catch { showError("清空失败", detail: "无法写入数据库，请稍后重试。") }
    }

    @objc private func revealData() {
        guard !demo else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipShelf Development")
        NSWorkspace.shared.open(directory)
    }

    private func showWelcome() {
        guard !isTerminating else { return }
        let alert = NSAlert()
        alert.messageText = "欢迎使用 ClipShelf"
        alert.informativeText = "ClipShelf 在本机保存之后复制的文字、图片和文件引用。使用 ⌘⇧V 打开历史，⌘⇧C 使用顺序粘贴。\n\n你可以随时从菜单栏暂停记录或排除应用。直接粘贴需要单独授予辅助功能权限；未授权仍可复制后手动粘贴。"
        alert.addButton(withTitle: "开始记录"); alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        preferences.set(true, forKey: "hasSeenWelcome")
        if choice == .alertFirstButtonReturn, store != nil {
            capture.start(); preferences.set(true, forKey: "recordingEnabled")
        }
        refresh()
    }

    private func updateRecord(_ record: ClipboardRecord) {
        if demo {
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record; refresh() }
            return
        }
        do {
            if let previous = try store?.item(id: record.id) { remember([previous]) }
            _ = try store?.update(record: record); reload()
        }
        catch { setStatus("内容已发生变化或保存失败，请重新打开后编辑。") }
    }

    private func deletePinboard(_ board: Pinboard) {
        guard !demo else { return }
        let alert = NSAlert(); alert.messageText = "删除「\(board.name)」？"
        alert.informativeText = "可以仅移除分组并把内容保留在历史中，也可以删除分组及其全部内容。后者不可撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "仅移除分组，保留内容")
        alert.addButton(withTitle: "删除分组及全部内容")
        let choice = alert.runModal()
        guard choice != .alertFirstButtonReturn else { return }
        do { try store?.deletePinboard(id: board.id, deleteItems: choice == .alertThirdButtonReturn); reload() }
        catch { setStatus("分组删除失败，请重试。") }
    }

    private func configureStack() {
        stackPanel.onEnd = { [weak self] in self?.stack.end() }
        stackPanel.onClear = { [weak self] in self?.stack.clear() }
        stackPanel.onReverse = { [weak self] in
            guard let self else { return }
            self.stack.direction = self.stack.direction == .forward ? .reverse : .forward
        }
        stackPanel.onRestore = { [weak self] in _ = self?.stack.restoreLastConsumed() }
        stackPanel.onRemove = { [weak self] index in _ = self?.stack.remove(at: index) }
        stackKeys.shouldHandlePaste = { [weak self] in self?.stack.peek() != nil }
        stackKeys.onUnavailable = { [weak self] in
            self?.setStatus("顺序粘贴的键盘访问已停止，队列仍保留。请检查辅助功能权限。")
        }
        stackKeys.onPaste = { [weak self] in
            guard let self, let record = self.stack.peek() else { return }
            let occurrence = self.stack.nextOccurrenceID
            let target = self.paste.captureTarget()
            self.paste.paste([record], plainText: false, target: target, dismiss: {}) { [weak self] in
                _ = self?.stack.markDispatched(expectedOccurrenceID: occurrence)
            }
        }
        stack.onChange = { [weak self] in
            guard let self else { return }
            self.stackPanel.update(self.stack)
            if self.stack.peek() != nil, !self.stackKeys.isMonitoring {
                if !self.stackKeys.start() { self.setStatus("顺序粘贴需要辅助功能权限；队列已保留。") }
            } else if self.stack.peek() == nil { self.stackKeys.stop() }
        }
    }

    @objc private func toggleStack() {
        guard !demo else { return }
        if stack.isActive { stack.end(); return }
        guard paste.hasPermission else { setStatus("请先开启辅助功能权限，再使用顺序粘贴。"); return }
        stack.activate()
        if !capture.isRunning { setStatus("顺序队列已开启；开始记录后，新的复制才会加入队列。") }
    }

    private func imageData(_ record: ClipboardRecord) -> Data? {
        record.parts.flatMap(\.representations).first { ["public.png", "public.tiff", "public.jpeg"].contains($0.typeIdentifier) }?.data
    }

    private func scheduleOCR(for record: ClipboardRecord) {
        guard record.kind == .image, let image = imageData(record) else { return }
        // Separate service per immutable revision so one image does not cancel another.
        let service = LocalIntelligenceService()
        Task { @MainActor [weak self] in
            do {
                let result = try await service.recognizeText(in: image)
                guard let self, let latest = try self.store?.item(id: record.id), latest.revision == record.revision else { return }
                var updated = latest; updated.ocrText = result.text
                _ = try self.store?.update(record: updated)
                self.reload()
            } catch { /* OCR is derived content; original image remains available. */ }
        }
    }

    private func extractText(_ record: ClipboardRecord) {
        guard let image = imageData(record) else { return }
        setStatus("正在本机识别图片文字…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.intelligence.recognizeText(in: image)
                guard !result.text.isEmpty else { self.setStatus("未识别到可用文字。"); return }
                let text = ClipboardRecord(text: result.text, sourceApp: "ClipShelf OCR", sourceBundleID: Bundle.main.bundleIdentifier)
                if self.demo { self.records.insert(text, at: 0); self.refresh() }
                else { _ = try self.store?.record(text); self.reload() }
                self.setStatus("已提取文字为新记录，原图保留。")
            } catch { self.setStatus("文字识别未完成：\(error.localizedDescription)") }
        }
    }

    private func rotateImage(_ record: ClipboardRecord) {
        guard let data = imageData(record), let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        guard let context = CGContext(data: nil, width: cg.height, height: cg.width, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: CGFloat(cg.height), y: 0); context.rotate(by: .pi / 2)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let rotated = context.makeImage(), let png = NSBitmapImageRep(cgImage: rotated).representation(using: .png, properties: [:]) else { return }
        var edited = record
        edited.parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: png)])]
        edited.text = "图片 \(cg.height) × \(cg.width)"; edited.rtf = nil; edited.html = nil; edited.ocrText = nil
        updateRecord(edited)
        if !demo, let latest = try? store?.item(id: record.id) { scheduleOCR(for: latest) }
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        guard !demo else { return }
        cancelSuggestions()
        capture.stop(); pauseTimer?.invalidate()
        let until = Date().addingTimeInterval(Double(sender.tag) * 60)
        preferences.set(true, forKey: "recordingEnabled")
        scheduleResume(at: until)
        setStatus("已暂停记录，\(sender.tag) 分钟后恢复。")
    }

    private func scheduleResume(at until: Date) {
        pauseTimer?.invalidate()
        pausedUntil = until
        preferences.set(until, forKey: "pauseUntil")
        pauseTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pausedUntil == until, self.store != nil else { return }
                self.pausedUntil = nil; self.preferences.removeObject(forKey: "pauseUntil")
                if !self.sessionSuspended { self.capture.start() }
                self.statusMessage = nil; self.refresh()
            }
        }
    }

    private func applyRetention() {
        guard !demo, let store else { return }
        let days = preferences.integer(forKey: "retentionDays")
        guard days > 0 else { return }
        do { _ = try store.prune(before: Date().addingTimeInterval(-Double(days) * 86_400)) }
        catch { statusMessage = "历史清理未完成，原有内容保留。" }
    }

    private func remember(_ originals: [ClipboardRecord]) {
        guard !originals.isEmpty else { return }
        historyUndo.levelsOfUndo = 10
        historyUndo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                do {
                    for var record in originals {
                        if let current = try target.store?.item(id: record.id) {
                            record.revision = current.revision
                            _ = try target.store?.update(record: record)
                        } else { _ = try target.store?.create(record) }
                    }
                    target.reload()
                } catch { target.setStatus("撤销未完成：相关分组或内容已发生变化。") }
            }
        }
    }

    private func openRecord(_ record: ClipboardRecord) {
        if record.kind == .file {
            for part in record.parts {
                guard let data = part.representations.first(where: { $0.typeIdentifier == "public.file-url" })?.data,
                      let string = String(data: data, encoding: .utf8), let url = URL(string: string), url.isFileURL,
                      FileManager.default.fileExists(atPath: url.path) else { setStatus("原文件已移动或不可用。"); continue }
                NSWorkspace.shared.open(url)
            }
        } else if let url = URL(string: record.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showSettings() {
        cancelSuggestions()
        let alert = NSAlert(); alert.messageText = "ClipShelf 设置"
        alert.informativeText = "数据保存在本机。菜单栏提供保留期限、定时暂停、排除应用、备份和登录启动设置。"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let plain = NSButton(checkboxWithTitle: "默认以纯文本粘贴（保留历史中的原格式）", target: nil, action: nil)
        plain.state = preferences.bool(forKey: "alwaysPlainText") ? .on : .off
        let shortcut = NSPopUpButton(); shortcut.addItems(withTitles: ["⌘⇧V", "⌃⌥V", "⌘⌥V"])
        shortcut.selectItem(at: preferences.integer(forKey: "shortcutPreset"))
        let label = NSTextField(labelWithString: "唤起快捷键")
        stack.addArrangedSubview(plain); stack.addArrangedSubview(NSStackView(views: [label, shortcut]))
        stack.frame = NSRect(x: 0, y: 0, width: 410, height: 90)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, !demo else { return }
        preferences.set(plain.state == .on, forKey: "alwaysPlainText")
        let modifiers = [UInt32(cmdKey | shiftKey), UInt32(controlKey | optionKey), UInt32(cmdKey | optionKey)]
        let index = max(0, min(2, shortcut.indexOfSelectedItem))
        if hotKey.register(modifiers: modifiers[index]) == noErr {
            preferences.set(index, forKey: "shortcutPreset"); setStatus("设置已保存。")
        } else {
            _ = hotKey.register(modifiers: modifiers[max(0, min(2, preferences.integer(forKey: "shortcutPreset")))])
            setStatus("这个快捷键已被占用，保留原设置。")
        }
    }

    @objc private func showMCPSettings() {
        guard !demo, let store else { return }
        cancelSuggestions()
        panel.dismiss()
        do {
            if mcpSettings == nil {
                mcpSettings = try MCPSettingsController(store: store)
                mcpSettings?.onDataChanged = { [weak self] in self?.reload() }
                mcpSettings?.onCredentialCopied = { [weak self] in self?.capture.noteSelfWrite() }
            }
            mcpSettings?.present()
        } catch { showError("MCP 设置不可用", detail: "无法读取本机钥匙串授权。已有历史不受影响。") }
    }

    @objc private func showCloudSettings() {
        guard !demo else { return }
        cancelSuggestions()
        panel.dismiss(); cloudSettings?.present()
    }

    @objc private func showSharingSettings() {
        guard !demo else { return }
        cancelSuggestions()
        panel.dismiss(); sharingSettings?.present()
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        guard !demo, let url = metadata.share.url else { return }
        sharingSettings?.offerInvitation(url)
    }

    @objc private func importFromCamera() {
        guard !demo else { return }
        cancelSuggestions()
        panel.dismiss(); systemIntegration.presentCameraImport()
    }

    private func configureSuggestions() {
        suggestionsPanel.onClose = { [weak self] in
            guard let self else { return }
            self.suggestionGeneration &+= 1; self.suggestionTask?.cancel(); self.suggestionTask = nil
            self.suggestionTargetPID = nil; self.contextSuggestions.cancel()
        }
        suggestionsPanel.onRequestScreenPermission = { [weak self] in
            _ = ContextSuggestionService.requestScreenRecordingPermission()
            self?.suggestionsPanel.showError(message: "请在系统设置确认屏幕权限，然后回到原应用重新打开智能建议。")
        }
        suggestionsPanel.onPaste = { [weak self] id, target in
            guard let self, let store = self.store else { return }
            let generation = self.suggestionGeneration
            Task { @MainActor [weak self] in
                guard let record = try? await Task.detached(priority: .userInitiated, operation: { try store.item(id: id) }).value,
                      let self, self.suggestionGeneration == generation else { return }
                self.paste.paste(record, plainText: self.outputAsPlainText([record], requested: false), target: target) {
                    self.suggestionsPanel.dismiss()
                }
            }
        }
    }

    @objc private func showSuggestions() {
        guard !demo, let store else { return }
        let originalTarget = panel.isVisible ? target : paste.captureTarget()
        guard let originalTarget else { setStatus("请回到需要粘贴的应用后再打开智能建议。"); return }
        cancelSuggestions(); panel.dismiss()
        suggestionTargetPID = originalTarget.application.processIdentifier
        suggestionGeneration &+= 1; let generation = suggestionGeneration
        suggestionsPanel.showLoading(target: originalTarget)
        let exclusions = capture.excludedBundleIDs
        let allowed = capture.isRunning && !sessionSuspended
        suggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let candidates = try await Task.detached(priority: .userInitiated) {
                    try store.searchMetadata(HistoryQuery(limit: 1_000))
                }.value
                guard !Task.isCancelled, self.suggestionGeneration == generation else { return }
                let result = try await self.contextSuggestions.request(target: originalTarget, records: candidates,
                    excludedBundleIDs: exclusions, captureAllowed: allowed)
                guard !Task.isCancelled, self.suggestionGeneration == generation else { return }
                self.suggestionsPanel.show(result: result, records: candidates)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.suggestionGeneration == generation else { return }
                self.suggestionsPanel.showError(message: error.localizedDescription,
                    canRequestScreenPermission: (error as? ContextSuggestionService.SuggestionError) == .screenRecordingRequired)
            }
        }
    }

    private func cancelSuggestions() {
        suggestionGeneration &+= 1; suggestionTask?.cancel(); suggestionTask = nil
        suggestionTargetPID = nil; contextSuggestions.cancel(); suggestionsPanel.dismiss()
    }

    @objc private func configureShortcuts() {
        guard !demo else { return }
        let alert = NSAlert(); alert.messageText = "快捷指令访问"
        alert.informativeText = "允许后，你运行的快捷指令可新增文本，并读取本地内容、当前同步账号及仍可读取的共享板；旧账号缓存和已撤销共享不会提供。快捷指令后续动作可能把内容发送给其他应用或网络服务。关闭后，这些动作会返回无权访问。"
        let allow = NSButton(checkboxWithTitle: "允许快捷指令新增和读取 ClipShelf 内容", target: nil, action: nil)
        allow.state = preferences.bool(forKey: "shortcutsEnabled") ? .on : .off
        allow.frame = NSRect(x: 0, y: 0, width: 420, height: 32); alert.accessoryView = allow
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "保存")
        if alert.runModal() == .alertSecondButtonReturn {
            preferences.set(allow.state == .on, forKey: "shortcutsEnabled")
            ClipboardIntentRuntime.shared.enabled = allow.state == .on
        }
    }

    @objc private func exportBackup() {
        guard !demo, let store else { return }
        cancelSuggestions()
        panel.dismiss()
        let options = NSAlert(); options.messageText = "导出备份"
        options.informativeText = "备份包含剪贴板正文和附件。加密密码不会保存，遗忘后无法恢复。"
        let encrypt = NSButton(checkboxWithTitle: "使用密码加密备份", target: nil, action: nil); encrypt.state = .on
        let password = NSSecureTextField(); password.placeholderString = "密码（至少 8 个字符）"
        let repeatPassword = NSSecureTextField(); repeatPassword.placeholderString = "再次输入密码"
        let fields = NSStackView(views: [encrypt, password, repeatPassword]); fields.orientation = .vertical
        fields.alignment = .leading; fields.spacing = 10; fields.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        password.widthAnchor.constraint(equalToConstant: 420).isActive = true
        repeatPassword.widthAnchor.constraint(equalToConstant: 420).isActive = true
        options.accessoryView = fields; options.addButton(withTitle: "取消"); options.addButton(withTitle: "继续")
        guard options.runModal() == .alertSecondButtonReturn else { return }
        let secret: String? = encrypt.state == .on ? password.stringValue : nil
        if let secret, secret.count < 8 || secret.utf8.count > 1024 || secret != repeatPassword.stringValue {
            showError("密码未通过检查", detail: "请使用至少 8 个字符、最多 1024 字节的密码，并确保两次输入一致。")
            return
        }
        password.stringValue = ""; repeatPassword.stringValue = ""
        let save = NSSavePanel(); save.nameFieldStringValue = "ClipShelf-backup.clipshelf"
        save.title = "导出本地备份"; save.message = secret == nil ? "将导出未加密文件，请妥善保存。" : "将导出密码加密文件。"
        guard save.runModal() == .OK, let url = save.url else { return }
        Task { @MainActor [weak self] in
            do {
                try await Task.detached {
                    if let secret { try EncryptedBackupService.export(store: store, to: url, password: secret) }
                    else { try store.exportBackup(to: url) }
                }.value
                self?.setStatus("备份已导出。")
            }
            catch { self?.showError("导出失败", detail: "目标文件可能已存在，或没有写入权限。请选择新文件名。") }
        }
    }

    @objc private func restoreBackup() {
        guard !demo, let store else { return }
        cancelSuggestions()
        panel.dismiss()
        let open = NSOpenPanel(); open.allowsMultipleSelection = false; open.canChooseDirectories = false
        open.title = "选择 ClipShelf 备份"
        guard open.runModal() == .OK, let url = open.url else { return }
        let encrypted: Bool
        do { encrypted = try EncryptedBackupService.isEncrypted(url) }
        catch { showError("无法读取备份", detail: "请检查文件是否仍存在，以及是否有读取权限。"); return }
        var secret: String?
        if encrypted {
            let prompt = NSAlert(); prompt.messageText = "输入备份密码"
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
            prompt.accessoryView = password; prompt.addButton(withTitle: "取消"); prompt.addButton(withTitle: "继续")
            guard prompt.runModal() == .alertSecondButtonReturn else { return }
            secret = password.stringValue; password.stringValue = ""
        }
        let alert = NSAlert(); alert.messageText = "如何恢复备份？"
        alert.informativeText = "合并会保留现有内容，并将备份导入为独立本地内容；不会自动上传或传播云端删除。有关联同步数据的档案只允许合并。纯本地档案可替换；执行前会在本机数据目录保存未加密恢复副本。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "合并"); alert.addButton(withTitle: "替换")
        let choice = alert.runModal(); guard choice != .alertFirstButtonReturn else { return }
        let mode: BackupRestoreMode = choice == .alertSecondButtonReturn ? .merge : .replace
        let password = secret
        Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached {
                    if let password { return try EncryptedBackupService.restore(store: store, from: url, password: password, mode: mode) }
                    return try store.restoreBackup(from: url, mode: mode)
                }.value
                let scope = result.restoredAsLocalOnly ? "恢复内容仅保存在本机，尚未上传。" : ""
                self?.reload(); self?.setStatus("已恢复 \(result.importedRecords) 条内容。\(scope)恢复前副本保存在本机数据目录。")
            } catch { self?.showError("恢复失败", detail: "\(error.localizedDescription)\n现有数据保留。") }
        }
    }

    @objc private func changeRetention(_ sender: NSMenuItem) {
        guard !demo, let store else { return }
        let days = sender.tag
        if days == 0 { preferences.set(0, forKey: "retentionDays"); setStatus("历史保留期限：永久。"); return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        do {
            let count = try store.countHistory(before: cutoff)
            let alert = NSAlert(); alert.messageText = "改为保留 \(days) 天？"
            alert.informativeText = "\(count) 条历史记录会移出历史列表，固定内容保留。未固定内容的清理无法撤销。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "更改并清理")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            _ = try store.prune(before: cutoff)
            preferences.set(days, forKey: "retentionDays"); reload()
        } catch { setStatus("保留期限未更改，请检查本机数据。") }
    }

    @objc private func toggleLoginItem() {
        guard !demo else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); setStatus("已关闭登录启动。") }
            else { try SMAppService.mainApp.register(); setStatus("已请求登录启动，可在系统设置中管理。") }
        } catch { showError("无法更改登录启动", detail: "请将应用安装到 Applications，并在系统设置的登录项中检查状态。") }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        capture.stop(); hotKey.unregister(); stackHotKey.unregister(); stackKeys.stop(); stack.end(); paste.cancel()
        queryTask?.cancel(); pauseTimer?.invalidate(); retentionTimer?.invalidate()
        shareInboxTask?.cancel(); shareInboxTimer?.invalidate()
        intelligence.cancelRecognition(); intelligence.cancelSuggestions()
        cancelSuggestions()
        mcpSettings?.stop()
        cloudSettings?.stop()
        sharingSettings?.stop()
        ClipboardIntentRuntime.shared.store = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        for observer in [activationObserver].compactMap({ $0 }) + lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private static var demoRecords: [ClipboardRecord] {
        var result = [
            ClipboardRecord(text: "把复制的内容，放回你的工作流。\n\n唤起、找到、粘贴，然后继续。", sourceApp: "备忘录", copiedAt: Date()),
            ClipboardRecord(text: "https://github.com/Bestbbb/clipshelf", sourceApp: "Safari", copiedAt: Date().addingTimeInterval(-120)),
            ClipboardRecord(text: "struct ClipboardItem: Identifiable {\n    let id: UUID\n    let content: String\n}", sourceApp: "Xcode", copiedAt: Date().addingTimeInterval(-360)),
            ClipboardRecord(text: "#457B9D", sourceApp: "设计稿", copiedAt: Date().addingTimeInterval(-900)),
            ClipboardRecord(text: "会议笔记\n• 先把跨 App 的焦点恢复做好\n• 保持中文输入和键盘操作流畅\n• 用真实结果验证粘贴", sourceApp: "TextEdit", copiedAt: Date().addingTimeInterval(-1600))
        ]
        let fixture = NSImage(size: NSSize(width: 640, height: 400))
        fixture.lockFocus()
        NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.35, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor(calibratedRed: 0.82, green: 0.94, blue: 0.72, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 42, y: 44, width: 556, height: 312), xRadius: 24, yRadius: 24).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: NSColor.black]
        ("ClipShelf\nYour ideas, within reach." as NSString).draw(in: NSRect(x: 72, y: 146, width: 500, height: 110), withAttributes: attributes)
        fixture.unlockFocus()
        if let tiff = fixture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            result.append(ClipboardRecord(text: "图片 640 × 400", sourceApp: "合成演示", copiedAt: Date().addingTimeInterval(-1800),
                parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: png)])]))
        }
        let document = PDFDocument()
        for pageNumber in 1...2 {
            let pageImage = NSImage(size: NSSize(width: 500, height: 640))
            pageImage.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 500, height: 640).fill()
            ("ClipShelf PDF Demo\nPage \(pageNumber) of 2\n\nSynthetic content only." as NSString).draw(
                in: NSRect(x: 40, y: 360, width: 420, height: 210),
                withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            pageImage.unlockFocus()
            if let page = PDFPage(image: pageImage) { document.insert(page, at: document.pageCount) }
        }
        if let data = document.dataRepresentation(), document.pageCount == 2 {
            result.append(ClipboardRecord(text: "ClipShelf 合成 PDF · 2 页", sourceApp: "合成演示",
                copiedAt: Date().addingTimeInterval(-2000), parts: [ClipboardPart(representations: [
                    ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.pdf.rawValue, data: data)])]))
        }
        return result
    }
}
