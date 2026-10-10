import ClipShelfLocalization
import AppKit
import ClipShelfCore
import Quartz
import UniformTypeIdentifiers
import PDFKit

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Keep one undo stack for the lifetime of a draft. A submitted draft is frozen
/// until its receipt arrives; hiding its undo manager also prevents native undo
/// from rewriting text underneath that pending submission.
private final class ShelfEditTextView: NSTextView {
    let draftUndoManager = UndoManager()
    var locksEdits = false
    override var undoManager: UndoManager? { locksEdits ? nil : draftUndoManager }
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

private struct PanelRetainedSelection {
    let generation: UUID
}

private struct PanelBoundaryNavigation {
    let id: UUID
    let generation: UUID
    let selection: PanelSelectionState?
}

private final class ResultsFocusView: NSCollectionView {
    override var acceptsFirstResponder: Bool { true }
    var onDropItems: (([NSPasteboardItem], Any?, NSPoint) -> Bool)?
    var onDragLocation: ((NSPoint, Any?) -> NSDragOperation)?
    var onDragExit: (() -> Void)?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ClipboardDragTrace.log("results draggingEntered sourceIsCard=\(sender.draggingSource is ClipboardCardView) sourceMask=\(sender.draggingSourceOperationMask.rawValue)")
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.pasteboardItems?.isEmpty == false else { return [] }
        let operation = onDragLocation?(convert(sender.draggingLocation, from: nil), sender.draggingSource) ?? .copy
        ClipboardDragTrace.log("results draggingUpdated returnedMask=\(operation.rawValue)")
        return operation
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { ClipboardDragTrace.log("results draggingExited"); onDragExit?() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { ClipboardDragTrace.log("results draggingEnded"); onDragExit?() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        ClipboardDragTrace.log("results prepareForDragOperation hasCallback=\(onDropItems != nil)")
        return onDropItems != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        ClipboardDragTrace.log("results performDragOperation items=\(sender.draggingPasteboard.pasteboardItems?.count ?? 0) sourceIsCard=\(sender.draggingSource is ClipboardCardView)")
        defer { onDragExit?() }
        guard let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty, let onDropItems else { return false }
        let accepted = onDropItems(items, sender.draggingSource, convert(sender.draggingLocation, from: nil))
        ClipboardDragTrace.log("results performDragOperation accepted=\(accepted)")
        return accepted
    }
}

private final class ShelfDropSurface: NSVisualEffectView {
    var onDropItems: (([NSPasteboardItem], Any?) -> Void)?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation: NSDragOperation = onDropItems != nil && sender.draggingPasteboard.pasteboardItems?.isEmpty == false ? .copy : []
        ClipboardDragTrace.log("surface draggingEntered sourceIsCard=\(sender.draggingSource is ClipboardCardView) returnedMask=\(operation.rawValue)")
        return operation
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { onDropItems != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        ClipboardDragTrace.log("surface performDragOperation items=\(sender.draggingPasteboard.pasteboardItems?.count ?? 0) sourceIsCard=\(sender.draggingSource is ClipboardCardView)")
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
final class ClipboardPanelController: NSWindowController, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate, NSPopoverDelegate, NSCollectionViewDataSource, NSMenuItemValidation {
    var onPaste: ((ClipboardRecord, Bool) -> Void)?
    var onPasteRecords: (([ClipboardRecord], Bool) -> Void)?
    var onCopy: ((ClipboardRecord) -> Void)?
    var onCopyRecords: (([ClipboardRecord]) -> Void)?
    var onDelete: ((ClipboardRecord) -> Void)?
    var onDeleteRecords: (([ClipboardRecord]) -> Void)?
    var onPrepareEdit: ((ClipboardSelectionReference, @escaping (Result<ClipboardEditSnapshot, Error>) -> Void) -> Void)?
    var onEdit: ((ClipboardEditSnapshot, ClipboardRecord, @escaping (Result<ClipboardSelectionReference, Error>) -> Void) -> Void)?
    var onEditPart: ((ClipboardEditSnapshot, ClipboardPartEdit, @escaping (Result<ClipboardSelectionReference, Error>) -> Void) -> Void)?
    /// Production uses native windows and a native discard sheet. Tests can keep
    /// them unshown and inject an encoding failure without touching a pasteboard.
    var presentDetailPanel: ((NSPanel, NSWindow?) -> Void)?
    var confirmDiscardEdits: ((NSPanel, @escaping (Bool) -> Void) -> (() -> Void))?
    var makeEditedRecord: ((ClipboardRecord, NSAttributedString) throws -> ClipboardRecord)?
    var makeEditedPart: ((ClipboardRecord, Int, NSAttributedString) throws -> ClipboardPartEdit)?
    var onNewText: (() -> Void)?
    var onQueryChange: ((HistoryQuery) -> Void)?
    /// Reads one bounded metadata window; completion must return on main.
    var onPageRequest: ((PanelPageRequest, @escaping (Result<PanelHistoryPage, Error>) -> Void) -> Void)?
    /// All callbacks complete on main. Selection snapshots contain IDs/versions, never payloads.
    var onSelectionSnapshot: ((HistoryQuery, @escaping (Result<HistorySelectionSnapshot, Error>) -> Void) -> Void)?
    var onValidateSelection: (([ClipboardSelectionReference], @escaping (Result<Void, Error>) -> Void) -> Void)?
    var resolveSelection: (([ClipboardSelectionReference], @escaping (Result<[ClipboardRecord], Error>) -> Void) -> Void)?
    var publications: OwnedFilePublicationCoordinator?
    var spaceCoordinator: StorageSpaceCoordinator?
    /// Output also validates managed-file projections. Management/repair reads must remain possible when output is unavailable.
    var resolveOutputSelection: (([ClipboardSelectionReference], @escaping (Result<[ClipboardRecord], Error>) -> Void) -> Void)?
    var onMoveSelection: (([ClipboardSelectionReference], UUID?, @escaping (Result<[ClipboardSelectionReference], Error>) -> Void) -> Void)?
    var onReorderSelection: (([ClipboardSelectionReference], UUID, ClipboardSelectionReference?, @escaping (Result<[ClipboardSelectionReference], Error>) -> Void) -> Void)?
    var onStepSelection: (([ClipboardSelectionReference], UUID, Bool, @escaping (Result<[ClipboardSelectionReference], Error>) -> Void) -> Void)?
    var onCreatePinboard: ((String, String) -> Void)?
    var onUpdatePinboard: ((Pinboard) -> Void)?
    var onReorderPinboards: (([UUID]) -> Void)?
    var onDeletePinboard: ((Pinboard) -> Void)?
    var onMoveRecords: (([ClipboardRecord], UUID?) -> Void)?
    /// Atomically moves these IDs before an anchor; completion must return on main.
    var onReorderRecords: ((UUID, [UUID], UUID?, [UUID: Int], @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onExtractText: ((ClipboardRecord) -> Void)?
    var onOpenRecord: ((ClipboardRecord) -> Void)?
    var onFileSnapshot: ((ClipboardSelectionReference, @escaping (Result<ClipboardFileRepairSnapshot, Error>) -> Void) -> Void)?
    var onRelocateFile: ((ClipboardFileRepairSnapshot, ClipboardFileReference, URL, @escaping (Result<ClipboardFileRepairSnapshot, Error>) -> Void) -> Void)?
    var onRestoreOwnedFile: ((ClipboardFileRepairSnapshot, ClipboardFileReference, @escaping (Result<ClipboardFileRepairSnapshot, Error>) -> Void) -> Void)?
    /// Injectable presenter for unshown-window tests; production uses the native file window.
    var makeFilePreview: ((ClipboardRecord, Bool) -> FileReferencePreviewController)?
    var makeImagePreview: ((ClipboardRecord, String) -> ImagePreviewController)?
    var onSettings: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDropItems: (([NSPasteboardItem], UUID?) -> Void)?
    var onCompactModeChange: ((Bool) -> Void)?
    var onShareRecord: ((ClipboardRecord) -> Void)?
    var onImageFileOutput: (([ClipboardRecord], Bool) -> Void)?
    var ocrCache: OCRDerivedCache = .shared
    var ocrSourceStore: HistoryStore?
    /// The application loads payload bytes on a background queue and returns on main.
    var resolveRecord: ((UUID, @escaping (ClipboardRecord?) -> Void) -> Void)?
    var onDismiss: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onPermissions: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }
    private(set) var shortcutConfiguration = KeyboardShortcutConfiguration.defaults
    private(set) var alwaysPlainText = false
    private var heldShortcutModifiers: NSEvent.ModifierFlags = []
    private let shortcutHints = NSTextField(labelWithString: "")

    func applyShortcuts(_ configuration: KeyboardShortcutConfiguration, alwaysPlainText: Bool) {
        if configuration != shortcutConfiguration {
            do { try configuration.validate() }
            catch { statusLabel.stringValue = error.localizedDescription; return }
        }
        shortcutConfiguration = configuration
        self.alwaysPlainText = alwaysPlainText
        updateShortcutPresentation()
        if isVisible { resultsView.reloadData() }
    }

    private func updateShortcutPresentation() {
        let quick = shortcutConfiguration.quickPaste.symbol, plain = shortcutConfiguration.plainText.symbol
        shortcutHints.stringValue = L10n.text("↵ 粘贴   \(plain)↵ 纯文本   \(quick)1–9 快速粘贴   esc 收起")
        shortcutHints.toolTip = L10n.text("切换分组：\(shortcutConfiguration.previousPinboard.displayName) / \(shortcutConfiguration.nextPinboard.displayName)")
        emptyDescription.stringValue = L10n.text("在其他 App 中复制文本，再按 \(shortcutConfiguration.activation.displayName) 打开 ClipShelf。")
        cardViews.forEach(updateShortcutLabel)
    }

    private func updateShortcutLabel(_ card: ClipboardCardView) {
        let quick = shortcutConfiguration.quickPaste.eventFlags
        let combined = quick.union(shortcutConfiguration.plainText.eventFlags)
        let show = card.position < 9 && !isEditingSearch && !isComposing
            && (heldShortcutModifiers == quick || heldShortcutModifiers == combined)
        let prefix = [ShortcutModifier.control, .option, .shift, .command]
            .filter { heldShortcutModifiers.contains($0.eventFlags) }.map(\.symbol).joined()
        card.setQuickPasteLabel(show ? "\(prefix)\(card.position + 1)" : nil)
    }

    func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        heldShortcutModifiers = ShortcutChord.normalizedModifiers(flags)
        cardViews.forEach(updateShortcutLabel)
    }

    private func outputPlainText(_ records: [ClipboardRecord], requested: Bool) -> Bool {
        requested || (alwaysPlainText && records.allSatisfy(ClipboardCodec.supportsPlainText))
    }

    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var baseStatus = ""
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyTitle = NSTextField(labelWithString: L10n.text("复制一点内容，从这里开始"))
    private let emptyDescription = NSTextField(labelWithString: L10n.text("在其他 App 中复制文本，再按 ⌘⇧V 打开 ClipShelf。"))
    private let emptyStack = NSStackView()
    private let pauseButton = NSButton(title: L10n.text("暂停记录"), target: nil, action: nil)
    private let compactButton = NSButton(title: L10n.text("紧凑"), target: nil, action: nil)
    private var compactMode = false
    private var preferredNormalHeight: CGFloat = 430
    private var preferredCompactHeight: CGFloat = 338
    private var applyingPresentationGeometry = false
    private var presentedVisibleFrame: NSRect?
    /// The application persists preferences in its own profile; isolated controllers never write defaults.
    var onPreferredHeightChange: ((Bool, CGFloat) -> Void)?
    /// Tests provide synthetic screens without changing the system display configuration.
    var resolveVisibleScreenFrame: ((NSScreen?) -> NSRect)?
    private enum ResultPresentation: Equatable { case ready, loading, failed }
    private var resultPresentation = ResultPresentation.ready
    private let retryLoadingButton = NSButton(title: L10n.text("重试读取"), target: nil, action: nil)
    private let boardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let multiBoardButton = NSButton(title: L10n.text("多板筛选…"), target: nil, action: nil)
    private let clearFiltersButton = NSButton(title: L10n.text("清除条件"), target: nil, action: nil)
    private let allFiltersButton = NSButton(title: L10n.text("全部筛选…"), target: nil, action: nil)
    private let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orderingActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private var filterPopover: NSPopover?
    private(set) var allFiltersController: HistoryFilterController?
    private var allFiltersSession: UUID?
    var presentFilterPopover: ((NSPopover, NSView) -> Void)?
    private var boardScope = PanelBoardScope()
    private var manualOrder = false
    private var orderingRequestID: UUID?
    private var reorderStatus: String?
    private var selectionStatus: String?
    private var pageStatus: String?
    private var pendingRevealID: UUID?
    private let insertionLine = NSView()
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loadMoreButton = NSButton(title: L10n.text("加载更多"), target: nil, action: nil)
    private let previousPageButton = NSButton(title: L10n.text("上一页"), target: nil, action: nil)
    private var pinboards: [Pinboard] = []
    private var sources: [String: String] = [:]
    private var devices: [UUID: String] = [:]
    private var localDeviceID: UUID?
    private var selectedDeviceFilter: HistoryDeviceFilter = .all
    private var selectedBoardID: UUID? {
        get { boardScope.navigationID }
        set { boardScope.navigate(to: newValue) }
    }
    private var selectedKind: ClipboardContentKind?
    private var selectedSourceID: String?
    private var copiedAfter: Date?
    private var copiedBefore: Date?
    private var lastDateIndex = 0
    private var resultLimit = 300
    private var pageWindow = PanelPageWindow()
    private var pageRequestID: UUID?
    private var pageMatchesQuery = true
    private var refreshAfterPageLoad = false
    private let scrollView = NSScrollView()
    private let resultsView = ResultsFocusView()
    private var records: [ClipboardCardContent] = []
    private var filteredRecords: [ClipboardCardContent] = []
    private var cardViews: [ClipboardCardView] { resultsView.visibleItems().compactMap { ($0 as? ClipboardCollectionItem)?.card } }
    private var selection = PanelSelectionState()
    private var selectedID: UUID? { selection.focusID }
    private var selectedIDs: Set<UUID> { selection.selectedIDs }
    private var scopeGeneration = UUID()
    private var selectionRequestID: UUID?
    private var validationRequestID: UUID?
    private var boundaryNavigationID: UUID?
    private var boundaryPageRequestID: UUID?
    private var eventMonitor: Any?
    private var detailWindow: NSPanel?
    private var linkPreview: LinkPreviewController?
    private var imagePreview: ImagePreviewController?
    private var filePreview: FileReferencePreviewController?
    private var detailPDFView: PDFView?
    private var pdfPageObserver: NSObjectProtocol?
    private var pdfLoadTask: Task<Void, Never>?
    private var detailRecord: ClipboardRecord?
    private var detailEditor: NSTextView?
    private var initialDetailContents: NSAttributedString?
    private var detailSnapshot: ClipboardEditSnapshot?
    private var detailSession = UUID()
    private var detailParentSession = UUID()
    private var detailPrepareID: UUID?
    private var detailSaveID: UUID?
    private var detailDiscardID: UUID?
    private var cancelDetailDiscard: (() -> Void)?
    private var detailDiscardCancelled: (() -> Void)?
    private var detailIsEditing = false
    private var detailIsRenaming = false
    private var detailPrepareReference: ClipboardSelectionReference?
    private var detailContextLabel: NSTextField?
    private var detailPartIndex: Int?
    private var detailPartPicker: NSPopUpButton?
    private var detailEditingRecord: ClipboardRecord?
    private var detailNote: NSTextField?
    private var detailPrimary: NSButton?
    private var detailStatus: NSTextField?
    private var detailColorWell: NSColorWell?
    private var detailError: String?
    private var detailStructureError: Error?
    private var detailEventMonitor: Any?
    private var detailUndoObservers: [NSObjectProtocol] = []
    private var detailHidden = false
    var hasPreservedDraft: Bool { detailHidden && detailIsEditing && detailWindow != nil }
    var hasOpenEditor: Bool { detailIsEditing && detailWindow != nil }
    private var inlineRecords: [UUID: ClipboardRecord] = [:]
    private var recordOriginDevices: [UUID: UUID] = [:]
    private var viewGeneration = UUID()
    private var queryGeneration = UUID()
    private var queryPending = false
    private var pendingActionID: UUID?
    private var outputActionGeneration = UUID()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailJobs: [() -> Void] = []
    private var activeThumbnailJobs = 0
    private var requestedThumbnails: Set<String> = []

    private let layoutDirection: NSUserInterfaceLayoutDirection
    private var earlierArrow: String { layoutDirection == .rightToLeft ? "\u{F703}" : "\u{F702}" }
    private var laterArrow: String { layoutDirection == .rightToLeft ? "\u{F702}" : "\u{F703}" }

    init(layoutDirection: NSUserInterfaceLayoutDirection? = nil) {
        self.layoutDirection = layoutDirection ?? InterfaceLayout.direction
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.title = L10n.text("ClipShelf 剪贴板历史")
        panel.minSize = NSSize(width: 720, height: 338)
        super.init(window: panel)
        panel.delegate = self
        thumbnailCache.totalCostLimit = 32 * 1_024 * 1_024
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(records: [ClipboardRecord], on screen: NSScreen? = nil, status: String? = nil) {
        inlineRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        recordOriginDevices = Dictionary(uniqueKeysWithValues: records.compactMap { record in record.originDeviceConflict ? nil : record.originDeviceID.map { (record.id, $0) } })
        present(records.map(ClipboardCardContent.init), on: screen, status: status)
    }

    func show(metadata: [ClipboardRecordMetadata], on screen: NSScreen? = nil, status: String? = nil) {
        inlineRecords.removeAll()
        recordOriginDevices = Dictionary(uniqueKeysWithValues: metadata.compactMap { record in record.originDeviceConflict ? nil : record.originDeviceID.map { (record.id, $0) } })
        present(metadata.map(ClipboardCardContent.init), on: screen, status: status)
    }

    private func present(_ contents: [ClipboardCardContent], on screen: NSScreen?, status: String?) {
        if hasPreservedDraft, let detailWindow {
            detailHidden = false
            if usesRemoteQuery {
                resultPresentation = .loading
                updateResultPresentation()
            }
            positionShelf(on: screen)
            if let visible = presentedVisibleFrame {
                let frame = PanelPresentationGeometry.detail(size: detailWindow.frame.size, in: visible)
                detailWindow.minSize = NSSize(width: min(440, frame.width), height: min(320, frame.height))
                detailWindow.setFrame(frame, display: false)
            }
            window?.makeKeyAndOrderFront(nil); installEventMonitor()
            presentDetail(detailWindow)
            detailWindow.makeFirstResponder(detailEditor)
            // Suspension retires the old read without a completion. Reload the
            // preserved scope explicitly; do not leave the draft's parent list
            // waiting for a request that the application has cancelled.
            if usesRemoteQuery {
                if onPageRequest != nil, pageMatchesQuery { refreshPage() }
                else { issueQuery(resetLimit: !pageMatchesQuery) }
            }
            return
        }
        if detailWindow != nil {
            requestDetailClose { [weak self] in self?.present(contents, on: screen, status: status) }
            return
        }
        filePreview?.dismiss()
        cancelBoundaryNavigation()
        closeAllFilters(restoreFocus: false)
        viewGeneration = UUID()
        heldShortcutModifiers = []
        pageWindow = PanelPageWindow()
        pageRequestID = nil
        pageMatchesQuery = true
        refreshAfterPageLoad = false
        resultLimit = 300
        self.records = Array(contents.prefix(resultLimit))
        searchField.stringValue = ""
        selectedBoardID = nil
        manualOrder = false
        orderingRequestID = nil
        reorderStatus = nil
        pageStatus = nil
        pendingRevealID = nil
        selectedKind = nil
        selectedSourceID = nil
        selectedDeviceFilter = .all
        copiedAfter = nil
        copiedBefore = nil
        lastDateIndex = 0
        boardPopup.selectItem(at: 0)
        typePopup.selectItem(at: 0)
        sourcePopup.selectItem(at: 0)
        devicePopup.selectItem(at: 0)
        datePopup.selectItem(at: 0)
        selection.clear()
        scopeGeneration = UUID()
        selectionRequestID = nil
        validationRequestID = nil
        baseStatus = status ?? L10n.text("本机保存 · 随时取用")
        statusLabel.stringValue = baseStatus
        resultPresentation = usesRemoteQuery ? .loading : .ready
        reloadResults(resetScroll: true)
        positionShelf(on: screen)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        installEventMonitor()
        issueQuery(resetLimit: true)
    }

    /// Refreshes captured history while preserving a current query and selection.
    func update(records: [ClipboardRecord], status: String? = nil) {
        inlineRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        recordOriginDevices = Dictionary(uniqueKeysWithValues: records.compactMap { record in record.originDeviceConflict ? nil : record.originDeviceID.map { (record.id, $0) } })
        updateContents(records.map(ClipboardCardContent.init), status: status)
    }

    func update(metadata: [ClipboardRecordMetadata], status: String? = nil) {
        if onPageRequest != nil {
            if let status { updateStatus(status) }
            return
        }
        inlineRecords.removeAll()
        recordOriginDevices = Dictionary(uniqueKeysWithValues: metadata.compactMap { record in record.originDeviceConflict ? nil : record.originDeviceID.map { (record.id, $0) } })
        updateContents(metadata.map(ClipboardCardContent.init), status: status)
    }

    func updateStatus(_ status: String) {
        baseStatus = status
        statusLabel.stringValue = selectionStatus ?? pageStatus ?? reorderStatus ?? status
    }

    /// Refresh the current window after storage changes without rereading a growing prefix.
    func refreshPage(status: String? = nil) {
        if let status { updateStatus(status) }
        guard isVisible, onPageRequest != nil else { return }
        if queryPending || boundaryNavigationID != nil || !pageMatchesQuery { refreshAfterPageLoad = true; return }
        let retained = PanelRetainedSelection(generation: selection.generation)
        var anchor: PanelPageAnchor?
        if let selectedID, let primary = filteredRecords.firstIndex(where: { $0.id == selectedID }) {
            let indices = filteredRecords.indices.filter { selectedIDs.contains(filteredRecords[$0].id) }
            // Center the span, not the number of selected items, so sparse multi-selection fits.
            let middle = ((indices.first ?? primary) + (indices.last ?? primary) + 1) / 2
            anchor = PanelPageAnchor(recordID: selectedID, displacement: middle - primary)
        }
        issueQuery(resetLimit: false, preserveStatus: true, anchor: anchor,
                   retainedSelection: retained, allowMissingAnchorFallback: true)
    }

    private func updateContents(_ contents: [ClipboardCardContent], status: String?) {
        queryPending = false
        resultPresentation = .ready
        self.records = Array(contents.prefix(resultLimit))
        if let status { statusLabel.stringValue = reorderStatus ?? status }
        reloadResults()
        validateCurrentSelection()
        if let id = pendingRevealID {
            if filteredRecords.contains(where: { $0.id == id }) {
                pendingRevealID = nil
                if let index = filteredRecords.firstIndex(where: { $0.id == id }) { revealItem(at: index) }
                window?.makeFirstResponder(resultsView)
            } else if hasMoreResults {
                statusLabel.stringValue = L10n.text("该条目尚未加载，请点“加载更多”以定位。")
            } else { pendingRevealID = nil }
        }
    }

    func setCapturePaused(_ paused: Bool, recordingAllowed: Bool = true) {
        pauseButton.isEnabled = recordingAllowed
        pauseButton.title = recordingAllowed ? (paused ? L10n.text("继续记录") : L10n.text("暂停记录")) : L10n.text("验收模式")
        pauseButton.setAccessibilityLabel(recordingAllowed ? (paused ? L10n.text("继续记录剪贴板") : L10n.text("暂停记录剪贴板")) : L10n.text("验收模式不记录剪贴板"))
    }

    func edit(_ record: ClipboardRecord) { showDetail(record, editing: true) }

    func setPreferredHeights(normal: CGFloat, compact: CGFloat) {
        preferredNormalHeight = PanelPresentationGeometry.preferredHeight(normal, compact: false)
        preferredCompactHeight = PanelPresentationGeometry.preferredHeight(compact, compact: true)
        if isVisible { positionShelf(on: window?.screen) }
    }

    func setCompactMode(_ compact: Bool) {
        compactMode = compact
        compactButton.state = compact ? .on : .off
        compactButton.toolTip = compact ? L10n.text("切换为大卡片") : L10n.text("切换为紧凑卡片")
        positionShelf(on: window?.screen)
    }

    private func positionShelf(on screen: NSScreen?) {
        guard let window else { return }
        let visible = PanelPresentationGeometry.usable(visibleFrame(on: screen))
        presentedVisibleFrame = visible
        let frame = PanelPresentationGeometry.shelf(in: visible,
            preferredHeight: compactMode ? preferredCompactHeight : preferredNormalHeight)
        applyingPresentationGeometry = true
        defer { applyingPresentationGeometry = false }
        window.minSize = NSSize(width: min(720, frame.width), height: min(338, frame.height))
        window.maxSize = NSSize(width: visible.width, height: visible.height)
        window.setFrame(frame, display: isVisible)
        updateCardLayout()
    }

    private func visibleFrame(on screen: NSScreen?) -> NSRect {
        resolveVisibleScreenFrame?(screen)
            ?? (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? PanelPresentationGeometry.defaultVisibleFrame
    }

    func setPinboards(_ pinboards: [Pinboard]) {
        self.pinboards = pinboards
        allFiltersController?.updateOptions(filterOptions)
        boardPopup.removeAllItems()
        boardPopup.addItem(withTitle: L10n.text("全部内容"))
        for board in self.pinboards {
            boardPopup.addItem(withTitle: board.name)
            boardPopup.lastItem?.representedObject = board.id
        }
        let oldScope = boardScope
        boardScope.retain(Set(pinboards.map(\.id)))
        if let selectedBoardID, let index = self.pinboards.firstIndex(where: { $0.id == selectedBoardID }) { boardPopup.selectItem(at: index + 1) }
        else { boardPopup.selectItem(at: 0) }
        updateFilterControls()
        if isVisible {
            if oldScope != boardScope { issueQuery(resetLimit: true) } else { reloadResults() }
        }
    }

    func setSources(_ sources: [String: String]) {
        self.sources.merge(sources) { _, newer in newer }
        allFiltersController?.updateOptions(filterOptions)
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: L10n.text("所有来源 App"))
        for (id, name) in self.sources.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
            sourcePopup.addItem(withTitle: name)
            sourcePopup.lastItem?.representedObject = id
        }
        if let selectedSourceID, self.sources[selectedSourceID] == nil {
            sourcePopup.addItem(withTitle: L10n.text("不可用来源 · \(selectedSourceID)"))
            sourcePopup.lastItem?.representedObject = selectedSourceID
        }
        if let selectedSourceID, let item = sourcePopup.itemArray.first(where: { $0.representedObject as? String == selectedSourceID }) { sourcePopup.select(item) }
    }

    func setDevices(_ devices: [ClipboardOriginDevice], localDeviceID: UUID?) {
        self.devices = devices.reduce(into: [:]) { $0[$1.id] = $1.name }
        self.localDeviceID = localDeviceID
        rebuildDeviceOptions()
        allFiltersController?.updateOptions(filterOptions)
    }

    private var selectedDeviceKey: String {
        switch selectedDeviceFilter {
        case .all: return "all"
        case .unknown: return "unknown"
        case .device(let id): return id.uuidString
        }
    }

    private func rebuildDeviceOptions() {
        devicePopup.removeAllItems()
        func add(_ title: String, key: String, enabled: Bool = true) {
            devicePopup.addItem(withTitle: title)
            devicePopup.lastItem?.representedObject = key
            devicePopup.lastItem?.isEnabled = enabled
        }
        add(L10n.text("所有来源设备"), key: "all")
        add(L10n.text("此 Mac"), key: localDeviceID?.uuidString ?? "local-unavailable", enabled: localDeviceID != nil)
        var candidates = devices
        // Keep an explicit condition after its last record disappears; never broaden silently.
        if case .device(let id) = selectedDeviceFilter, id != localDeviceID, candidates[id] == nil { candidates[id] = "Mac" }
        for (id, name) in candidates.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where id != localDeviceID {
            add("\(name.prefix(20)) · \(id.uuidString.prefix(8))", key: id.uuidString)
        }
        add(L10n.text("未知（含来源矛盾）"), key: "unknown")
        if let item = devicePopup.itemArray.first(where: { $0.representedObject as? String == selectedDeviceKey }) { devicePopup.select(item) }
    }

    func dismiss() {
        guard isVisible else { return }
        if detailWindow != nil {
            let session = viewGeneration
            requestDetailClose { [weak self] in
                guard let self, self.viewGeneration == session else { return }
                self.dismiss()
            }
            return
        }
        cancelBoundaryNavigation()
        closeAllFilters(restoreFocus: false)
        cardViews.forEach { $0.cancelPendingDrag() }
        heldShortcutModifiers = []
        cardViews.forEach(updateShortcutLabel)
        pageRequestID = nil
        queryPending = false
        refreshAfterPageLoad = false
        selectionRequestID = nil
        validationRequestID = nil
        scopeGeneration = UUID()
        viewGeneration = UUID()
        pendingActionID = nil
        thumbnailJobs.removeAll()
        requestedThumbnails.removeAll()
        linkPreview?.dismiss()
        imagePreview?.dismiss()
        filePreview?.dismiss()
        filterPopover?.close()
        filterPopover = nil
        insertionLine.isHidden = true
        detailWindow?.close()
        window?.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        onDismiss?()
    }

    /// Actions such as opening settings or quitting must wait for a draft decision.
    func dismissForAction(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        requestDetailClose(onCancel: onCancel) { [weak self] in
            self?.dismiss()
            action()
        }
    }

    func hideForSuspension() { hidePreservingDraft() }

    /// Outside clicks and suspension hide sensitive content immediately. A draft
    /// remains in memory until the next explicit show; no fresh editing authority
    /// is acquired and no output is performed as a side effect of showing it again.
    func hidePreservingDraft() {
        guard detailIsDirty || detailSaveID != nil else { dismiss(); return }
        // Keep the editor's parent session and frozen selection, but retire all
        // page callbacks before onDismiss cancels the database coordinator.
        pageRequestID = nil
        queryGeneration = UUID()
        queryPending = false
        refreshAfterPageLoad = false
        cancelBoundaryNavigation(); closeAllFilters(restoreFocus: false)
        cardViews.forEach { $0.cancelPendingDrag() }; invalidateOutputContext()
        retireDiscardPrompt()
        if detailColorWell?.isActive == true { NSColorPanel.shared.orderOut(nil) }
        detailColorWell?.deactivate()
        detailHidden = true
        detailWindow?.orderOut(nil)
        linkPreview?.dismiss(); imagePreview?.dismiss(); filePreview?.dismiss()
        filterPopover?.close(); filterPopover = nil
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
        defer { InterfaceLayout.apply(to: background, direction: layoutDirection) }

        let logo = NSTextField(labelWithString: "ClipShelf")
        logo.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString: L10n.text("你的剪贴板，触手可及"))
        subtitle.font = .systemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        let branding = NSStackView(views: [logo, subtitle])
        branding.orientation = .vertical
        branding.alignment = .leading
        branding.spacing = 3
        branding.setContentHuggingPriority(.required, for: .horizontal)

        searchField.placeholderString = L10n.text("搜索内容或来源 App")
        searchField.font = .systemFont(ofSize: 13)
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel(L10n.text("搜索剪贴板历史"))
        searchField.setAccessibilityHelp(L10n.text("输入文字过滤历史，按回车进入结果，再按回车粘贴。搜索中按 Command-F 打开全部筛选。"))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        let permissions = NSButton(image: NSImage(systemSymbolName: "hand.raised", accessibilityDescription: L10n.text("粘贴权限")) ?? NSImage(), target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .inline
        permissions.toolTip = L10n.text("设置直接粘贴所需的辅助功能权限")
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("收起 ClipShelf")) ?? NSImage(), target: self, action: #selector(closePanel))
        close.bezelStyle = .inline
        compactButton.image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: L10n.text("切换紧凑卡片"))
        compactButton.imagePosition = .imageOnly
        compactButton.bezelStyle = .inline
        compactButton.setButtonType(.toggle)
        compactButton.target = self
        compactButton.action = #selector(toggleCompactMode)
        compactButton.setAccessibilityLabel(L10n.text("切换紧凑卡片"))
        let header = NSStackView(views: [branding, searchField, pauseButton, compactButton, permissions, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        boardPopup.addItem(withTitle: L10n.text("全部内容"))
        boardPopup.target = self
        boardPopup.action = #selector(boardChanged)
        boardPopup.setAccessibilityLabel(L10n.text("分组"))
        let boardActions = NSPopUpButton(frame: .zero, pullsDown: true)
        boardActions.addItem(withTitle: L10n.text("分组操作"))
        for (title, action) in [(L10n.text("新建分组…"), #selector(createBoard)), (L10n.text("编辑当前分组…"), #selector(renameBoard)), (L10n.text("将当前分组前移"), #selector(moveBoardEarlier)), (L10n.text("将当前分组后移"), #selector(moveBoardLater)), (L10n.text("删除当前分组…"), #selector(deleteBoard))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            boardActions.menu?.addItem(item)
        }
        typePopup.addItem(withTitle: L10n.text("所有类型"))
        for kind in ClipboardContentKind.allCases {
            typePopup.addItem(withTitle: Self.kindTitle(kind))
            typePopup.lastItem?.representedObject = kind.rawValue
        }
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        typePopup.setAccessibilityLabel(L10n.text("按内容类型筛选"))
        sourcePopup.addItem(withTitle: L10n.text("所有来源 App"))
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.setAccessibilityLabel(L10n.text("按来源应用筛选"))
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        devicePopup.setAccessibilityLabel(L10n.text("按最初采集设备筛选"))
        devicePopup.toolTip = L10n.text("最初由哪台 ClipShelf 安装采集或创建；不会推断通用剪贴板的 iPhone 等物理来源。")
        devicePopup.menu?.autoenablesItems = false
        rebuildDeviceOptions()
        devicePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        devicePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        datePopup.addItems(withTitles: [L10n.text("任意时间"), L10n.text("今天"), L10n.text("最近 7 天"), L10n.text("最近 30 天"), L10n.text("自定义时间范围…")])
        datePopup.target = self
        datePopup.action = #selector(dateChanged)
        datePopup.setAccessibilityLabel(L10n.text("按复制时间筛选"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        loadMoreButton.bezelStyle = .inline
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore)
        previousPageButton.bezelStyle = .inline
        previousPageButton.target = self
        previousPageButton.action = #selector(loadPreviousPage)
        previousPageButton.isHidden = true
        multiBoardButton.target = self
        multiBoardButton.action = #selector(showBoardFilters)
        multiBoardButton.bezelStyle = .rounded
        multiBoardButton.setAccessibilityLabel(L10n.text("勾选多个分组筛选"))
        clearFiltersButton.target = self
        clearFiltersButton.action = #selector(clearFilters)
        clearFiltersButton.bezelStyle = .inline
        allFiltersButton.target = self
        allFiltersButton.action = #selector(showAllFilters)
        allFiltersButton.bezelStyle = .rounded
        allFiltersButton.setAccessibilityLabel(L10n.text("全部筛选"))
        orderPopup.addItems(withTitles: [L10n.text("最近复制"), L10n.text("分组内手动顺序")])
        orderPopup.target = self
        orderPopup.action = #selector(orderChanged)
        orderPopup.setAccessibilityLabel(L10n.text("条目顺序"))
        orderingActions.addItem(withTitle: L10n.text("调整条目顺序"))
        for (title, action, key) in [(L10n.text("选中条目前移"), #selector(moveItemsEarlier), earlierArrow), (L10n.text("选中条目后移"), #selector(moveItemsLater), laterArrow)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            orderingActions.menu?.addItem(item)
        }
        orderingActions.toolTip = L10n.text("拖动卡片在分组内排序；⌥ 拖动原始内容到其他 App；⌥⌘← / ⌥⌘→ 移动选中条目")
        let boardRow = NSStackView(views: [boardPopup, multiBoardButton, boardActions, devicePopup, spacer, clearFiltersButton])
        let filterRow = NSStackView(views: [typePopup, sourcePopup, datePopup, orderPopup, orderingActions, allFiltersButton, NSView(), previousPageButton, loadMoreButton])
        for row in [boardRow, filterRow] { row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10 }
        let filters = NSStackView(views: [boardRow, filterRow])
        filters.orientation = .vertical
        filters.alignment = .leading
        filters.spacing = 6
        boardRow.widthAnchor.constraint(equalTo: filters.widthAnchor).isActive = true
        filterRow.widthAnchor.constraint(equalTo: filters.widthAnchor).isActive = true
        [boardPopup, typePopup, sourcePopup, devicePopup, datePopup, boardActions, orderPopup, orderingActions].forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: 11) }
        [multiBoardButton, clearFiltersButton, allFiltersButton].forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: 11) }

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
        resultsView.onDropItems = { [weak self] items, source, point in self?.handleResultsDrop(items, source: source, point: point) ?? false }
        resultsView.onDragLocation = { [weak self] point, source in self?.updateDragInsertion(at: point, source: source) ?? [] }
        resultsView.onDragExit = { [weak self] in self?.insertionLine.isHidden = true }
        insertionLine.wantsLayer = true
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionLine.layer?.cornerRadius = 2
        insertionLine.isHidden = true
        resultsView.addSubview(insertionLine)
        resultsView.isSelectable = false
        resultsView.backgroundColors = [.clear]
        resultsView.register(ClipboardCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("clipboard-card"))
        resultsView.frame = NSRect(x: 0, y: 0, width: 1076, height: 239)
        resultsView.autoresizingMask = [.width]
        scrollView.documentView = resultsView
        resultsView.setAccessibilityRole(.group)
        resultsView.setAccessibilityLabel(L10n.text("剪贴板搜索结果"))

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
        countLabel.setAccessibilityLabel(L10n.text("结果数量与选中项"))
        let hints = shortcutHints
        updateShortcutPresentation()
        hints.font = .systemFont(ofSize: 10)
        hints.textColor = .tertiaryLabelColor
        hints.setContentHuggingPriority(.required, for: .horizontal)
        retryLoadingButton.target = self
        retryLoadingButton.action = #selector(retryPageLoading)
        retryLoadingButton.bezelStyle = .inline
        retryLoadingButton.controlSize = .small
        retryLoadingButton.isHidden = true
        let footer = NSStackView(views: [statusLabel, retryLoadingButton, countLabel, hints])
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
            filters.heightAnchor.constraint(equalToConstant: 50),
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
        boardScope.beginTextSearch()
        boardPopup.selectItem(at: 0)
        issueQuery(resetLimit: true)
    }

    private var isComposing: Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    private var isEditingSearch: Bool { searchField.currentEditor() === window?.firstResponder || window?.firstResponder === searchField }
    private var selectedRecord: ClipboardCardContent? { filteredRecords.first(where: { $0.id == selectedID }) }
    private func reference(_ content: ClipboardCardContent) -> ClipboardSelectionReference {
        ClipboardSelectionReference(id: content.id, revision: content.revision)
    }
    private var currentQuery: HistoryQuery {
        HistoryQuery(text: searchField.stringValue, kind: selectedKind, sourceBundleID: selectedSourceID,
                     copiedAfter: copiedAfter, copiedBefore: copiedBefore, pinboardIDs: boardScope.queryIDs,
                     includePinned: true, limit: resultLimit,
                     sortOrder: manualOrder && boardScope.singleBoardID != nil ? .pinboard : .recent,
                     deviceFilter: selectedDeviceFilter)
    }

    private func reloadResults(resetScroll: Bool = false, allowAutomaticSelection: Bool = true) {
        let previousOrigin = resetScroll ? NSPoint.zero : scrollView.contentView.bounds.origin
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredRecords = usesRemoteQuery ? records : records.filter {
            (query.isEmpty || $0.text.localizedStandardContains(query) || $0.title.localizedStandardContains(query) || ($0.ocrText?.localizedStandardContains(query) ?? false) || ($0.sourceApp?.localizedStandardContains(query) ?? false))
            && (selectedKind == nil || $0.kind == selectedKind)
            && (selectedSourceID == nil || $0.sourceBundleID == selectedSourceID)
            && matchesSelectedDevice($0.id)
            && (boardScope.queryIDs.isEmpty || $0.pinboardID.map { boardScope.queryIDs.contains($0) } == true)
            && (copiedAfter == nil || $0.copiedAt >= copiedAfter!)
            && (copiedBefore == nil || $0.copiedAt <= copiedBefore!)
        }
        let selectFirst = selection.references.isEmpty && !selection.isInvalid && allowAutomaticSelection && !filteredRecords.isEmpty
        if selectFirst, let first = filteredRecords.first {
            selection.selectSingle(reference(first))
        }
        resultsView.reloadData()
        updateResultPresentation()
        updateSelectionCount()
        updateFilterControls()
        updatePageControls()
        resultsView.layoutSubtreeIfNeeded()
        let maximumX = max(0, resultsView.bounds.width - scrollView.contentView.bounds.width)
        let originX = resetScroll || selectFirst
            ? (layoutDirection == .rightToLeft ? maximumX : 0)
            : min(previousOrigin.x, maximumX)
        scrollView.contentView.scroll(to: NSPoint(x: originX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateResultPresentation() {
        emptyStack.isHidden = !filteredRecords.isEmpty
        retryLoadingButton.isHidden = resultPresentation != .failed
        retryLoadingButton.isEnabled = !queryPending
        switch resultPresentation {
        case .loading:
            emptyTitle.stringValue = L10n.text("正在读取条目…")
            emptyDescription.stringValue = ""
        case .failed:
            emptyTitle.stringValue = L10n.text("读取未完成，原因见下方。")
            emptyDescription.stringValue = ""
        case .ready:
            if !hasFilters {
                emptyTitle.stringValue = L10n.text("复制一点内容，从这里开始")
                emptyDescription.stringValue = L10n.text("在其他 App 中复制文本，再按 \(shortcutConfiguration.activation.displayName) 打开 ClipShelf。")
            } else {
                emptyTitle.stringValue = L10n.text("没有找到相关内容")
                emptyDescription.stringValue = L10n.text("试试更短的关键词，或点击“清除条件”重新搜索全部内容。")
            }
        }
        emptyDescription.isHidden = emptyDescription.stringValue.isEmpty
        updateSelectionCount()
    }

    @objc private func retryPageLoading() {
        guard isVisible, !queryPending, resultPresentation == .failed else { return }
        issueQuery(resetLimit: !pageMatchesQuery)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { filteredRecords.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clipboard-card"), for: indexPath) as! ClipboardCollectionItem
        let record = filteredRecords[indexPath.item]
        item.configure(makeCard(record: record, position: indexPath.item))
        InterfaceLayout.apply(to: item.view, direction: layoutDirection)
        return item
    }

    private func makeCard(record: ClipboardCardContent, position: Int) -> ClipboardCardView {
        let card = ClipboardCardView(record: record, position: position, compact: compactMode)
        InterfaceLayout.apply(to: card, direction: layoutDirection)
        card.publications = publications
        card.isSelected = selectedIDs.contains(record.id)
        updateShortcutLabel(card)
        card.onSelect = { [weak self] in
            guard let self, self.detailWindow == nil else { return }
            self.cancelBoundaryNavigation()
            guard !self.queryPending else { return }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if self.selectedIDs.count > 1, self.selectedIDs.contains(record.id), !modifiers.contains(.shift), !modifiers.contains(.command) {
                self.window?.makeFirstResponder(self.resultsView)
                self.cardViews.forEach(self.updateShortcutLabel)
                return
            }
            self.select(record.id, focusResults: true, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        }
        card.onClick = { [weak self] event in
            guard let self, self.detailWindow == nil, !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command),
                  self.selectedIDs.count > 1, self.selectedIDs.contains(record.id) else { return }
            self.select(record.id, focusResults: true)
        }
        card.onOpen = { [weak self] modifiers in
            guard let self, self.detailWindow == nil, !self.isComposing else { return }
            self.select(record.id, focusResults: true)
            let plain = ShortcutChord.normalizedModifiers(modifiers).contains(self.shortcutConfiguration.plainText.eventFlags)
            self.resolve(record, forOutput: true) { self.onPaste?($0, self.outputPlainText([$0], requested: plain)) }
        }
        if manualOrder {
            card.toolTip = L10n.text("拖动以调整分组内顺序；按住 ⌥ 拖出内容，图片会作为 PNG 文件。")
            card.setAccessibilityHelp(L10n.text("单击选择，双击粘贴；拖动调整分组内顺序，⌥ 拖出内容，图片转为 PNG 文件；⌥⌘左右箭头调整顺序。"))
        } else if record.hasImageFileParts {
            card.toolTip = L10n.text("拖动保留图片格式；按住 ⌥ 拖出 PNG 文件。")
            card.setAccessibilityHelp(L10n.text("单击选择，双击粘贴；拖动保留图片格式，按住 Option 拖出 PNG 文件。"))
        }
        card.onPrepareDrag = { [weak self, weak card] event in
            guard let self, self.detailWindow == nil, let card, let gestureID = card.activeGestureID else { return }
            guard !self.selection.isInvalid, self.selectionRequestID == nil else { return }
            let refs = self.selectedIDs.contains(record.id) ? self.selection.references : [self.reference(record)]
            ClipboardDragTrace.log("panel prepare manual=\(self.manualOrder) option=\(event.modifierFlags.contains(.option)) canReorder=\(self.canReorderItems) queryPending=\(self.queryPending) requestPending=\(self.orderingRequestID != nil) count=\(refs.count)")
            if self.manualOrder && !event.modifierFlags.contains(.option) {
                guard self.canReorderItems else { return }
                card.prepareOrderingDrag(references: refs, originID: self.viewGeneration,
                                         scopeID: self.scopeGeneration, selectionID: self.selection.generation)
            } else {
                card.preparePayloadDrag(originID: self.viewGeneration, scopeID: self.scopeGeneration,
                                        selectionID: self.selection.generation)
                let imagesAsFiles = event.modifierFlags.contains(.option)
                self.resolveReferences(refs, forOutput: true) { [weak self, weak card] records in
                    guard let self, let card, card.activeGestureID == gestureID else { return }
                    guard imagesAsFiles, ImageFileOutput.hasImages(in: records) else {
                        card.providePreparedPayload(records: records, gestureID: gestureID); return
                    }
                    let isCurrent = self.captureOutputContext()
                    let spaceCoordinator = self.spaceCoordinator
                    let retention: OwnedAssetLease?
                    do { retention = try self.publications?.retain(records) }
                    catch { card.rejectPreparedPayload(error, gestureID: gestureID); return }
                    Task { @MainActor [weak card] in
                        defer { withExtendedLifetime(retention) {} }
                        do {
                            let prepared = try await Task.detached(priority: .userInitiated) {
                                try ImageFileOutput.prepare(records, spaceCoordinator: spaceCoordinator)
                            }.value
                            guard isCurrent() else {
                                if card?.activeGestureID == gestureID { card?.cancelPendingDrag() }
                                return
                            }
                            card?.providePreparedImageFiles(prepared, records: records, gestureID: gestureID)
                        } catch {
                            guard isCurrent() else { return }
                            card?.rejectPreparedPayload(error, gestureID: gestureID)
                        }
                    }
                }
            }
        }
        card.onDragError = { [weak self] error in self?.statusLabel.stringValue = L10n.text("无法拖出内容：\(error.localizedDescription)") }
        if record.kind == .image { requestThumbnail(record, for: card) }
        let menu = NSMenu()
        for (title, action) in [(L10n.text("粘贴"), #selector(pasteFromMenu(_:))), (L10n.text("以纯文本粘贴"), #selector(pastePlainFromMenu(_:))), (L10n.text("复制"), #selector(copyFromMenu(_:))), (record.kind == .file ? L10n.text("文件与位置…") : L10n.text("预览此项"), #selector(previewFromMenu(_:))), (record.kind == .file ? L10n.text("查看文件后打开…") : L10n.text("打开此项"), #selector(openFromMenu(_:))), (L10n.text("编辑此项"), #selector(editFromMenu(_:))), (L10n.text("重命名此项"), #selector(renameFromMenu(_:))), (L10n.text("删除"), #selector(deleteFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = record.id
            if action == #selector(pasteFromMenu(_:)) { item.keyEquivalent = "\r"; item.keyEquivalentModifierMask = [] }
            if action == #selector(pastePlainFromMenu(_:)) {
                item.keyEquivalent = "\r"; item.keyEquivalentModifierMask = shortcutConfiguration.plainText.eventFlags
            }
            menu.addItem(item)
        }
        if canReorderItems {
            menu.addItem(.separator())
            for (title, action, key) in [(L10n.text("选中条目前移"), #selector(reorderEarlierFromMenu(_:)), earlierArrow), (L10n.text("选中条目后移"), #selector(reorderLaterFromMenu(_:)), laterArrow)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = [.command, .option]
                item.target = self; item.representedObject = record.id; menu.addItem(item)
            }
        }
        card.menu = menu
        if record.kind == .file {
            let relocate = NSMenuItem(title: L10n.text("重新定位文件…"), action: #selector(relocateFileFromMenu(_:)), keyEquivalent: "")
            relocate.target = self; relocate.representedObject = record.id
            menu.insertItem(relocate, at: 4)
        }
        let shareItem = NSMenuItem(title: L10n.text("分享此项…"), action: #selector(shareFromMenu(_:)), keyEquivalent: "")
        shareItem.target = self
        shareItem.representedObject = record.id
        menu.insertItem(shareItem, at: max(0, menu.items.count - 1))
        // Validation also considers multi-selection, including off-page image records.
        for (title, action) in [(L10n.text("作为图片文件粘贴"), #selector(pasteImageFileFromMenu(_:))),
                                (L10n.text("复制为图片文件"), #selector(copyImageFileFromMenu(_:)))] {
            let fileItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            fileItem.target = self; fileItem.representedObject = record.id
            menu.insertItem(fileItem, at: 3)
        }
        let moveMenu = NSMenu()
        for (name, id) in [(L10n.text("取消固定"), Optional<UUID>.none)] + pinboards.map({ ($0.name, Optional($0.id)) }) {
            let item = NSMenuItem(title: name, action: #selector(moveFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["recordID": record.id.uuidString, "boardID": id?.uuidString ?? ""]
            item.state = record.pinboardID == id ? .on : .off
            moveMenu.addItem(item)
        }
        let moveItem = NSMenuItem(title: L10n.text("固定到分组"), action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.insertItem(moveItem, at: max(0, menu.items.count - 1))
        return card
    }

    private func updateSelectionAppearance(focusResults: Bool = false, revealID: UUID? = nil) {
        let ids = selectedIDs
        for card in cardViews { card.isSelected = ids.contains(card.record.id) }
        updateSelectionCount()
        if focusResults { window?.makeFirstResponder(resultsView); cardViews.forEach(updateShortcutLabel) }
        if let id = revealID, let index = filteredRecords.firstIndex(where: { $0.id == id }) { revealItem(at: index) }
    }

    private func select(_ id: UUID, focusResults: Bool, extending: Bool = false, toggling: Bool = false) {
        cancelBoundaryNavigation()
        guard !queryPending, pageMatchesQuery,
              let ref = filteredRecords.first(where: { $0.id == id }).map(reference) ?? selection.reference(id) else { return }
        reorderStatus = nil
        if !extending && !toggling {
            selectionRequestID = nil
            pendingActionID = nil
            selection.selectSingle(ref)
            selectionStatus = nil
            updateSelectionAppearance(focusResults: focusResults, revealID: id)
            return
        }
        ensureSelectionUniverse(including: ref) { [weak self] in
            guard let self else { return }
            do {
                try self.selection.select(ref: ref, toggle: toggling, extend: extending)
                self.updateSelectionAppearance(focusResults: focusResults, revealID: id)
            } catch { self.selectionFailed(error) }
        }
    }

    private func selectionFailed(_ error: Error) {
        cancelBoundaryNavigation()
        selectionRequestID = nil
        selection.invalidate()
        selectionStatus = L10n.text("选中内容已变化或无法读取，操作未执行；请重新选择。\(error.localizedDescription)")
        statusLabel.stringValue = selectionStatus!
        updateSelectionAppearance()
    }

    /// Rebuilding a universe may include new captures, but preserves only the explicitly chosen IDs.
    private func ensureSelectionUniverse(including ref: ClipboardSelectionReference? = nil, action: @escaping () -> Void) {
        guard !selection.isInvalid, selectionRequestID == nil, isVisible, !queryPending, pageMatchesQuery else { return }
        if selection.universe != nil, ref.map({ selection.reference($0.id) == $0 }) ?? true { action(); return }
        selection.beginChange()
        pendingActionID = nil
        validationRequestID = nil
        let requestID = UUID(), session = viewGeneration, scope = scopeGeneration, generation = selection.generation
        selectionRequestID = requestID
        let chosen = selection.references
        func valid() -> Bool {
            isVisible && viewGeneration == session && scopeGeneration == scope && selection.generation == generation && selectionRequestID == requestID
        }
        func capture() {
            guard valid() else { return }
            requestSelectionSnapshot { [weak self] result in
                guard let self, valid() else { return }
                self.selectionRequestID = nil
                do {
                    let snapshot = try result.get()
                    try self.selection.installUniverse(snapshot.references)
                    if let ref, self.selection.reference(ref.id) != ref { throw PanelSelectionState.SelectionError.staleSelection }
                    action()
                } catch { self.selectionFailed(error) }
            }
        }
        if chosen.isEmpty { capture() }
        else {
            validateReferences(chosen) { [weak self] result in
                guard let self, valid() else { return }
                switch result { case .success: capture(); case .failure(let error): self.selectionFailed(error) }
            }
        }
    }

    private func requestSelectionSnapshot(_ completion: @escaping (Result<HistorySelectionSnapshot, Error>) -> Void) {
        if let onSelectionSnapshot { onSelectionSnapshot(currentQuery, completion); return }
        // Demo/local mode owns every record. A paginated caller must provide the global callback.
        guard !usesRemoteQuery else { completion(.failure(PanelSelectionState.SelectionError.missingUniverse)); return }
        completion(.success(HistorySelectionSnapshot(references: filteredRecords.map(reference))))
    }

    private func selectAllResults() {
        guard isVisible, !queryPending, pageMatchesQuery else { return }
        selection.beginChange()
        pendingActionID = nil
        validationRequestID = nil
        let requestID = UUID(), session = viewGeneration, scope = scopeGeneration, generation = selection.generation
        selectionRequestID = requestID
        pendingActionID = nil
        requestSelectionSnapshot { [weak self] result in
            guard let self, self.isVisible, self.viewGeneration == session, self.scopeGeneration == scope,
                  self.selection.generation == generation, self.selectionRequestID == requestID else { return }
            self.selectionRequestID = nil
            do { try self.selection.selectAll(try result.get().references); self.selectionStatus = nil; self.updateSelectionAppearance() }
            catch { self.selectionFailed(error) }
        }
    }

    private func validateReferences(_ references: [ClipboardSelectionReference], completion: @escaping (Result<Void, Error>) -> Void) {
        if let onValidateSelection { onValidateSelection(references, completion); return }
        let visible = Dictionary(uniqueKeysWithValues: filteredRecords.map { ($0.id, $0.revision) })
        guard references.allSatisfy({ ref in inlineRecords[ref.id]?.revision == ref.revision || visible[ref.id] == ref.revision }) else {
            completion(.failure(PanelSelectionState.SelectionError.staleSelection)); return
        }
        completion(.success(()))
    }

    private func validateCurrentSelection() {
        guard !selection.references.isEmpty, !selection.isInvalid, orderingRequestID == nil else { return }
        let requestID = UUID(), session = viewGeneration, scope = scopeGeneration, generation = selection.generation
        validationRequestID = requestID
        validateReferences(selection.references) { [weak self] result in
            guard let self, self.isVisible, self.viewGeneration == session, self.scopeGeneration == scope,
                  self.selection.generation == generation, self.validationRequestID == requestID else { return }
            self.validationRequestID = nil
            if case .failure(let error) = result { self.selectionFailed(error) }
        }
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
        cancelBoundaryNavigation()
        guard !filteredRecords.isEmpty, !queryPending else { return }
        if extending {
            ensureSelectionUniverse { [weak self] in
                guard let self, let id = self.selection.rangeTarget(delta: offset), let ref = self.selection.reference(id) else { return }
                do {
                    try self.selection.select(ref: ref, toggle: false, extend: true)
                    self.updateSelectionAppearance(focusResults: true, revealID: id)
                    if !self.filteredRecords.contains(where: { $0.id == id }) {
                        self.issueQuery(resetLimit: false, anchor: PanelPageAnchor(recordID: id, displacement: 0),
                                        retainedSelection: PanelRetainedSelection(generation: self.selection.generation))
                    }
                } catch { self.selectionFailed(error) }
            }
            return
        }
        let old = filteredRecords.firstIndex(where: { $0.id == selectedID }) ?? (offset < 0 ? filteredRecords.count : -1)
        let crossesWindow = old + offset < 0 ? hasPreviousResults : old + offset >= filteredRecords.count && hasMoreResults
        if crossesWindow, onPageRequest != nil, filteredRecords.indices.contains(old) {
            issueQuery(resetLimit: false, anchor: PanelPageAnchor(recordID: filteredRecords[old].id, displacement: offset < 0 ? -1 : 1), replaceSelectionOnFocus: true)
            return
        }
        let index = max(0, min(filteredRecords.count - 1, old + offset))
        select(filteredRecords[index].id, focusResults: true)
    }

    private func cancelBoundaryNavigation() {
        guard boundaryNavigationID != nil else { return }
        boundaryNavigationID = nil
        selectionRequestID = nil
        validationRequestID = nil
        selection.beginChange()
        if let pending = boundaryPageRequestID, pageRequestID == pending {
            pageRequestID = nil
            queryGeneration = UUID()
            queryPending = false
            resultPresentation = .ready
            updateResultPresentation()
        }
        boundaryPageRequestID = nil
        let needsRefresh = refreshAfterPageLoad
        refreshAfterPageLoad = false
        updatePageControls()
        if needsRefresh {
            let session = viewGeneration, scope = scopeGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, self.viewGeneration == session, self.scopeGeneration == scope else { return }
                self.refreshPage()
            }
        }
    }

    private func isCurrentBoundary(_ intent: PanelBoundaryNavigation) -> Bool {
        isVisible && boundaryNavigationID == intent.id && selection.generation == intent.generation
            && !isEditingSearch && allFiltersController == nil && filterPopover?.isShown != true
    }

    private func moveToBoundary(_ boundary: HistoryPageBoundary, extending: Bool) {
        cancelBoundaryNavigation()
        guard isVisible, !queryPending, pageMatchesQuery else { return }
        if extending && selection.isInvalid { return }
        let id = UUID()
        boundaryNavigationID = id
        selection.beginChange()
        pendingActionID = nil
        validationRequestID = nil
        selectionRequestID = nil
        if !extending || selection.anchorID == nil {
            let intent = PanelBoundaryNavigation(id: id, generation: selection.generation, selection: nil)
            if onPageRequest != nil {
                issueQuery(resetLimit: false, offset: 0, boundary: boundary,
                           replaceSelectionOnFocus: true, boundaryNavigation: intent)
            } else if !usesRemoteQuery {
                let target = boundary == .first ? filteredRecords.first : filteredRecords.last
                if let target { selection.selectSingle(reference(target)) } else { selection.clear() }
                boundaryNavigationID = nil
                updateSelectionAppearance(focusResults: true, revealID: target?.id)
            } else { cancelBoundaryNavigation() }
            return
        }
        ensureSelectionUniverse { [weak self] in
            guard let self, self.boundaryNavigationID == id,
                  let refs = self.selection.universe,
                  let target = boundary == .first ? refs.first : refs.last else { return }
            do {
                var candidate = self.selection
                try candidate.select(ref: target, toggle: false, extend: true)
                let intent = PanelBoundaryNavigation(id: id, generation: self.selection.generation, selection: candidate)
                guard self.isCurrentBoundary(intent) else { self.cancelBoundaryNavigation(); return }
                if self.onPageRequest != nil {
                    self.issueQuery(resetLimit: false, anchor: PanelPageAnchor(recordID: target.id, displacement: 0),
                                    boundaryNavigation: intent)
                } else {
                    self.validateReferences(candidate.references) { [weak self] result in
                        guard let self, self.isCurrentBoundary(intent) else { return }
                        self.boundaryNavigationID = nil
                        switch result {
                        case .success:
                            self.selection = candidate
                            self.updateSelectionAppearance(focusResults: true, revealID: target.id)
                        case .failure(let error): self.selectionFailed(error)
                        }
                    }
                }
            } catch { self.cancelBoundaryNavigation(); self.selectionFailed(error) }
        }
    }

    private func updateSelectionCount() {
        orderingActions.isEnabled = canReorderItems && !selectedIDs.isEmpty
        if resultPresentation == .loading {
            countLabel.stringValue = L10n.text("正在读取条目…")
            return
        }
        if resultPresentation == .failed && filteredRecords.isEmpty { countLabel.stringValue = ""; return }
        let count = onPageRequest != nil ? pageWindow.rangeDescription : L10n.text("\(filteredRecords.count) 条")
        let selected = selection.references.count
        countLabel.stringValue = selected > 1 || selection.isInvalid ? L10n.text("\(count) · 已选 \(selected) 条\(selection.isInvalid ? L10n.text("（已变化）") : "")") : count
    }

    private func loadPayload(_ id: UUID, completion: @escaping (ClipboardRecord?) -> Void) {
        if let record = inlineRecords[id] { completion(record); return }
        guard let resolveRecord else { completion(nil); return }
        resolveRecord(id) { record in
            DispatchQueue.main.async { completion(record) }
        }
    }

    private var hasFilters: Bool {
        !searchField.stringValue.isEmpty || !boardScope.queryIDs.isEmpty || selectedKind != nil || selectedSourceID != nil || selectedDeviceKey != "all" || copiedAfter != nil || copiedBefore != nil
    }
    private var usesRemoteQuery: Bool { onPageRequest != nil || onQueryChange != nil }
    private func matchesSelectedDevice(_ recordID: UUID) -> Bool {
        switch selectedDeviceFilter {
        case .all: return true
        case .unknown: return recordOriginDevices[recordID] == nil
        case .device(let id): return recordOriginDevices[recordID] == id
        }
    }
    private var hasPreviousResults: Bool { onPageRequest != nil && pageWindow.hasPrevious }
    private var hasMoreResults: Bool { onPageRequest != nil ? pageWindow.hasMore : onQueryChange != nil && records.count >= resultLimit }
    private var canReorderItems: Bool { manualOrder && boardScope.singleBoardID != nil && (onReorderSelection != nil || onReorderRecords != nil) && orderingRequestID == nil && !queryPending && boundaryNavigationID == nil && pageMatchesQuery && !selection.isInvalid && selectionRequestID == nil }

    private func updatePageControls() {
        previousPageButton.isHidden = onPageRequest == nil || !hasPreviousResults
        previousPageButton.isEnabled = !queryPending
        loadMoreButton.title = onPageRequest != nil ? L10n.text("下一页") : L10n.text("加载更多")
        loadMoreButton.isHidden = !usesRemoteQuery || !hasMoreResults
        loadMoreButton.isEnabled = !queryPending
        loadMoreButton.toolTip = onPageRequest != nil ? L10n.text("读取下一页；每页最多显示 300 条。方向键到边缘会自动读取相邻内容。") : nil
    }

    private func updateFilterControls() {
        let count = boardScope.filteredIDs.count
        multiBoardButton.title = count == 0 ? L10n.text("多板筛选…") : L10n.text("已筛选 \(count) 个分组…")
        multiBoardButton.toolTip = pinboards.filter { boardScope.filteredIDs.contains($0.id) }.map(\.name).joined(separator: "、")
        clearFiltersButton.isEnabled = hasFilters
        if boardScope.singleBoardID == nil { manualOrder = false }
        orderPopup.isEnabled = boardScope.singleBoardID != nil
        orderPopup.selectItem(at: manualOrder ? 1 : 0)
        orderingActions.isEnabled = canReorderItems && !selectedIDs.isEmpty
        orderingActions.isHidden = boardScope.singleBoardID == nil
        updatePageControls()
    }

    @objc private func showBoardFilters() {
        invalidateOutputContext()
        cancelBoundaryNavigation()
        closeAllFilters(restoreFocus: false)
        let controller = PinboardFilterController(boards: pinboards, selected: boardScope.queryIDs)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        InterfaceLayout.apply(to: controller.view, direction: layoutDirection)
        popover.contentSize = NSSize(width: 310, height: 340)
        controller.onCancel = { [weak popover] in popover?.close() }
        controller.onApply = { [weak self, weak popover] ids in
            guard let self else { return }
            self.boardScope.filter(ids.intersection(Set(self.pinboards.map(\.id))))
            self.boardPopup.selectItem(at: 0)
            self.manualOrder = self.boardScope.singleBoardID != nil
            popover?.close()
            self.issueQuery(resetLimit: true)
        }
        filterPopover?.close()
        filterPopover = popover
        popover.show(relativeTo: multiBoardButton.bounds, of: multiBoardButton, preferredEdge: .maxY)
    }

    private var filterOptions: HistoryFilterOptions {
        HistoryFilterOptions(pinboards: pinboards, sources: sources, devices: devices, localDeviceID: localDeviceID)
    }

    @objc func showAllFilters() {
        guard isVisible, !isComposing else { return }
        invalidateOutputContext()
        cancelBoundaryNavigation()
        if let allFiltersController { allFiltersController.focusInitialControl(); return }
        filterPopover?.close()
        let controller = HistoryFilterController(query: currentQuery, options: filterOptions)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        InterfaceLayout.apply(to: controller.view, direction: layoutDirection)
        popover.contentSize = controller.preferredContentSize
        let token = UUID(), session = viewGeneration, scope = scopeGeneration
        allFiltersSession = token
        allFiltersController = controller
        filterPopover = popover
        controller.onCancel = { [weak self] in
            guard let self, self.allFiltersSession == token else { return }
            self.closeAllFilters(restoreFocus: true)
        }
        controller.onApply = { [weak self] query in
            guard let self, self.isVisible, self.allFiltersSession == token,
                  self.viewGeneration == session, self.scopeGeneration == scope else { return }
            do { try HistoryFilterDraft(query: query).validate(availablePinboardIDs: Set(self.pinboards.map(\.id))) }
            catch { self.statusLabel.stringValue = error.localizedDescription; return }
            self.closeAllFilters(restoreFocus: true)
            self.boardScope.filter(query.pinboardIDs)
            self.boardPopup.selectItem(at: 0)
            self.selectedKind = query.kind
            self.selectedSourceID = query.sourceBundleID
            self.selectedDeviceFilter = query.deviceFilter
            self.copiedAfter = query.copiedAfter; self.copiedBefore = query.copiedBefore
            self.manualOrder = query.sortOrder == .pinboard
            if let item = self.typePopup.itemArray.first(where: { ($0.representedObject as? String) == query.kind?.rawValue }) { self.typePopup.select(item) }
            self.setSources([:])
            self.rebuildDeviceOptions()
            self.lastDateIndex = query.copiedAfter == nil && query.copiedBefore == nil ? 0 : 4
            self.datePopup.selectItem(at: self.lastDateIndex)
            self.issueQuery(resetLimit: true)
        }
        if let presentFilterPopover { presentFilterPopover(popover, searchField) }
        else { popover.show(relativeTo: searchField.bounds, of: searchField, preferredEdge: .maxY) }
        controller.focusInitialControl()
    }

    private func closeAllFilters(restoreFocus: Bool) {
        guard allFiltersController != nil else { return }
        allFiltersSession = nil
        allFiltersController = nil
        let popover = filterPopover
        filterPopover = nil
        popover?.delegate = nil
        popover?.close()
        if restoreFocus, isVisible { window?.makeFirstResponder(searchField); cardViews.forEach(updateShortcutLabel) }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === filterPopover else { return }
        closeAllFilters(restoreFocus: true)
    }

    @objc private func clearFilters() {
        searchField.stringValue = ""
        boardScope.navigate(to: nil)
        selectedKind = nil; selectedSourceID = nil; copiedAfter = nil; copiedBefore = nil; lastDateIndex = 0
        selectedDeviceFilter = .all
        manualOrder = false; pendingRevealID = nil
        [boardPopup, typePopup, sourcePopup, devicePopup, datePopup].forEach { $0.selectItem(at: 0) }
        issueQuery(resetLimit: true)
        window?.makeFirstResponder(searchField)
    }
    @objc private func orderChanged() { manualOrder = orderPopup.indexOfSelectedItem == 1 && boardScope.singleBoardID != nil; issueQuery(resetLimit: true) }
    @objc private func moveItemsEarlier() { stepSelectedItems(forward: false) }
    @objc private func moveItemsLater() { stepSelectedItems(forward: true) }
    @objc private func reorderEarlierFromMenu(_ item: NSMenuItem) { if selectContextItemIfNeeded(item) { stepSelectedItems(forward: false) } }
    @objc private func reorderLaterFromMenu(_ item: NSMenuItem) { if selectContextItemIfNeeded(item) { stepSelectedItems(forward: true) } }
    private func selectContextItemIfNeeded(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? UUID, !queryPending, boundaryNavigationID == nil, pageMatchesQuery else { return false }
        if selectedIDs.contains(id) { return !selection.isInvalid }
        guard filteredRecords.contains(where: { $0.id == id }) else {
            statusLabel.stringValue = L10n.text("菜单对应的条目已变化，请重新选择。")
            return false
        }
        select(id, focusResults: true)
        return selectedIDs.contains(id)
    }
    private func stepSelectedItems(forward: Bool) {
        guard canReorderItems else { statusLabel.stringValue = L10n.text("请先选择一个分组，并切换为“分组内手动顺序”。"); return }
        if let onStepSelection, let boardID = boardScope.singleBoardID {
            let refs = selection.references
            performSelectionMutation(refs, success: L10n.text("已保存分组顺序")) { completion in
                onStepSelection(refs, boardID, forward, completion)
            }
            return
        }
        do {
            let plan = try PanelReorderPlan.step(movingIDs: selectedIDs, visibleIDs: filteredRecords.map(\.id), forward: forward, hasMore: hasMoreResults, hasPrevious: hasPreviousResults)
            applyReorder(plan)
        } catch { reportReorderPlanningError(error) }
    }
    private func applyReorder(_ plan: PanelReorderPlan, dragRevisions: [UUID: Int] = [:]) {
        ClipboardDragTrace.log("panel applyReorder canReorder=\(canReorderItems) movingCount=\(plan.movingIDs.count) hasAnchor=\(plan.beforeID != nil)")
        guard canReorderItems, let boardID = boardScope.singleBoardID, let onReorderRecords else { return }
        let relevant = Set(plan.movingIDs + (plan.beforeID.map { [$0] } ?? []))
        var versions = Dictionary(uniqueKeysWithValues: filteredRecords.filter { relevant.contains($0.id) }.map { ($0.id, $0.revision) })
        for id in plan.movingIDs { if let revision = dragRevisions[id] { versions[id] = revision } }
        guard versions.count == relevant.count,
              filteredRecords.filter({ relevant.contains($0.id) }).allSatisfy({ $0.pinboardID == boardID }) else {
            statusLabel.stringValue = L10n.text("内容已变化，请刷新后重试。"); issueQuery(resetLimit: false); return
        }
        let requestID = UUID(), session = viewGeneration, query = queryGeneration, pageRequest = pageRequestID
        orderingRequestID = requestID
        statusLabel.stringValue = L10n.text("正在保存分组顺序…")
        updateFilterControls()
        onReorderRecords(boardID, plan.movingIDs, plan.beforeID, versions) { [weak self] result in
            guard let self, self.orderingRequestID == requestID else { return }
            self.orderingRequestID = nil
            self.updateFilterControls()
            // A storage write may finish after navigation. Only its originating query may refresh.
            guard self.isVisible, self.viewGeneration == session, self.queryGeneration == query,
                  self.pageRequestID == pageRequest else { return }
            switch result {
            case .success:
                self.reorderStatus = L10n.text("已保存分组顺序")
                self.statusLabel.stringValue = self.reorderStatus!
                if self.boardScope.singleBoardID == boardID { self.pendingRevealID = self.selectedID }
            case .failure(let error):
                self.reorderStatus = L10n.text("顺序未更改，请刷新后重试。\(error.localizedDescription)")
                self.statusLabel.stringValue = self.reorderStatus!
            }
            // Storage is authoritative; no speculative reorder can overwrite a newer refresh.
            self.issueQuery(resetLimit: false, preserveReveal: true, preserveStatus: true)
        }
    }
    private func performSelectionMutation(_ refs: [ClipboardSelectionReference], success: String,
                                          clearAfterSuccess: Bool = false,
                                          operation: (@escaping (Result<[ClipboardSelectionReference], Error>) -> Void) -> Void) {
        guard !refs.isEmpty, refs == selection.references, !selection.isInvalid, selectionRequestID == nil,
              isVisible, !queryPending, boundaryNavigationID == nil, pageMatchesQuery, orderingRequestID == nil else { return }
        let requestID = UUID(), session = viewGeneration, scope = scopeGeneration
        let generation = selection.generation, page = queryGeneration, pageRequest = pageRequestID
        orderingRequestID = requestID
        pendingActionID = nil
        statusLabel.stringValue = L10n.text("正在保存选中内容…")
        updateFilterControls()
        operation { [weak self] result in
            guard let self, self.orderingRequestID == requestID else { return }
            self.orderingRequestID = nil
            self.updateFilterControls()
            guard self.isVisible, self.viewGeneration == session, self.scopeGeneration == scope,
                  self.selection.generation == generation, self.queryGeneration == page,
                  self.pageRequestID == pageRequest else { return }
            do {
                try self.selection.adoptCommitted(try result.get())
                if clearAfterSuccess { self.selection.clear() }
                self.selectionStatus = nil
                self.reorderStatus = success
                self.statusLabel.stringValue = success
                self.updateSelectionAppearance()
                self.refreshPage()
            } catch {
                self.reorderStatus = L10n.text("操作未完成，请重新选择后重试。\(error.localizedDescription)")
                self.statusLabel.stringValue = self.reorderStatus!
                self.selection.invalidate()
                self.selectionStatus = self.reorderStatus
                self.updateSelectionAppearance()
            }
        }
    }

    private func moveReferences(_ refs: [ClipboardSelectionReference], to destination: UUID?) {
        if let onMoveSelection {
            let leavesScope = !boardScope.queryIDs.isEmpty && destination.map { !boardScope.queryIDs.contains($0) } != false
            performSelectionMutation(refs, success: leavesScope ? L10n.text("已移动；内容已离开当前筛选，已取消选择") : L10n.text("已移动选中内容"), clearAfterSuccess: leavesScope) { completion in
                onMoveSelection(refs, destination, completion)
            }
        } else {
            resolveReferences(refs) { [weak self] in self?.onMoveRecords?($0, destination) }
        }
    }

    private func reorderReferences(_ refs: [ClipboardSelectionReference], before: UUID?) {
        guard let board = boardScope.singleBoardID else { return }
        if let onReorderSelection {
            let anchor = before.flatMap { id in filteredRecords.first(where: { $0.id == id }).map(reference) }
            guard before == nil || anchor != nil else { return }
            performSelectionMutation(refs, success: L10n.text("已保存分组顺序")) { completion in onReorderSelection(refs, board, anchor, completion) }
        } else {
            applyReorder(PanelReorderPlan(movingIDs: refs.map(\.id), beforeID: before),
                         dragRevisions: Dictionary(uniqueKeysWithValues: refs.map { ($0.id, $0.revision) }))
        }
    }

    private func reportReorderPlanningError(_ error: Error) {
        if error as? PanelReorderPlan.PlanningError == .unloadedBoundary {
            statusLabel.stringValue = onPageRequest != nil ? L10n.text("该方向还有未加载的内容，请先翻页，再调整顺序。") : L10n.text("后面还有未加载的内容，请先点“加载更多”再移动到这里。")
        } else if error as? PanelReorderPlan.PlanningError != .noMovement {
            statusLabel.stringValue = L10n.text("当前选择已变化，请重新选择后排序。")
        }
    }
    private func insertionIndex(at point: NSPoint) -> Int {
        guard let layout = resultsView.collectionViewLayout else { return filteredRecords.count }
        let frames = filteredRecords.indices.compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        guard frames.count == filteredRecords.count else { return filteredRecords.count }
        return PanelLayoutDirection.insertionIndex(at: point.x, frames: frames, direction: layoutDirection)
    }
    private func ownedDraggedCard(_ source: Any?) -> ClipboardCardView? {
        ClipboardDragTrace.log("panel ownedSource isCard=\(source is ClipboardCardView) generationMatches=\((source as? ClipboardCardView)?.dragOriginID == viewGeneration)")
        guard let card = source as? ClipboardCardView, card.dragOriginID == viewGeneration,
              card.dragScopeID == scopeGeneration, card.dragSelectionID == selection.generation else { return nil }
        return card
    }
    private func updateDragInsertion(at point: NSPoint, source: Any?) -> NSDragOperation {
        insertionLine.isHidden = true
        guard let card = ownedDraggedCard(source) else { return source is ClipboardCardView || boardScope.queryIDs.count > 1 ? [] : .copy }
        guard canReorderItems else { return boardScope.queryIDs.count > 1 ? [] : .move }
        let index = insertionIndex(at: point)
        ClipboardDragTrace.log("panel insertion index=\(index) total=\(filteredRecords.count) movingCount=\(card.draggedRecordIDs.count) hasMore=\(hasMoreResults)")
        guard (try? PanelReorderPlan.insertion(references: card.draggedReferences, visibleIDs: filteredRecords.map(\.id), at: index, hasMore: hasMoreResults, hasPrevious: hasPreviousResults)) != nil,
              let layout = resultsView.collectionViewLayout else { return [] }
        let adjacent = index < filteredRecords.count ? index : max(0, index - 1)
        if let frame = layout.layoutAttributesForItem(at: IndexPath(item: adjacent, section: 0))?.frame {
            insertionLine.frame = PanelLayoutDirection.insertionLineFrame(frame: frame, before: index < filteredRecords.count,
                                                                          direction: layoutDirection, contentWidth: resultsView.bounds.width)
            insertionLine.isHidden = false
        }
        return .move
    }
    private func handleResultsDrop(_ items: [NSPasteboardItem], source: Any?, point: NSPoint) -> Bool {
        ClipboardDragTrace.log("panel handleResultsDrop manual=\(manualOrder) canReorder=\(canReorderItems) items=\(items.count)")
        if let card = ownedDraggedCard(source), manualOrder {
            guard canReorderItems else { return false }
            do {
                let plan = try PanelReorderPlan.insertion(references: card.draggedReferences, visibleIDs: filteredRecords.map(\.id), at: insertionIndex(at: point), hasMore: hasMoreResults, hasPrevious: hasPreviousResults)
                reorderReferences(card.draggedReferences, before: plan.beforeID); return true
            } catch { reportReorderPlanningError(error); return false }
        }
        handleDrop(items, source: source)
        return boardScope.queryIDs.count <= 1
    }
    private func handleDrop(_ items: [NSPasteboardItem], source: Any?) {
        guard boardScope.queryIDs.count <= 1 else { statusLabel.stringValue = L10n.text("拖入前请选择一个目标分组，或清除多板筛选。"); return }
        if let card = ownedDraggedCard(source) {
            // Trust the in-process source object's IDs, never a pasteboard marker.
            guard !manualOrder else { statusLabel.stringValue = L10n.text("请将条目拖到卡片之间的插入标记处。"); return }
            moveReferences(card.draggedReferences, to: boardScope.singleBoardID)
        } else if !(source is ClipboardCardView) {
            onDropItems?(items, boardScope.singleBoardID)
        }
    }

    private func resolve(_ content: ClipboardCardContent, forOutput: Bool = false, action: @escaping (ClipboardRecord) -> Void) {
        resolve([content], forOutput: forOutput) { if let record = $0.first { action(record) } }
    }

    private func resolve(_ contents: [ClipboardCardContent], forOutput: Bool = false, action: @escaping ([ClipboardRecord]) -> Void) {
        resolveReferences(contents.map(reference), forOutput: forOutput, action: action)
    }

    /// The whole captured set is validated before exposing any payload to an output callback.
    private func resolveReferences(_ references: [ClipboardSelectionReference], forOutput: Bool = false, action: @escaping ([ClipboardRecord]) -> Void) {
        guard !forOutput || detailWindow == nil else { return }
        guard !references.isEmpty, isVisible, filePreview == nil, !queryPending, boundaryNavigationID == nil, pageMatchesQuery,
              !selection.isInvalid, selectionRequestID == nil else { return }
        let actionID = UUID(), session = viewGeneration, scope = scopeGeneration
        outputActionGeneration = actionID
        let generation = selection.generation, page = queryGeneration
        pendingActionID = actionID
        func finish(_ result: Result<[ClipboardRecord], Error>) {
            guard !forOutput || (detailWindow == nil && outputActionGeneration == actionID) else { return }
            guard isVisible, pendingActionID == actionID, viewGeneration == session, scopeGeneration == scope,
                  selection.generation == generation, queryGeneration == page else { return }
            pendingActionID = nil
            do {
                let records = try result.get()
                guard records.count == references.count,
                      zip(records, references).allSatisfy({ $0.id == $1.id && $0.revision == $1.revision }) else {
                    throw PanelSelectionState.SelectionError.staleSelection
                }
                action(records)
            } catch {
                // A missing/unsafe file must still allow preview, repair, rename and
                // deletion. Every future output revalidates the complete captured set.
                if forOutput { statusLabel.stringValue = L10n.text("无法输出内容：\(error.localizedDescription)") }
                else { selectionFailed(error) }
            }
        }
        if let resolver = forOutput ? (resolveOutputSelection ?? resolveSelection) : resolveSelection { resolver(references, finish); return }
        // Legacy/demo fallback has no global reader. It still rejects the entire output on mismatch.
        var result: [ClipboardRecord] = []
        result.reserveCapacity(references.count)
        var bytes = 0
        func read(_ index: Int) {
            guard !forOutput || (detailWindow == nil && outputActionGeneration == actionID) else { return }
            guard isVisible, pendingActionID == actionID, viewGeneration == session, scopeGeneration == scope,
                  selection.generation == generation, queryGeneration == page else { return }
            guard index < references.count else { finish(.success(result)); return }
            let ref = references[index]
            loadPayload(ref.id) { record in
                guard let record, record.revision == ref.revision else { finish(.failure(PanelSelectionState.SelectionError.staleSelection)); return }
                bytes += record.parts.reduce(0) { $0 + $1.representations.reduce(0) { $0 + $1.data.count } }
                guard bytes <= 512 * 1_024 * 1_024 else { finish(.failure(PanelSelectionState.SelectionError.malformedSnapshot)); return }
                result.append(record)
                // Avoid recursive stack growth when a demo resolver calls back synchronously.
                if index + 1 == references.count { finish(.success(result)) }
                else { DispatchQueue.main.async { read(index + 1) } }
            }
        }
        read(0)
    }

    private func resolveFocused(action: @escaping (ClipboardRecord) -> Void) {
        guard let id = selectedID, let ref = selection.reference(id) else { return }
        resolveReferences([ref]) { if let record = $0.first { action(record) } }
    }

    /// Image conversion can finish after selection, query, window, or another output action changes.
    /// The caller must discard an unpublished export when this guard expires.
    func captureOutputContext() -> () -> Bool {
        let session = viewGeneration, scope = scopeGeneration, page = queryGeneration
        let selectionID = selection.generation, outputID = outputActionGeneration
        return { [weak self] in
            guard let self else { return false }
            return self.isVisible && self.viewGeneration == session && self.scopeGeneration == scope
                && self.queryGeneration == page && self.selection.generation == selectionID
                && self.outputActionGeneration == outputID && !self.selection.isInvalid
                && !self.queryPending && self.pageMatchesQuery && self.selectionRequestID == nil
                && !self.isEditingSearch && self.window?.attachedSheet == nil
                && self.boundaryNavigationID == nil && self.allFiltersController == nil
                && self.filterPopover?.isShown != true && self.filePreview == nil && self.detailWindow == nil
                && self.imagePreview == nil && self.linkPreview == nil
        }
    }

    private func invalidateOutputContext() { outputActionGeneration = UUID() }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { invalidateOutputContext() }
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
        resolveReferences(selection.references, forOutput: true) { [weak self] records in
            guard let self else { return }
            let outputPlain = self.outputPlainText(records, requested: plain)
            if records.count == 1, let record = records.first { self.onPaste?(record, outputPlain) }
            else if records.count > 1 { self.onPasteRecords?(records, outputPlain) }
        }
    }

    private func copySelection() {
        resolveReferences(selection.references, forOutput: true) { [weak self] records in
            if records.count == 1, let record = records.first { self?.onCopy?(record) }
            else if records.count > 1 { self?.onCopyRecords?(records) }
        }
    }

    private func deleteSelection() {
        resolveReferences(selection.references) { [weak self] records in
            if let onDeleteRecords = self?.onDeleteRecords { onDeleteRecords(records) }
            else if records.count == 1, let record = records.first { self?.onDelete?(record) }
            else { self?.statusLabel.stringValue = L10n.text("当前入口不支持原子批量删除，操作未执行。") }
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible, event.window === self.window else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.invalidateOutputContext(); return event
            }
            if event.type == .flagsChanged { self.handleModifierFlags(event.modifierFlags); return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if detailWindow != nil, event.window === window {
            if event.keyCode == 53, !event.isARepeat { closeDetail() }
            return true
        }
        // Repeated Return/Quick Paste is consumed below. It must not cancel the
        // original request while that request is still loading its payload.
        if !event.isARepeat { invalidateOutputContext() }
        if let filePreview {
            // Child windows and their sheets retain native text/button handling. A key
            // accidentally delivered to history while the file window is open cannot paste.
            guard event.window === window else { return false }
            if event.keyCode == 53, !event.isARepeat { filePreview.dismiss() }
            return true
        }
        // Mouse/Tab focus changes can enter an editor without passing through Cmd-F.
        if isEditingSearch || window?.firstResponder is NSTextView { cancelBoundaryNavigation() }
        guard !isComposing, !(window?.firstResponder is ShortcutRecorderView) else { return false }
        if window?.firstResponder is NSTextView, !isEditingSearch { return false }
        let flags = ShortcutChord.normalizedModifiers(event.modifierFlags)
        if boundaryNavigationID != nil {
            let command = KeyboardShortcutConfiguration.fixedCommand(for: event)
            let selectionCommands: [FixedShortcutCommand] = [.open, .reveal, .copy, .undo, .edit, .rename]
            let quick = shortcutConfiguration.quickPaste.eventFlags
            let quickOutput = [UInt16(18), 19, 20, 21, 23, 22, 26, 28, 25].contains(event.keyCode)
                && (flags == quick || flags == quick.union(shortcutConfiguration.plainText.eventFlags))
            let selectionKey = [UInt16(36), 76, 49, 51, 117].contains(event.keyCode)
            let reorderKey = [UInt16(123), 124].contains(event.keyCode) && flags == [.command, .option]
            if command.map({ selectionCommands.contains($0) }) == true || quickOutput || selectionKey || reorderKey { return true }
            if !event.isARepeat { cancelBoundaryNavigation() }
        }
        handleModifierFlags(flags)
        let editingSearch = isEditingSearch
        let plainFlags = shortcutConfiguration.plainText.eventFlags
        if let command = KeyboardShortcutConfiguration.fixedCommand(for: event) {
            let permittedWhileEditing: [FixedShortcutCommand] = [.search, .settings, .pause, .newText, .newPinboard]
            guard !editingSearch || permittedWhileEditing.contains(command) else { return false }
            // These stay in the native responder/menu chain even when a saved physical
            // board shortcut collides after an input-source change.
            if command == .cut || command == .paste || command == .quit { return false }
            guard !event.isARepeat else { return true }
            switch command {
            case .search:
                outputActionGeneration = UUID()
                if editingSearch { showAllFilters() }
                else { window?.makeFirstResponder(searchField); cardViews.forEach(updateShortcutLabel) }
            case .settings: onSettings?()
            case .pause: onPauseToggle?()
            case .newText: onNewText?()
            case .newPinboard: createBoard()
            case .open: resolveFocused { [weak self] in self?.onOpenRecord?($0) }
            case .reveal: revealSelection()
            case .copy: copySelection()
            case .undo: onUndo?()
            case .selectAll: selectAllResults()
            case .edit: resolveFocused { [weak self] in self?.showDetail($0, editing: true) }
            case .rename:
                if let id = selectedID, let ref = selection.reference(id) { rename(ref) }
            case .cut, .paste, .quit: break
            }
            return true
        }
        if !editingSearch {
            let numbers: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            let quick = shortcutConfiguration.quickPaste.eventFlags
            if let index = numbers[event.keyCode], flags == quick || flags == quick.union(plainFlags) {
                if !event.isARepeat, filteredRecords.indices.contains(index) {
                    let plain = flags == quick.union(plainFlags)
                    resolve(filteredRecords[index], forOutput: true) { [weak self] in
                        guard let self else { return }
                        self.onPaste?($0, self.outputPlainText([$0], requested: plain))
                    }
                }
                return true
            }
            if shortcutConfiguration.previousPinboard.matches(event) { moveBoardSelection(-1); return true }
            if shortcutConfiguration.nextPinboard.matches(event) { moveBoardSelection(1); return true }
        }
        switch event.keyCode {
        case 53 where flags.isEmpty:
            guard !event.isARepeat else { return true }
            cardViews.forEach { $0.cancelPendingDrag() }
            pendingActionID = nil
            if !searchField.stringValue.isEmpty { searchField.stringValue = ""; issueQuery(resetLimit: true); window?.makeFirstResponder(searchField) }
            else { dismiss() }
            return true
        case 36, 76:
            guard flags.isEmpty || flags == plainFlags else { return false }
            guard !event.isARepeat else { return true }
            if editingSearch { window?.makeFirstResponder(resultsView); cardViews.forEach(updateShortcutLabel); return true }
            pasteSelection(plain: flags == plainFlags)
            return true
        case 125 where editingSearch && flags.isEmpty,
             48 where editingSearch && flags.isEmpty:
            window?.makeFirstResponder(resultsView); cardViews.forEach(updateShortcutLabel)
            return true
        case 48 where !editingSearch && flags == .shift:
            window?.makeFirstResponder(searchField); cardViews.forEach(updateShortcutLabel)
            return true
        case 49 where !editingSearch && flags.isEmpty:
            if !event.isARepeat { resolveFocused { [weak self] in self?.showDetail($0, editing: false) } }
            return true
        case 123 where !editingSearch && flags == [.command, .option]:
            if !event.isARepeat { stepSelectedItems(forward: layoutDirection == .rightToLeft) }; return true
        case 124 where !editingSearch && flags == [.command, .option]:
            if !event.isARepeat { stepSelectedItems(forward: layoutDirection == .leftToRight) }; return true
        case 126 where !editingSearch && (flags == .command || flags == [.command, .shift]):
            if !event.isARepeat { moveToBoundary(.first, extending: flags.contains(.shift)) }
            return true
        case 125 where !editingSearch && (flags == .command || flags == [.command, .shift]):
            if !event.isARepeat { moveToBoundary(.last, extending: flags.contains(.shift)) }
            return true
        case 123 where !editingSearch && (flags.isEmpty || flags == .shift): moveSelection(PanelLayoutDirection.step(towardRight: false, direction: layoutDirection), extending: flags == .shift); return true
        case 124 where !editingSearch && (flags.isEmpty || flags == .shift): moveSelection(PanelLayoutDirection.step(towardRight: true, direction: layoutDirection), extending: flags == .shift); return true
        case 51 where !editingSearch && flags.isEmpty,
             117 where !editingSearch && flags.isEmpty:
            if !event.isARepeat { deleteSelection() }
            return true
        default:
            // Deliver the original event to the search editor; preserve IME and native edit commands.
            if !editingSearch, flags.intersection([.command, .control]).isEmpty,
               let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value >= 0x20 && !($0.value >= 0xF700 && $0.value <= 0xF8FF) }) {
                window?.makeFirstResponder(searchField); cardViews.forEach(updateShortcutLabel)
            }
            return false
        }
    }

    private func recordFromMenu(_ sender: NSMenuItem) -> ClipboardCardContent? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return filteredRecords.first(where: { $0.id == id })
    }

    private static func kindTitle(_ kind: ClipboardContentKind) -> String {
        switch kind { case .text: return L10n.text("文本"); case .link: return L10n.text("链接"); case .image: return L10n.text("图片"); case .file: return L10n.text("文件"); case .color: return L10n.text("颜色") }
    }

    private func issueQuery(resetLimit: Bool, preserveReveal: Bool = false, preserveStatus: Bool = false,
                            anchor: PanelPageAnchor? = nil, offset: Int? = nil, focusLast: Bool = false,
                            boundary: HistoryPageBoundary? = nil,
                            retainedSelection: PanelRetainedSelection? = nil, allowMissingAnchorFallback: Bool = false,
                            replaceSelectionOnFocus: Bool = false, boundaryNavigation: PanelBoundaryNavigation? = nil) {
        if boundaryNavigation == nil { cancelBoundaryNavigation() }
        if resetLimit {
            filePreview?.dismiss()
            closeAllFilters(restoreFocus: false)
            scopeGeneration = UUID()
            selectionRequestID = nil
            validationRequestID = nil
            selection.clear()
            selectionStatus = nil
        }
        queryGeneration = UUID()
        pendingActionID = nil
        cardViews.forEach { $0.cancelPendingDrag() }
        if !preserveStatus {
            if resultPresentation == .failed { statusLabel.stringValue = baseStatus }
            reorderStatus = nil; pageStatus = nil
        }
        if !preserveReveal { pendingRevealID = nil }
        if resetLimit || onPageRequest != nil { resultLimit = PanelPageWindow.size }
        queryPending = usesRemoteQuery
        resultPresentation = usesRemoteQuery ? .loading : .ready
        if onPageRequest != nil, resetLimit { pageMatchesQuery = false }
        updateFilterControls()
        updateResultPresentation()
        let query = currentQuery
        if let onPageRequest {
            let requestedAnchor = anchor ?? (preserveReveal ? pendingRevealID.map { PanelPageAnchor(recordID: $0, displacement: 0) } : nil)
            let request = PanelPageRequest(id: queryGeneration, query: query,
                                          offset: boundary == nil ? max(0, offset ?? (resetLimit ? 0 : pageWindow.offset)) : 0,
                                          anchor: requestedAnchor, boundary: boundary)
            pageRequestID = request.id
            if boundaryNavigation != nil { boundaryPageRequestID = request.id }
            let session = viewGeneration
            let focusResults = !isEditingSearch && allFiltersController == nil
            onPageRequest(request) { [weak self] result in
                guard let self else { return }
                @MainActor func current() -> Bool {
                    guard self.isVisible, self.viewGeneration == session,
                          self.queryGeneration == request.id, self.pageRequestID == request.id else { return false }
                    if let intent = boundaryNavigation, !self.isCurrentBoundary(intent) {
                        if self.boundaryNavigationID == intent.id { self.cancelBoundaryNavigation() }
                        return false
                    }
                    return true
                }
                guard current() else { return }
                @MainActor func finish() {
                    self.pageRequestID = nil
                    self.queryPending = false
                    if self.resultPresentation == .loading { self.resultPresentation = .ready }
                    self.updateResultPresentation()
                    if boundaryNavigation != nil { self.boundaryNavigationID = nil; self.boundaryPageRequestID = nil }
                    self.updateFilterControls()
                    if self.refreshAfterPageLoad {
                        self.refreshAfterPageLoad = false
                        self.refreshPage()
                    }
                }
                switch result {
                case .success(let page):
                    let ids = Set(page.records.map(\.id))
                    let validFocus = page.focusID.map { ids.contains($0) } ?? (request.anchor == nil && (boundary == nil || page.records.isEmpty))
                    let exactAnchor = request.anchor?.displacement != 0 || page.focusID == request.anchor?.recordID
                    let exactBoundary = boundary == nil || (boundary == .first
                        ? page.offset == 0 && page.focusID == page.records.first?.id
                        : !page.hasMore && page.focusID == page.records.last?.id)
                    guard page.records.count <= PanelPageWindow.size, ids.count == page.records.count,
                          page.offset >= 0, validFocus, exactAnchor, exactBoundary else {
                        self.pageLoadFailed(); finish(); return
                    }
                    @MainActor func accept() {
                        guard current() else { return }
                        let changedWindow = page.offset != self.pageWindow.offset || resetLimit
                        self.pageWindow.update(offset: page.offset, count: page.records.count, hasMore: page.hasMore)
                        self.pageMatchesQuery = true
                        self.resultPresentation = .ready
                        self.pageStatus = nil
                        self.inlineRecords.removeAll()
                        self.recordOriginDevices = Dictionary(uniqueKeysWithValues: page.records.compactMap { record in
                            record.originDeviceConflict ? nil : record.originDeviceID.map { (record.id, $0) }
                        })
                        self.records = page.records.map(ClipboardCardContent.init)
                        var focus = page.focusID ?? (focusLast ? page.records.last?.id : page.records.first?.id)
                        if let candidate = boundaryNavigation?.selection {
                            self.selection = candidate
                            self.selectionStatus = nil
                            focus = candidate.focusID
                        } else if let retainedSelection {
                            focus = retainedSelection.generation == self.selection.generation ? self.selectedID : nil
                        } else if resetLimit || replaceSelectionOnFocus {
                            if let focus, let content = self.records.first(where: { $0.id == focus }) {
                                self.selection.selectSingle(self.reference(content))
                            } else { self.selection.clear() }
                            self.selectionStatus = nil
                        }
                        self.pendingRevealID = nil
                        self.reloadResults(resetScroll: changedWindow, allowAutomaticSelection: resetLimit)
                        if retainedSelection != nil { self.validateCurrentSelection() }
                        if let focus, let index = self.filteredRecords.firstIndex(where: { $0.id == focus }) {
                            self.revealItem(at: index)
                            if focusResults, !self.isEditingSearch, self.allFiltersController == nil, retainedSelection == nil {
                                self.window?.makeFirstResponder(self.resultsView)
                            }
                        }
                        finish()
                    }
                    if let candidate = boundaryNavigation?.selection {
                        let expected = Dictionary(uniqueKeysWithValues: candidate.references.map { ($0.id, $0.revision) })
                        guard let target = candidate.focusID, let targetVersion = expected[target],
                              page.records.contains(where: { $0.id == target && $0.revision == targetVersion }),
                              page.records.allSatisfy({ record in expected[record.id].map { $0 == record.revision } ?? true }) else {
                            self.selectionFailed(PanelSelectionState.SelectionError.staleSelection); finish(); return
                        }
                        self.validateReferences(candidate.references) { [weak self] validation in
                            guard let self, current() else { return }
                            switch validation {
                            case .success: accept()
                            case .failure(let error): self.selectionFailed(error); finish()
                            }
                        }
                    } else { accept() }
                case .failure(let error):
                    if allowMissingAnchorFallback, requestedAnchor != nil,
                       let storeError = error as? HistoryStoreError, case .recordNotFound = storeError {
                        self.issueQuery(resetLimit: false, preserveStatus: true, offset: self.pageWindow.offset,
                                        retainedSelection: retainedSelection)
                        return
                    }
                    self.pageLoadFailed(); finish()
                }
            }
            return
        }
        if let onQueryChange { onQueryChange(query) } else { reloadResults(resetScroll: resetLimit) }
    }

    private func pageLoadFailed() {
        pendingRevealID = nil
        refreshAfterPageLoad = false
        pageStatus = L10n.text("内容已变化或暂时无法读取；保留当前页，请重试。")
        statusLabel.stringValue = pageStatus!
        resultPresentation = .failed
        updateResultPresentation()
        updateFilterControls()
    }

    @objc private func boardChanged() { selectedBoardID = boardPopup.selectedItem?.representedObject as? UUID; manualOrder = selectedBoardID != nil; issueQuery(resetLimit: true) }
    @objc private func typeChanged() { selectedKind = (typePopup.selectedItem?.representedObject as? String).flatMap(ClipboardContentKind.init(rawValue:)); issueQuery(resetLimit: true) }
    @objc private func sourceChanged() { selectedSourceID = sourcePopup.selectedItem?.representedObject as? String; issueQuery(resetLimit: true) }
    @objc private func deviceChanged() {
        switch devicePopup.selectedItem?.representedObject as? String {
        case "all": selectedDeviceFilter = .all
        case "unknown": selectedDeviceFilter = .unknown
        case .some(let value):
            guard let id = UUID(uuidString: value) else { return }
            selectedDeviceFilter = .device(id)
        case .none: return
        }
        issueQuery(resetLimit: true)
    }
    @objc private func loadMore() {
        cancelBoundaryNavigation()
        guard !queryPending else { return }
        if onPageRequest != nil { issueQuery(resetLimit: false, offset: pageWindow.nextOffset) }
        else { resultLimit += 300; issueQuery(resetLimit: false, preserveReveal: true) }
    }
    @objc private func loadPreviousPage() {
        cancelBoundaryNavigation()
        guard onPageRequest != nil, hasPreviousResults, !queryPending else { return }
        issueQuery(resetLimit: false, offset: pageWindow.previousOffset, focusLast: true)
    }

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
        cancelBoundaryNavigation()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("按复制时间筛选")
        alert.addButton(withTitle: L10n.text("应用"))
        alert.addButton(withTitle: L10n.text("取消"))
        let start = NSDatePicker()
        let end = NSDatePicker()
        for picker in [start, end] { picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = [.yearMonthDay, .hourMinute] }
        start.dateValue = copiedAfter ?? Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        end.dateValue = copiedBefore ?? Date()
        let fields = NSStackView(views: [NSTextField(labelWithString: L10n.text("开始（含）")), start, NSTextField(labelWithString: L10n.text("结束（含）")), end])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 110)
        alert.accessoryView = fields
        alert.beginLocalizedSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { self.datePopup.selectItem(at: self.lastDateIndex); return }
            guard start.dateValue <= end.dateValue else { self.datePopup.selectItem(at: self.lastDateIndex); self.statusLabel.stringValue = L10n.text("开始时间不能晚于结束时间"); return }
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
        if let record = selectedRecord { revealRecord(id: record.id, pinboardID: record.pinboardID) }
        else { resolveFocused { [weak self] in self?.revealRecord(id: $0.id, pinboardID: $0.pinboardID) } }
    }

    private func revealRecord(id: UUID, pinboardID: UUID?) {
        searchField.stringValue = ""
        selectedKind = nil; typePopup.selectItem(at: 0)
        selectedSourceID = nil; sourcePopup.selectItem(at: 0)
        selectedDeviceFilter = .all; devicePopup.selectItem(at: 0)
        copiedAfter = nil; copiedBefore = nil; datePopup.selectItem(at: 0)
        selectedBoardID = pinboardID
        manualOrder = pinboardID != nil
        pendingRevealID = id
        lastDateIndex = 0
        if let index = pinboards.firstIndex(where: { $0.id == pinboardID }) { boardPopup.selectItem(at: index + 1) } else { boardPopup.selectItem(at: 0) }
        issueQuery(resetLimit: true, preserveReveal: true)
        if !usesRemoteQuery, filteredRecords.contains(where: { $0.id == id }) { pendingRevealID = nil; select(id, focusResults: true) }
    }

    private func promptBoard(_ board: Pinboard?) {
        invalidateOutputContext()
        cancelBoundaryNavigation()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = board == nil ? L10n.text("新建分组") : L10n.text("编辑分组")
        alert.informativeText = L10n.text("固定的内容不受历史保留期限影响。")
        alert.addButton(withTitle: L10n.text("保存"))
        alert.addButton(withTitle: L10n.text("取消"))
        let name = NSTextField(string: board?.name ?? "")
        name.placeholderString = L10n.text("例如：常用回复、项目资料")
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 26))
        color.color = ClipboardCardView.hexColor(board?.color ?? "#4F7CFF") ?? .controlAccentColor
        color.setAccessibilityLabel(L10n.text("分组颜色"))
        let fields = NSStackView(views: [name, color])
        fields.orientation = .horizontal
        fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        alert.accessoryView = fields
        alert.beginLocalizedSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { self.statusLabel.stringValue = L10n.text("分组名称不能为空"); return }
            let hex = Self.hexString(color.color)
            if var board { board.name = value; board.color = hex; self.onUpdatePinboard?(board) }
            else { self.onCreatePinboard?(value, hex) }
        }
        alert.window.initialFirstResponder = name
    }

    @objc private func createBoard() { promptBoard(nil) }
    @objc private func renameBoard() { if let board = pinboards.first(where: { $0.id == boardScope.singleBoardID }) { promptBoard(board) } }
    @objc private func moveBoardEarlier() { reorderCurrentBoard(by: -1) }
    @objc private func moveBoardLater() { reorderCurrentBoard(by: 1) }
    private func reorderCurrentBoard(by offset: Int) {
        guard let index = pinboards.firstIndex(where: { $0.id == boardScope.singleBoardID }), pinboards.indices.contains(index + offset) else { return }
        var reordered = pinboards
        reordered.swapAt(index, index + offset)
        onReorderPinboards?(reordered.map(\.id))
    }
    @objc private func deleteBoard() {
        guard let board = pinboards.first(where: { $0.id == boardScope.singleBoardID }) else { return }
        // The application owns the destructive-action choices and confirmation.
        onDeletePinboard?(board)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyImageFileFromMenu(_:)), #selector(pasteImageFileFromMenu(_:)):
            guard let content = recordFromMenu(menuItem), !selection.isInvalid, !queryPending else { return false }
            return content.hasImageFileParts || (selectedIDs.contains(content.id) && selectedIDs.count > 1)
        case #selector(renameBoard), #selector(deleteBoard): return boardScope.singleBoardID != nil
        case #selector(moveBoardEarlier): return pinboards.firstIndex(where: { $0.id == boardScope.singleBoardID }).map { $0 > 0 } ?? false
        case #selector(moveBoardLater): return pinboards.firstIndex(where: { $0.id == boardScope.singleBoardID }).map { $0 + 1 < pinboards.count } ?? false
        case #selector(moveItemsEarlier), #selector(moveItemsLater), #selector(reorderEarlierFromMenu(_:)), #selector(reorderLaterFromMenu(_:)): return canReorderItems && !selectedIDs.isEmpty
        default: return true
        }
    }

    @objc private func moveFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String], let id = payload["recordID"].flatMap(UUID.init(uuidString:)) else { return }
        let context = NSMenuItem(); context.representedObject = id
        guard selectContextItemIfNeeded(context) else { return }
        moveReferences(selection.references, to: payload["boardID"].flatMap(UUID.init(uuidString:)))
    }

