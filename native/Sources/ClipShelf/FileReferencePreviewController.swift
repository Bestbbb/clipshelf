import ClipShelfLocalization
import AppKit
import ClipShelfCore
import Quartz
import UniformTypeIdentifiers

private final class FileReferencePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One row is one original representation slot. Rows never disappear merely because
/// their file is unavailable, and opening a window never opens a file or Quick Look.
@MainActor
final class FileReferencePreviewController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                            @preconcurrency QLPreviewPanelDataSource {
    typealias SnapshotReply = (Result<ClipboardFileRepairSnapshot, Error>) -> Void
    typealias FilePicker = (NSWindow, ClipboardFileReference, @escaping (URL?) -> Void) -> (() -> Void)
    typealias ApplicationPicker = (NSWindow, @escaping (URL?) -> Void) -> (() -> Void)
    typealias ApplicationMenuPresenter = (NSMenu, NSView, @escaping () -> Void) -> (() -> Void)
    var onSnapshot: ((ClipboardSelectionReference, @escaping SnapshotReply) -> Void)?
    var onRelocate: ((ClipboardFileRepairSnapshot, ClipboardFileReference, URL, @escaping SnapshotReply) -> Void)?
    var onRestoreOwned: ((ClipboardFileRepairSnapshot, ClipboardFileReference, @escaping SnapshotReply) -> Void)?
    var onDismiss: (() -> Void)?
    var isContextCurrent: (() -> Bool)?
    var publications: OwnedFilePublicationCoordinator? {
        didSet { applicationOpener.publications = publications }
    }
    private(set) var snapshot: ClipboardFileRepairSnapshot?
    private(set) var snapshotIsCurrent = false
    var selectedFile: ClipboardFileReference? {
        guard let snapshot, snapshot.files.indices.contains(table.selectedRow) else { return nil }
        return snapshot.files[table.selectedRow]
    }

    private var reference: ClipboardSelectionReference
    private let preferUnavailable: Bool
    private let chooseFile: FilePicker?
    private let openURL: (URL) -> Bool
    private let previewURL: ((URL) -> Void)?
    private let dismissPreview: (() -> Void)?
    private let applicationOpener: FileApplicationOpener
    private let chooseApplication: ApplicationPicker?
    private let presentApplicationMenu: ApplicationMenuPresenter?
    private let table = NSTableView()
    private let path = NSTextField(wrappingLabelWithString: L10n.text("正在读取文件位置…"))
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let preview = NSButton(title: L10n.text("预览所选文件"), target: nil, action: nil)
    private let open = NSButton(title: L10n.text("打开所选文件"), target: nil, action: nil)
    private let openWith = NSButton(title: L10n.text("打开方式…"), target: nil, action: nil)
    private let repair = NSButton(title: L10n.text("重新定位…"), target: nil, action: nil)
    private let refreshButton = NSButton(title: L10n.text("刷新状态"), target: nil, action: nil)
    private var presented = false
    private var requestID: UUID?
    private var pickerID: UUID?
    private var cancelPicker: (() -> Void)?
    private var keyMonitor: Any?
    private var quickLookURL: URL?
    private var injectedPreviewIsOpen = false
    private struct ApplicationIntent {
        let id = UUID()
        let reference: ClipboardSelectionReference
        let snapshot: ClipboardFileRepairSnapshot
        let file: ClipboardFileReference
    }
    private final class ApplicationMenuChoice: NSObject {
        let intentID: UUID
        let application: FileOpeningApplication?
        init(intentID: UUID, application: FileOpeningApplication?) {
            self.intentID = intentID; self.application = application
        }
    }
    private var applicationIntent: ApplicationIntent?
    private var cancelApplicationMenu: (() -> Void)?
    private var isBusy: Bool { requestID != nil || pickerID != nil || applicationIntent != nil }
    private var contextIsCurrent: Bool { presented && window?.isVisible == true && isContextCurrent?() != false }

