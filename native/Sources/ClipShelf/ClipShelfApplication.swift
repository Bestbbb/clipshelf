import AppKit
import ClipShelfCore
import Carbon
import ServiceManagement
import UniformTypeIdentifiers
import AppIntents
import CloudKit
import PDFKit
import ClipShelfLocalization

@MainActor
final class ClipShelfApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let profile = RuntimeProfile.current
    private let demo = RuntimeProfile.current.mode == .demo
    private let validation = RuntimeProfile.current.mode == .validation
    private let preferences = RuntimeProfile.current.preferences
    private var store: HistoryStore?
    private var mcpSettings: MCPSettingsController?
    private var cloudSettings: CloudSyncSettingsController?
    private var sharingSettings: SharingSettingsController?
    private var storageSettings: StorageSettingsController?
    private var appUpdates: AppUpdateCoordinator?
    private var updateSettings: UpdateSettingsController?
    private var languageSettings: LanguageSettingsController?
    private var updateCheckItems: [NSMenuItem] = []
    private var ownedPublications: OwnedFilePublicationCoordinator?
    private var shareInbox: ShareInboxService?
    private var shareInboxUnavailableReason = L10n.text("此构建未配置系统分享扩展。")
    private var shareInboxTask: Task<Void, Never>?
    private var shareInboxTimer: Timer?
    private let panel = ClipboardPanelController()
    private let capture = CaptureService()
    private var captureIngestion: CaptureIngestionCoordinator<CapturePersistenceInput, RetainedClipboardRecords>?
    private let paste = PasteCoordinator()
    private let globalShortcuts = GlobalShortcutCoordinator()
    private var shortcutConfiguration = KeyboardShortcutConfiguration.defaults
    private var shortcutSettings: ShortcutSettingsController?
    private var shortcutConfigurationWarning: String?
    private var shortcutRegistrationFailures: [String] = []
    private var shortcutLayoutWarning: String?
    private var shortcutInputSourceObserver: Any?
    private let stack = StackCoordinator()
    private let stackPanel = StackPanelController()
    private let stackKeys = StackKeyMonitor()
    private lazy var stackGestures: StackPasteGestureCoordinator<PasteCoordinator.Target> = StackPasteGestureCoordinator(
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        isAvailable: { [weak self] in self?.stackInputIsAvailable == true },
        foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        captureTarget: { [weak self] in self?.paste.captureTarget() },
        targetPID: { $0.application.processIdentifier }
    )
    private let intelligence = LocalIntelligenceService()
    private let ocrCache: OCRDerivedCache = RuntimeProfile.current.validationDirectory.map {
        OCRDerivedCache(directory: $0.appendingPathComponent("OCR", isDirectory: true))
    } ?? .shared
    private let systemIntegration = SystemIntegrationController()
    private let contextSuggestions = ContextSuggestionService()
    private let suggestionsPanel = SuggestionPanelController()
    private var suggestionTask: Task<Void, Never>?
    private var suggestionGeneration: UInt64 = 0
    private var suggestionTargetPID: pid_t?
    private let pageQueries = HistoryPageQueryCoordinator<HistoryPanelReadResult>()
    private var pinboardReadGeneration = UUID()
    private var pinboardReorderInProgress = false
    private var ocrCleanupTask: Task<Void, Never>?
    private var ocrCleanupRequested = false
    private var pausedUntil: Date?
    private var pauseTimer: Timer?
    private var retentionTimer: Timer?
    private var retentionMenu: NSMenu?
    private var historyCleanup: HistoryCleanupCoordinator?
    private var cleanupConfirmation: HistoryCleanupConfirmationController?
    private var statusItem: NSStatusItem!
    private var recordingItem: NSMenuItem!
    private var retryCaptureItem: NSMenuItem!
    private var discardCaptureItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var activationItem: NSMenuItem!
    private var stackActivationItem: NSMenuItem!
    private var records: [ClipboardRecord] = []
    private var metadata: [ClipboardRecordMetadata] = []
    private var target: PasteCoordinator.Target?
    private var pasteDestinationChoices: [PasteCoordinator.Target] = []
    private var requiresPasteDestinationChoice = false
    private let pasteFeedback = PasteFeedbackController()
    private var statusMessage: String?
    private var activationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var suspensionReasons = Set<String>()
    private var outsideMonitor: Any?
    private var sessionSuspended = false
    private lazy var interactionLifecycle: ApplicationInteractionLifecycle = ApplicationInteractionLifecycle(
        allowsInteraction: { [weak self] in
            guard let self else { return false }
            return !self.sessionSuspended && !self.isTerminating && !self.terminationDecisionPending
        },
        cancelPendingPaste: { [weak self] in self?.cancelPendingInteraction() },
        cancelSuggestions: { [weak self] in self?.cancelSuggestions() },
        hideHistory: { [weak self] in self?.target = nil; self?.panel.hidePreservingDraft() },
        hideStack: { [weak self] in self?.stackPanel.suspend() }
    )
    private let historyUndo: UndoManager = {
        let manager = UndoManager(); manager.levelsOfUndo = 10; manager.groupsByEvent = false; return manager
    }()
    private lazy var selectionUndoHistory = SelectionUndoHistory(manager: historyUndo)
    @UpdateAvailabilityFlag private var selectionMutationInProgress = false {
        didSet {
            if oldValue && !selectionMutationInProgress {
                // Let the mutation's completion, Undo registration and refresh finish first.
                DispatchQueue.main.async { [weak self] in
                    self?.historyCleanup?.resumeDeferred()
                    self?.storageSettings?.requestAutomaticReclamation()
                    self?.storageSettings?.resumeDeferred()
                }
            }
        }
    }
    private var isDataMutationInProgress: Bool {
        selectionMutationInProgress || captureIngestion?.isProcessing == true || historyCleanup?.isBusy == true || storageSettings?.isBusy == true || terminationDecisionPending || isTerminating
    }
    private var imageOutputOperationID: UUID?
    private var isTerminating = false
    private var recordingBeforeTermination = false
    private var discardCapturesOnTermination = false
    @UpdateAvailabilityFlag private var terminationDecisionPending = false
    private let defaultExclusions = ["com.1password.1password", "com.agilebits.onepassword7",
                                     "com.bitwarden.desktop", "com.apple.Passwords"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.register(defaults: ["retentionDays": 30])
        let loadedShortcuts = KeyboardShortcutConfiguration.loadResult(from: preferences)
        shortcutConfiguration = loadedShortcuts.configuration
        shortcutConfigurationWarning = loadedShortcuts.warning
        configureMenu()
        configurePanel()
        configureAppUpdates()
        panel.applyShortcuts(shortcutConfiguration, alwaysPlainText: preferences.bool(forKey: "alwaysPlainText"))
        configureStack()
        configureSuggestions()
        if demo {
            installShortcutInputSourceObserver()
            records = Self.demoRecords
            statusMessage = L10n.text("演示模式 · 合成内容 · 不读取或写入系统剪贴板")
            refresh()
            panel.show(records: records, on: NSScreen.main, status: statusText)
            return
        }
        do {
            let directory = try profile.dataDirectory()
            store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"), recordsLocalOrigin: true)
            panel.ocrSourceStore = store
            panel.spaceCoordinator = store?.spaceCoordinator
            configureOwnedLifetimes(store: store!)
            configureHistoryCleanup()
            configureStorageManagement(store: store!)
            if profile.allowsBackgroundIntegrations {
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
            } else if validation, let store {
                let codeBoard = try store.createPinboard(name: "验收 · 代码", color: "#457B9D")
                let referenceBoard = try store.createPinboard(name: "验收 · 资料", color: "#AA7744")
                for (index, original) in Self.demoRecords.enumerated() {
                    var record = original
                    if index == 2 { record.pinboardID = codeBoard.id }
                    if [1, 6].contains(index) { record.pinboardID = referenceBoard.id }
                    _ = try store.create(record)
                }
                for record in try EditValidationFixtures.records(directory: directory) {
                    _ = try store.create(record)
                }
                if profile.includesSearchFixtures { try SearchValidationFixtures.populate(store) }
            }
            applyRetention()
            storageSettings?.requestRecovery()
            storageSettings?.requestAutomaticReclamation()
            reload()
        } catch {
            statusMessage = L10n.text("无法打开历史数据库，记录已停止。")
        }
        let excluded = preferences.stringArray(forKey: "excludedBundleIDs") ?? defaultExclusions
        systemIntegration.onImport = { [weak self] record in
            guard let self, let store = self.store else { throw ClipboardCodecError.noContent }
            let created = try store.create(record)
            self.reload(); self.scheduleOCR(for: created)
        }
        systemIntegration.onStatus = { [weak self] in self?.setStatus($0) }
        if profile.allowsBackgroundIntegrations {
            systemIntegration.registerServices()
            ClipboardIntentRuntime.shared.store = store
            ClipboardIntentRuntime.shared.enabled = preferences.bool(forKey: "shortcutsEnabled")
            ClipboardIntentRuntime.shared.onDataChanged = { [weak self] in self?.reload() }
            ClipShelfShortcuts.updateAppShortcutParameters()
        }
        capture.excludedBundleIDs = Set(excluded)
        configureCaptureIngestion()
        capture.onStatus = { [weak self] message in self?.setStatus(message) }
        paste.onResult = { [weak self] message in self?.setStatus(message) }
        paste.onFailureMessage = { [weak self] message in
            guard let self, self.interactionLifecycle.isAllowed, !self.panel.isVisible else { return }
            self.pasteFeedback.show(message, on: NSScreen.main)
        }
        globalShortcuts.onPressed = { [weak self] action, chord in
            guard let self else { return }
            guard self.interactionLifecycle.isAllowed else {
                ValidationTrace.emit(.invocationBlocked, state: .unavailable)
                return
            }
            if self.shortcutSettings?.captureRegisteredShortcut(chord) == true { return }
            guard self.shortcutSettings?.isKeyWindow != true else { return }
            switch action {
            case .activation: self.togglePanel()
            case .stack: self.toggleStack()
            }
        }
        do { shortcutRegistrationFailures = try globalShortcuts.start(shortcutConfiguration).map(\.localizedDescription) }
        catch { shortcutLayoutWarning = error.localizedDescription }
        if let message = shortcutRegistrationMessage { statusMessage = message }
        installShortcutInputSourceObserver()
        installObservers()
        if let deadline = preferences.object(forKey: "pauseUntil") as? Date, deadline > Date() {
            scheduleResume(at: deadline)
        } else if !validation, store != nil, preferences.bool(forKey: "recordingEnabled") { capture.start() }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyRetention()
                self?.storageSettings?.requestAutomaticReclamation()
            }
        }
        refresh()
        if store != nil, !preferences.bool(forKey: "hasSeenWelcome") {
            setStatus(L10n.text("欢迎使用 ClipShelf · 打开历史或选择开始记录以完成设置。"))
        }
    }

    private func configureCaptureIngestion() {
        guard let store else { return }
        let ingestion = CaptureIngestionCoordinator<CapturePersistenceInput, RetainedClipboardRecords> { input in
            try await CapturePersistence.save(input, to: store)
        }
        captureIngestion = ingestion
        capture.onSnapshot = { [weak self] snapshot in
            guard let self, self.interactionLifecycle.isAllowed else { return }
            let input = CapturePersistenceInput(snapshot: snapshot, stackSessionID: self.stack.isActive ? self.stack.sessionID : nil)
            if self.captureIngestion?.enqueue(input, byteCount: snapshot.byteCount) != true {
                self.capture.stop()
                self.preferences.set(false, forKey: "recordingEnabled")
                self.setStatus(L10n.text("保存队列已满，已暂停记录；本次复制未加入队列。请等待现有内容保存后继续，或丢弃待保存内容。"))
            }
        }
        ingestion.onSaved = { [weak self] input, retained in
            guard let self, !self.isTerminating, let stored = retained.records.first else { return }
            // An earlier capture must never enter a newly started Stack session.
            self.panel.didRecapture(stored)
            self.stack.appendCaptured(stored, lease: retained.lease, capturedIn: input.stackSessionID)
            if self.capture.isRunning { self.statusMessage = nil }
            self.scheduleOCR(for: stored)
        }
        ingestion.onFailure = { [weak self] _, error in
            guard let self, !self.isTerminating else { return }
            self.capture.stop()
            self.preferences.set(false, forKey: "recordingEnabled")
            var message = L10n.text("保存失败，已暂停记录；\(self.captureIngestion?.pendingCount ?? 0) 项内容暂存在内存。可在菜单中重试保存或丢弃。\n\(error.localizedDescription)")
            if let quotaError = error as? ContentQuotaError, case .exceeded = quotaError {
                message += "\n" + L10n.text("已达到保存数据上限。可打开“存储管理…”调高上限或选择不限，也可清理已有内容，然后明确重试保存。")
            }
            if self.captureBlocksOwnedReclamation {
                message += "\n" + L10n.text("待保存内容含文件引用，请先重试或丢弃这些内容，再回收托管文件。")
            }
            self.setStatus(message)
        }
        ingestion.onSettled = { [weak self] in
            guard let self, !self.isTerminating else { return }
            // A canceled operation may already have committed. Refresh the view,
            // without allowing its stale receipt to update Stack or status text.
            self.reload()
        }
        ingestion.onStateChanged = { [weak self] in
            guard let self else { return }
            self.refresh()
            if !self.isCaptureWriteBusy {
                self.historyCleanup?.resumeDeferred()
                self.storageSettings?.resumeDeferred()
            }
        }
    }

    private var isCaptureWriteBusy: Bool {
        guard let ingestion = captureIngestion else { return false }
        return ingestion.isProcessing || (ingestion.pendingCount > 0 && !ingestion.hasFailure)
    }

    private var captureBlocksOwnedReclamation: Bool {
        captureIngestion?.containsPending(where: { $0.blocksOwnedReclamation }) == true
    }

    @discardableResult
    private func discardPendingCapturesForPrivacy() -> Bool {
        let hadPending = (captureIngestion?.pendingCount ?? 0) > 0
        captureIngestion?.discardPending()
        if hadPending {
            statusMessage = L10n.text("已取消等待保存的内容；如需保留，请恢复记录后重新复制。已开始的写入可能仍会完成。")
        }
        return hadPending
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: L10n.text("ClipShelf 剪贴板"))
        let menu = NSMenu()
        menu.autoenablesItems = !validation
        let title = NSMenuItem(title: validation ? L10n.text("ClipShelf · 隔离验收") : (profile.isReleaseDistribution ? "ClipShelf" : L10n.text("ClipShelf · 开发预览")), action: nil, keyEquivalent: "")
        menu.addItem(title)
        stateItem = NSMenuItem(title: L10n.text("记录已暂停"), action: nil, keyEquivalent: "")
        menu.addItem(stateItem)
        menu.addItem(.separator())
        activationItem = item(L10n.text("打开剪贴板    \(shortcutConfiguration.activation.displayName)"), #selector(openFromMenu))
        menu.addItem(activationItem)
        recordingItem = item(L10n.text("开始记录"), #selector(toggleRecording))
        menu.addItem(recordingItem)
        retryCaptureItem = item(L10n.text("重试保存并继续记录"), #selector(retryCapturedContents))
        menu.addItem(retryCaptureItem)
        discardCaptureItem = item(L10n.text("丢弃未保存的内容…"), #selector(discardCapturedContents))
        menu.addItem(discardCaptureItem)
        permissionItem = item(L10n.text("开启直接粘贴…"), #selector(enableDirectPaste))
        menu.addItem(permissionItem)
        menu.addItem(item(L10n.text("排除应用…"), #selector(editExclusions)))
        let pauseMenuItem = NSMenuItem(title: L10n.text("定时暂停"), action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        for (label, minutes) in [(L10n.text("暂停 5 分钟"), 5), (L10n.text("暂停 30 分钟"), 30), (L10n.text("暂停 1 小时"), 60)] {
            let action = item(label, #selector(pauseFor(_:))); action.tag = minutes; pauseMenu.addItem(action)
        }
        pauseMenuItem.submenu = pauseMenu; menu.addItem(pauseMenuItem)
        stackActivationItem = item(L10n.text("顺序粘贴 Stack    \(shortcutConfiguration.stack.displayName)"), #selector(toggleStack))
        menu.addItem(stackActivationItem)
        menu.addItem(.separator())
        menu.addItem(item(L10n.text("新建文本…"), #selector(newText)))
        menu.addItem(item(L10n.text("从 iPhone 或 iPad 导入…"), #selector(importFromCamera)))
        menu.addItem(item(L10n.text("系统分享收件箱…"), #selector(checkShareInbox)))
        menu.addItem(item(L10n.text("允许快捷指令访问…"), #selector(configureShortcuts)))
        menu.addItem(item(L10n.text("导出备份…"), #selector(exportBackup)))
        menu.addItem(item(L10n.text("恢复备份…"), #selector(restoreBackup)))
        let retentionRoot = NSMenuItem(title: L10n.text("历史保留期限"), action: nil, keyEquivalent: "")
        let retentionMenu = NSMenu()
        self.retentionMenu = retentionMenu
        for (label, days) in [(L10n.text("1 天"), 1), (L10n.text("1 周"), 7), (L10n.text("1 月"), 30), (L10n.text("1 年"), 365), (L10n.text("永久"), 0)] {
            let entry = item(label, #selector(changeRetention(_:))); entry.tag = days; retentionMenu.addItem(entry)
        }
        retentionRoot.submenu = retentionMenu; menu.addItem(retentionRoot)
        menu.addItem(item(L10n.text("清空历史…"), #selector(clearHistory)))
        menu.addItem(item(L10n.text("存储管理…"), #selector(showStorageSettings)))
        menu.addItem(item(L10n.text("打开数据文件夹"), #selector(revealData)))
        menu.addItem(item(L10n.text("登录时启动…"), #selector(toggleLoginItem)))
        menu.addItem(item(L10n.text("设置…"), #selector(showSettings)))
        menu.addItem(item(L10n.text("语言 / Language…"), #selector(showLanguageSettings)))
        menu.addItem(item(L10n.text("MCP 与 AI 工具…"), #selector(showMCPSettings)))
        menu.addItem(item(L10n.text("智能建议…"), #selector(showSuggestions)))
        menu.addItem(item(L10n.text("iCloud 同步…"), #selector(showCloudSettings)))
        menu.addItem(item(L10n.text("共享板…"), #selector(showSharingSettings)))
        let checkUpdate = item(L10n.text("检查更新…"), #selector(checkAppUpdates))
        menu.addItem(checkUpdate); updateCheckItems.append(checkUpdate)
        menu.addItem(item(L10n.text("更新设置…"), #selector(showUpdateSettings)))
        menu.addItem(.separator())
        let quit = item(L10n.text("退出 ClipShelf"), #selector(quitApplication))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu

        let main = NSMenu()
        let appRoot = NSMenuItem()
        let appMenu = NSMenu()
        let appCheckUpdate = item(L10n.text("检查更新…"), #selector(checkAppUpdates))
        appMenu.addItem(appCheckUpdate); updateCheckItems.append(appCheckUpdate)
        appMenu.addItem(item(L10n.text("更新设置…"), #selector(showUpdateSettings)))
        appMenu.addItem(item(L10n.text("语言 / Language…"), #selector(showLanguageSettings)))
        let appQuit = NSMenuItem(title: L10n.text("退出 ClipShelf"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(appQuit)
        appRoot.submenu = appMenu
        main.addItem(appRoot)
        let editRoot = NSMenuItem(title: L10n.text("编辑"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L10n.text("编辑"))
        for (title, selector, key) in [
            (L10n.text("剪切"), #selector(NSText.cut(_:)), "x"),
            (L10n.text("复制"), #selector(NSText.copy(_:)), "c"),
            (L10n.text("粘贴"), #selector(NSText.paste(_:)), "v"),
            (L10n.text("全选"), #selector(NSText.selectAll(_:)), "a")
        ] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        editRoot.submenu = edit
        main.addItem(editRoot)
        let servicesRoot = NSMenuItem(title: L10n.text("服务"), action: nil, keyEquivalent: "")
        let services = NSMenu(title: L10n.text("服务")); servicesRoot.submenu = services
        appMenu.addItem(servicesRoot); NSApp.servicesMenu = services
        let camera = NSMenuItem(title: L10n.text("从设备导入"), action: nil, keyEquivalent: "")
        camera.identifier = NSMenuItem.importFromDeviceIdentifier; edit.addItem(camera)
        NSApp.mainMenu = main
    }

    private func configurePanel() {
        panel.ocrCache = ocrCache
        panel.onShareRecord = { [weak self] record in
            guard let self, !self.demo, let view = self.panel.window?.contentView else { return }
            do { try self.systemIntegration.share(record, from: view) }
            catch { self.setStatus(L10n.text("该内容当前无法分享，请检查原文件是否可用。")) }
        }
        panel.onImageFileOutput = { [weak self] records, directlyPaste in
            self?.outputImageFiles(records, directlyPaste: directlyPaste)
        }
        panel.setPreferredHeights(normal: CGFloat(demo ? 0 : preferences.double(forKey: "normalPanelHeight")),
                                  compact: CGFloat(demo ? 0 : preferences.double(forKey: "compactPanelHeight")))
        panel.onPreferredHeightChange = { [weak self] compact, height in
            guard let self, !self.demo, !self.validation else { return }
            self.preferences.set(Double(height), forKey: compact ? "compactPanelHeight" : "normalPanelHeight")
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
            guard let self, self.interactionLifecycle.isAllowed else { return }
            if self.demo { self.setStatus(L10n.text("演示：已选择「\(record.title)」；不会写入剪贴板。")); return }
            guard !self.requiresPasteDestinationChoice else { self.panel.requestPasteDestinationChoice(); return }
            self.paste.paste(record, plainText: self.outputAsPlainText([record], requested: plain), target: self.target) { self.panel.dismiss() }
        }
        panel.onCopy = { [weak self] record in
            guard let self, self.interactionLifecycle.isAllowed else { return }
            if self.demo { self.setStatus(L10n.text("演示模式不会写入系统剪贴板。")); return }
            if self.paste.copy(record) { self.setStatus(L10n.text("内容已复制，可在目标应用按 ⌘V。")) }
        }
        panel.onDelete = { [weak self] record in
            self?.deleteSelection([record])
        }
        panel.onPauseToggle = { [weak self] in self?.toggleRecording() }
        panel.onPermissions = { [weak self] in self?.enableDirectPaste() }
        panel.onSelectPasteDestination = { [weak self] pid in
            guard let self, self.panel.isVisible,
                  let selected = self.pasteDestinationChoices.first(where: { $0.application.processIdentifier == pid }),
                  !selected.application.isTerminated else { return }
            self.target = selected
            self.requiresPasteDestinationChoice = false
            self.panel.setPasteDestination(name: selected.application.localizedName,
                                           available: self.paste.hasPermission && selected.window != nil)
            ValidationTrace.emit(.destinationSelected, pid: pid, bundleID: selected.application.bundleIdentifier, state: .captured)
            self.setStatus(L10n.text("单击粘贴；⌘/Shift 单击多选；回车粘贴，Shift 回车以纯文本粘贴。"))
        }
        panel.onDismiss = { [weak self] in
            ValidationTrace.emit(.panelDismissed, state: .hidden)
            self?.paste.returnToTargetIfIdle(self?.target)
            self?.target = nil
            self?.pageQueries.cancel()
        }
        panel.onPasteRecords = { [weak self] selected, plain in
            guard let self, !self.demo, self.interactionLifecycle.isAllowed else { return }
            guard !self.requiresPasteDestinationChoice else { self.panel.requestPasteDestinationChoice(); return }
            self.paste.paste(selected, plainText: self.outputAsPlainText(selected, requested: plain), target: self.target) { self.panel.dismiss() }
        }
        panel.onCopyRecords = { [weak self] selected in
            guard let self, !self.demo, self.interactionLifecycle.isAllowed else { return }
            if self.paste.copy(selected) { self.setStatus(L10n.text("已复制 \(selected.count) 项。")) }
        }
        panel.onDeleteRecords = { [weak self] selected in
            self?.deleteSelection(selected)
        }
        panel.onPrepareEdit = { [weak self] reference, completion in
            guard let self else { completion(.failure(EditorOperationError.unavailable)); return }
            self.prepareEditor(reference, completion: completion)
        }
        panel.onEdit = { [weak self] snapshot, edited, completion in
            guard let self else { completion(.failure(EditorOperationError.unavailable)); return }
            self.saveEditor(edited, snapshot: snapshot, completion: completion)
        }
        panel.onEditPart = { [weak self] snapshot, edit, completion in
            guard let self else { completion(.failure(EditorOperationError.unavailable)); return }
            self.savePartEditor(edit, snapshot: snapshot, completion: completion)
        }
        panel.onNewText = { [weak self] in self?.newText() }
        if !demo {
            panel.onPageRequest = { [weak self] request, completion in
                self?.loadPage(request, completion: completion)
            }
            panel.onSelectionSnapshot = { [weak self] query, completion in
                self?.readSelection({ try $0.selectionSnapshot(query) }, completion: completion)
            }
            panel.onValidateSelection = { [weak self] references, completion in
                self?.readSelection({ try $0.validateSelection(references) }, completion: completion)
            }
            panel.resolveSelection = { [weak self] references, completion in
                self?.readSelection({ try $0.resolveSelection(references) }, completion: completion)
            }
            panel.resolveOutputSelection = { [weak self] references, completion in
                self?.readSelection({ try $0.resolveSelectionForRetainedOutput(references) }) { result in
                    switch result {
                    case .success(let retained): withExtendedLifetime(retained) { completion(.success(retained.records)) }
                    case .failure(let error): completion(.failure(error))
                    }
                }
            }
            panel.onMoveSelection = { [weak self] references, boardID, completion in
                self?.moveSelection({ try $0.moveSelection(references, to: boardID) }, completion: completion)
            }
            panel.onReorderSelection = { [weak self] references, boardID, before, completion in
                self?.moveSelection({ try $0.moveSelection(references, to: boardID, before: before) }, completion: completion)
            }
            panel.onStepSelection = { [weak self] references, boardID, forward, completion in
                self?.moveSelection({ try $0.stepSelection(references, boardID: boardID, forward: forward) }, completion: completion)
            }
        }
        panel.onCreatePinboard = { [weak self] name, color in
            guard let self, !self.demo, self.mutationIsAvailable() else { return }
            do { _ = try self.store?.createPinboard(name: name, color: color); self.reload() }
            catch { self.setStatus(L10n.text("无法创建分组，请检查名称与颜色。")) }
        }
        panel.onUpdatePinboard = { [weak self] board in
            guard let self, !self.demo, self.mutationIsAvailable() else { return }
            do { try self.store?.updatePinboard(board); self.reload() }
            catch { self.setStatus(L10n.text("无法更新分组，请重试。")) }
        }
        panel.onReorderPinboards = { [weak self] ids, expectedOrder, completion in
            guard let self, !self.demo else {
                completion(.failure(HistoryStoreError.recordNotFound)); return
            }
            self.reorderPinboards(ids: ids, expectedOrder: expectedOrder, completion: completion)
        }
        panel.onReorderRecords = { [weak self] boardID, ids, beforeID, revisions, completion in
            guard let self, !self.demo else {
                completion(.failure(HistoryStoreError.recordNotFound)); return
            }
            let references = ids.compactMap { id in revisions[id].map { ClipboardSelectionReference(id: id, revision: $0) } }
            guard references.count == ids.count else { completion(.failure(HistoryStoreError.recordNotFound)); return }
            let anchor = beforeID.flatMap { id in revisions[id].map { ClipboardSelectionReference(id: id, revision: $0) } }
            guard beforeID == nil || anchor != nil else { completion(.failure(HistoryStoreError.recordNotFound)); return }
            self.moveSelection({ store in
                try store.moveSelection(references, to: boardID, before: anchor)
            }) { result in
                completion(result.map { _ in () })
            }
        }
        panel.onDeletePinboard = { [weak self] board in self?.deletePinboard(board) }
        panel.onMoveRecords = { [weak self] selected, boardID in
            guard let self, !self.demo else { return }
            let references = selected.map { ClipboardSelectionReference(id: $0.id, revision: $0.revision) }
            self.moveSelection({ try $0.moveSelection(references, to: boardID) }) { [weak self] result in
                if case .failure = result { self?.setStatus(L10n.text("内容已改变或无法移动，本次移动未保存；请刷新后重试。")) }
            }
        }
        panel.onExtractText = { [weak self] record in self?.extractText(record) }
        panel.onOpenRecord = { [weak self] record in self?.openRecord(record) }
        panel.onFileSnapshot = { [weak self] reference, completion in
            guard let self else { completion(.failure(HistoryStoreError.recordNotFound)); return }
            self.loadFileRepairSnapshot(reference, completion: completion)
        }
        panel.onRelocateFile = { [weak self] snapshot, file, url, completion in
            guard let self else { completion(.failure(HistoryStoreError.recordNotFound)); return }
            self.relocateFile(snapshot, file: file, to: url, completion: completion)
        }
        panel.onRestoreOwnedFile = { [weak self] snapshot, file, completion in
            guard let self else { completion(.failure(HistoryStoreError.recordNotFound)); return }
            self.restoreOwnedFile(snapshot, file: file, completion: completion)
        }
        panel.onSettings = { [weak self] in self?.showSettings() }
        panel.onUndo = { [weak self] in
            guard let self, !self.isDataMutationInProgress else { return }
            self.historyUndo.undo()
        }
        panel.onDropItems = { [weak self] items, boardID in
            guard let self, !self.demo, self.mutationIsAvailable() else { return }
            do {
                if var record = try ClipboardCodec.record(from: items, sourceApp: L10n.text("拖入"), sourceBundleID: nil) {
                    record.pinboardID = boardID
                    let stored = try self.store?.create(record)
                    self.reload()
                    if let stored { self.scheduleOCR(for: stored) }
                }
            } catch { self.setStatus(L10n.text("拖入失败，原有内容未改变。")) }
        }
    }

    private func installObservers() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                ValidationTrace.emit(.workspaceActivated, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                                     state: self.panel.isVisible ? .visible : .hidden)
                self.stackGestures.invalidate()
                self.capture.noteFrontmostApplication(bundleID: app.bundleIdentifier)
                self.paste.applicationDidActivate(processIdentifier: app.processIdentifier)
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                if let pid = self.suggestionTargetPID, app.processIdentifier != pid { self.cancelSuggestions() }
                if self.panel.isVisible, self.panel.hasOpenEditor || app.processIdentifier != self.target?.application.processIdentifier {
                    ValidationTrace.emit(.workspaceHidesPanel, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                                         state: .hidden)
                    self.paste.cancel()
                    self.panel.hidePreservingDraft()
                }
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Use the event's position, not where the pointer has moved by
                // the time AppKit delivers the global monitor callback.
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                guard !self.panel.contains(screenPoint: point) else { return }
                guard self.panel.isVisible else {
                    if self.paste.cancelForMouseDown(at: event.timestamp) {
                        ValidationTrace.emit(.outsideClick, state: .hidden)
                        self.stackGestures.invalidate(); self.stack.cancelPendingPastes()
                    } else if !self.paste.hasPendingAttempt {
                        self.stackGestures.invalidate(); self.stack.cancelPendingPastes()
                    }
                    self.cancelSuggestions()
                    return
                }
                ValidationTrace.emit(.outsideClick, state: self.panel.isVisible ? .visible : .hidden)
                self.cancelPendingInteraction(); self.panel.hidePreservingDraft(); self.cancelSuggestions()
            }
        }
        interactionLifecycle.observeSpaces(in: NSWorkspace.shared.notificationCenter)
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
            pasteFeedback.hide()
            historyCleanup?.cancelPending()
            storageSettings?.suspend()
            languageSettings?.suspend()
            interactionLifecycle.invalidateContext(); capture.stop(); discardPendingCapturesForPrivacy(); stackKeys.stop()
            if let shareInbox { Task { try? await shareInbox.publishDestinations(allowImports: false) } }
        } else {
            if !validation, preferences.bool(forKey: "recordingEnabled"), pausedUntil == nil, store != nil { capture.start() }
            refreshStackPresentation()
            processShareInbox()
            applyRetention()
            historyCleanup?.resumeDeferred()
            storageSettings?.requestRecovery()
            storageSettings?.requestAutomaticReclamation()
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
            if userInitiated { setStatus(L10n.text("会话恢复后才能导入系统分享。")) }
            return
        }
        guard let shareInbox else {
            if userInitiated { showError(L10n.text("系统分享暂不可用"), detail: shareInboxUnavailableReason) }
            return
        }
        guard shareInboxTask == nil else {
            if userInitiated { setStatus(L10n.text("正在检查系统分享收件箱，请稍候。")) }
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
                    self.setStatus(L10n.text("已导入 \(result.imported) 条系统分享；\(result.failures.count) 项尚未导入，内容保留在收件箱。"))
                    if userInitiated {
                        self.showError(L10n.text("部分分享尚未导入"), detail: result.failures.prefix(3).map(\.message).joined(separator: "\n"))
                    }
                } else if result.imported > 0 || userInitiated {
                    self.setStatus(result.imported > 0 ? L10n.text("已导入 \(result.imported) 条系统分享。") : L10n.text("系统分享收件箱已检查，没有待导入内容。"))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setStatus(L10n.text("系统分享导入未完成，内容保留在收件箱。"))
                if userInitiated { self.showError(L10n.text("系统分享导入未完成"), detail: error.localizedDescription) }
            }
        }
    }

    @objc private func checkShareInbox() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performCheckShareInbox() }
    }

    private func performCheckShareInbox() {
        guard !demo else { return }
        cancelSuggestions()
        guard shareInbox != nil else { processShareInbox(userInitiated: true); return }
        let alert = NSAlert(); alert.messageText = L10n.text("系统分享收件箱")
        alert.informativeText = L10n.text("通过其他应用的分享菜单保存的内容会自动导入。如果上次导入因退出而中断，可以重试未确认项；请先检查历史，避免重复保存已手动恢复的内容。")
        alert.addButton(withTitle: L10n.text("检查收件箱")); alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("重试中断项"))
        let choice = alert.runLocalizedModal()
        guard choice != .alertSecondButtonReturn else { return }
        processShareInbox(retryUncertain: choice == .alertThirdButtonReturn, userInitiated: true)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if validation, [#selector(toggleRecording), #selector(pauseFor(_:)), #selector(toggleLoginItem),
                        #selector(showMCPSettings), #selector(showCloudSettings), #selector(showSharingSettings),
                        #selector(showSuggestions), #selector(importFromCamera), #selector(configureShortcuts),
                        #selector(checkShareInbox)].contains(action) { item.isEnabled = false }
        return item
    }

    private var statusText: String {
        if let statusMessage { return validation ? L10n.text("隔离验收 · \(statusMessage)") : statusMessage }
        if validation { return L10n.text("隔离验收 · 合成内容 · 记录关闭 · \(paste.hasPermission ? L10n.text("直接粘贴可用") : L10n.text("辅助功能未授权，仅复制"))") }
        let recording = capture.isRunning ? L10n.text("记录中") : L10n.text("记录已暂停")
        let mode = paste.hasPermission ? L10n.text("直接粘贴可用") : L10n.text("复制模式 · 授权后可直接粘贴")
        return L10n.text("\(recording) · \(demo ? records.count : metadata.count) 条结果 · \(mode)")
    }

    private func reload() {
        guard let store else { refresh(); return }
        requestOCRCleanup(store: store)
        panel.refreshPage(status: statusText)
        refresh()
    }

    private func loadPage(_ request: PanelPageRequest,
                          completion: @escaping (Result<PanelHistoryPage, Error>) -> Void) {
        guard let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        let boardGeneration = pinboardReadGeneration
        pageQueries.submit(read: { cancellation in
            func checkCancellation() throws {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
            }
            var query = request.query
            query.limit = PanelPageWindow.size
            let page = try store.metadataPage(query, offset: request.offset,
                anchorID: request.anchor?.recordID, displacement: request.anchor?.displacement ?? 0,
                boundary: request.boundary, cancellation: cancellation)
            try checkCancellation()
            let boards = try store.pinboards(cancellation: cancellation)
            try checkCancellation()
            let sources = try store.metadataSources(cancellation: cancellation)
            try checkCancellation()
            let devices = try store.metadataDevices(cancellation: cancellation)
            try checkCancellation()
            let localDevice = try store.localDeviceIdentity(cancellation: cancellation)
            return HistoryPanelReadResult(page: page, pinboards: boards, sources: sources,
                                          devices: devices, localDeviceID: localDevice.id)
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let result):
                self.metadata = result.page.records
                // A list-order write does not invalidate the content page. Finish its
                // callback, but never let an older list read undo the saved tab order.
                if !self.pinboardReorderInProgress, self.pinboardReadGeneration == boardGeneration {
                    self.panel.setPinboards(result.pinboards)
                }
                self.panel.setSources(result.sources)
                self.panel.setDevices(result.devices, localDeviceID: result.localDeviceID)
                completion(.success(PanelHistoryPage(records: result.page.records, offset: result.page.offset,
                    hasMore: result.page.hasMore, focusID: result.page.focusID)))
                self.refresh()
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    private func readSelection<Value: Sendable>(
        _ operation: @escaping @Sendable (HistoryStore) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        guard let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        Task { @MainActor in
            do { completion(.success(try await Task.detached(priority: .userInitiated) { try operation(store) }.value)) }
            catch { completion(.failure(error)) }
        }
    }

    private func reorderPinboards(ids: [UUID], expectedOrder: [UUID],
                                  completion: @escaping (Result<[Pinboard], Error>) -> Void) {
        guard let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        guard !isDataMutationInProgress else { completion(.failure(SelectionOperationError.busy)); return }
        selectionMutationInProgress = true
        pinboardReorderInProgress = true
        pinboardReadGeneration = UUID()
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try store.reorderPinboards(ids: ids, expectedOrder: expectedOrder)
                }
            }.value
            selectionMutationInProgress = false
            pinboardReorderInProgress = false
            pinboardReadGeneration = UUID()
            completion(result)
            // Read the current query, including any search/navigation done during
            // the save. Existing page callbacks still finish, so none stay pending.
            reload()
        }
    }

    private func moveSelection(
        _ operation: @escaping @Sendable (HistoryStore) throws -> HistorySelectionMoveUndo,
        completion: @escaping (Result<[ClipboardSelectionReference], Error>) -> Void
    ) {
        guard let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        guard !isDataMutationInProgress else { completion(.failure(SelectionOperationError.busy)); return }
        selectionMutationInProgress = true
        Task { @MainActor in
            defer { selectionMutationInProgress = false }
            do {
                let undo = try await Task.detached(priority: .userInitiated) { try operation(store) }.value
                selectionUndoHistory.register(.move(undo)) { [weak self] in self?.undoSelection($0, store: store) }
                completion(.success(undo.references))
                reload()
            } catch { completion(.failure(error)) }
        }
    }

    private func deleteSelection(_ selected: [ClipboardRecord]) {
        guard !selected.isEmpty else { return }
        if demo {
            let ids = Set(selected.map(\.id))
            records.removeAll { ids.contains($0.id) }
            refresh()
            return
        }
        guard let store else { return }
        guard !isDataMutationInProgress else { setStatus(SelectionOperationError.busy.localizedDescription); return }
        guard SelectionUndoTicket.payloadSize(selected) <= selectionUndoHistory.maximumPayloadBytes else {
            setStatus(L10n.text("所选内容过大，无法保留整批撤销；请缩小选择后重试。"))
            return
        }
        selectionMutationInProgress = true
        let references = selected.map { ClipboardSelectionReference(id: $0.id, revision: $0.revision) }
        Task { @MainActor in
            defer { selectionMutationInProgress = false }
            do {
                let undo = try await Task.detached(priority: .userInitiated) { try store.deleteSelection(references) }.value
                selectionUndoHistory.register(.deletion(selected, undo)) { [weak self] in self?.undoSelection($0, store: store) }
                reload()
            } catch {
                setStatus(L10n.text("所选内容已改变或不可删除；本次整批删除未保存。"))
                reload()
            }
        }
    }

    private func undoSelection(_ ticket: SelectionUndoTicket, store: HistoryStore) {
        guard !isDataMutationInProgress else { return }
        selectionMutationInProgress = true
        let action = ticket.action
        let presentUndo = panel.captureUndoPresentation()
        Task { @MainActor in
            defer { selectionMutationInProgress = false }
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    switch action {
                    case .move(let undo): return try store.undoSelectionMove(undo)
                    case .deletion(let records, let undo): return try store.restoreDeletedSelection(records, undo: undo)
                    case .edit(let undo): return try store.undoSelectionEdit(undo)
                    }
                }.value
                selectionUndoHistory.remove(ticket)
                if selectionUndoHistory.rebaseActions(using: store, receipt: receipt) > 0 {
                    setStatus(L10n.text("已撤销；部分更早的撤销记录已失效。"))
                }
                requestOCRCleanup(store: store)
                refresh()
                presentUndo(receipt.references)
            } catch {
                if SelectionUndoHistory.isRetryableFailure(error),
                   selectionUndoHistory.retainForRetry(ticket, handler: { [weak self] in self?.undoSelection($0, store: store) }) {
                    setStatus(L10n.text("撤销未完成，已保留重试机会：\(error.localizedDescription)"))
                } else {
                    selectionUndoHistory.remove(ticket)
                    setStatus(L10n.text("本次撤销已失效，相关内容、分组或同步状态已改变；没有部分恢复。"))
                }
                reload()
            }
        }
    }

    private enum SelectionOperationError: Error, LocalizedError {
        case busy
        var errorDescription: String? { L10n.text("正在完成修改、撤销或历史清理，请稍后再试。") }
    }

    private func mutationIsAvailable() -> Bool {
        guard !isDataMutationInProgress else { setStatus(SelectionOperationError.busy.localizedDescription); return false }
        return true
    }

    private func requestOCRCleanup(store: HistoryStore) {
        ocrCleanupRequested = true
        guard ocrCleanupTask == nil else { return }
        ocrCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.ocrCleanupTask = nil }
            repeat {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                self.ocrCleanupRequested = false
                try? await self.ocrCache.purgeStaleEntries(using: store)
            } while self.ocrCleanupRequested && !Task.isCancelled
        }
    }

    private func refresh() {
        appUpdates?.refreshAvailability()
        stateItem?.title = demo ? L10n.text("演示模式 · 记录关闭") : (capture.isRunning ? L10n.text("正在记录") : L10n.text("记录已暂停"))
        recordingItem?.title = capture.isRunning ? L10n.text("暂停记录") : L10n.text("开始记录")
        recordingItem?.isEnabled = !demo && !validation && store != nil
        let pendingCaptures = captureIngestion?.pendingCount ?? 0
        retryCaptureItem?.isHidden = captureIngestion?.hasFailure != true
        retryCaptureItem?.isEnabled = !demo && !validation && interactionLifecycle.isAllowed && captureIngestion?.isProcessing != true
        discardCaptureItem?.isHidden = pendingCaptures == 0
        discardCaptureItem?.isEnabled = interactionLifecycle.isAllowed
        permissionItem?.isEnabled = !demo
        permissionItem?.title = paste.hasPermission ? L10n.text("检查直接粘贴权限…") : L10n.text("开启直接粘贴…")
        statusItem?.button?.toolTip = "ClipShelf · \(capture.isRunning ? L10n.text("记录中") : L10n.text("已暂停"))"
        activationItem?.title = L10n.text("打开剪贴板    \(shortcutConfiguration.activation.displayName)")
        stackActivationItem?.title = L10n.text("顺序粘贴 Stack    \(shortcutConfiguration.stack.displayName)")
        for entry in retentionMenu?.items ?? [] {
            entry.state = entry.tag == preferences.integer(forKey: "retentionDays") ? .on : .off
        }
        panel.setCapturePaused(!capture.isRunning, recordingAllowed: !validation)
        if demo { panel.update(records: records, status: statusText) }
        else { panel.updateStatus(statusText) }
    }

    private func setStatus(_ message: String) { statusMessage = message; refresh() }

    private func outputAsPlainText(_ selected: [ClipboardRecord], requested: Bool) -> Bool {
        requested || (preferences.bool(forKey: "alwaysPlainText") && selected.allSatisfy(ClipboardCodec.supportsPlainText))
    }

    @objc private func openFromMenu() { togglePanel() }

    private func togglePanel(forApplicationLaunch: Bool = false) {
        ValidationTrace.emit(.invocation, state: panel.isVisible ? .visible : .hidden)
        interactionLifecycle.prepareForInvocation { self.performTogglePanel(forApplicationLaunch: forApplicationLaunch) }
    }

    private func performTogglePanel(forApplicationLaunch: Bool = false) {
        pasteFeedback.hide()
        if let window = cleanupConfirmation?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if panel.isVisible { panel.dismiss(); return }
        if !demo, store == nil {
            showError(L10n.text("历史数据库未能打开"), detail: L10n.text("原有文件会保留。请检查本机磁盘和数据目录权限后重新启动。"))
            return
        }
        target = paste.captureTarget(forApplicationLaunch: forApplicationLaunch)
        requiresPasteDestinationChoice = forApplicationLaunch && target == nil && paste.hasPermission
        pasteDestinationChoices = requiresPasteDestinationChoice ? paste.destinationChoices() : []
        if pasteDestinationChoices.isEmpty { requiresPasteDestinationChoice = false }
        panel.setPasteDestinations(pasteDestinationChoices.map { ($0.application.processIdentifier, $0.application.localizedName ?? "ClipShelf") },
                                   selectedPID: target?.application.processIdentifier)
        panel.setPasteDestination(name: target?.application.localizedName,
                                  available: paste.hasPermission && target?.window != nil,
                                  requiresChoice: requiresPasteDestinationChoice)
        if !demo, !preferences.bool(forKey: "hasSeenWelcome"), !showWelcome() { return }
        statusMessage = demo ? L10n.text("演示模式 · 合成内容 · 不读取或写入系统剪贴板")
            : requiresPasteDestinationChoice ? L10n.text("从应用图标打开时，请先选择接收内容的应用。") : nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if demo { panel.show(records: records, on: screen, status: statusText) }
        else { panel.show(metadata: [], on: screen, status: statusText) }
        ValidationTrace.emit(.panelShown, state: panel.isVisible ? .visible : .hidden)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ValidationTrace.emit(.reopen, state: panel.isVisible ? .visible : .hidden)
        if !panel.isVisible { togglePanel(forApplicationLaunch: true) }
        return true
    }

    @objc private func toggleRecording() {
        guard !demo, !validation, store != nil, interactionLifecycle.isAllowed else { return }
        if !preferences.bool(forKey: "hasSeenWelcome") { showWelcome(); return }
        cancelSuggestions()
        statusMessage = nil
        if capture.isRunning {
            capture.stop(); discardPendingCapturesForPrivacy()
        } else {
            captureIngestion?.retry(); capture.start()
        }
        pauseTimer?.invalidate(); pausedUntil = nil
        preferences.removeObject(forKey: "pauseUntil")
        preferences.set(capture.isRunning, forKey: "recordingEnabled")
        refresh()
    }

    @objc private func retryCapturedContents() {
        guard !demo, !validation, store != nil, interactionLifecycle.isAllowed,
              captureIngestion?.hasFailure == true, captureIngestion?.isProcessing != true else { return }
        captureIngestion?.retry()
        capture.start()
        pauseTimer?.invalidate(); pausedUntil = nil
        preferences.removeObject(forKey: "pauseUntil")
        preferences.set(true, forKey: "recordingEnabled")
        setStatus(L10n.text("正在重试保存并继续记录。"))
    }

    @objc private func discardCapturedContents() {
        guard interactionLifecycle.isAllowed, let ingestion = captureIngestion, ingestion.pendingCount > 0 else { return }
        let wasRecording = capture.isRunning
        capture.stop() // Freeze the confirmation scope; no later copy joins this batch.
        let alert = NSAlert()
        alert.messageText = L10n.text("丢弃未保存的内容？")
        alert.informativeText = L10n.text("这 \(ingestion.pendingCount) 项尚未确认保存，仅保留在内存中。丢弃后需要重新复制；已经开始的写入可能仍会完成。")
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("丢弃"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runLocalizedModal() == .alertSecondButtonReturn, interactionLifecycle.isAllowed else {
            if wasRecording, interactionLifecycle.isAllowed, !ingestion.hasFailure,
               preferences.bool(forKey: "recordingEnabled") { capture.start() }
            refresh()
            return
        }
        capture.stop(); ingestion.discardPending()
        preferences.set(false, forKey: "recordingEnabled")
        setStatus(L10n.text("已丢弃尚未开始的保存请求；已开始的写入可能仍会完成。"))
    }

    @objc private func enableDirectPaste() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performEnableDirectPaste() }
    }

    private func performEnableDirectPaste() {
        guard !demo else { return }
        paste.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        setStatus(L10n.text("在系统设置中允许 ClipShelf 使用辅助功能，然后重新打开面板。"))
    }

    @objc private func editExclusions() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performEditExclusions() }
    }

    private func performEditExclusions() {
        guard !demo else { return }
        cancelSuggestions()
        let alert = NSAlert()
        alert.messageText = L10n.text("排除应用")
        alert.informativeText = L10n.text("这些应用中之后复制的内容不会记录。填写应用的 Bundle ID，用逗号或换行分隔；已有历史不会自动删除。")
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = true; field.isSelectable = true; field.isBordered = true
        field.drawsBackground = true
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 95)
        field.stringValue = capture.excludedBundleIDs.sorted().joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("保存"))
        alert.addButton(withTitle: L10n.text("取消"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runLocalizedModal() == .alertFirstButtonReturn {
            let values = field.stringValue.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if capture.excludedBundleIDs != Set(values) { discardPendingCapturesForPrivacy() }
            capture.excludedBundleIDs = Set(values)
            preferences.set(values, forKey: "excludedBundleIDs")
            refresh()
        }
    }

    @objc private func newText() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performNewText() }
    }

    private func performNewText() {
        guard !demo, store != nil, mutationIsAvailable() else { return }
        cancelSuggestions()
        let alert = NSAlert()
        alert.messageText = L10n.text("新建文本")
        alert.informativeText = L10n.text("保存到本地历史，可从面板搜索和粘贴。")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .systemFont(ofSize: 14)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.text("保存")); alert.addButton(withTitle: L10n.text("取消"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runLocalizedModal() == .alertFirstButtonReturn, !text.string.isEmpty, mutationIsAvailable() {
            do {
                _ = try store?.create(ClipboardRecord(text: text.string, sourceApp: "ClipShelf",
                                                      sourceBundleID: Bundle.main.bundleIdentifier))
                reload()
            } catch { showError(L10n.text("保存失败"), detail: L10n.text("原有历史未改变，请检查本机磁盘空间。")) }
        }
    }

    @objc private func clearHistory() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performClearHistory() }
    }

    private func performClearHistory() {
        guard !demo, store != nil, !sessionSuspended, !isTerminating, !terminationDecisionPending else { return }
        if historyCleanup?.start(.clearHistory) == .ignored {
            setStatus(L10n.text("请先完成或取消当前历史清理。"))
            cleanupConfirmation?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func revealData() {
        guard !demo else { return }
        if let directory = try? profile.dataDirectory() { NSWorkspace.shared.open(directory) }
    }

    @discardableResult
    private func showWelcome() -> Bool {
        guard !isTerminating, !validation else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.text("欢迎使用 ClipShelf")
        alert.informativeText = L10n.text("ClipShelf 在本机保存之后复制的文字、图片和文件引用。使用 \(shortcutConfiguration.activation.displayName) 打开历史，\(shortcutConfiguration.stack.displayName) 使用顺序粘贴；可在设置中更改快捷键。\n\n你可以随时从菜单栏暂停记录或排除应用。直接粘贴需要单独授予辅助功能权限；未授权仍可复制后手动粘贴。")
        alert.addButton(withTitle: L10n.text("开始记录")); alert.addButton(withTitle: L10n.text("稍后"))
        alert.addButton(withTitle: L10n.text("语言 / Language…"))
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runLocalizedModal()
        if choice == .alertThirdButtonReturn {
            showLanguageSettings()
            return false
        }
        preferences.set(true, forKey: "hasSeenWelcome")
        if choice == .alertFirstButtonReturn, store != nil {
            capture.start(); preferences.set(true, forKey: "recordingEnabled")
        }
        refresh()
        return true
    }

    private func prepareEditor(_ reference: ClipboardSelectionReference,
                               completion: @escaping (Result<ClipboardEditSnapshot, Error>) -> Void) {
        guard !isTerminating else { completion(.failure(EditorOperationError.unavailable)); return }
        if demo {
            guard let record = records.first(where: { $0.id == reference.id && $0.revision == reference.revision }) else {
                completion(.failure(EditorOperationError.changed)); return
            }
            completion(.success(ClipboardEditSnapshot(record: record)))
            return
        }
        readSelection({ try $0.prepareEdit(reference) }) { result in
            completion(result.mapError { EditorOperationError.wrapping($0) })
        }
    }

    private func saveEditor(_ edited: ClipboardRecord, snapshot: ClipboardEditSnapshot,
                            completion: @escaping (Result<ClipboardSelectionReference, Error>) -> Void) {
        guard !isTerminating else { completion(.failure(EditorOperationError.unavailable)); return }
        if demo {
            guard let index = records.firstIndex(where: { $0 == snapshot.record }),
                  edited.id == snapshot.record.id, edited.revision == snapshot.record.revision,
                  edited.revision < Int.max else { completion(.failure(EditorOperationError.changed)); return }
            var updated = edited; updated.revision += 1
            records[index] = updated
            completion(.success(.init(id: updated.id, revision: updated.revision)))
            refresh()
            return
        }
        guard let store else { completion(.failure(EditorOperationError.unavailable)); return }
        guard !isDataMutationInProgress else { completion(.failure(SelectionOperationError.busy)); return }
        selectionMutationInProgress = true
        Task { @MainActor in
            do {
                let undo = try await ClipboardEditCommitter.commit(edited, snapshot: snapshot,
                                                                 store: store, cache: ocrCache)
                selectionUndoHistory.register(.edit(undo)) { [weak self] in self?.undoSelection($0, store: store) }
                selectionMutationInProgress = false
                completion(.success(undo.committedReference))
                reload()
            } catch {
                selectionMutationInProgress = false
                completion(.failure(EditorOperationError.wrapping(error)))
            }
        }
    }

    private func savePartEditor(_ edit: ClipboardPartEdit, snapshot: ClipboardEditSnapshot,
                                completion: @escaping (Result<ClipboardSelectionReference, Error>) -> Void) {
        guard !isTerminating else { completion(.failure(EditorOperationError.unavailable)); return }
        if demo {
            do { saveEditor(try edit.applying(to: snapshot.record), snapshot: snapshot, completion: completion) }
            catch { completion(.failure(EditorOperationError.wrapping(error))) }
            return
        }
        guard let store else { completion(.failure(EditorOperationError.unavailable)); return }
        guard !isDataMutationInProgress else { completion(.failure(SelectionOperationError.busy)); return }
        selectionMutationInProgress = true
        Task { @MainActor in
            do {
                let undo = try await ClipboardEditCommitter.commitPartEdit(edit, snapshot: snapshot,
                                                                         store: store, cache: ocrCache)
                selectionUndoHistory.register(.edit(undo)) { [weak self] in self?.undoSelection($0, store: store) }
                selectionMutationInProgress = false
                completion(.success(undo.committedReference))
                reload()
            } catch {
                selectionMutationInProgress = false
                completion(.failure(EditorOperationError.wrapping(error)))
            }
        }
    }

    private enum EditorOperationError: LocalizedError {
        case unavailable, changed, removed, tooLarge, accountChanged, failed
        var errorDescription: String? {
            switch self {
            case .unavailable: return L10n.text("资料库暂不可用，请稍后重试。")
            case .changed: return L10n.text("原条目或资料库已变化，未覆盖现有内容。草稿仍保留，可复制所需内容后重新打开条目。")
            case .removed: return L10n.text("原条目已被删除，未保存修改。草稿仍保留。")
            case .tooLarge: return L10n.text("内容过大，无法保留完整撤销，本次修改未保存。")
            case .accountChanged: return L10n.text("同步账号已变化，旧草稿不能保存到当前账号。草稿仍保留。")
            case .failed: return L10n.text("保存失败，请稍后重试。草稿仍保留。")
            }
        }
        static func wrapping(_ error: Error) -> Error {
            switch error {
            case HistoryStoreError.staleRevision, HistoryStoreError.invalidSelection: return changed
            case HistoryStoreError.recordNotFound: return removed
            case HistoryStoreError.selectionPayloadTooLarge, HistoryStoreError.valueTooLarge: return tooLarge
            case SyncError.accountChanged, SyncError.namespaceConflict: return accountChanged
            case is SharedBoardError: return error
            case is HistoryStoreError: return failed
            default: return error
            }
        }
    }

    private func deletePinboard(_ board: Pinboard) {
        guard !demo, mutationIsAvailable() else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("删除「\(board.name)」？")
        alert.informativeText = L10n.text("可以仅移除分组并把内容保留在历史中，也可以删除分组及其全部内容。后者不可撤销。")
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("仅移除分组，保留内容"))
        alert.addButton(withTitle: L10n.text("删除分组及全部内容"))
        let choice = alert.runLocalizedModal()
        guard choice != .alertFirstButtonReturn, mutationIsAvailable() else { return }
        do {
            try store?.deletePinboard(id: board.id, deleteItems: choice == .alertThirdButtonReturn); reload()
            if choice == .alertThirdButtonReturn { Task { try? await ocrCache.clear() } }
        }
        catch { setStatus(L10n.text("分组删除失败，请重试。")) }
    }

    private func configureStack() {
        stackPanel.isPresentationAllowed = { [weak self] in self?.interactionLifecycle.isAllowed == true }
        stack.onCancelPendingPaste = { [weak self] in self?.paste.cancel() }
        stackPanel.onEnd = { [weak self] in self?.cancelPendingInteraction(); self?.stack.end() }
        stackPanel.onClear = { [weak self] in self?.cancelPendingInteraction(); self?.stack.clear() }
        stackPanel.onReverse = { [weak self] in
            guard let self else { return }
            self.stack.direction = self.stack.direction == .forward ? .reverse : .forward
        }
        stackPanel.onRestore = { [weak self] in _ = self?.stack.restoreLastConsumed() }
        stackPanel.onRemove = { [weak self] index in _ = self?.stack.remove(at: index) }
        stackKeys.shouldHandlePaste = { [weak self] in
            guard let self else { return false }
            return self.stackInputIsAvailable && self.stack.peek() != nil
        }
        stackKeys.onUnavailable = { [weak self] in
            guard let self else { return }
            self.cancelPendingInteraction()
            if self.interactionLifecycle.isAllowed {
                self.setStatus(L10n.text("顺序粘贴的键盘访问已停止，队列仍保留。请检查辅助功能权限。"))
            }
        }
        stackKeys.preparePaste = { [weak self] in
            self?.stackGestures.prepare { [weak self] target, isGestureCurrent in
                guard let self else { return }
                self.stack.requestPaste { [weak self] request, completed in
                    guard let self, isGestureCurrent(), self.stack.isDispatchCurrent(request) else {
                        completed(.cancelled); return
                    }
                    do {
                        guard let store = self.store else { throw HistoryStoreError.recordNotFound }
                        // Queue occurrences retain their captured content even after history coalesces it.
                        try store.validateCapturedFileOutput([request.record])
                    } catch {
                        completed(.failed); self.setStatus(error.localizedDescription); return
                    }
                    self.paste.paste([request.record], plainText: false, target: target, dismiss: {},
                        allowHeldCommand: true, isContextCurrent: { [weak self] in
                            guard let self else { return false }
                            return isGestureCurrent() && self.stack.isDispatchCurrent(request)
                        }, onCompleted: completed)
                }
            }
        }
        stack.onChange = { [weak self] in self?.refreshStackPresentation() }
    }

    private var stackInputIsAvailable: Bool {
        interactionLifecycle.isAllowed && !panel.isVisible && NSApp.keyWindow == nil
    }

    private func cancelPendingInteraction() {
        ValidationTrace.emit(.interactionCancelled, state: .requested)
        stackGestures.invalidate()
        stack.cancelPendingPastes()
        paste.cancel()
    }

    private func refreshStackPresentation() {
        guard interactionLifecycle.isAllowed else { stackPanel.suspend(); stackKeys.stop(); return }
        stackPanel.update(stack)
        if stack.peek() != nil, !stackKeys.isMonitoring {
            if !stackKeys.start() { setStatus(L10n.text("顺序粘贴需要辅助功能权限；队列已保留。")) }
        } else if stack.peek() == nil { stackKeys.stopAfterCurrentPress() }
    }

    @objc private func toggleStack() {
        interactionLifecycle.prepareForInvocation { self.performToggleStack() }
    }

    private func performToggleStack() {
        guard !demo else { return }
        if stack.isActive { stack.end(); return }
        guard paste.hasPermission else { setStatus(L10n.text("请先开启辅助功能权限，再使用顺序粘贴。")); return }
        stack.activate()
        if !capture.isRunning { setStatus(L10n.text("顺序队列已开启；开始记录后，新的复制才会加入队列。")) }
    }

    private func imageData(_ record: ClipboardRecord) -> Data? {
        OCRDerivedCache.imageData(in: record)
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
                if let stored = try self.store?.update(record: updated) {
                    try? await self.ocrCache.store(result, for: stored, imageData: image, sourceStore: self.store)
                }
                self.reload()
            } catch { /* OCR is derived content; original image remains available. */ }
        }
    }

    private func extractText(_ record: ClipboardRecord) {
        guard let image = imageData(record) else { return }
        setStatus(L10n.text("正在本机识别图片文字…"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: LocalIntelligenceService.OCRResult
                if let cached = try? await self.ocrCache.result(for: record, imageData: image) {
                    result = cached
                } else {
                    result = try await self.intelligence.recognizeText(in: image)
                }
                if !self.demo {
                    guard let latest = try self.store?.item(id: record.id), latest.revision == record.revision else {
                        self.setStatus(L10n.text("原图已改变或删除，请重新打开图片后提取文字。")); return
                    }
                    try? await self.ocrCache.store(result, for: latest, imageData: image, sourceStore: self.store)
                }
                guard !result.text.isEmpty else { self.setStatus(L10n.text("未识别到可用文字。")); return }
                let text = ClipboardRecord(text: result.text, sourceApp: "ClipShelf OCR", sourceBundleID: Bundle.main.bundleIdentifier)
                if self.demo { self.records.insert(text, at: 0); self.refresh() }
                else { _ = try self.store?.record(text); self.reload() }
                self.setStatus(L10n.text("已提取文字为新记录，原图保留。"))
            } catch { self.setStatus(L10n.text("文字识别未完成：\(error.localizedDescription)")) }
        }
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        guard !demo, !validation else { return }
        cancelSuggestions()
        capture.stop(); pauseTimer?.invalidate()
        let discarded = discardPendingCapturesForPrivacy()
        let discardNotice = discarded ? statusMessage : nil
        let until = Date().addingTimeInterval(Double(sender.tag) * 60)
        preferences.set(true, forKey: "recordingEnabled")
        scheduleResume(at: until)
        var message = L10n.text("已暂停记录，\(sender.tag) 分钟后恢复。")
        if let discardNotice { message += "\n" + discardNotice }
        setStatus(message)
    }

    private func scheduleResume(at until: Date) {
        guard !validation else { return }
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

    private func configureOwnedLifetimes(store: HistoryStore) {
        let publications = OwnedFilePublicationCoordinator(store: store)
        ownedPublications = publications
        publications.onError = { [weak self] error in self?.setStatus(L10n.text("文件使用保护未完成：\(error.localizedDescription)")) }
        paste.publications = publications
        systemIntegration.publications = publications
        panel.publications = publications
        stack.retainer = { try store.retainCapturedOwnedFiles($0, purpose: .stack) }
        stack.onRetentionError = { [weak self] error in self?.setStatus(L10n.text("Stack 未加入文件：\(error.localizedDescription)")) }
        if profile.allowsBackgroundIntegrations { publications.startObserving() }
    }

    private func configureStorageManagement(store: HistoryStore) {
        let controller = StorageSettingsController(actions: .init(
            scan: { try await Task.detached(priority: .utility) { try store.ownedStorageUsage() }.value },
            prepare: { try await Task.detached(priority: .utility) { try store.prepareOwnedStorageCleanup() }.value },
            commit: { plan in try await Task.detached(priority: .utility) { try store.commitOwnedStorageCleanup(plan) }.value },
            recover: { try await Task.detached(priority: .utility) { try store.resumeOwnedStorageCleanup() }.value },
            readExternalUses: { try await Task.detached(priority: .utility) { try store.ownedPublications().filter { $0.purpose != .clipboard } }.value },
            releaseExternalUses: { ids in try await Task.detached(priority: .utility) { try store.clearConfirmedExternalOwnedPublications(expectedIDs: ids) }.value },
            scanLibrary: { [weak self] cancellation in
                guard let self else { throw CancellationError() }
                let inboxRoot = await self.shareInbox?.storageRootURL()
                let roots = LibraryStorageReader.additionalRoots(validationDirectory: self.validation ? store.storageUsageScope().profileDirectory : nil,
                    cachesDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                    shareInboxRoot: inboxRoot)
                let worker = Task.detached(priority: .utility) {
                    try LibraryStorageReader.read(store: store, roots: roots, cancellation: cancellation)
                }
                return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
                    cancellation.cancel(); worker.cancel()
                })
            },
            readContentQuota: {
                try await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try store.contentQuotaStatus()
                }.value
            },
            setContentQuota: { bytes, revision in
                try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try store.setContentQuotaLimit(bytes, expectedRevision: revision)
                }.value
            }
        ), preferences: preferences)
        storageSettings = controller
        controller.allowsLibraryScan = { [weak self] in self?.interactionLifecycle.isAllowed == true }
        controller.allowsLimitChange = { [weak self] in
            guard let self, self.interactionLifecycle.isAllowed else { return false }
            return !self.selectionMutationInProgress && !self.isCaptureWriteBusy &&
                self.historyCleanup?.isBusy != true && !self.isTerminating && !self.terminationDecisionPending
        }
        controller.isExternalMutationBusy = { [weak self] in
            guard let self else { return true }
            return self.selectionMutationInProgress || self.isCaptureWriteBusy || self.captureBlocksOwnedReclamation || self.historyCleanup?.isBusy == true || self.sessionSuspended || self.isTerminating || self.terminationDecisionPending
        }
        controller.onBusyChanged = { [weak self] busy in
            self?.appUpdates?.refreshAvailability()
            if !busy { DispatchQueue.main.async { [weak self] in self?.historyCleanup?.resumeDeferred() } }
        }
        controller.onMessage = { [weak self] message in self?.setStatus(message) }
    }

    @objc private func showStorageSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        guard !demo else { setStatus(L10n.text("演示模式没有持久保存的托管文件。")); return }
        cancelSuggestions()
        panel.dismissForAction { [weak self] in
            guard let self, self.interactionLifecycle.isAllowed else { return }
            self.storageSettings?.present()
        }
    }

    private func configureHistoryCleanup() {
        let coordinator = HistoryCleanupCoordinator()
        historyCleanup = coordinator
        coordinator.isExternalMutationBusy = { [weak self] in
            guard let self else { return true }
            return self.selectionMutationInProgress || self.isCaptureWriteBusy || self.storageSettings?.isBusy == true || self.sessionSuspended || self.isTerminating || self.terminationDecisionPending
        }
        coordinator.onPrepare = { [weak self] request, completion in
            guard let self, !self.isTerminating, !self.terminationDecisionPending else {
                completion(.failure(HistoryCleanupFlowError.unavailable)); return
            }
            let cutoff: Date?
            switch request {
            case .clearHistory: cutoff = nil
            case .retention(let days), .automatic(let days):
                cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            }
            if !request.isAutomatic { self.setStatus(L10n.text("正在统计历史清理范围…")) }
            self.readSelection({ try $0.prepareHistoryCleanup(before: cutoff) }, completion: completion)
        }
        coordinator.confirm = { [weak self] summary, request, completion in
            guard let self, !self.sessionSuspended, !self.isTerminating, !self.terminationDecisionPending else {
                completion(false); return {}
            }
            let confirmation = HistoryCleanupConfirmationController(request: request, summary: summary)
            self.cleanupConfirmation?.dismiss()
            self.cleanupConfirmation = confirmation
            confirmation.present { [weak self, weak confirmation] accepted in
                if self?.cleanupConfirmation === confirmation { self?.cleanupConfirmation = nil }
                completion(accepted)
            }
            return { [weak self, weak confirmation] in
                confirmation?.dismiss()
                if self?.cleanupConfirmation === confirmation { self?.cleanupConfirmation = nil }
            }
        }
        coordinator.onCommit = { [weak self] plan, completion in
            guard let self, let store = self.store, !self.isTerminating, !self.terminationDecisionPending else {
                completion(.failure(HistoryCleanupFlowError.unavailable)); return
            }
            Task { @MainActor in
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try store.commitHistoryCleanup(plan)
                    }.value
                    completion(.success(result))
                } catch { completion(.failure(error)) }
            }
        }
        coordinator.onBusyChanged = { [weak self] busy in
            self?.refresh()
            if !busy { DispatchQueue.main.async { [weak self] in self?.storageSettings?.resumeDeferred() } }
        }
        coordinator.onSuccess = { [weak self] result, request in
            guard let self else { return }
            if case .retention(let days) = request {
                self.preferences.set(days, forKey: "retentionDays")
            }
            let affected = Set(result.deletedIDs + result.preservedReferences.map(\.id))
            self.selectionUndoHistory.invalidate(recordIDs: affected)
            self.storageSettings?.requestAutomaticReclamation()
            if result.summary.affectedCount > 0 { self.reload() }
            if !request.isAutomatic || result.summary.affectedCount > 0 {
                var message = L10n.text("历史清理完成：删除 \(result.summary.deletedCount) 条，\(result.summary.preservedPinnedCount) 条移出历史并保留在分组。")
                if case .retention(let days) = request { message = L10n.text("已改为保留 \(days) 天。") + message }
                if result.summary.excludedCount > 0 {
                    message += L10n.text("另有 \(result.summary.excludedCount) 条因账号或权限限制保留。")
                }
                self.setStatus(message)
            } else { self.refresh() }
        }
        coordinator.onFailure = { [weak self] error, request in
            guard let self else { return }
            let prefix = request.isAutomatic ? L10n.text("自动清理未完成。") : L10n.text("历史清理未完成，保留期限未更改。")
            self.setStatus(prefix + error.localizedDescription)
        }
        coordinator.onCancelled = { [weak self] request in
            if !request.isAutomatic { self?.setStatus(L10n.text("已取消历史清理；内容和保留期限未改变。")) }
        }
    }

    private func applyRetention() {
        guard !demo, store != nil, !isTerminating else { return }
        let days = preferences.integer(forKey: "retentionDays")
        historyCleanup?.start(.automatic(days: days))
    }

    private func outputImageFiles(_ records: [ClipboardRecord], directlyPaste: Bool) {
        guard !demo, let store else { return }
        let lease: OwnedAssetLease
        do { lease = try store.retainCapturedOwnedFiles(records, purpose: .output) }
        catch { setStatus(L10n.text("文件使用保护未完成：\(error.localizedDescription)")); return }
        let isCurrent = panel.captureOutputContext(), originalTarget = target
        let directory = profile.validationDirectory?.appendingPathComponent("ImageExports", isDirectory: true)
        let references = records.map { ClipboardSelectionReference(id: $0.id, revision: $0.revision) }
        let operationID = UUID(), progress = L10n.text("正在生成图片文件…")
        imageOutputOperationID = operationID
        setStatus(progress)
        Task { @MainActor [weak self, lease] in
            defer {
                withExtendedLifetime(lease) {}
                if let self, self.imageOutputOperationID == operationID {
                    self.imageOutputOperationID = nil
                    if self.statusMessage == progress { self.statusMessage = nil; self.refresh() }
                }
            }
            do {
                let exported = try await Task.detached(priority: .userInitiated) {
                    let prepared = try ImageFileOutput.prepare(records, spaceCoordinator: store.spaceCoordinator)
                    let receipt = try prepared.exportReceipt(directory: directory)
                    do {
                        // Conversion can take time; recheck the frozen selection before publishing it.
                        _ = try store.resolveSelectionForOutput(references)
                        return receipt
                    } catch { receipt.discardUnpublished(); throw error }
                }.value
                guard let self, !self.isTerminating, isCurrent() else {
                    exported.discardUnpublished(); return
                }
                if directlyPaste {
                    var copied = false
                    self.paste.paste(exported.records, plainText: false, target: originalTarget,
                                     dismiss: { self.panel.dismiss() }, onCopied: { copied = true })
                    if !copied { exported.discardUnpublished() }
                } else if self.paste.copy(exported.records) {
                    self.setStatus(L10n.text("图片已复制为 PNG 文件，可在目标应用粘贴。"))
                } else { exported.discardUnpublished() }
            } catch {
                guard let self, isCurrent() else { return }
                self.setStatus(L10n.text("图片文件未输出：\(error.localizedDescription)"))
            }
        }
    }

    private func openRecord(_ record: ClipboardRecord) {
        if record.kind == .file {
            panel.showFileReferences(record)
        } else if let url = URL(string: record.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadFileRepairSnapshot(_ reference: ClipboardSelectionReference,
                                        completion: @escaping (Result<ClipboardFileRepairSnapshot, Error>) -> Void) {
        guard !demo, let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        Task { @MainActor in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try store.fileRepairSnapshot(reference)
                }.value
                completion(.success(snapshot))
            } catch { completion(.failure(error)) }
        }
    }

    private func relocateFile(_ snapshot: ClipboardFileRepairSnapshot, file: ClipboardFileReference, to url: URL,
                              completion: @escaping (Result<ClipboardFileRepairSnapshot, Error>) -> Void) {
        guard !demo, let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        guard mutationIsAvailable() else { completion(.failure(SelectionOperationError.busy)); return }
        selectionMutationInProgress = true
        Task { @MainActor in
            defer { selectionMutationInProgress = false }
            do {
                let undo = try await Task.detached(priority: .userInitiated) {
                    try store.relocateExternalFile(snapshot, file: file, to: url)
                }.value
                selectionUndoHistory.register(.edit(undo)) { [weak self] in self?.undoSelection($0, store: store) }
                do {
                    let updated = try await Task.detached(priority: .userInitiated) {
                        try store.fileRepairSnapshot(undo.committedReference)
                    }.value
                    // Let the panel adopt the committed version before validating its selection on reload.
                    completion(.success(updated))
                    setStatus(L10n.text("已更新文件位置，可撤销；外部文件未移动。"))
                } catch { completion(.failure(FileRepairApplicationError.savedNeedsRefresh)) }
                reload()
            } catch { completion(.failure(error)) }
        }
    }

    private func restoreOwnedFile(_ snapshot: ClipboardFileRepairSnapshot, file: ClipboardFileReference,
                                  completion: @escaping (Result<ClipboardFileRepairSnapshot, Error>) -> Void) {
        guard !demo, let store else { completion(.failure(HistoryStoreError.recordNotFound)); return }
        guard mutationIsAvailable() else { completion(.failure(SelectionOperationError.busy)); return }
        selectionMutationInProgress = true
        Task { @MainActor in
            defer { selectionMutationInProgress = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try store.restoreMissingOwnedProjection(snapshot, file: file)
                }.value
                do {
                    let updated = try await Task.detached(priority: .userInitiated) {
                        try store.fileRepairSnapshot(ClipboardSelectionReference(id: snapshot.record.id, revision: snapshot.record.revision))
                    }.value
                    completion(.success(updated))
                    switch result {
                    case .restored: setStatus(L10n.text("已从保存的原件恢复打开副本。"))
                    case .alreadyPresent: setStatus(L10n.text("打开副本已存在，保留现有内容。"))
                    }
                } catch { completion(.failure(FileRepairApplicationError.restoredNeedsRefresh)) }
                reload()
            } catch { completion(.failure(error)) }
        }
    }

    private enum FileRepairApplicationError: LocalizedError {
        case savedNeedsRefresh, restoredNeedsRefresh
        var errorDescription: String? {
            switch self {
            case .savedNeedsRefresh: return L10n.text("文件位置已更新且可撤销；条目随后发生变化，请关闭后重新打开。")
            case .restoredNeedsRefresh: return L10n.text("文件副本已处理；条目随后发生变化，请关闭后重新打开。")
            }
        }
    }

    @objc private func showSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performShowSettings() }
    }

    @objc private func showLanguageSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        guard !sessionSuspended, !isTerminating, !terminationDecisionPending else { return }
        if languageSettings == nil {
            let allowsChanges = profile.mode == .standard
            let languagePreferences = LanguagePreferences(
                preferences: preferences, allowsChanges: allowsChanges,
                sharedPreferences: LanguagePreferences.configuredSharedPreferences(allowsChanges: allowsChanges))
            let controller = LanguageSettingsController(preferences: languagePreferences)
            controller.isPresentationAllowed = { [weak self] in
                guard let self else { return false }
                return !self.sessionSuspended && !self.isTerminating && !self.terminationDecisionPending
            }
            controller.onPreparePresentation = { [weak self] in
                self?.cancelSuggestions(); self?.paste.cancel(); self?.panel.hidePreservingDraft()
            }
            languageSettings = controller
        }
        languageSettings?.present()
    }

    private func configureAppUpdates() {
        let coordinator = AppUpdateCoordinator(allowsBackgroundIntegrations: profile.allowsBackgroundIntegrations)
        appUpdates = coordinator
        $selectionMutationInProgress.updater = coordinator
        $terminationDecisionPending.updater = coordinator
        coordinator.isRestartBlocked = { [weak self] in
            guard let self else { return true }
            return self.sessionSuspended || self.isTerminating || self.terminationDecisionPending ||
                self.selectionMutationInProgress || self.isCaptureWriteBusy || self.historyCleanup?.isCommitting == true || self.storageSettings?.isCommitting == true
        }
        coordinator.onChange = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            self.updateCheckItems.forEach {
                $0.title = coordinator.menuActionTitle
                $0.isEnabled = coordinator.canPerformMenuAction
            }
            self.updateSettings?.refreshView()
        }
        coordinator.start()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkAppUpdates) { return appUpdates?.canPerformMenuAction == true }
        if menuItem.action == #selector(retryCapturedContents) {
            return !demo && !validation && interactionLifecycle.isAllowed && captureIngestion?.hasFailure == true && captureIngestion?.isProcessing != true
        }
        if menuItem.action == #selector(discardCapturedContents) {
            return interactionLifecycle.isAllowed && (captureIngestion?.pendingCount ?? 0) > 0
        }
        return true
    }

    @objc private func checkAppUpdates() {
        if appUpdates?.hasPendingRestart == true {
            // Explicit user action only. The real quit event performs the draft
            // decision; merely exposing this menu item never opens a window or
            // interrupts typing, suspension, or an in-progress termination.
            appUpdates?.retryPendingRestart()
            return
        }
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.appUpdates?.checkForUpdates() }
    }

    @objc private func showUpdateSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        cancelSuggestions()
        panel.dismissForAction { [weak self] in
            guard let self, self.interactionLifecycle.isAllowed, let coordinator = self.appUpdates else { return }
            if self.updateSettings == nil { self.updateSettings = UpdateSettingsController(coordinator: coordinator) }
            self.updateSettings?.present()
        }
    }

    private func performShowSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelSuggestions()
        if shortcutSettings == nil {
            let controller = ShortcutSettingsController()
            controller.onValidate = { [weak self] configuration in
                guard let self else { return .failure(ShortcutSettingsError.unavailable) }
                return Result {
                    if self.demo { try configuration.validate() }
                    else { try self.globalShortcuts.probe(configuration) }
                }
            }
            controller.onApply = { [weak self] configuration, alwaysPlain in
                guard let self else { return .failure(ShortcutSettingsError.unavailable) }
                guard !self.demo else { return .failure(ShortcutSettingsError.demo) }
                do {
                    try self.globalShortcuts.applyAndSave(configuration, alwaysPlainText: alwaysPlain, preferences: self.preferences)
                    self.shortcutConfiguration = configuration
                    self.shortcutConfigurationWarning = nil
                    self.shortcutLayoutWarning = nil
                    self.shortcutRegistrationFailures = []
                    self.panel.applyShortcuts(configuration, alwaysPlainText: alwaysPlain)
                    self.setStatus(L10n.text("快捷键与粘贴设置已保存。"))
                    return .success(())
                } catch { return .failure(error) }
            }
            controller.onTryActivation = { [weak self] in self?.showShortcutPreview() }
            shortcutSettings = controller
        }
        shortcutSettings?.show(configuration: shortcutConfiguration, alwaysPlainText: preferences.bool(forKey: "alwaysPlainText"),
                               registrationMessage: shortcutRegistrationMessage)
    }

    private var shortcutRegistrationMessage: String? {
        var messages = shortcutRegistrationFailures
        if let shortcutConfigurationWarning { messages.append(shortcutConfigurationWarning) }
        if let shortcutLayoutWarning { messages.append(shortcutLayoutWarning) }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func installShortcutInputSourceObserver() {
        guard shortcutInputSourceObserver == nil else { return }
        shortcutInputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTerminating else { return }
                let previousMessage = self.shortcutRegistrationMessage
                do { try self.shortcutConfiguration.validate(); self.shortcutLayoutWarning = nil }
                catch { self.shortcutLayoutWarning = L10n.text("键盘布局改变，请在快捷键设置中检查：\(error.localizedDescription)") }
                if !self.demo {
                    self.shortcutRegistrationFailures = self.globalShortcuts.reconcileAfterInputSourceChange(self.shortcutConfiguration)
                }
                self.panel.applyShortcuts(self.shortcutConfiguration, alwaysPlainText: self.preferences.bool(forKey: "alwaysPlainText"))
                self.shortcutSettings?.keyboardInputSourceDidChange(registrationMessage: self.shortcutRegistrationMessage)
                if let message = self.shortcutRegistrationMessage { self.setStatus(message) }
                else {
                    if self.statusMessage == previousMessage { self.statusMessage = nil }
                    self.refresh()
                }
            }
        }
    }

    private func showShortcutPreview() {
        guard interactionLifecycle.isAllowed else { return }
        cancelSuggestions(); cancelPendingInteraction(); target = nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let message = L10n.text("快捷键试用 · 可在设置中录制组合；按 Esc 关闭面板。")
        if demo { panel.show(records: records, on: screen, status: message) }
        else { panel.show(metadata: [], on: screen, status: message) }
    }

    private enum ShortcutSettingsError: Error, LocalizedError {
        case demo, unavailable
        var errorDescription: String? {
            switch self {
            case .demo: return L10n.text("演示模式不保存设置或注册全局快捷键。")
            case .unavailable: return L10n.text("设置暂时不可用，请重新打开。")
            }
        }
    }

    @objc private func showMCPSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performShowMCPSettings() }
    }

    private func performShowMCPSettings() {
        guard interactionLifecycle.isAllowed else { return }
        guard profile.allowsBackgroundIntegrations, let store else { return }
        cancelSuggestions()
        do {
            if mcpSettings == nil {
                mcpSettings = try MCPSettingsController(store: store)
                mcpSettings?.onDataChanged = { [weak self] in self?.reload() }
            }
            mcpSettings?.present()
        } catch { showError(L10n.text("MCP 设置不可用"), detail: L10n.text("无法读取本机钥匙串授权。已有历史不受影响。")) }
    }

    @objc private func showCloudSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performShowCloudSettings() }
    }

    private func performShowCloudSettings() {
        guard interactionLifecycle.isAllowed else { return }
        guard profile.allowsBackgroundIntegrations else { return }
        cancelSuggestions()
        cloudSettings?.present()
    }

    @objc private func showSharingSettings() {
        guard interactionLifecycle.isAllowed else { return }
        cancelPendingInteraction()
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performShowSharingSettings() }
    }

    private func performShowSharingSettings() {
        guard interactionLifecycle.isAllowed else { return }
        guard profile.allowsBackgroundIntegrations else { return }
        cancelSuggestions()
        sharingSettings?.present()
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        guard profile.allowsBackgroundIntegrations, let url = metadata.share.url else { return }
        sharingSettings?.offerInvitation(url)
    }

    @objc private func importFromCamera() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performImportFromCamera() }
    }

    private func performImportFromCamera() {
        guard profile.allowsBackgroundIntegrations else { return }
        cancelSuggestions()
        systemIntegration.presentCameraImport()
    }

    private func configureSuggestions() {
        suggestionsPanel.onClose = { [weak self] in
            guard let self else { return }
            self.suggestionGeneration &+= 1; self.suggestionTask?.cancel(); self.suggestionTask = nil
            self.suggestionTargetPID = nil; self.contextSuggestions.cancel()
        }
        suggestionsPanel.onRequestScreenPermission = { [weak self] in
            _ = ContextSuggestionService.requestScreenRecordingPermission()
            self?.suggestionsPanel.showError(message: L10n.text("请在系统设置确认屏幕权限，然后回到原应用重新打开智能建议。"))
        }
        suggestionsPanel.onPaste = { [weak self] id, target in
            guard let self, self.interactionLifecycle.isAllowed, let store = self.store else { return }
            let generation = self.suggestionGeneration
            Task { @MainActor [weak self] in
                do {
                    let retained = try await Task.detached(priority: .userInitiated) {
                        guard let current = try store.item(id: id) else { throw HistoryStoreError.recordNotFound }
                        return try store.resolveSelectionForRetainedOutput([.init(id: id, revision: current.revision)])
                    }.value
                    guard let self, self.interactionLifecycle.isAllowed, self.suggestionGeneration == generation else { return }
                    withExtendedLifetime(retained) {
                        guard let record = retained.records.first else { return }
                        self.paste.paste(record, plainText: self.outputAsPlainText([record], requested: false), target: target) {
                            self.suggestionsPanel.dismiss()
                        }
                    }
                } catch {
                    guard let self, self.suggestionGeneration == generation else { return }
                    self.suggestionsPanel.showError(message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func showSuggestions() {
        guard interactionLifecycle.isAllowed, profile.allowsBackgroundIntegrations, store != nil else { return }
        cancelPendingInteraction()
        let originalTarget = panel.isVisible ? target : paste.captureTarget()
        guard let originalTarget else { setStatus(L10n.text("请回到需要粘贴的应用后再打开智能建议。")); return }
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.startSuggestions(target: originalTarget) }
    }

    private func startSuggestions(target originalTarget: PasteCoordinator.Target) {
        guard interactionLifecycle.isAllowed, profile.allowsBackgroundIntegrations, let store else { return }
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
        guard profile.allowsBackgroundIntegrations else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("快捷指令访问")
        alert.informativeText = L10n.text("允许后，你运行的快捷指令可新增文本，并读取本地内容、当前同步账号及仍可读取的共享板；旧账号缓存和已撤销共享不会提供。快捷指令后续动作可能把内容发送给其他应用或网络服务。关闭后，这些动作会返回无权访问。")
        let allow = NSButton(checkboxWithTitle: L10n.text("允许快捷指令新增和读取 ClipShelf 内容"), target: nil, action: nil)
        allow.state = preferences.bool(forKey: "shortcutsEnabled") ? .on : .off
        allow.frame = NSRect(x: 0, y: 0, width: 420, height: 32); alert.accessoryView = allow
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("保存"))
        if alert.runLocalizedModal() == .alertSecondButtonReturn {
            preferences.set(allow.state == .on, forKey: "shortcutsEnabled")
            ClipboardIntentRuntime.shared.enabled = allow.state == .on
        }
    }

    @objc private func exportBackup() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performExportBackup() }
    }

    private func performExportBackup() {
        guard !demo, let store, mutationIsAvailable() else { return }
        cancelSuggestions()
        let options = NSAlert(); options.messageText = L10n.text("导出备份")
        options.informativeText = L10n.text("备份包含剪贴板正文和附件。加密密码不会保存，遗忘后无法恢复。")
        let encrypt = NSButton(checkboxWithTitle: L10n.text("使用密码加密备份"), target: nil, action: nil); encrypt.state = .on
        let password = NSSecureTextField(); password.placeholderString = L10n.text("密码（至少 8 个字符）")
        let repeatPassword = NSSecureTextField(); repeatPassword.placeholderString = L10n.text("再次输入密码")
        let fields = NSStackView(views: [encrypt, password, repeatPassword]); fields.orientation = .vertical
        fields.alignment = .leading; fields.spacing = 10; fields.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        password.widthAnchor.constraint(equalToConstant: 420).isActive = true
        repeatPassword.widthAnchor.constraint(equalToConstant: 420).isActive = true
        options.accessoryView = fields; options.addButton(withTitle: L10n.text("取消")); options.addButton(withTitle: L10n.text("继续"))
        guard options.runLocalizedModal() == .alertSecondButtonReturn else { return }
        let secret: String? = encrypt.state == .on ? password.stringValue : nil
        if let secret, secret.count < 8 || secret.utf8.count > 1024 || secret != repeatPassword.stringValue {
            showError(L10n.text("密码未通过检查"), detail: L10n.text("请使用至少 8 个字符、最多 1024 字节的密码，并确保两次输入一致。"))
            return
        }
        password.stringValue = ""; repeatPassword.stringValue = ""
        let save = NSSavePanel(); save.nameFieldStringValue = "ClipShelf-backup.clipshelf"
        save.title = L10n.text("导出本地备份"); save.message = secret == nil ? L10n.text("将导出未加密文件，请妥善保存。") : L10n.text("将导出密码加密文件。")
        guard save.runModal() == .OK, let url = save.url, mutationIsAvailable() else { return }
        selectionMutationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.selectionMutationInProgress = false }
            do {
                let privateDirectory = try self.profile.dataDirectory()
                let migration = try await Task.detached {
                    try ShareInboxService.migrateLegacyFiles(store: store, privateDirectory: privateDirectory)
                }.value
                if migration.migratedRecords > 0 { self.selectionUndoHistory.removeAll(); self.reload() }
                try migration.requireComplete()
                try await Task.detached {
                    if let secret { try EncryptedBackupService.export(store: store, to: url, password: secret) }
                    else { try store.exportBackup(to: url) }
                }.value
                self.setStatus(L10n.text("备份已导出。\(migration.snapshotNotice)"))
            }
            catch { self.showError(L10n.text("导出失败"), detail: error.localizedDescription) }
        }
    }

    @objc private func restoreBackup() {
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performRestoreBackup() }
    }

    private func performRestoreBackup() {
        guard !demo, let store, mutationIsAvailable() else { return }
        cancelSuggestions()
        let open = NSOpenPanel(); open.allowsMultipleSelection = false; open.canChooseDirectories = false
        open.title = L10n.text("选择 ClipShelf 备份")
        guard open.runModal() == .OK, let url = open.url else { return }
        let encrypted: Bool
        do { encrypted = try EncryptedBackupService.isEncrypted(url) }
        catch { showError(L10n.text("无法读取备份"), detail: L10n.text("请检查文件是否仍存在，以及是否有读取权限。")); return }
        var secret: String?
        if encrypted {
            let prompt = NSAlert(); prompt.messageText = L10n.text("输入备份密码")
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
            prompt.accessoryView = password; prompt.addButton(withTitle: L10n.text("取消")); prompt.addButton(withTitle: L10n.text("继续"))
            guard prompt.runLocalizedModal() == .alertSecondButtonReturn else { return }
            secret = password.stringValue; password.stringValue = ""
        }
        let alert = NSAlert(); alert.messageText = L10n.text("如何恢复备份？")
        alert.informativeText = L10n.text("合并会保留现有内容，并将备份导入为独立本地内容；不会自动上传或传播云端删除。有关联同步数据的档案只允许合并。纯本地档案可替换；执行前会在本机数据目录保存未加密恢复副本。")
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("合并")); alert.addButton(withTitle: L10n.text("替换"))
        let choice = alert.runLocalizedModal(); guard choice != .alertFirstButtonReturn, mutationIsAvailable() else { return }
        let mode: BackupRestoreMode = choice == .alertSecondButtonReturn ? .merge : .replace
        let password = secret
        selectionMutationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.selectionMutationInProgress = false }
            do {
                let prepared = try await Task.detached {
                    if let password { return try EncryptedBackupService.prepareRestore(from: url, password: password, mode: mode, store: store) }
                    return try store.prepareBackupRestore(from: url, mode: mode)
                }.value
                let privateDirectory = try self.profile.dataDirectory()
                let migration = try await Task.detached {
                    try ShareInboxService.migrateLegacyFiles(store: store, privateDirectory: privateDirectory)
                }.value
                if migration.migratedRecords > 0 { self.selectionUndoHistory.removeAll(); self.reload() }
                try migration.requireComplete()
                let result = try await Task.detached { try store.restoreBackup(prepared) }.value
                self.selectionUndoHistory.removeAll()
                let scope = result.restoredAsLocalOnly ? L10n.text("恢复内容仅保存在本机，尚未上传。") : ""
                try? await self.ocrCache.clear()
                self.reload(); self.setStatus(L10n.text("已恢复 \(result.importedRecords) 条内容。\(scope)恢复前副本保存在本机数据目录。\(migration.snapshotNotice)"))
            } catch { self.showError(L10n.text("恢复失败"), detail: L10n.text("\(error.localizedDescription)\n现有数据保留。")) }
        }
    }

    @objc private func changeRetention(_ sender: NSMenuItem) {
        let days = sender.tag
        guard !demo, store != nil, [0, 1, 7, 30, 365].contains(days) else { return }
        cancelSuggestions()
        panel.dismissForAction { [weak self] in self?.performChangeRetention(days: days) }
    }

    private func performChangeRetention(days: Int) {
        guard !sessionSuspended, !isTerminating, !terminationDecisionPending else { return }
        if days == 0 {
            guard !selectionMutationInProgress, historyCleanup?.isCommitting != true else {
                setStatus(SelectionOperationError.busy.localizedDescription); return
            }
            historyCleanup?.cancelPending()
            historyCleanup?.start(.automatic(days: 0))
            preferences.set(0, forKey: "retentionDays")
            setStatus(L10n.text("历史保留期限：永久。"))
        } else if historyCleanup?.start(.retention(days: days)) == .ignored {
            setStatus(L10n.text("请先完成或取消当前历史清理；保留期限尚未更改。"))
            cleanupConfirmation?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func toggleLoginItem() {
        guard profile.allowsBackgroundIntegrations else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); setStatus(L10n.text("已关闭登录启动。")) }
            else { try SMAppService.mainApp.register(); setStatus(L10n.text("已请求登录启动，可在系统设置中管理。")) }
        } catch { showError(L10n.text("无法更改登录启动"), detail: L10n.text("请将应用安装到 Applications，并在系统设置的登录项中检查状态。")) }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runLocalizedModal()
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationDecisionPending else { return .terminateLater }
        guard !selectionMutationInProgress, captureIngestion?.isProcessing != true,
              historyCleanup?.isCommitting != true, storageSettings?.isCommitting != true else {
            setStatus(L10n.text("正在保存、撤销或清理，请完成后再退出。"))
            return .terminateCancel
        }
        terminationDecisionPending = true
        recordingBeforeTermination = capture.isRunning
        discardCapturesOnTermination = false
        capture.stop()
        cancelPendingInteraction(); cancelSuggestions(); stackKeys.stopAfterCurrentPress(); stackPanel.suspend()
        historyCleanup?.cancelPending()
        storageSettings?.cancelPending()
        if let pending = captureIngestion?.pendingCount, pending > 0 {
            let alert = NSAlert()
            alert.messageText = L10n.text("仍有内容尚未保存")
            alert.informativeText = L10n.text("\(pending) 项内容仅保留在内存中。可以取消退出并重试保存，或丢弃这些内容后退出。")
            alert.addButton(withTitle: L10n.text("取消"))
            alert.addButton(withTitle: L10n.text("丢弃并退出"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runLocalizedModal() != .alertSecondButtonReturn {
                terminationDecisionPending = false
                if recordingBeforeTermination, !sessionSuspended, captureIngestion?.hasFailure != true { capture.start() }
                refreshStackPresentation(); refresh()
                return .terminateCancel
            }
            // Preserve the batch if the subsequent editor-draft decision is canceled.
            discardCapturesOnTermination = true
        }
        panel.dismissForAction({ [weak self] in
            DispatchQueue.main.async { self?.finishTerminationDecision(true, sender: sender) }
        }, onCancel: { [weak self] in
            DispatchQueue.main.async { self?.finishTerminationDecision(false, sender: sender) }
        })
        return .terminateLater
    }

    private func finishTerminationDecision(_ accepted: Bool, sender: NSApplication) {
        guard terminationDecisionPending else { return }
        if accepted, !selectionMutationInProgress, captureIngestion?.isProcessing != true,
           historyCleanup?.isCommitting != true, storageSettings?.isCommitting != true,
           historyCleanup?.terminate() != false {
            if discardCapturesOnTermination { captureIngestion?.discardPending() }
            isTerminating = true
            terminationDecisionPending = false
            sender.reply(toApplicationShouldTerminate: true)
        } else {
            terminationDecisionPending = false
            if accepted { setStatus(L10n.text("资料库修改尚未完成，请完成后再退出。")) }
            sender.reply(toApplicationShouldTerminate: false)
            historyCleanup?.resumeDeferred()
            storageSettings?.resumeDeferred()
            if recordingBeforeTermination, !sessionSuspended, captureIngestion?.hasFailure != true { capture.start() }
            refreshStackPresentation()
            refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        pasteFeedback.hide()
        interactionLifecycle.stopObserving()
        appUpdates?.stop()
        historyCleanup?.terminate()
        storageSettings?.cancelPending()
        ownedPublications?.stopObserving()
        cleanupConfirmation?.dismiss(); cleanupConfirmation = nil
        capture.stop(); captureIngestion?.discardPending(); globalShortcuts.stop(); stackKeys.stop(); stack.end(); paste.cancel()
        if let shortcutInputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(shortcutInputSourceObserver)
            self.shortcutInputSourceObserver = nil
        }
        pageQueries.cancel(); pauseTimer?.invalidate(); retentionTimer?.invalidate()
        ocrCleanupTask?.cancel()
        shareInboxTask?.cancel(); shareInboxTimer?.invalidate()
        intelligence.cancelRecognition(); intelligence.cancelSuggestions()
        cancelSuggestions()
        mcpSettings?.stop()
        cloudSettings?.stop()
        sharingSettings?.stop()
        ClipboardIntentRuntime.shared.store = nil
        profile.discardValidationPreferences()
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