    private func showDetail(_ record: ClipboardRecord, editing: Bool) {
        guard isVisible else { return }
        cardViews.forEach { $0.cancelPendingDrag() }
        invalidateOutputContext()
        if detailWindow != nil {
            requestDetailClose { [weak self] in self?.showDetail(record, editing: editing) }
            return
        }
        linkPreview?.dismiss()
        imagePreview?.dismiss()
        filePreview?.dismiss()
        // Mixed-record edits select one object before routing by the aggregate kind.
        if editing, record.parts.count > 1 {
            showTextDetail(record, editing: true)
            return
        }
        // A file may also contain an embedded PDF; its reference-management entry
        // must remain reachable regardless of the other representations.
        if record.kind == .file || record.parts.flatMap(\.representations).contains(where: { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }) {
            showFileReferences(record)
            return
        }
        if record.kind == .image {
            detailWindow?.close()
            let session = viewGeneration
            let preview = makeImagePreview?(record, searchField.stringValue) ?? ImagePreviewController(record: record, searchQuery: searchField.stringValue,
                                                                                                     cache: ocrCache, sourceStore: ocrSourceStore)
            imagePreview = preview
            preview.onDismiss = { [weak self, weak preview] in
                guard let self, self.imagePreview === preview else { return }
                self.imagePreview = nil
                if self.isVisible, self.viewGeneration == session { self.window?.makeKey(); self.window?.makeFirstResponder(self.resultsView) }
            }
            let current: () -> Bool = { [weak self, weak preview] in
                guard let self, let preview else { return false }
                return self.isVisible && self.viewGeneration == session && self.imagePreview === preview
            }
            preview.isContextCurrent = current
            preview.onPrepareEdit = { [weak self] ref, reply in
                guard current(), let callback = self?.onPrepareEdit else { return }
                callback(ref) { result in guard current() else { return }; reply(result) }
            }
            preview.onEdit = { [weak self] snapshot, edited, reply in
                guard current(), let callback = self?.onEdit else { return }
                callback(snapshot, edited) { result in guard current() else { return }; reply(result) }
            }
            if onPrepareEdit == nil { preview.onPrepareEdit = nil }
            if onEdit == nil { preview.onEdit = nil }
            preview.onCommitted = { [weak self] original, committed in
                guard let self, current() else { return }
                let ref = ClipboardSelectionReference(id: committed.id, revision: committed.revision)
                guard ref.id == original.id, ref.revision > original.revision else { return }
                let refs = self.selection.references.map { $0 == original ? ref : $0 }
                try? self.selection.adoptCommitted(refs)
                self.updateSelectionAppearance()
            }
            preview.onExtractText = { [weak self] latest in self?.onExtractText?(latest) }
            preview.present(relativeTo: window)
            return
        }
        if let pdf = record.parts.flatMap(\.representations).first(where: { ClipboardCardContent.isPDFType($0.typeIdentifier) }) {
            showPDFPreview(record, data: pdf.data)
            return
        }
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
        showTextDetail(record, editing: editing)
    }

