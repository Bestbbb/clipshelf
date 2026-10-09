import AppKit
import ClipShelfCore
import Quartz
import UniformTypeIdentifiers
import PDFKit

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ShelfReadOnlyPDFView: PDFView {
    override func perform(_ action: PDFAction) {
        // PDF links may otherwise launch files, apps or printing through NSWorkspace.
        // This reader only follows destinations within the already-loaded document.
        if action is PDFActionGoTo { super.perform(action) }
    }
}

/// A parsed document is transferred once, after background preparation has finished.
private struct ShelfPDFDocument: @unchecked Sendable { let document: PDFDocument? }

private final class ResultsFocusView: NSCollectionView {
    override var acceptsFirstResponder: Bool { true }
    var onDropItems: (([NSPasteboardItem], Any?) -> Void)?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { onDropItems != nil && sender.draggingPasteboard.pasteboardItems?.isEmpty == false ? .copy : [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { onDropItems != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty, let onDropItems else { return false }
        onDropItems(items, sender.draggingSource)
        return true
    }
}

private final class ShelfDropSurface: NSVisualEffectView {
    var onDropItems: (([NSPasteboardItem], Any?) -> Void)?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { onDropItems != nil && sender.draggingPasteboard.pasteboardItems?.isEmpty == false ? .copy : [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { onDropItems != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty, let onDropItems else { return false }
        onDropItems(items, sender.draggingSource)
        return true
    }
}

private final class ClipboardCollectionItem: NSCollectionViewItem {
    var card: ClipboardCardView?
    override func loadView() { view = NSView() }
    func configure(_ card: ClipboardCardView) {
        self.card?.removeFromSuperview()
        self.card = card
        view.addSubview(card)
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: view.leadingAnchor), card.trailingAnchor.constraint(equalTo: view.trailingAnchor), card.topAnchor.constraint(equalTo: view.topAnchor), card.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }
}

/// Presents history without activating ClipShelf or performing clipboard side effects.
@MainActor
final class ClipboardPanelController: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate, NSCollectionViewDataSource, @preconcurrency QLPreviewPanelDataSource {
    var onPaste: ((ClipboardRecord, Bool) -> Void)?
    var onPasteRecords: (([ClipboardRecord], Bool) -> Void)?
    var onCopy: ((ClipboardRecord) -> Void)?
    var onCopyRecords: (([ClipboardRecord]) -> Void)?
    var onDelete: ((ClipboardRecord) -> Void)?
    var onDeleteRecords: (([ClipboardRecord]) -> Void)?
    var onEdit: ((ClipboardRecord, String, Data?) -> Void)?
    var onRename: ((ClipboardRecord, String) -> Void)?
    var onNewText: (() -> Void)?
    var onQueryChange: ((HistoryQuery) -> Void)?
    var onCreatePinboard: ((String, String) -> Void)?
    var onUpdatePinboard: ((Pinboard) -> Void)?
    var onReorderPinboards: (([UUID]) -> Void)?
    var onDeletePinboard: ((Pinboard) -> Void)?
    var onMoveRecords: (([ClipboardRecord], UUID?) -> Void)?
    var onRotateImage: ((ClipboardRecord) -> Void)?
    var onExtractText: ((ClipboardRecord) -> Void)?
    var onOpenRecord: ((ClipboardRecord) -> Void)?
    var onSettings: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDropItems: (([NSPasteboardItem], UUID?) -> Void)?
    var onCompactModeChange: ((Bool) -> Void)?
    var onShareRecord: ((ClipboardRecord) -> Void)?
    var onCopyImageFile: ((ClipboardRecord) -> Void)?
    /// The application loads payload bytes on a background queue and returns on main.
    var resolveRecord: ((UUID, @escaping (ClipboardRecord?) -> Void) -> Void)?
    var onDismiss: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onPermissions: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyTitle = NSTextField(labelWithString: "复制一点内容，从这里开始")
    private let emptyDescription = NSTextField(labelWithString: "在其他 App 中复制文本，再按 ⌘⇧V 打开 ClipShelf。")
    private let emptyStack = NSStackView()
    private let pauseButton = NSButton(title: "暂停记录", target: nil, action: nil)
    private let compactButton = NSButton(title: "紧凑", target: nil, action: nil)
    private var compactMode = false
    private let boardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loadMoreButton = NSButton(title: "加载更多", target: nil, action: nil)
    private var pinboards: [Pinboard] = []
    private var sources: [String: String] = [:]
    private var selectedBoardID: UUID?
    private var selectedKind: ClipboardContentKind?
    private var selectedSourceID: String?
    private var copiedAfter: Date?
    private var copiedBefore: Date?
    private var lastDateIndex = 0
    private var resultLimit = 300
    private let scrollView = NSScrollView()
    private let resultsView = ResultsFocusView()
    private var records: [ClipboardCardContent] = []
    private var filteredRecords: [ClipboardCardContent] = []
    private var cardViews: [ClipboardCardView] { resultsView.visibleItems().compactMap { ($0 as? ClipboardCollectionItem)?.card } }
    private var selectedID: UUID?
    private var selectedIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?
    private var eventMonitor: Any?
    private var detailWindow: NSPanel?
    private var linkPreview: LinkPreviewController?
    private var detailPDFView: PDFView?
    private var pdfPageObserver: NSObjectProtocol?
    private var pdfLoadTask: Task<Void, Never>?
    private var detailRecord: ClipboardRecord?
    private var detailEditor: NSTextView?
    private var initialDetailContents: NSAttributedString?
    private var previewFileURLs: [URL] = []
    private var inlineRecords: [UUID: ClipboardRecord] = [:]
    private var viewGeneration = UUID()
    private var queryGeneration = UUID()
    private var pendingActionID: UUID?
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailJobs: [() -> Void] = []
    private var activeThumbnailJobs = 0
    private var requestedThumbnails: Set<String> = []

    init() {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 404), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.title = "ClipShelf 剪贴板历史"
        panel.minSize = NSSize(width: 720, height: 312)
        super.init(window: panel)
        panel.delegate = self
        thumbnailCache.totalCostLimit = 32 * 1_024 * 1_024
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(records: [ClipboardRecord], on screen: NSScreen? = nil, status: String? = nil) {
        inlineRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        present(records.map(ClipboardCardContent.init), on: screen, status: status)
    }

    func show(metadata: [ClipboardRecordMetadata], on screen: NSScreen? = nil, status: String? = nil) {
        inlineRecords.removeAll()
        present(metadata.map(ClipboardCardContent.init), on: screen, status: status)
    }

    private func present(_ contents: [ClipboardCardContent], on screen: NSScreen?, status: String?) {
        viewGeneration = UUID()
        resultLimit = 300
        self.records = Array(contents.prefix(resultLimit))
        searchField.stringValue = ""
        selectedBoardID = nil
        selectedKind = nil
        selectedSourceID = nil
        copiedAfter = nil
        copiedBefore = nil
        lastDateIndex = 0
        boardPopup.selectItem(at: 0)
        typePopup.selectItem(at: 0)
        sourcePopup.selectItem(at: 0)
        datePopup.selectItem(at: 0)
        selectedID = self.records.first?.id
        selectedIDs = Set(self.records.first.map { [$0.id] } ?? [])
        selectionAnchorID = selectedID
        statusLabel.stringValue = status ?? "本机保存 · 随时取用"
        reloadResults(resetScroll: true)
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = max(520, min(1180, visible.width - 40))
        window?.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 18, width: width, height: compactMode ? 312 : 404), display: false)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        installEventMonitor()
        issueQuery(resetLimit: true)
    }

    /// Refreshes captured history while preserving a current query and selection.
    func update(records: [ClipboardRecord], status: String? = nil) {
        inlineRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        updateContents(records.map(ClipboardCardContent.init), status: status)
    }

    func update(metadata: [ClipboardRecordMetadata], status: String? = nil) {
        inlineRecords.removeAll()
        updateContents(metadata.map(ClipboardCardContent.init), status: status)
    }

    private func updateContents(_ contents: [ClipboardCardContent], status: String?) {
        self.records = Array(contents.prefix(resultLimit))
        if let status { statusLabel.stringValue = status }
        reloadResults()
    }

    func setCapturePaused(_ paused: Bool) {
        pauseButton.title = paused ? "继续记录" : "暂停记录"
        pauseButton.setAccessibilityLabel(paused ? "继续记录剪贴板" : "暂停记录剪贴板")
    }

    func edit(_ record: ClipboardRecord) { showDetail(record, editing: true) }

    func setCompactMode(_ compact: Bool) {
        compactMode = compact
        compactButton.state = compact ? .on : .off
        compactButton.toolTip = compact ? "切换为大卡片" : "切换为紧凑卡片"
        guard let window else { return }
        var frame = window.frame
        frame.size.height = compact ? 312 : 404
        window.setFrame(frame, display: true)
        updateCardLayout()
    }

    func setPinboards(_ pinboards: [Pinboard]) {
        self.pinboards = pinboards
        boardPopup.removeAllItems()
        boardPopup.addItem(withTitle: "全部内容")
        for board in self.pinboards {
            boardPopup.addItem(withTitle: board.name)
            boardPopup.lastItem?.representedObject = board.id
        }
        if let selectedBoardID, let index = self.pinboards.firstIndex(where: { $0.id == selectedBoardID }) { boardPopup.selectItem(at: index + 1) }
        else { selectedBoardID = nil; boardPopup.selectItem(at: 0) }
        if isVisible { reloadResults() }
    }

    func setSources(_ sources: [String: String]) {
        self.sources.merge(sources) { _, newer in newer }
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "所有来源 App")
        for (id, name) in self.sources.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
            sourcePopup.addItem(withTitle: name)
            sourcePopup.lastItem?.representedObject = id
        }
        if let selectedSourceID, let item = sourcePopup.itemArray.first(where: { $0.representedObject as? String == selectedSourceID }) { sourcePopup.select(item) }
    }

    func dismiss() {
        guard isVisible else { return }
        viewGeneration = UUID()
        pendingActionID = nil
        thumbnailJobs.removeAll()
        requestedThumbnails.removeAll()
        linkPreview?.dismiss()
        detailWindow?.close()
        window?.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        onDismiss?()
    }

    private func buildInterface() {
        guard let panel = window else { return }
        let background = ShelfDropSurface()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true
        let dragTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("io.github.bestbbb.clipshelf.record-id")]
        background.registerForDraggedTypes(dragTypes)
        background.onDropItems = { [weak self] items, source in self?.handleDrop(items, source: source) }
        panel.contentView = background

        let logo = NSTextField(labelWithString: "ClipShelf")
        logo.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString: "你的剪贴板，触手可及")
        subtitle.font = .systemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        let branding = NSStackView(views: [logo, subtitle])
        branding.orientation = .vertical
        branding.alignment = .leading
        branding.spacing = 3
        branding.setContentHuggingPriority(.required, for: .horizontal)

        searchField.placeholderString = "搜索内容或来源 App"
        searchField.font = .systemFont(ofSize: 13)
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("搜索剪贴板历史")
        searchField.setAccessibilityHelp("输入文字过滤历史，按回车进入结果，再按回车粘贴。")
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        let permissions = NSButton(image: NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "粘贴权限") ?? NSImage(), target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .inline
        permissions.toolTip = "设置直接粘贴所需的辅助功能权限"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "收起 ClipShelf") ?? NSImage(), target: self, action: #selector(closePanel))
        close.bezelStyle = .inline
        compactButton.image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: "切换紧凑卡片")
        compactButton.imagePosition = .imageOnly
        compactButton.bezelStyle = .inline
        compactButton.setButtonType(.toggle)
        compactButton.target = self
        compactButton.action = #selector(toggleCompactMode)
        compactButton.setAccessibilityLabel("切换紧凑卡片")
        let header = NSStackView(views: [branding, searchField, pauseButton, compactButton, permissions, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        boardPopup.addItem(withTitle: "全部内容")
        boardPopup.target = self
        boardPopup.action = #selector(boardChanged)
        boardPopup.setAccessibilityLabel("分组")
        let boardActions = NSPopUpButton(frame: .zero, pullsDown: true)
        boardActions.addItem(withTitle: "分组操作")
        for (title, action) in [("新建分组…", #selector(createBoard)), ("编辑当前分组…", #selector(renameBoard)), ("将当前分组前移", #selector(moveBoardEarlier)), ("将当前分组后移", #selector(moveBoardLater)), ("删除当前分组…", #selector(deleteBoard))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            boardActions.menu?.addItem(item)
        }
        typePopup.addItem(withTitle: "所有类型")
        for kind in ClipboardContentKind.allCases {
            typePopup.addItem(withTitle: Self.kindTitle(kind))
            typePopup.lastItem?.representedObject = kind.rawValue
        }
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        typePopup.setAccessibilityLabel("按内容类型筛选")
        sourcePopup.addItem(withTitle: "所有来源 App")
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.setAccessibilityLabel("按来源应用筛选")
        datePopup.addItems(withTitles: ["任意时间", "今天", "最近 7 天", "最近 30 天", "自定义时间范围…"])
        datePopup.target = self
        datePopup.action = #selector(dateChanged)
        datePopup.setAccessibilityLabel("按复制时间筛选")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        loadMoreButton.bezelStyle = .inline
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore)
        let filters = NSStackView(views: [boardPopup, boardActions, spacer, typePopup, sourcePopup, datePopup, loadMoreButton])
        filters.orientation = .horizontal
        filters.alignment = .centerY
        filters.spacing = 10
        [boardPopup, typePopup, sourcePopup, datePopup, boardActions].forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: 11) }

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 222, height: 224)
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        resultsView.collectionViewLayout = layout
        resultsView.dataSource = self
        resultsView.registerForDraggedTypes(dragTypes)
        resultsView.onDropItems = { [weak self] items, source in self?.handleDrop(items, source: source) }
        resultsView.isSelectable = false
        resultsView.backgroundColors = [.clear]
        resultsView.register(ClipboardCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("clipboard-card"))
        resultsView.frame = NSRect(x: 0, y: 0, width: 1076, height: 239)
        resultsView.autoresizingMask = [.width]
        scrollView.documentView = resultsView
        resultsView.setAccessibilityRole(.group)
        resultsView.setAccessibilityLabel("剪贴板搜索结果")

        emptyTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        emptyTitle.alignment = .center
        emptyDescription.font = .systemFont(ofSize: 12)
        emptyDescription.textColor = .secondaryLabelColor
        emptyDescription.alignment = .center
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptyDescription)
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 10

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        let hints = NSTextField(labelWithString: "↵ 粘贴   ⇧↵ 纯文本   ⌘1–9 快速粘贴   esc 收起")
        hints.font = .systemFont(ofSize: 10)
        hints.textColor = .tertiaryLabelColor
        hints.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, countLabel, hints])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16

        for view in [header, filters, scrollView, emptyStack, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            header.heightAnchor.constraint(equalToConstant: 43),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            filters.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            filters.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            filters.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 13),
            filters.heightAnchor.constraint(equalToConstant: 24),
            boardPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            sourcePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            scrollView.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 17),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -18),
            emptyStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        // Marked text remains owned by the input method; results update at commit.
        guard !isComposing else { return }
        // Starting a search intentionally leaves the current board: results are global
        // unless the user subsequently selects a board as an explicit search filter.
        selectedBoardID = nil
        boardPopup.selectItem(at: 0)
        issueQuery(resetLimit: true)
    }

    private var isComposing: Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    private var isEditingSearch: Bool { searchField.currentEditor() === window?.firstResponder || window?.firstResponder === searchField }
    private var selectedRecord: ClipboardCardContent? { filteredRecords.first(where: { $0.id == selectedID }) }
    private var selectedRecords: [ClipboardCardContent] { filteredRecords.filter { selectedIDs.contains($0.id) } }

    private func reloadResults(resetScroll: Bool = false) {
        let previousOrigin = resetScroll ? NSPoint.zero : scrollView.contentView.bounds.origin
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredRecords = onQueryChange != nil ? records : records.filter {
            (query.isEmpty || $0.text.localizedStandardContains(query) || $0.title.localizedStandardContains(query) || ($0.ocrText?.localizedStandardContains(query) ?? false) || ($0.sourceApp?.localizedStandardContains(query) ?? false))
            && (selectedKind == nil || $0.kind == selectedKind)
            && (selectedSourceID == nil || $0.sourceBundleID == selectedSourceID)
            && (selectedBoardID == nil || $0.pinboardID == selectedBoardID)
            && (copiedAfter == nil || $0.copiedAt >= copiedAfter!)
            && (copiedBefore == nil || $0.copiedAt <= copiedBefore!)
        }
        if !filteredRecords.contains(where: { $0.id == selectedID }) { selectedID = filteredRecords.first?.id }
        selectedIDs.formIntersection(Set(filteredRecords.map(\.id)))
        if selectedIDs.isEmpty, let selectedID { selectedIDs.insert(selectedID) }
        resultsView.reloadData()
        emptyStack.isHidden = !filteredRecords.isEmpty
        if query.isEmpty {
            emptyTitle.stringValue = "复制一点内容，从这里开始"
            emptyDescription.stringValue = "在其他 App 中复制文本，再按 ⌘⇧V 打开 ClipShelf。"
        } else {
            emptyTitle.stringValue = "没有找到相关内容"
            emptyDescription.stringValue = "试试更短的关键词，或按 esc 清空搜索。"
        }
        updateSelectionCount()
        loadMoreButton.isHidden = onQueryChange == nil || records.count < resultLimit
        resultsView.layoutSubtreeIfNeeded()
        let maximumX = max(0, resultsView.bounds.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(previousOrigin.x, maximumX), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { filteredRecords.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clipboard-card"), for: indexPath) as! ClipboardCollectionItem
        let record = filteredRecords[indexPath.item]
        item.configure(makeCard(record: record, position: indexPath.item))
        return item
    }

    private func makeCard(record: ClipboardCardContent, position: Int) -> ClipboardCardView {
        let card = ClipboardCardView(record: record, position: position, compact: compactMode)
        card.isSelected = selectedIDs.contains(record.id)
        card.onSelect = { [weak self] in
            guard let self else { return }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if self.selectedIDs.count > 1, self.selectedIDs.contains(record.id), !modifiers.contains(.shift), !modifiers.contains(.command) {
                self.window?.makeFirstResponder(self.resultsView)
                return
            }
            self.select(record.id, focusResults: true, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        }
        card.onOpen = { [weak self] in
            guard let self else { return }
            self.select(record.id, focusResults: true)
            let plain = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            self.resolve(record) { self.onPaste?($0, plain) }
        }
        card.onDragRequested = { [weak self, weak card] event in
            guard let self else { return }
            let contents = self.selectedIDs.contains(record.id) ? self.selectedRecords : [record]
            self.resolve(contents) { records in
                guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                card?.beginDrag(records: records, event: event)
            }
        }
        if record.kind == .image { requestThumbnail(record, for: card) }
        let menu = NSMenu()
        for (title, action) in [("粘贴", #selector(pasteFromMenu(_:))), ("以纯文本粘贴", #selector(pastePlainFromMenu(_:))), ("复制", #selector(copyFromMenu(_:))), ("预览", #selector(previewFromMenu(_:))), ("打开", #selector(openFromMenu(_:))), ("编辑", #selector(editFromMenu(_:))), ("重命名", #selector(renameFromMenu(_:))), ("删除", #selector(deleteFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = record.id
            menu.addItem(item)
        }
        card.menu = menu
        let shareItem = NSMenuItem(title: "分享…", action: #selector(shareFromMenu(_:)), keyEquivalent: "")
        shareItem.target = self
        shareItem.representedObject = record.id
        menu.insertItem(shareItem, at: max(0, menu.items.count - 1))
        if record.kind == .image {
            let fileItem = NSMenuItem(title: "复制为图片文件", action: #selector(copyImageFileFromMenu(_:)), keyEquivalent: "")
            fileItem.target = self
            fileItem.representedObject = record.id
            menu.insertItem(fileItem, at: 3)
        }
        let moveMenu = NSMenu()
        for (name, id) in [("取消固定", Optional<UUID>.none)] + pinboards.map({ ($0.name, Optional($0.id)) }) {
            let item = NSMenuItem(title: name, action: #selector(moveFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["recordID": record.id.uuidString, "boardID": id?.uuidString ?? ""]
            item.state = record.pinboardID == id ? .on : .off
            moveMenu.addItem(item)
        }
        let moveItem = NSMenuItem(title: "固定到分组", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.insertItem(moveItem, at: max(0, menu.items.count - 1))
        return card
    }

    private func select(_ id: UUID, focusResults: Bool, extending: Bool = false, toggling: Bool = false) {
        if extending,
           let anchor = filteredRecords.firstIndex(where: { $0.id == (selectionAnchorID ?? selectedID) }),
           let next = filteredRecords.firstIndex(where: { $0.id == id }) {
            selectedIDs = Set(filteredRecords[min(anchor, next)...max(anchor, next)].map(\.id))
        } else if toggling {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            selectionAnchorID = id
        } else {
            selectedIDs = [id]
            selectionAnchorID = id
        }
        selectedID = id
        if toggling, !selectedIDs.contains(id) { selectedID = filteredRecords.first(where: { selectedIDs.contains($0.id) })?.id }
        for card in cardViews { card.isSelected = selectedIDs.contains(card.record.id) }
        updateSelectionCount()
        if focusResults { window?.makeFirstResponder(resultsView) }
        if let index = filteredRecords.firstIndex(where: { $0.id == id }) { revealItem(at: index) }
    }

    private func revealItem(at index: Int) {
        resultsView.layoutSubtreeIfNeeded()
        guard let layout = resultsView.collectionViewLayout,
              let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let visible = scrollView.contentView.bounds
        var targetX = visible.minX
        if frame.minX < visible.minX { targetX = frame.minX }
        else if frame.maxX > visible.maxX { targetX = frame.maxX - visible.width }
        let maximumX = max(0, layout.collectionViewContentSize.width - visible.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(max(0, targetX), maximumX), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func moveSelection(_ offset: Int, extending: Bool = false) {
        guard !filteredRecords.isEmpty else { return }
        let old = filteredRecords.firstIndex(where: { $0.id == selectedID }) ?? 0
        let index = max(0, min(filteredRecords.count - 1, old + offset))
        select(filteredRecords[index].id, focusResults: true, extending: extending)
    }

    private func updateSelectionCount() {
        countLabel.stringValue = selectedIDs.count > 1 ? "\(filteredRecords.count) 条 · 已选 \(selectedIDs.count) 条" : "\(filteredRecords.count) 条"
    }

    private func loadPayload(_ id: UUID, completion: @escaping (ClipboardRecord?) -> Void) {
        if let record = inlineRecords[id] { completion(record); return }
        guard let resolveRecord else { completion(nil); return }
        resolveRecord(id) { record in
            DispatchQueue.main.async { completion(record) }
        }
    }

    private func handleDrop(_ items: [NSPasteboardItem], source: Any?) {
        if let card = source as? ClipboardCardView, card.window === window {
            // Trust the in-process source object's IDs, never a pasteboard marker.
            let ids = Set(card.draggedRecordIDs)
            let contents = filteredRecords.filter { ids.contains($0.id) }
            let destination = selectedBoardID
            resolve(contents) { [weak self] in self?.onMoveRecords?($0, destination) }
        } else {
            onDropItems?(items, selectedBoardID)
        }
    }

    private func resolve(_ content: ClipboardCardContent, action: @escaping (ClipboardRecord) -> Void) {
        resolve([content]) { if let record = $0.first { action(record) } }
    }

    /// A delayed read never pastes after a new panel session, query, selection, or item revision.
    private func resolve(_ contents: [ClipboardCardContent], action: @escaping ([ClipboardRecord]) -> Void) {
        guard !contents.isEmpty, isVisible else { return }
        let actionID = UUID()
        pendingActionID = actionID
        let session = viewGeneration
        let query = queryGeneration
        let selection = selectedIDs
        let expected = Dictionary(uniqueKeysWithValues: contents.map { ($0.id, $0.revision) })
        func valid() -> Bool {
            isVisible && pendingActionID == actionID && viewGeneration == session && queryGeneration == query && selectedIDs == selection
                && expected.allSatisfy { id, revision in filteredRecords.contains(where: { $0.id == id && $0.revision == revision }) }
        }
        func read(_ index: Int, accumulated: [ClipboardRecord]) {
            guard valid() else { return }
            if index == contents.count { pendingActionID = nil; action(accumulated); return }
            let expectedContent = contents[index]
            loadPayload(expectedContent.id) { [weak self] record in
                guard let self, valid() else { return }
                guard let record, record.id == expectedContent.id, record.revision == expectedContent.revision else {
                    self.pendingActionID = nil
                    self.statusLabel.stringValue = "条目已变化或暂时无法读取，请重新选择。"
                    return
                }
                read(index + 1, accumulated: accumulated + [record])
            }
        }
        read(0, accumulated: [])
    }

    private func requestThumbnail(_ content: ClipboardCardContent, for card: ClipboardCardView) {
        let cacheKey = "\(content.id)-\(content.revision)-512"
        if let image = thumbnailCache.object(forKey: cacheKey as NSString) { card.applyThumbnail(image); return }
        let session = viewGeneration
        let requestID = "\(session)-\(cacheKey)"
        guard requestedThumbnails.insert(requestID).inserted else { return }
        thumbnailJobs.append { [weak self] in
            guard let self else { return }
            guard self.viewGeneration == session else { self.completeThumbnailJob(requestID); return }
            self.loadPayload(content.id) { [weak self] record in
                guard let self else { return }
                guard let record, record.revision == content.revision, self.viewGeneration == session else { self.completeThumbnailJob(requestID); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = ClipboardCardView.thumbnailCGImage(for: record, maxPixelSize: 512)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.viewGeneration == session {
                            let preview = image.map { NSImage(cgImage: $0, size: .zero) }
                            if let preview, let image { self.thumbnailCache.setObject(preview, forKey: cacheKey as NSString, cost: image.bytesPerRow * image.height) }
                            for card in self.cardViews where card.record.id == content.id && card.record.revision == content.revision { card.applyThumbnail(preview) }
                        }
                        self.completeThumbnailJob(requestID)
                    }
                }
            }
        }
        startThumbnailJobs()
    }

    private func startThumbnailJobs() {
        while activeThumbnailJobs < 2, !thumbnailJobs.isEmpty {
            activeThumbnailJobs += 1
            thumbnailJobs.removeFirst()()
        }
    }

    private func completeThumbnailJob(_ id: String) {
        requestedThumbnails.remove(id)
        activeThumbnailJobs = max(0, activeThumbnailJobs - 1)
        startThumbnailJobs()
    }

    private func pasteSelection(plain: Bool) {
        let chosen = selectedRecords
        resolve(chosen) { [weak self] records in
            if records.count == 1, let record = records.first { self?.onPaste?(record, plain) }
            else if records.count > 1 { self?.onPasteRecords?(records, plain) }
        }
    }

    private func copySelection() {
        let chosen = selectedRecords
        resolve(chosen) { [weak self] records in
            if records.count == 1, let record = records.first { self?.onCopy?(record) }
            else if records.count > 1 { self?.onCopyRecords?(records) }
        }
    }

    private func deleteSelection() {
        let chosen = selectedRecords
        resolve(chosen) { [weak self] records in
            if let onDeleteRecords = self?.onDeleteRecords { onDeleteRecords(records) }
            else { records.forEach { self?.onDelete?($0) } }
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.window, !self.isComposing else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        if command, !flags.contains(.option), !flags.contains(.control) {
            let numbers: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if let index = numbers[event.keyCode] {
                if !event.isARepeat, filteredRecords.indices.contains(index) { resolve(filteredRecords[index]) { [weak self] in self?.onPaste?($0, shift) } }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": window?.makeFirstResponder(searchField); return true
            case ",": onSettings?(); return true
            case "t": onPauseToggle?(); return true
            case "n": if shift { createBoard() } else { onNewText?() }; return true
            case "o" where !isEditingSearch:
                if let selectedRecord { resolve(selectedRecord) { [weak self] in self?.onOpenRecord?($0) } }
                return true
            case "g" where !isEditingSearch:
                revealSelection()
                return true
            case "c" where !isEditingSearch:
                copySelection()
                return true
            case "z" where !isEditingSearch:
                onUndo?()
                return true
            case "a" where !isEditingSearch:
                selectedIDs = Set(filteredRecords.map(\.id))
                cardViews.forEach { $0.isSelected = true }
                updateSelectionCount()
                return true
            case "e" where !isEditingSearch:
                if let selectedRecord { resolve(selectedRecord) { [weak self] in self?.showDetail($0, editing: true) } }
                return true
            case "r" where !isEditingSearch:
                if let selectedRecord { resolve(selectedRecord) { [weak self] in self?.rename($0) } }
                return true
            default: break
            }
        }
        switch event.keyCode {
        case 53:
            if !searchField.stringValue.isEmpty { searchField.stringValue = ""; issueQuery(resetLimit: true); window?.makeFirstResponder(searchField) }
            else { dismiss() }
            return true
        case 36, 76:
            guard !command, !flags.contains(.option), !flags.contains(.control) else { return false }
            if isEditingSearch { if let selectedRecord { select(selectedRecord.id, focusResults: true) }; return true }
            if !event.isARepeat { pasteSelection(plain: shift) }
            return true
        case 125 where isEditingSearch:
            if let selectedRecord { select(selectedRecord.id, focusResults: true) }
            return true
        case 48 where isEditingSearch && !shift:
            if let selectedRecord { select(selectedRecord.id, focusResults: true) }
            return true
        case 48 where !isEditingSearch && shift:
            window?.makeFirstResponder(searchField)
            return true
        case 49 where !isEditingSearch && !command:
            if let selectedRecord { resolve(selectedRecord) { [weak self] in self?.showDetail($0, editing: false) } }
            return true
        case 123 where !isEditingSearch && command: moveBoardSelection(-1); return true
        case 124 where !isEditingSearch && command: moveBoardSelection(1); return true
        case 126 where !isEditingSearch && command:
            if let first = filteredRecords.first { select(first.id, focusResults: true, extending: shift) }
            return true
        case 125 where !isEditingSearch && command:
            if let last = filteredRecords.last { select(last.id, focusResults: true, extending: shift) }
            return true
        case 123 where !isEditingSearch: moveSelection(-1, extending: shift); return true
        case 124 where !isEditingSearch: moveSelection(1, extending: shift); return true
        case 51 where !isEditingSearch, 117 where !isEditingSearch:
            if !event.isARepeat { deleteSelection() }
            return true
        default:
            // Route the original event to the search field, including input-method
            // initiation, instead of reconstructing text from keyboard characters.
            if !isEditingSearch, !command, !flags.contains(.control),
               let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value >= 0x20 && !($0.value >= 0xF700 && $0.value <= 0xF8FF) }) {
                window?.makeFirstResponder(searchField)
            }
            return false
        }
    }

    private func recordFromMenu(_ sender: NSMenuItem) -> ClipboardCardContent? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return filteredRecords.first(where: { $0.id == id })
    }

    private static func kindTitle(_ kind: ClipboardContentKind) -> String {
        switch kind { case .text: return "文本"; case .link: return "链接"; case .image: return "图片"; case .file: return "文件"; case .color: return "颜色" }
    }

    private func issueQuery(resetLimit: Bool) {
        queryGeneration = UUID()
        if resetLimit { resultLimit = 300; scrollView.contentView.scroll(to: .zero) }
        let query = HistoryQuery(text: searchField.stringValue, kind: selectedKind, sourceBundleID: selectedSourceID, copiedAfter: copiedAfter, copiedBefore: copiedBefore, pinboardIDs: Set(selectedBoardID.map { [$0] } ?? []), includePinned: true, limit: resultLimit)
        if let onQueryChange { onQueryChange(query) } else { reloadResults(resetScroll: resetLimit) }
    }

    @objc private func boardChanged() { selectedBoardID = boardPopup.selectedItem?.representedObject as? UUID; issueQuery(resetLimit: true) }
    @objc private func typeChanged() { selectedKind = (typePopup.selectedItem?.representedObject as? String).flatMap(ClipboardContentKind.init(rawValue:)); issueQuery(resetLimit: true) }
    @objc private func sourceChanged() { selectedSourceID = sourcePopup.selectedItem?.representedObject as? String; issueQuery(resetLimit: true) }
    @objc private func loadMore() { resultLimit += 300; issueQuery(resetLimit: false) }

    @objc private func dateChanged() {
        if datePopup.indexOfSelectedItem == 4 { promptDateRange(); return }
        copiedBefore = nil
        switch datePopup.indexOfSelectedItem {
        case 1: copiedAfter = Calendar.current.startOfDay(for: Date())
        case 2: copiedAfter = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case 3: copiedAfter = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        default: copiedAfter = nil
        }
        lastDateIndex = datePopup.indexOfSelectedItem
        issueQuery(resetLimit: true)
    }

    private func promptDateRange() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "按复制时间筛选"
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        let start = NSDatePicker()
        let end = NSDatePicker()
        for picker in [start, end] { picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = [.yearMonthDay, .hourMinute] }
        start.dateValue = copiedAfter ?? Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        end.dateValue = copiedBefore ?? Date()
        let fields = NSStackView(views: [NSTextField(labelWithString: "开始（含）"), start, NSTextField(labelWithString: "结束（含）"), end])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 110)
        alert.accessoryView = fields
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { self.datePopup.selectItem(at: self.lastDateIndex); return }
            guard start.dateValue <= end.dateValue else { self.datePopup.selectItem(at: self.lastDateIndex); self.statusLabel.stringValue = "开始时间不能晚于结束时间"; return }
            self.copiedAfter = start.dateValue
            self.copiedBefore = end.dateValue
            self.lastDateIndex = 4
            self.issueQuery(resetLimit: true)
        }
    }

    private func moveBoardSelection(_ offset: Int) {
        let next = max(0, min(boardPopup.numberOfItems - 1, boardPopup.indexOfSelectedItem + offset))
        boardPopup.selectItem(at: next)
        boardChanged()
    }

    private func revealSelection() {
        guard let record = selectedRecord else { return }
        searchField.stringValue = ""
        selectedKind = nil; typePopup.selectItem(at: 0)
        selectedSourceID = nil; sourcePopup.selectItem(at: 0)
        copiedAfter = nil; copiedBefore = nil; datePopup.selectItem(at: 0)
        selectedBoardID = record.pinboardID
        if let index = pinboards.firstIndex(where: { $0.id == record.pinboardID }) { boardPopup.selectItem(at: index + 1) } else { boardPopup.selectItem(at: 0) }
        issueQuery(resetLimit: true)
        if filteredRecords.contains(where: { $0.id == record.id }) { select(record.id, focusResults: true) }
    }

    private func promptBoard(_ board: Pinboard?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = board == nil ? "新建分组" : "编辑分组"
        alert.informativeText = "固定的内容不受历史保留期限影响。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let name = NSTextField(string: board?.name ?? "")
        name.placeholderString = "例如：常用回复、项目资料"
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 26))
        color.color = ClipboardCardView.hexColor(board?.color ?? "#4F7CFF") ?? .controlAccentColor
        color.setAccessibilityLabel("分组颜色")
        let fields = NSStackView(views: [name, color])
        fields.orientation = .horizontal
        fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        alert.accessoryView = fields
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { self.statusLabel.stringValue = "分组名称不能为空"; return }
            let hex = Self.hexString(color.color)
            if var board { board.name = value; board.color = hex; self.onUpdatePinboard?(board) }
            else { self.onCreatePinboard?(value, hex) }
        }
        alert.window.initialFirstResponder = name
    }

    @objc private func createBoard() { promptBoard(nil) }
    @objc private func renameBoard() { if let board = pinboards.first(where: { $0.id == selectedBoardID }) { promptBoard(board) } }
    @objc private func moveBoardEarlier() { reorderCurrentBoard(by: -1) }
    @objc private func moveBoardLater() { reorderCurrentBoard(by: 1) }
    private func reorderCurrentBoard(by offset: Int) {
        guard let index = pinboards.firstIndex(where: { $0.id == selectedBoardID }), pinboards.indices.contains(index + offset) else { return }
        var reordered = pinboards
        reordered.swapAt(index, index + offset)
        onReorderPinboards?(reordered.map(\.id))
    }
    @objc private func deleteBoard() {
        guard let board = pinboards.first(where: { $0.id == selectedBoardID }) else { return }
        // The application owns the destructive-action choices and confirmation.
        onDeletePinboard?(board)
    }

    @objc private func moveFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String], let id = payload["recordID"].flatMap(UUID.init(uuidString:)), let record = filteredRecords.first(where: { $0.id == id }) else { return }
        let chosen = selectedIDs.contains(id) ? selectedRecords : [record]
        let destination = payload["boardID"].flatMap(UUID.init(uuidString:))
        resolve(chosen) { [weak self] in self?.onMoveRecords?($0, destination) }
    }

    private func showDetail(_ record: ClipboardRecord, editing: Bool) {
        linkPreview?.dismiss()
        if let pdf = record.parts.flatMap(\.representations).first(where: { ClipboardCardContent.isPDFType($0.typeIdentifier) }) {
            showPDFPreview(record, data: pdf.data)
            return
        }
        if record.kind == .file { showFilePreview(record); return }
        detailWindow?.close()
        if !editing, record.kind == .link, let url = URL(string: record.text.trimmingCharacters(in: .whitespacesAndNewlines)), LinkPreviewController.allows(url) {
            let session = viewGeneration
            let preview = LinkPreviewController(url: url)
            linkPreview = preview
            preview.onDismiss = { [weak self, weak preview] in
                guard let self, self.linkPreview === preview else { return }
                self.linkPreview = nil
                if self.isVisible, self.viewGeneration == session { self.window?.makeKey(); self.window?.makeFirstResponder(self.resultsView) }
            }
            preview.present(relativeTo: window)
            return
        }
        let detail = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        let editingText = editing && record.kind != .image
        detail.title = record.kind == .image ? "图片预览" : (editingText ? "编辑剪贴板内容" : "预览剪贴板内容")
        detail.level = .floating
        detail.hidesOnDeactivate = false
        detail.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        detail.isReleasedWhenClosed = false
        detail.minSize = NSSize(width: 440, height: 300)
        detail.delegate = self
        detailRecord = record
        detailWindow = detail
        let root = NSView()
        detail.contentView = root
        let context = NSTextField(labelWithString: "\(record.sourceApp ?? "剪贴板") · \(record.copiedAt.formatted(date: .abbreviated, time: .shortened))")
        context.font = .systemFont(ofSize: 11)
        context.textColor = .secondaryLabelColor
        context.lineBreakMode = .byTruncatingTail
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: .zero)
        editor.isEditable = editingText
        editor.isSelectable = true
        editor.isRichText = true
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .complete }
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.font = .systemFont(ofSize: 14)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if let data = record.rtf, let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            editor.textStorage?.setAttributedString(attributed)
        } else { editor.string = record.text }
        editor.setAccessibilityLabel(editingText ? "编辑内容" : "内容预览")
        detailEditor = editor
        initialDetailContents = NSAttributedString(attributedString: editor.attributedString())
        scroll.documentView = editor
        if record.kind == .image {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 580, height: 320))
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "正在读取图片")
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            imageView.setAccessibilityLabel(record.title)
            scroll.documentView = imageView
            scroll.hasVerticalScroller = false
            DispatchQueue.global(qos: .userInitiated).async {
                let image = ClipboardCardView.thumbnailCGImage(for: record, maxPixelSize: 2048)
                DispatchQueue.main.async { [weak self, weak detail, weak imageView] in
                    guard let self, let detail, self.detailWindow === detail, self.detailRecord?.id == record.id else { return }
                    imageView?.image = image.map { NSImage(cgImage: $0, size: .zero) } ?? NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: "无法读取图片")
                }
            }
        }
        let note = NSTextField(labelWithString: record.kind == .image ? "文字识别在本机完成；旋转后会更新当前图片。" : (editingText && record.html != nil && record.rtf == nil ? "此条目仅有 HTML 格式；编辑后将保存为文本及原生富文本。" : (editingText ? "编辑后更新当前条目。可使用系统文字格式菜单。" : "内容只读；编辑不会立即粘贴到其他 App。")))
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: editingText ? "取消" : "关闭", target: self, action: #selector(closeDetail))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let primary = NSButton(title: editingText ? "保存修改" : "编辑", target: self, action: editingText ? #selector(saveDetail) : #selector(editDetail))
        primary.bezelStyle = .rounded
        primary.isEnabled = !editingText || onEdit != nil
        // No Return equivalent: line breaks must remain available in the editor.
        let actions = NSStackView(views: [cancel, primary])
        if record.kind == .image {
            actions.removeArrangedSubview(primary)
            primary.removeFromSuperview()
            let rotate = NSButton(title: "向左旋转", target: self, action: #selector(rotateDetail))
            rotate.bezelStyle = .rounded
            rotate.isEnabled = onRotateImage != nil
            let extract = NSButton(title: "识别文字", target: self, action: #selector(extractDetail))
            extract.bezelStyle = .rounded
            extract.isEnabled = onExtractText != nil
            actions.addArrangedSubview(rotate)
            actions.addArrangedSubview(extract)
        } else if record.kind == .color && editingText {
            let picker = NSColorWell(frame: NSRect(x: 0, y: 0, width: 48, height: 25))
            picker.color = ClipboardCardView.hexColor(record.text) ?? .controlAccentColor
            picker.target = self
            picker.action = #selector(colorChanged(_:))
            picker.setAccessibilityLabel("选择颜色")
            actions.insertArrangedSubview(picker, at: 0)
        }
        actions.orientation = .horizontal
        actions.spacing = 8
        for view in [context, scroll, note, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            context.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), context.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), context.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), scroll.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), note.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        detail.setFrameOrigin(NSPoint(x: screen.midX - 310, y: screen.midY - 230))
        window?.addChildWindow(detail, ordered: .above)
        detail.makeKeyAndOrderFront(nil)
        detail.makeFirstResponder(record.kind == .image ? cancel : editor)
    }

    private func showPDFPreview(_ record: ClipboardRecord, data: Data) {
        detailWindow?.close()
        let detail = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        detail.title = ClipboardCardContent(record).title
        detail.level = .floating; detail.hidesOnDeactivate = false; detail.isReleasedWhenClosed = false
        detail.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        detail.minSize = NSSize(width: 500, height: 350)
        detail.delegate = self
        detailWindow = detail; detailRecord = record
        let pdf = ShelfReadOnlyPDFView()
        pdf.autoScales = true; pdf.displayMode = .singlePageContinuous; pdf.displayDirection = .vertical
        pdf.displaysPageBreaks = true; pdf.backgroundColor = .underPageBackgroundColor
        pdf.setAccessibilityLabel("只读 PDF 文稿预览")
        detailPDFView = pdf
        let page = NSTextField(labelWithString: "正在读取 PDF…")
        page.textColor = .secondaryLabelColor; page.font = .systemFont(ofSize: 11)
        let previous = NSButton(title: "上一页", target: pdf, action: #selector(PDFView.goToPreviousPage(_:)))
        let next = NSButton(title: "下一页", target: pdf, action: #selector(PDFView.goToNextPage(_:)))
        let zoomOut = NSButton(title: "缩小", target: pdf, action: #selector(PDFView.zoomOut(_:)))
        let zoomIn = NSButton(title: "放大", target: pdf, action: #selector(PDFView.zoomIn(_:)))
        let close = NSButton(title: "返回列表", target: self, action: #selector(closeDetail)); close.keyEquivalent = "\u{1b}"
        let controls = NSStackView(views: [previous, next, zoomOut, zoomIn, close]); controls.spacing = 8
        let note = NSTextField(labelWithString: "只读预览 · 保留原始 PDF · 不打开文稿内的外部链接")
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
        let root = NSView(); detail.contentView = root
        for view in [controls, pdf, page, note] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            pdf.leadingAnchor.constraint(equalTo: root.leadingAnchor), pdf.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdf.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12), pdf.bottomAnchor.constraint(equalTo: page.topAnchor, constant: -10),
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), note.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            page.trailingAnchor.constraint(lessThanOrEqualTo: note.leadingAnchor, constant: -12)
        ])
        let updatePage: () -> Void = { [weak pdf, weak page, weak previous, weak next] in
            guard let pdf, let document = pdf.document else { return }
            let index = pdf.currentPage.map { document.index(for: $0) + 1 } ?? 1
            page?.stringValue = "第 \(index) / \(document.pageCount) 页"
            previous?.isEnabled = pdf.canGoToPreviousPage; next?.isEnabled = pdf.canGoToNextPage
        }
        previous.isEnabled = false; next.isEnabled = false
        pdfPageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdf, queue: .main) { _ in MainActor.assumeIsolated { updatePage() } }
        pdfLoadTask = Task.detached(priority: .userInitiated) { [weak self, weak detail, weak pdf, weak page] in
            guard !Task.isCancelled else { return }
            let document = PDFDocument(data: data)
            if let document, !document.isLocked {
                for index in 0..<document.pageCount {
                    guard !Task.isCancelled else { return }
                    for annotation in document.page(at: index)?.annotations ?? [] {
                        annotation.isReadOnly = true
                        if !(annotation.action is PDFActionGoTo) { annotation.action = nil }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let prepared = ShelfPDFDocument(document: document)
            await MainActor.run { [weak self, weak detail, weak pdf, weak page] in
                guard let self, let detail, self.detailWindow === detail, self.detailRecord?.id == record.id else { return }
                guard let document = prepared.document, !document.isLocked, document.pageCount > 0 else { page?.stringValue = "PDF 已加密或无法读取；原始内容保留。"; return }
                pdf?.document = document
                updatePage()
            }
        }
        if let frame = (window?.screen ?? NSScreen.main)?.visibleFrame {
            detail.setFrameOrigin(NSPoint(x: frame.midX - 360, y: frame.midY - 320))
        }
        window?.addChildWindow(detail, ordered: .above)
        detail.makeKeyAndOrderFront(nil); detail.makeFirstResponder(pdf)
    }

    private func showFilePreview(_ record: ClipboardRecord) {
        previewFileURLs = record.parts.flatMap(\.representations).compactMap { representation in
            guard UTType(representation.typeIdentifier)?.conforms(to: .fileURL) == true,
                  let value = String(data: representation.data, encoding: .utf8),
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard !previewFileURLs.isEmpty else { statusLabel.stringValue = "原文件已移动、删除或暂时无权访问；历史中仅保存文件引用。"; return }
        window?.makeFirstResponder(resultsView)
        let preview = QLPreviewPanel.shared()
        preview?.updateController()
        preview?.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !previewFileURLs.isEmpty && isVisible }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { if panel.dataSource === self { panel.dataSource = nil } }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewFileURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewFileURLs.indices.contains(index) else { return nil }
        return previewFileURLs[index] as NSURL
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === detailWindow else { return }
        window?.removeChildWindow(closing)
        detailWindow = nil
        pdfLoadTask?.cancel(); pdfLoadTask = nil
        detailPDFView?.document = nil; detailPDFView = nil
        if let pdfPageObserver { NotificationCenter.default.removeObserver(pdfPageObserver); self.pdfPageObserver = nil }
        detailRecord = nil
        detailEditor = nil
        initialDetailContents = nil
        if isVisible { window?.makeKey(); window?.makeFirstResponder(resultsView) }
    }

    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow, resized === window else { return }
        updateCardLayout()
    }

    private func updateCardLayout() {
        guard let layout = resultsView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let height = max(120, scrollView.contentView.bounds.height - 15)
        layout.itemSize = NSSize(width: compactMode ? 190 : 222, height: height)
        resultsView.setFrameSize(NSSize(width: max(scrollView.contentView.bounds.width, resultsView.frame.width), height: scrollView.contentView.bounds.height))
        layout.invalidateLayout()
        resultsView.reloadData()
    }

    @objc private func toggleCompactMode() { setCompactMode(!compactMode); onCompactModeChange?(compactMode) }

    @objc private func closeDetail() { detailWindow?.close() }
    private static func hexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#4F7CFF" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    @objc private func colorChanged(_ sender: NSColorWell) { detailEditor?.string = Self.hexString(sender.color) }
    @objc private func rotateDetail() { if let record = detailRecord { detailWindow?.close(); onRotateImage?(record) } }
    @objc private func extractDetail() { if let record = detailRecord { detailWindow?.close(); onExtractText?(record) } }
    @objc private func editDetail() { if let record = detailRecord { showDetail(record, editing: true) } }
    @objc private func saveDetail() {
        guard let record = detailRecord, let editor = detailEditor, let onEdit else { return }
        if let initialDetailContents, editor.attributedString().isEqual(to: initialDetailContents) {
            detailWindow?.close()
            return
        }
        let text = editor.string
        let richText = try? editor.attributedString().data(from: NSRange(location: 0, length: editor.attributedString().length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        detailWindow?.close()
        onEdit(record, text, richText)
    }

    private func rename(_ record: ClipboardRecord) {
        guard let window, onRename != nil else { return }
        let alert = NSAlert()
        alert.messageText = "重命名条目"
        alert.informativeText = "名称用于查找和识别，不会修改粘贴的内容。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: record.title)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.setAccessibilityLabel("条目名称")
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onRename?(record, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        alert.window.initialFirstResponder = field
    }

    @objc private func pasteFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onPaste?($0, false) } } }
    @objc private func pastePlainFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onPaste?($0, true) } } }
    @objc private func copyFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onCopy?($0) } } }
    @objc private func openFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onOpenRecord?($0) } } }
    @objc private func deleteFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onDelete?($0) } } }
    @objc private func previewFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.showDetail($0, editing: false) } } }
    @objc private func editFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.showDetail($0, editing: true) } } }
    @objc private func renameFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.rename($0) } } }
    @objc private func shareFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onShareRecord?($0) } } }
    @objc private func copyImageFileFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onCopyImageFile?($0) } } }
    @objc private func togglePause() { onPauseToggle?() }
    @objc private func openPermissions() { onPermissions?() }
    @objc private func closePanel() { dismiss() }
}