    init(record: ClipboardRecord, preferUnavailable: Bool = false, window: NSPanel? = nil,
         chooseFile: FilePicker? = nil, openURL: ((URL) -> Bool)? = nil,
         previewURL: ((URL) -> Void)? = nil, dismissPreview: (() -> Void)? = nil,
         applicationOpener: FileApplicationOpener? = nil, chooseApplication: ApplicationPicker? = nil,
         presentApplicationMenu: ApplicationMenuPresenter? = nil) {
        reference = .init(id: record.id, revision: record.revision)
        self.preferUnavailable = preferUnavailable
        self.chooseFile = chooseFile
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        self.previewURL = previewURL; self.dismissPreview = dismissPreview
        self.applicationOpener = applicationOpener ?? FileApplicationOpener()
        self.chooseApplication = chooseApplication; self.presentApplicationMenu = presentApplicationMenu
        let panel = window ?? FileReferencePanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.text("文件与位置 · \(record.title)")
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 620, height: 450)
        super.init(window: panel)
        panel.delegate = self
        buildInterface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(relativeTo parent: NSWindow?) {
        guard !presented, let window else { return }
        presented = true
        if let frame = (parent?.screen ?? NSScreen.main)?.visibleFrame {
            let size = NSSize(width: min(window.frame.width, frame.width), height: min(window.frame.height, frame.height))
            window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
        refresh()
    }

    func dismiss() {
        guard presented else { return }
        presented = false; requestID = nil; pickerID = nil; snapshotIsCurrent = false
        cancelApplicationSelection()
        let cancel = cancelPicker; cancelPicker = nil; cancel?()
        closeQuickLook()
        snapshot = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
        updateActions()
        onDismiss?()
    }
    func windowWillClose(_ notification: Notification) { dismiss() }

    func ownsWindow(_ candidate: NSWindow?) -> Bool {
        guard presented, let candidate else { return false }
        if quickLookURL != nil, QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
           preview === candidate, preview.dataSource === self { return true }
        var current: NSWindow? = candidate
        while let next = current {
            if next === window { return true }
            current = next.sheetParent ?? next.parent
        }
        return false
    }

    func contains(screenPoint: NSPoint) -> Bool {
        guard presented else { return false }
        if let window, window.isVisible, window.frame.contains(screenPoint) { return true }
        if let sheet = window?.attachedSheet, sheet.isVisible, sheet.frame.contains(screenPoint) { return true }
        if quickLookURL != nil, QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
           preview.dataSource === self, preview.isVisible, preview.frame.contains(screenPoint) { return true }
        return false
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard contextIsCurrent, event.type == .keyDown,
              (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        let flags = ShortcutChord.normalizedModifiers(event.modifierFlags)
        if event.keyCode == 53 || (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
            dismiss(); return true
        }
        if event.keyCode == 49, flags.isEmpty, window?.firstResponder === table {
            if !event.isARepeat { previewSelected() }
            return true
        }
        return false
    }

    @objc func refresh() {
        guard contextIsCurrent, !isBusy else { return }
        requestSnapshot { _ in }
    }

    private func requestSnapshot(after: @escaping (ClipboardFileRepairSnapshot) -> Void) {
        guard contextIsCurrent, !isBusy else { return }
        closeQuickLook()
        guard let onSnapshot else { fail(L10n.text("当前模式无法读取文件状态，请关闭后重试。")); return }
        let token = UUID(), expected = reference
        requestID = token; snapshotIsCurrent = false
        setStatus(L10n.text("正在检查文件状态…")); updateActions()
        onSnapshot(expected) { [weak self] result in
            guard let self, self.contextIsCurrent, self.requestID == token, self.reference == expected else { return }
            self.requestID = nil
            switch result {
            case .success(let next):
                guard next.record.id == expected.id, next.record.revision == expected.revision else {
                    self.fail(L10n.text("条目已变化，请关闭后重新打开。")); return
                }
                self.install(next)
                self.setStatus("")
                after(next)
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }

    @objc func previewSelected() { performAvailable { [weak self] url in self?.showQuickLook(url) } }
    @objc func openSelected() {
        performAvailable { [weak self] url in
            guard let self else { return }
            do { _ = try self.publications?.publish(fileURL: url, purpose: .externalOpen) }
            catch { self.fail(error.localizedDescription); return }
            if !self.openURL(url) { self.fail(L10n.text("系统未能打开此文件，请刷新状态后重试。")) }
        }
    }
    private func performAvailable(_ action: @escaping (URL) -> Void) {
        guard snapshotIsCurrent, let file = selectedFile, file.status == .available, !isBusy else { return }
        requestSnapshot { [weak self] next in
            guard let self, let current = self.selectedFile, Self.sameSlot(current, file),
                  current.rawURL == file.rawURL, current.status == .available, let url = current.url else {
                self?.setStatus(L10n.text("所选文件状态已改变，请检查位置；操作未执行。")); return
            }
            guard next.record.id == self.reference.id else { return }
            action(url)
        }
    }

    @objc func openWithSelected() {
        guard contextIsCurrent, snapshotIsCurrent, !isBusy,
              let file = selectedFile, file.status == .available else { return }
        requestSnapshot { [weak self] next in
            guard let self, let current = self.selectedFile, Self.sameSlot(current, file),
                  current.rawURL == file.rawURL, current.status == .available, let url = current.url else {
                self?.setStatus(L10n.text("所选文件状态已改变；未查询打开方式，请检查位置。")); return
            }
            let intent = ApplicationIntent(reference: self.reference, snapshot: next, file: current)
            self.applicationIntent = intent
            self.setStatus(L10n.text("正在查找本机可打开此文件的应用…")); self.updateActions()
            self.applicationOpener.applications(for: url) { [weak self] result in
                guard let self, self.applicationIntentIsCurrent(intent) else { return }
                switch result {
                case .success(let applications): self.showApplications(applications, intent: intent)
                case .failure(let error):
                    self.cancelApplicationSelection(); self.setStatus(error.localizedDescription); self.updateActions()
                }
            }
        }
    }

    private func applicationIntentIsCurrent(_ intent: ApplicationIntent) -> Bool {
        contextIsCurrent && applicationIntent?.id == intent.id && reference == intent.reference &&
            snapshotIsCurrent && snapshot == intent.snapshot && selectedFile == intent.file
    }

    private func showApplications(_ applications: [FileOpeningApplication], intent: ApplicationIntent) {
        let menu = NSMenu(title: L10n.text("打开方式"))
        menu.autoenablesItems = false
        if applications.isEmpty {
            let empty = NSMenuItem(title: L10n.text("没有推荐应用"), action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for application in applications {
            let item = NSMenuItem(title: application.menuTitle, action: #selector(selectApplication(_:)), keyEquivalent: "")
            item.target = self; item.toolTip = application.url.path
            item.representedObject = ApplicationMenuChoice(intentID: intent.id, application: application)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: L10n.text("其他应用…"), action: #selector(selectApplication(_:)), keyEquivalent: "")
        other.target = self; other.representedObject = ApplicationMenuChoice(intentID: intent.id, application: nil)
        menu.addItem(other)
        setStatus(L10n.text("仅使用所选应用打开此文件，不更改系统默认应用。"))
        let closed = { [weak self] in
            guard let self, self.applicationIntent?.id == intent.id, self.pickerID == nil else { return }
            self.applicationIntent = nil; self.cancelApplicationMenu = nil; self.updateActions()
        }
        let cancellation: () -> Void
        if let presentApplicationMenu { cancellation = presentApplicationMenu(menu, openWith, closed) }
        else {
            // popUp tracks synchronously; item actions run before it returns.
            // Install cancellation before entering its nested event loop, so a
            // parent dismissal can also retire the native menu while tracking.
            cancelApplicationMenu = { menu.cancelTracking() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: openWith.bounds.height), in: openWith)
            closed(); cancellation = { menu.cancelTracking() }
        }
        if applicationIntent?.id == intent.id, pickerID == nil { cancelApplicationMenu = cancellation }
    }

    @objc private func selectApplication(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? ApplicationMenuChoice,
              let intent = applicationIntent, choice.intentID == intent.id,
              applicationIntentIsCurrent(intent), pickerID == nil else { return }
        // Clear the menu cancellation before invoking it; menu-close callbacks
        // must never invalidate the picker or the final fresh-state request.
        let cancel = cancelApplicationMenu; cancelApplicationMenu = nil
        if let application = choice.application {
            applicationIntent = nil; cancel?(); launch(application, intent: intent)
        } else {
            guard let window else { return }
            let token = UUID(); pickerID = token; cancel?(); updateActions()
            let reply: (URL?) -> Void = { [weak self] url in
                guard let self, self.pickerID == token, self.applicationIntentIsCurrent(intent) else { return }
                self.pickerID = nil; self.cancelPicker = nil; self.applicationIntent = nil; self.updateActions()
                guard let url else { return }
                do { self.launch(try self.applicationOpener.application(at: url), intent: intent) }
                catch { self.setStatus(error.localizedDescription) }
            }
            let cancellation = chooseApplication?(window, reply) ?? presentApplicationPicker(window, reply: reply)
            if pickerID == token { cancelPicker = cancellation }
        }
    }

    private func launch(_ application: FileOpeningApplication, intent: ApplicationIntent) {
        guard contextIsCurrent, reference == intent.reference, snapshot == intent.snapshot,
              selectedFile == intent.file else { updateActions(); return }
        requestSnapshot { [weak self] next in
            guard let self, self.reference == intent.reference,
                  next.syncConfiguration == intent.snapshot.syncConfiguration,
                  next.sharingConfiguration == intent.snapshot.sharingConfiguration,
                  let current = self.selectedFile, Self.sameSlot(current, intent.file),
                  current.rawURL == intent.file.rawURL, current.status == .available, let url = current.url else {
                self?.setStatus(L10n.text("文件或当前账户状态已改变；未打开，请重新选择。")); return
            }
            let token = UUID(); self.requestID = token
            self.setStatus(L10n.text("正在使用 \(application.name) 打开所选文件…")); self.updateActions()
            self.applicationOpener.open(file: url, using: application) { [weak self] result in
                guard let self, self.contextIsCurrent, self.requestID == token, self.reference == intent.reference else { return }
                self.requestID = nil; self.updateActions()
                switch result {
                case .success: self.setStatus(L10n.text("已交给 \(application.name) 打开。"))
                case .failure(let error): self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    private func cancelApplicationSelection() {
        applicationIntent = nil
        let cancel = cancelApplicationMenu; cancelApplicationMenu = nil; cancel?()
    }

    private func presentApplicationPicker(_ parent: NSWindow, reply: @escaping (URL?) -> Void) -> () -> Void {
        let picker = NSOpenPanel()
        picker.title = L10n.text("选择打开此文件的应用"); picker.prompt = L10n.text("使用此应用")
        picker.message = L10n.text("仅打开所选文件，不更改系统默认应用。")
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseFiles = true; picker.canChooseDirectories = false
        picker.treatsFilePackagesAsDirectories = false; picker.allowsMultipleSelection = false
        picker.canCreateDirectories = false
        picker.beginSheetModal(for: parent) { result in reply(result == .OK ? picker.url : nil) }
        return { [weak picker] in picker?.cancel(nil) }
    }

    @objc func repairSelected() {
        guard contextIsCurrent, snapshotIsCurrent, !isBusy, let snapshot, let file = selectedFile else { return }
        if file.isOwned {
            guard file.status == .missing, let onRestoreOwned else { return }
            startMutation(snapshot, file: file) { reply in onRestoreOwned(snapshot, file, reply) }
        } else {
            guard !snapshot.isReadOnly, onRelocate != nil, let window else { return }
            let token = UUID(), expected = reference
            pickerID = token; updateActions(); closeQuickLook()
            let reply: (URL?) -> Void = { [weak self] url in
                guard let self, self.contextIsCurrent, self.pickerID == token else { return }
                self.pickerID = nil; self.cancelPicker = nil; self.updateActions()
                guard let url else { return }
                guard self.reference == expected, self.snapshot == snapshot, self.snapshotIsCurrent,
                      self.selectedFile == file, let onRelocate = self.onRelocate else { return }
                self.startMutation(snapshot, file: file) { completion in onRelocate(snapshot, file, url, completion) }
            }
            let cancellation = chooseFile?(window, file, reply) ?? presentPicker(window, file: file, reply: reply)
            // Injected pickers may finish synchronously, so never retain a completed cancellation.
            if pickerID == token { cancelPicker = cancellation }
        }
    }

    private func startMutation(_ old: ClipboardFileRepairSnapshot, file: ClipboardFileReference,
                               operation: (@escaping SnapshotReply) -> Void) {
        guard contextIsCurrent, !isBusy, snapshotIsCurrent, snapshot == old, selectedFile == file else { return }
        let token = UUID(), expected = reference
        requestID = token; snapshotIsCurrent = false; closeQuickLook()
        setStatus(file.isOwned ? L10n.text("正在重建已保存文件的打开副本…") : L10n.text("正在保存文件位置…")); updateActions()
        operation { [weak self] result in
            guard let self, self.contextIsCurrent, self.requestID == token, self.reference == expected else { return }
            self.requestID = nil
            switch result {
            case .success(let next):
                // External relinking canonicalizes this part's representations. The
                // original representation index need not survive that committed edit.
                let repaired = next.files.first { candidate in
                    candidate.partIndex == file.partIndex && (file.isOwned ? Self.sameSlot(candidate, file) : candidate.representationIndex == 0)
                }
                guard next.record.id == expected.id, next.record.revision >= expected.revision,
                      let repaired else {
                    self.fail(L10n.text("操作回执对应的条目已变化，请关闭后重新打开。")); return
                }
                self.reference = .init(id: next.record.id, revision: next.record.revision)
                self.install(next, selected: repaired)
                self.setStatus(file.isOwned ? L10n.text("已处理保存副本；可查看当前状态，再明确选择预览或打开。") : L10n.text("文件位置已更新。未自动打开或粘贴。"))
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }

    private func presentPicker(_ parent: NSWindow, file: ClipboardFileReference, reply: @escaping (URL?) -> Void) -> () -> Void {
        let picker = NSOpenPanel()
        picker.title = L10n.text("重新定位所选文件或文件夹")
        picker.message = L10n.text("选择此文件的新位置；其他文件不变。")
        picker.prompt = L10n.text("使用此位置")
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.canCreateDirectories = false
        // Do not probe a stale network path simply to choose an initial directory.
        picker.beginSheetModal(for: parent) { result in reply(result == .OK ? picker.url : nil) }
        return { [weak picker] in picker?.cancel(nil) }
    }

    private func install(_ next: ClipboardFileRepairSnapshot, selected: ClipboardFileReference? = nil) {
        let oldSlot = selected ?? selectedFile
        let first = snapshot == nil
        snapshot = next; snapshotIsCurrent = true
        table.reloadData()
        let row = oldSlot.flatMap { old in next.files.firstIndex { Self.sameSlot($0, old) } }
            ?? (first && preferUnavailable ? next.files.firstIndex { $0.status != .available } : nil)
            ?? (next.files.isEmpty ? nil : 0)
        if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updateActions()
    }
    private static func sameSlot(_ a: ClipboardFileReference, _ b: ClipboardFileReference) -> Bool {
        a.partIndex == b.partIndex && a.representationIndex == b.representationIndex
    }
    private func fail(_ message: String) { snapshotIsCurrent = false; setStatus(message); updateActions() }
    private func setStatus(_ message: String) { status.stringValue = message; status.toolTip = message }

    private func updateActions() {
        let file = selectedFile
        let usable = contextIsCurrent && snapshotIsCurrent && !isBusy
        preview.isEnabled = usable && file?.status == .available && file?.url != nil
        open.isEnabled = preview.isEnabled
        openWith.isEnabled = preview.isEnabled
        refreshButton.isEnabled = contextIsCurrent && !isBusy
        table.isEnabled = !isBusy
        repair.title = file?.isOwned == true ? L10n.text("从已保存原件重建打开副本") : L10n.text("重新定位…")
        repair.isEnabled = usable && file.map { $0.isOwned ? ($0.status == .missing && onRestoreOwned != nil) : (snapshot?.isReadOnly == false && onRelocate != nil) } == true
        guard let file else {
            path.stringValue = snapshot == nil ? L10n.text("正在读取文件位置…") : L10n.text("此条目没有文件引用。")
            explanation.stringValue = L10n.text("文件与文件夹按原剪贴板对象顺序显示。")
            return
        }
        path.stringValue = file.url?.path ?? L10n.text("无效文件地址（保留原始引用）")
        path.toolTip = file.url?.absoluteString
        let identity = L10n.text("第 \(table.selectedRow + 1) 项文件")
        let ownership = file.isOwned ? L10n.text("ClipShelf 保存的文件；打开的是独立副本。") : L10n.text("外部文件引用；ClipShelf 不持有原文件的备份。")
        let readOnly = snapshot?.isReadOnly == true && !file.isOwned ? L10n.text(" 当前共享内容为只读，不能重新定位。") : ""
        let special = file.status == .unsafeProjection ? L10n.text(" 打开副本的路径不安全，不自动覆盖或重建。") : ""
        explanation.stringValue = "\(identity) · \(Self.statusName(file.status))\n\(ownership)\(readOnly)\(special)"
    }

    static func statusName(_ value: ClipboardFileAvailability) -> String {
        switch value {
        case .available: return L10n.text("可用")
        case .missing: return L10n.text("位置缺失")
        case .unreadable: return L10n.text("不可访问")
        case .invalidURL: return L10n.text("地址无效")
        case .unsafeProjection: return L10n.text("打开副本路径不安全")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { snapshot?.files.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let snapshot, snapshot.files.indices.contains(row) else { return nil }
        let file = snapshot.files[row]
        let text = tableColumn?.identifier.rawValue == "status" ? Self.statusName(file.status) : "\(row + 1). \(file.url?.lastPathComponent ?? L10n.text("无效文件地址"))"
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityLabel(L10n.text("第 \(row + 1) 项文件，\(text)"))
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if applicationIntent != nil {
            cancelApplicationSelection()
            pickerID = nil
            let cancel = cancelPicker; cancelPicker = nil; cancel?()
        }
        closeQuickLook(); updateActions()
    }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView(); window.contentView = root
        defer { InterfaceLayout.apply(to: root) }
        let heading = NSTextField(labelWithString: L10n.text("所有文件位置"))
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let name = NSTableColumn(identifier: .init("name")); name.title = L10n.text("文件 / 文件夹"); name.width = 480; name.minWidth = 160
        let availability = NSTableColumn(identifier: .init("status")); availability.title = L10n.text("状态"); availability.width = 165; availability.minWidth = 155
        table.addTableColumn(name); table.addTableColumn(availability)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.rowHeight = 30
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(L10n.text("文件位置列表"))
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        path.isSelectable = true; path.maximumNumberOfLines = 2; path.lineBreakMode = .byTruncatingMiddle
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular); path.setAccessibilityLabel(L10n.text("所选文件完整路径"))
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3; explanation.setAccessibilityLabel(L10n.text("所选文件状态与归属"))
        status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 3; status.setAccessibilityLabel(L10n.text("文件操作状态"))
        preview.target = self; preview.action = #selector(previewSelected)
        open.target = self; open.action = #selector(openSelected)
        openWith.target = self; openWith.action = #selector(openWithSelected)
        repair.target = self; repair.action = #selector(repairSelected)
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        let close = NSButton(title: L10n.text("返回列表"), target: self, action: #selector(closeWindow)); close.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [preview, open, openWith]); actions.spacing = 8
        let footer = NSStackView(views: [repair, refreshButton, close]); footer.spacing = 8
        for view in [heading, scroll, path, explanation, actions, status, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: path.topAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            path.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), path.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            path.bottomAnchor.constraint(equalTo: explanation.topAnchor, constant: -8),
            explanation.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), explanation.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            explanation.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), actions.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), status.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 36), status.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        updateActions()
    }
    @objc private func closeWindow() { dismiss() }

    private func showQuickLook(_ url: URL) {
        if let previewURL { injectedPreviewIsOpen = true; previewURL(url); return }
        quickLookURL = url
        window?.makeKey()
        let panel = QLPreviewPanel.shared()
        panel?.updateController(); panel?.makeKeyAndOrderFront(nil)
    }
    private func closeQuickLook() {
        if injectedPreviewIsOpen { injectedPreviewIsOpen = false; dismissPreview?() }
        if quickLookURL != nil, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self {
            panel.orderOut(nil); panel.dataSource = nil
        }
        quickLookURL = nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { contextIsCurrent && quickLookURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { if panel.dataSource === self { panel.dataSource = nil }; quickLookURL = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { index == 0 ? quickLookURL as NSURL? : nil }
}