    private func showTextDetail(_ record: ClipboardRecord, editing: Bool, renameReference: ClipboardSelectionReference? = nil,
                                partIndex: Int? = nil) {
        let renaming = renameReference != nil
        let detail = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        detail.title = renaming ? L10n.text("重命名条目") : (editing ? L10n.text("编辑剪贴板内容") : L10n.text("预览剪贴板内容"))
        detail.level = .floating; detail.hidesOnDeactivate = false
        detail.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        detail.isReleasedWhenClosed = false; detail.minSize = NSSize(width: 440, height: 320)
        detail.delegate = self
        detailRecord = record; detailWindow = detail
        detailSession = UUID(); detailParentSession = viewGeneration; detailIsEditing = editing
        detailIsRenaming = renaming
        detailPartIndex = editing && !renaming && record.parts.count > 1
            ? (partIndex ?? ClipboardEditPlan.editablePartIndices(original: record).first ?? 0) : nil
        if detailPartIndex != nil { detail.minSize = NSSize(width: 440, height: 360) }
        detailPrepareReference = renameReference ?? .init(id: record.id, revision: record.revision)
        configureDetailEditingRecord(record)
        let root = NSView(); detail.contentView = root
        defer { InterfaceLayout.apply(to: root, direction: layoutDirection) }
        let context = NSTextField(labelWithString: renaming ? L10n.text("正在读取条目…") : "\(record.sourceApp ?? L10n.text("剪贴板")) · \(L10n.date(record.copiedAt))")
        detailContextLabel = context
        context.font = .systemFont(ofSize: 11); context.textColor = .secondaryLabelColor
        context.lineBreakMode = .byTruncatingTail
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = ShelfEditTextView(frame: .zero)
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = !renaming
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .complete }
        editor.importsGraphics = false; editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 12, height: 12); editor.font = .systemFont(ofSize: 14)
        editor.autoresizingMask = [.width]; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if !renaming { loadDetailContents(record, into: editor) }
        editor.setAccessibilityLabel(renaming ? L10n.text("条目名称") : (editing ? L10n.text("编辑内容") : L10n.text("内容预览")))
        editor.delegate = self; detailEditor = editor
        for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
            detailUndoObservers.append(NotificationCenter.default.addObserver(forName: name, object: editor.draftUndoManager, queue: .main) { [weak self, weak editor] _ in
                MainActor.assumeIsolated {
                    guard let self, let editor, self.detailEditor === editor else { return }
                    self.detailError = nil; self.updateDetailEditingState()
                }
            })
        }
        initialDetailContents = NSAttributedString(attributedString: editor.attributedString())
        scroll.documentView = editor
        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; note.maximumNumberOfLines = 4
        note.setAccessibilityIdentifier("editor.note"); detailNote = note
        let error = NSTextField(wrappingLabelWithString: "")
        error.font = .systemFont(ofSize: 11); error.maximumNumberOfLines = 3
        error.setAccessibilityLabel(L10n.text("编辑状态")); detailStatus = error
        let cancel = NSButton(title: editing ? L10n.text("放弃修改") : L10n.text("关闭"), target: self, action: editing ? #selector(discardDetail) : #selector(closeDetail))
        cancel.bezelStyle = .rounded
        let primary = NSButton(title: editing ? L10n.text("保存修改") : L10n.text("编辑"), target: self, action: editing ? #selector(saveDetail) : #selector(editDetail))
        primary.bezelStyle = .rounded; detailPrimary = primary
        // Return is never a button equivalent: text may contain line breaks.
        let actions = NSStackView(views: [cancel, primary])
        if editing && !renaming {
            let picker = NSColorWell(frame: NSRect(x: 0, y: 0, width: 48, height: 25))
            picker.color = ClipboardEditPlan.color(from: detailEditingRecord?.text ?? "") ?? .controlAccentColor
            picker.target = self; picker.action = #selector(colorChanged(_:)); picker.setAccessibilityLabel(L10n.text("选择颜色"))
            detailColorWell = picker; actions.insertArrangedSubview(picker, at: 0)
        }
        actions.orientation = .horizontal; actions.spacing = 8
        for view in [context, scroll, note, error, actions] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        var scrollTop = context.bottomAnchor
        if detailPartIndex != nil {
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.target = self; picker.action = #selector(changeDetailPart(_:))
            picker.setAccessibilityLabel(L10n.text("编辑对象")); picker.setAccessibilityIdentifier("editor.part")
            picker.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(picker)
            detailPartPicker = picker; populateDetailParts(record)
            NSLayoutConstraint.activate([
                picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                picker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                picker.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 10)
            ])
            scrollTop = picker.bottomAnchor
        }
        updateDetailNote()
        NSLayoutConstraint.activate([
            context.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), context.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), context.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), scroll.topAnchor.constraint(equalTo: scrollTop, constant: 14), scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), note.bottomAnchor.constraint(equalTo: error.topAnchor, constant: -8),
            error.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), error.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), error.heightAnchor.constraint(greaterThanOrEqualToConstant: 30), error.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20), actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        detail.setFrameOrigin(NSPoint(x: screen.midX - 310, y: screen.midY - 230))
        presentDetail(detail)
        detail.makeFirstResponder(editor)
        if editing { prepareDetailEdit() } else { updateDetailEditingState() }
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
        pdf.setAccessibilityLabel(L10n.text("只读 PDF 文稿预览"))
        detailPDFView = pdf
        let page = NSTextField(labelWithString: L10n.text("正在读取 PDF…"))
        page.textColor = .secondaryLabelColor; page.font = .systemFont(ofSize: 11)
        let previous = NSButton(title: L10n.text("上一页"), target: pdf, action: #selector(PDFView.goToPreviousPage(_:)))
        let next = NSButton(title: L10n.text("下一页"), target: pdf, action: #selector(PDFView.goToNextPage(_:)))
        let zoomOut = NSButton(title: L10n.text("缩小"), target: pdf, action: #selector(PDFView.zoomOut(_:)))
        let zoomIn = NSButton(title: L10n.text("放大"), target: pdf, action: #selector(PDFView.zoomIn(_:)))
        let close = NSButton(title: L10n.text("返回列表"), target: self, action: #selector(closeDetail)); close.keyEquivalent = "\u{1b}"
        let controls = NSStackView(views: [previous, next, zoomOut, zoomIn, close]); controls.spacing = 8
        let note = NSTextField(labelWithString: L10n.text("只读预览 · 保留原始 PDF · 不打开文稿内的外部链接"))
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
        let root = NSView(); detail.contentView = root
        defer { InterfaceLayout.apply(to: root, direction: layoutDirection) }
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
            page?.stringValue = L10n.text("第 \(index) / \(document.pageCount) 页")
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
                guard let document = prepared.document, !document.isLocked, document.pageCount > 0 else { page?.stringValue = L10n.text("PDF 已加密或无法读取；原始内容保留。"); return }
                pdf?.document = document
                updatePage()
            }
        }
        if let frame = (window?.screen ?? NSScreen.main)?.visibleFrame {
            detail.setFrameOrigin(NSPoint(x: frame.midX - 360, y: frame.midY - 320))
        }
        window?.addChildWindow(detail, ordered: .above)
        InterfaceLayout.apply(to: detail.contentView, direction: layoutDirection)
        detail.makeKeyAndOrderFront(nil); detail.makeFirstResponder(pdf)
    }

    func showFileReferences(_ record: ClipboardRecord, preferUnavailable: Bool = false) {
        guard isVisible else { return }
        cardViews.forEach { $0.cancelPendingDrag() }
        invalidateOutputContext()
        if detailWindow != nil {
            requestDetailClose { [weak self] in self?.showFileReferences(record, preferUnavailable: preferUnavailable) }
            return
        }
        cancelBoundaryNavigation(); pendingActionID = nil
        linkPreview?.dismiss(); imagePreview?.dismiss(); detailWindow?.close(); filePreview?.dismiss()
        let preview = makeFilePreview?(record, preferUnavailable) ?? FileReferencePreviewController(record: record, preferUnavailable: preferUnavailable)
        preview.publications = publications
        let session = viewGeneration, scope = scopeGeneration
        filePreview = preview
        let current: () -> Bool = { [weak self, weak preview] in
            guard let self, let preview else { return false }
            return self.isVisible && self.viewGeneration == session && self.scopeGeneration == scope && self.filePreview === preview
        }
        preview.isContextCurrent = current
        preview.onSnapshot = { [weak self] ref, reply in
            guard current(), let callback = self?.onFileSnapshot else { reply(.failure(ClipboardFileRepairError.invalidReference)); return }
            callback(ref, reply)
        }
        preview.onRelocate = { [weak self] snapshot, file, url, reply in
            guard current(), let self, let callback = self.onRelocateFile else { reply(.failure(ClipboardFileRepairError.invalidReference)); return }
            callback(snapshot, file, url) { [weak self] result in
                guard current() else { return }
                if case .success(let updated) = result { self?.adoptFileRepair(from: snapshot, to: updated) }
                reply(result)
            }
        }
        preview.onRestoreOwned = { [weak self] snapshot, file, reply in
            guard current(), let self, let callback = self.onRestoreOwnedFile else { reply(.failure(ClipboardFileRepairError.invalidReference)); return }
            callback(snapshot, file) { result in guard current() else { return }; reply(result) }
        }
        // Callback availability controls buttons; do not show an enabled mutation
        // that can only fail because the host does not support it.
        if onRelocateFile == nil { preview.onRelocate = nil }
        if onRestoreOwnedFile == nil { preview.onRestoreOwned = nil }
        preview.onDismiss = { [weak self, weak preview] in
            guard let self, self.filePreview === preview else { return }
            self.filePreview = nil
            if self.isVisible, self.viewGeneration == session, self.scopeGeneration == scope {
                self.window?.makeKey(); self.window?.makeFirstResponder(self.resultsView)
            }
        }
        preview.present(relativeTo: window)
    }

    private func adoptFileRepair(from old: ClipboardFileRepairSnapshot, to updated: ClipboardFileRepairSnapshot) {
        guard updated.record.id == old.record.id,
              selection.references.first(where: { $0.id == old.record.id })?.revision == old.record.revision else { return }
        let refs = selection.references.map { $0.id == updated.record.id ? ClipboardSelectionReference(id: $0.id, revision: updated.record.revision) : $0 }
        do { try selection.adoptCommitted(refs); selectionStatus = nil; updateSelectionAppearance() }
        catch { selectionFailed(error) }
    }

    func ownsWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        if detailColorWell?.isActive == true, candidate === NSColorPanel.shared { return true }
        if filePreview?.ownsWindow(candidate) == true { return true }
        var current: NSWindow? = candidate
        while let next = current {
            if next === window || next === detailWindow || next === linkPreview?.window || next === imagePreview?.window { return true }
            current = next.sheetParent ?? next.parent
        }
        return false
    }

    func contains(screenPoint: NSPoint) -> Bool {
        if detailColorWell?.isActive == true, NSColorPanel.shared.isVisible, NSColorPanel.shared.frame.contains(screenPoint) { return true }
        if let sheet = detailWindow?.attachedSheet, sheet.isVisible, sheet.frame.contains(screenPoint) { return true }
        return [window, detailWindow, linkPreview?.window, imagePreview?.window].compactMap { $0 }
            .contains { $0.isVisible && $0.frame.contains(screenPoint) } || filePreview?.contains(screenPoint: screenPoint) == true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            if detailIsDirty || detailSaveID != nil { hidePreservingDraft() }
            filePreview?.dismiss()
            cardViews.forEach { $0.cancelPendingDrag() }
            pageRequestID = nil
            queryPending = false
            refreshAfterPageLoad = false
            viewGeneration = UUID()
            pendingActionID = nil
            return
        }
        guard closing === detailWindow else { return }
        retireDiscardPrompt()
        if detailColorWell?.isActive == true { NSColorPanel.shared.orderOut(nil) }
        detailColorWell?.deactivate()
        if let detailEventMonitor { NSEvent.removeMonitor(detailEventMonitor); self.detailEventMonitor = nil }
        detailUndoObservers.forEach(NotificationCenter.default.removeObserver); detailUndoObservers.removeAll()
        window?.removeChildWindow(closing)
        detailWindow = nil
        pdfLoadTask?.cancel(); pdfLoadTask = nil
        detailPDFView?.document = nil; detailPDFView = nil
        if let pdfPageObserver { NotificationCenter.default.removeObserver(pdfPageObserver); self.pdfPageObserver = nil }
        detailRecord = nil
        detailEditor = nil
        initialDetailContents = nil
        detailSnapshot = nil; detailSession = UUID(); detailPrepareID = nil; detailSaveID = nil
        detailIsEditing = false; detailHidden = false; detailPrimary = nil; detailStatus = nil
        detailColorWell = nil; detailError = nil
        detailStructureError = nil; detailIsRenaming = false; detailPrepareReference = nil; detailContextLabel = nil
        detailPartIndex = nil; detailPartPicker = nil; detailEditingRecord = nil; detailNote = nil
        if isVisible { window?.makeKey(); window?.makeFirstResponder(resultsView) }
    }

    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow, resized === window else { return }
        if isVisible, !applyingPresentationGeometry {
            let height = PanelPresentationGeometry.preferredHeight(resized.frame.height, compact: compactMode)
            if compactMode { preferredCompactHeight = height } else { preferredNormalHeight = height }
            onPreferredHeightChange?(compactMode, height)
        }
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

    private var detailIsDirty: Bool {
        guard detailIsEditing, let editor = detailEditor, let original = initialDetailContents else { return false }
        return !editor.attributedString().isEqual(to: original)
    }

    private func detailContextIsCurrent(_ detail: NSPanel, session: UUID) -> Bool {
        detailWindow === detail && detailSession == session && detailParentSession == viewGeneration
    }

    private func presentDetail(_ detail: NSPanel) {
        InterfaceLayout.apply(to: detail.contentView, direction: layoutDirection)
        if let presentDetailPanel { presentDetailPanel(detail, window) }
        else {
            if detail.parent == nil { window?.addChildWindow(detail, ordered: .above) }
            detail.makeKeyAndOrderFront(nil)
        }
        guard detailEventMonitor == nil else { return }
        detailEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.detailWindow,
                  (self.detailWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return event }
            let flags = ShortcutChord.normalizedModifiers(event.modifierFlags)
            if event.keyCode == 53 || (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
                if !event.isARepeat { self.closeDetail() }
                return nil
            }
            return event
        }
    }

    private func configureDetailEditingRecord(_ record: ClipboardRecord) {
        detailEditingRecord = nil; detailStructureError = nil
        guard detailIsEditing, !detailIsRenaming else { return }
        do {
            let index = detailPartIndex ?? (record.parts.count == 1 ? 0 : nil)
            let projected = try index.map { try ClipboardEditPlan.partRecord(original: record, partIndex: $0) } ?? record
            detailEditingRecord = projected
            detailStructureError = ClipboardEditPlan.editingError(original: projected)
        } catch { detailStructureError = error }
    }

    private func detailPartSummary(_ record: ClipboardRecord, index: Int) -> String {
        if let projected = try? ClipboardEditPlan.partRecord(original: record, partIndex: index) {
            return String(projected.text.prefix(256).split(whereSeparator: { $0.isNewline }).joined(separator: " ").prefix(72))
        }
        let part = record.parts[index]
        if let file = part.representations.first(where: { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }),
           let value = String(data: file.data.prefix(4_096), encoding: .utf8), let url = URL(string: value) {
            return String(url.lastPathComponent.prefix(72))
        }
        return ClipboardRecord(text: "", parts: [part]).title
    }

    private func populateDetailParts(_ record: ClipboardRecord) {
        guard let picker = detailPartPicker else { return }
        let editable = Set(ClipboardEditPlan.editablePartIndices(original: record))
        picker.removeAllItems()
        for index in record.parts.indices {
            let state = editable.contains(index) ? L10n.text("可编辑") : L10n.text("只读")
            let summary = detailPartSummary(record, index: index)
            picker.addItem(withTitle: L10n.text("对象 \(index + 1)：\(summary) · \(state)"))
            picker.lastItem?.tag = index
        }
        if let index = detailPartIndex { picker.selectItem(withTag: index) }
    }

    @objc private func changeDetailPart(_ sender: NSPopUpButton) {
        guard let current = detailPartIndex else { return }
        let target = sender.selectedTag()
        // Keep the selector on the current draft while a discard decision is pending.
        sender.selectItem(withTag: current)
        guard target != current, detailPrepareID == nil, detailSaveID == nil,
              detailDiscardID == nil, detailSnapshot != nil,
              let record = detailRecord, record.parts.indices.contains(target) else { return }
        requestDetailClose { [weak self] in
            guard let self, self.isVisible else { return }
            self.showTextDetail(record, editing: true, partIndex: target)
        }
    }

    private func updateDetailNote() {
        let projected = detailEditingRecord ?? (detailPartIndex == nil ? detailRecord : nil)
        let htmlOnly = projected.map { Self.detailRTF($0) == nil && ($0.html != nil || $0.parts.flatMap(\.representations).contains { $0.typeIdentifier == "public.html" }) } ?? false
        var note: String
        if detailIsRenaming { note = L10n.text("名称用于查找和识别，不会修改粘贴的内容。留空可恢复自动名称。") }
        else if detailIsEditing && htmlOnly { note = L10n.text("此条目仅有 HTML 格式；修改后将保存为文本及原生富文本。未修改保存会保留原格式。") }
        else if detailIsEditing { note = L10n.text("保存成功后更新当前条目。关闭未保存的草稿时可选择继续编辑。") }
        else { note = L10n.text("内容只读；编辑不会立即粘贴到其他 App。") }
        if detailPartIndex != nil { note += "\n" + L10n.text("本次仅修改选中的对象，其他对象保持原样。") }
        detailNote?.stringValue = note
        detailColorWell?.isHidden = detailEditingRecord?.kind != .color || detailIsRenaming
    }

    private func loadDetailContents(_ record: ClipboardRecord, into editor: NSTextView) {
        if detailIsRenaming { editor.string = record.title }
        else if detailIsEditing, let index = detailPartIndex ?? (record.parts.count == 1 ? 0 : nil) {
            do { editor.textStorage?.setAttributedString(try ClipboardEditPlan.partContents(original: record, partIndex: index)) }
            catch {
                detailStructureError = error
                editor.string = record.parts.indices.contains(index) ? detailPartSummary(record, index: index) : ""
            }
        }
        else if let data = Self.detailRTF(record), let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            editor.textStorage?.setAttributedString(attributed)
        } else { editor.string = record.text }
        (editor as? ShelfEditTextView)?.draftUndoManager.removeAllActions()
    }

    private static func detailRTF(_ record: ClipboardRecord) -> Data? {
        record.rtf ?? record.parts.flatMap(\.representations).first { $0.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue }?.data
    }

    private func prepareDetailEdit() {
        guard detailIsEditing, let detail = detailWindow, let record = detailRecord,
              detailPrepareID == nil, detailSaveID == nil else { return }
        guard let onPrepareEdit else {
            detailError = L10n.text("当前模式无法开始编辑。原内容已保留。"); updateDetailEditingState(); return
        }
        let token = UUID(), session = detailSession
        let expected = detailPrepareReference ?? ClipboardSelectionReference(id: record.id, revision: record.revision)
        detailPrepareID = token; detailError = nil; updateDetailEditingState()
        onPrepareEdit(expected) { [weak self, weak detail] result in
            guard let self, let detail, self.detailContextIsCurrent(detail, session: session), self.detailPrepareID == token else { return }
            self.detailPrepareID = nil
            switch result {
            case .success(let snapshot):
                guard snapshot.record.id == expected.id, snapshot.record.revision == expected.revision else {
                    self.detailError = L10n.text("条目已变化，请关闭后重新打开；没有覆盖原内容。")
                    self.updateDetailEditingState(); return
                }
                self.detailSnapshot = snapshot; self.detailRecord = snapshot.record
                self.configureDetailEditingRecord(snapshot.record)
                self.populateDetailParts(snapshot.record)
                self.detailContextLabel?.stringValue = "\(snapshot.record.sourceApp ?? L10n.text("剪贴板")) · \(L10n.date(snapshot.record.copiedAt))"
                if let editor = self.detailEditor {
                    self.loadDetailContents(snapshot.record, into: editor)
                    self.initialDetailContents = NSAttributedString(attributedString: editor.attributedString())
                }
                self.detailError = nil
                self.updateDetailNote()
            case .failure(let error): self.detailError = error.localizedDescription
            }
            self.updateDetailEditingState()
        }
    }

    private func updateDetailEditingState() {
        guard let editor = detailEditor else { return }
        guard detailIsEditing else { detailPrimary?.isEnabled = onPrepareEdit != nil && onEdit != nil; return }
        let structural = detailStructureError
        let validation = detailIsRenaming ? nil : detailEditingRecord.flatMap { ClipboardEditPlan.validationError(original: $0, text: editor.string) }
        let busy = detailPrepareID != nil || detailSaveID != nil || detailDiscardID != nil
        let editable = detailSnapshot != nil && structural == nil && !busy
        editor.isEditable = editable
        (editor as? ShelfEditTextView)?.locksEdits = !editable
        detailColorWell?.isEnabled = editable
        detailPartPicker?.isEnabled = !busy && detailSnapshot != nil
        if let color = ClipboardEditPlan.color(from: editor.string), detailColorWell != nil { detailColorWell?.color = color }
        detailPrimary?.title = detailSnapshot == nil && detailPrepareID == nil ? L10n.text("重试读取") : (detailSaveID == nil ? L10n.text("保存修改") : L10n.text("正在保存…"))
        let canSave = detailPartIndex == nil ? onEdit != nil : onEditPart != nil
        detailPrimary?.isEnabled = !busy && (detailSnapshot == nil ? onPrepareEdit != nil : (structural == nil && validation == nil && canSave))
        let message: String
        if detailPrepareID != nil { message = L10n.text("正在检查条目与编辑权限…") }
        else if detailSaveID != nil { message = L10n.text("正在保存，草稿暂时只读；放弃或关闭不会撤回已提交的保存。") }
        else { message = detailError ?? structural?.localizedDescription ?? validation?.localizedDescription ?? "" }
        detailStatus?.stringValue = message; detailStatus?.toolTip = message
        detailStatus?.textColor = busy ? .secondaryLabelColor : .labelColor
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === detailEditor, detailIsEditing else { return }
        detailError = nil; updateDetailEditingState()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        textView !== detailEditor || (detailIsEditing && detailSnapshot != nil && detailPrepareID == nil && detailSaveID == nil && detailDiscardID == nil && detailStructureError == nil)
    }

    private func requestDetailClose(onCancel: (() -> Void)? = nil, _ continuation: @escaping () -> Void) {
        guard let detail = detailWindow else { continuation(); return }
        guard detailIsDirty else { detail.close(); continuation(); return }
        guard detailDiscardID == nil else { onCancel?(); return }
        if detailHidden {
            detailHidden = false; window?.makeKeyAndOrderFront(nil); installEventMonitor(); presentDetail(detail)
        }
        let token = UUID(), session = detailSession
        detailDiscardID = token
        detailDiscardCancelled = onCancel
        updateDetailEditingState()
        let reply: (Bool) -> Void = { [weak self, weak detail] discard in
            guard let self, let detail, self.detailContextIsCurrent(detail, session: session), self.detailDiscardID == token else { return }
            self.detailDiscardID = nil; self.cancelDetailDiscard = nil
            self.detailDiscardCancelled = nil
            self.updateDetailEditingState()
            if discard { detail.close(); continuation() }
            else { onCancel?() }
        }
        let cancel: () -> Void
        if let confirmDiscardEdits { cancel = confirmDiscardEdits(detail, reply) }
        else {
            let alert = NSAlert()
            alert.messageText = L10n.text("保留当前修改继续编辑？")
            alert.informativeText = detailSaveID == nil ? L10n.text("放弃后会关闭此草稿，已保存的剪贴板内容不受影响。") : L10n.text("保存请求已提交；关闭草稿不会撤回可能已经完成的保存。")
            alert.addButton(withTitle: L10n.text("继续编辑")); alert.addButton(withTitle: L10n.text("放弃修改"))
            alert.beginLocalizedSheetModal(for: detail) { reply($0 == .alertSecondButtonReturn) }
            cancel = { [weak detail, weak alert] in
                guard let detail, let alert, alert.window.sheetParent === detail else { return }
                detail.endSheet(alert.window, returnCode: .cancel)
            }
        }
        if detailDiscardID == token { cancelDetailDiscard = cancel }
    }

    private func retireDiscardPrompt() {
        detailDiscardID = nil
        let cancelled = detailDiscardCancelled; detailDiscardCancelled = nil
        let cancel = cancelDetailDiscard; cancelDetailDiscard = nil; cancel?()
        cancelled?()
        updateDetailEditingState()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === detailWindow, detailIsDirty { requestDetailClose({}); return false }
        if sender === window, detailIsDirty { dismiss(); return false }
        return true
    }

    @objc private func closeDetail() { requestDetailClose({}) }
    @objc private func discardDetail() { detailWindow?.close() }
    private static func hexString(_ color: NSColor) -> String {
        ClipboardEditPlan.hexString(for: color) ?? "#4F7CFF"
    }
    @objc private func colorChanged(_ sender: NSColorWell) {
        guard detailIsEditing, detailSaveID == nil, detailPrepareID == nil, detailSnapshot != nil,
              detailDiscardID == nil, detailEditingRecord?.kind == .color,
              let editor = detailEditor, editor.isEditable, let text = ClipboardEditPlan.hexString(for: sender.color) else { return }
        let range = NSRange(location: 0, length: editor.attributedString().length)
        editor.breakUndoCoalescing()
        if editor.shouldChangeText(in: range, replacementString: text) {
            editor.textStorage?.replaceCharacters(in: range, with: text)
            editor.didChangeText()
        }
        editor.breakUndoCoalescing()
    }
    @objc private func extractDetail() { if let record = detailRecord { requestDetailClose { [weak self] in self?.onExtractText?(record) } } }
    @objc private func editDetail() { if let record = detailRecord { showDetail(record, editing: true) } }
    @objc private func saveDetail() {
        guard detailIsEditing, detailSaveID == nil, detailPrepareID == nil, detailDiscardID == nil else { return }
        guard let snapshot = detailSnapshot else { prepareDetailEdit(); return }
        guard let detail = detailWindow, let editor = detailEditor, detailStructureError == nil else { return }
        if !detailIsRenaming, let original = detailEditingRecord,
           let error = ClipboardEditPlan.validationError(original: original, text: editor.string) {
            detailError = error.localizedDescription; updateDetailEditingState(); return
        }
        guard detailIsDirty else { detail.close(); return }
        let submit: (@escaping (Result<ClipboardSelectionReference, Error>) -> Void) -> Void
        do {
            if let index = detailPartIndex {
                guard let onEditPart else { return }
                let contents = NSAttributedString(attributedString: editor.attributedString())
                let edited = try makeEditedPart?(snapshot.record, index, contents)
                    ?? ClipboardEditPlan.makePartEdit(original: snapshot.record, partIndex: index, contents: contents)
                submit = { reply in onEditPart(snapshot, edited, reply) }
            } else {
                guard let onEdit else { return }
                let submitted: ClipboardRecord
                if detailIsRenaming {
                    var renamed = snapshot.record
                    renamed.renamedTitle = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    submitted = renamed
                } else {
                    let contents = NSAttributedString(attributedString: editor.attributedString())
                    submitted = try makeEditedRecord?(snapshot.record, contents) ?? ClipboardEditPlan.makeRecord(original: snapshot.record, contents: contents)
                }
                submit = { reply in onEdit(snapshot, submitted, reply) }
            }
        } catch { detailError = error.localizedDescription; updateDetailEditingState(); return }
        let token = UUID(), session = detailSession
        detailSaveID = token; detailError = nil; updateDetailEditingState()
        submit { [weak self, weak detail] result in
            guard let self, let detail, self.detailContextIsCurrent(detail, session: session), self.detailSaveID == token else { return }
            self.detailSaveID = nil
            switch result {
            case .success(let committed):
                guard committed.id == snapshot.record.id, committed.revision > snapshot.record.revision else {
                    self.detailError = L10n.text("保存回执不匹配，请保留草稿并重试。"); self.updateDetailEditingState(); return
                }
                let refs = self.selection.references.map { $0.id == committed.id && $0.revision == snapshot.record.revision ? committed : $0 }
                try? self.selection.adoptCommitted(refs)
                detail.close()
            case .failure(let error):
                self.detailError = error.localizedDescription; self.updateDetailEditingState()
            }
        }
    }

    /// Naming needs only the captured identity/version until prepareEdit returns
    /// its single authoritative payload and account-bound editing snapshot.
    func rename(_ reference: ClipboardSelectionReference) {
        guard isVisible else { return }
        cardViews.forEach { $0.cancelPendingDrag() }; invalidateOutputContext()
        if detailWindow != nil {
            requestDetailClose { [weak self] in self?.rename(reference) }
            return
        }
        linkPreview?.dismiss(); imagePreview?.dismiss(); filePreview?.dismiss()
        let placeholder = ClipboardRecord(id: reference.id, text: "", revision: reference.revision)
        showTextDetail(placeholder, editing: true, renameReference: reference)
    }

    @objc private func pasteFromMenu(_ sender: NSMenuItem) { if selectContextItemIfNeeded(sender) { pasteSelection(plain: false) } }
    @objc private func pastePlainFromMenu(_ sender: NSMenuItem) { if selectContextItemIfNeeded(sender) { pasteSelection(plain: true) } }
    @objc private func copyFromMenu(_ sender: NSMenuItem) { if selectContextItemIfNeeded(sender) { copySelection() } }
    @objc private func openFromMenu(_ sender: NSMenuItem) { guard detailWindow == nil else { return }; if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.onOpenRecord?($0) } } }
    @objc private func deleteFromMenu(_ sender: NSMenuItem) { if selectContextItemIfNeeded(sender) { deleteSelection() } }
    @objc private func previewFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.showDetail($0, editing: false) } } }
    @objc private func relocateFileFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.showFileReferences($0, preferUnavailable: true) } } }
    @objc private func editFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record) { [weak self] in self?.showDetail($0, editing: true) } } }
    @objc private func renameFromMenu(_ sender: NSMenuItem) { if let content = recordFromMenu(sender) { rename(reference(content)) } }
    @objc private func shareFromMenu(_ sender: NSMenuItem) { if let record = recordFromMenu(sender) { resolve(record, forOutput: true) { [weak self] in self?.onShareRecord?($0) } } }
    private func outputImageFilesFromMenu(_ sender: NSMenuItem, paste: Bool) {
        guard selectContextItemIfNeeded(sender) else { return }
        window?.makeFirstResponder(resultsView)
        resolveReferences(selection.references, forOutput: true) { [weak self] records in
            self?.onImageFileOutput?(records, paste)
        }
    }
    @objc private func copyImageFileFromMenu(_ sender: NSMenuItem) { outputImageFilesFromMenu(sender, paste: false) }
    @objc private func pasteImageFileFromMenu(_ sender: NSMenuItem) { outputImageFilesFromMenu(sender, paste: true) }
    @objc private func togglePause() { onPauseToggle?() }
    @objc private func openPermissions() { onPermissions?() }
    @objc private func closePanel() { dismiss() }
}
